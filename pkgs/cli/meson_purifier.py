# SPDX-License-Identifier: MIT
"""meson-purifier: Nix as the download backend of Meson subprojects.

`meson-purifier lock` reads the wrap files of a Meson project with Meson's own
wrap code, fetches every source they name, and writes
meson-purifier.lock.json beside meson.build. Every other command runs Meson
with its package cache (MESON_PACKAGE_CACHE_DIR) set to a tree that Nix
builds from that lockfile, and with downloads disabled.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

LOCK_NAME = "meson-purifier.lock.json"
LOCK_VERSION = 1
# Where interactive commands keep the GC root of the realized package cache,
# relative to the project root.
STATE_DIR = ".meson-purifier"
WRAPDB_URL = "https://wrapdb.mesonbuild.com/v2"
# The start of a wrap file that only redirects to a wrap in a subproject.
REDIRECT = b"[wrap-redirect]"

# Set by the package: the directory of the Nix library, the nixpkgs the
# interactive commands build the package cache with, and the meson binary.
NIX_LIB = os.environ.get("MESON_PURIFIER_NIX_LIB", "")
NIXPKGS = os.environ.get("MESON_PURIFIER_NIXPKGS", "")


class PurifierError(Exception):
    pass


def log(message: str) -> None:
    print(f"meson-purifier: {message}", file=sys.stderr)


def real_meson() -> str:
    """The meson binary that interactive commands run.

    The package sets MESON_PURIFIER_MESON, because the `meson` on PATH may be
    meson-purifier's own wrapper.
    """
    return os.environ.get("MESON_PURIFIER_MESON", "meson")


# ---------------------------------------------------------------------------
# Hashes and names shared with the Nix library


def sri_from_hex(hexdigest: str) -> str:
    """The SRI form of a SHA-256 hex digest, as wrap files write them."""
    return "sha256-" + base64.b64encode(bytes.fromhex(hexdigest)).decode()


def store_name(path: str) -> str:
    """A store path name for a cache path; nix/lib/lock.nix has the same rule.

    Store path names allow [A-Za-z0-9+._?=-], must not start with a dot, and
    are at most 211 characters. Every other character becomes "_", and a
    long name keeps its end.
    """
    replaced = re.sub(r"[^A-Za-z0-9+._?=-]", "_", path)
    if len(replaced) > 200:
        replaced = replaced[-200:]
    undotted = replaced.lstrip(".")
    return undotted or "file"


def subprojects_dir_of(project: Path) -> str:
    """The subproject directory that project() in meson.build names."""
    build = project / "meson.build"
    if build.is_file():
        text = build.read_text(encoding="utf-8", errors="replace")
        match = re.search(r"subproject_dir\s*:\s*'([^']*)'", text)
        if match:
            return match.group(1)
    return "subprojects"


DEFINITION_FILES = ("meson.build", "meson.options", "meson_options.txt")


def definition_files(project: Path, subprojects_dir: str) -> list:
    """The build definition of the project: its meson.build and option
    files, as paths relative to the project root, in byte order.

    The subproject directory, directories whose name starts with a dot, and
    Meson build directories (the ones holding meson-private) are left out.
    """
    found = []
    for directory, dirs, files in os.walk(project):
        rel_dir = os.path.relpath(directory, project)
        rel_dir = "" if rel_dir == "." else rel_dir
        dirs[:] = [
            d
            for d in dirs
            if not d.startswith(".")
            and os.path.join(rel_dir, d) != subprojects_dir
            and not os.path.isdir(os.path.join(directory, d, "meson-private"))
        ]
        found += [os.path.join(rel_dir, f) for f in files if f in DEFINITION_FILES]
    return sorted(found)


def inputs_hash(
    project: Path, subprojects_dir: str, installed: frozenset = frozenset()
) -> str:
    """The hash of the files a lock run reads; nix/lib/inputs-hash.nix has
    the same rule.

    They are the wrap files and wrapdb.json in the subproject directory, a
    Cargo.lock at the project root, and the build definition (see
    definition_files), each as its path, a newline, its contents and a
    newline, in byte order of the paths within each group. Two kinds of wrap
    file are left out. The ones named in `installed` are the wraps the
    lockfile itself installs from wrapdb.json. A file that starts with
    [wrap-redirect] only selects a wrap that a subproject carries; Meson
    writes one when it uses such a wrap, and the lock run locks every wrap
    that a subproject carries.
    """
    directory = project / subprojects_dir
    data = b""
    if directory.is_dir():
        names = sorted(
            name
            for name in os.listdir(directory)
            if (name.endswith(".wrap") or name == "wrapdb.json")
            and name not in installed
            and (directory / name).is_file()
        )
        for name in names:
            content = (directory / name).read_bytes()
            if content.startswith(REDIRECT):
                continue
            data += name.encode() + b"\n" + content + b"\n"
    cargo = project / "Cargo.lock"
    if cargo.is_file():
        data += b"Cargo.lock\n" + cargo.read_bytes() + b"\n"
    for rel in definition_files(project, subprojects_dir):
        data += rel.encode() + b"\n" + (project / rel).read_bytes() + b"\n"
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------------------
# Fetching during a lock run


def run(args: list, **kwargs) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(args, check=True, **kwargs)
    except FileNotFoundError as e:
        raise PurifierError(f"{args[0]} is not installed") from e


def nix_hash_path(path: Path) -> str:
    out = run(
        ["nix", "hash", "path", "--type", "sha256", "--sri", str(path)],
        stdout=subprocess.PIPE,
        text=True,
    )
    return out.stdout.strip()


def prefetch_file(urls: list, name: str, expected: str) -> tuple:
    """Downloads the first URL that yields the expected hash into the store.

    Returns the URL and the store path.
    """
    errors = []
    for url in urls:
        result = subprocess.run(
            [
                "nix",
                "store",
                "prefetch-file",
                "--json",
                "--hash-type",
                "sha256",
                "--expected-hash",
                expected,
                "--name",
                store_name(name),
                url,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            return url, json.loads(result.stdout)["storePath"]
        errors.append(f"{url}: {result.stderr.strip()}")
    raise PurifierError(f"could not fetch {name}:\n" + "\n".join(errors))


def prefetch_git(url: str, revision: str, submodules: bool) -> tuple:
    """Fetches a git revision the way nixpkgs' fetchgit does.

    Returns the commit, the NAR hash and the store path.
    """
    args = ["nix-prefetch-git", "--quiet", "--url", url]
    if revision and revision.lower() != "head":
        args += ["--rev", revision]
    if submodules:
        args.append("--fetch-submodules")
    out = run(args, stdout=subprocess.PIPE, text=True)
    info = json.loads(out.stdout)
    return info["rev"], info["hash"], info["path"]


def fetch_hg(url: str, revision: str, into: Path) -> tuple:
    """Fetches a Mercurial revision the way nixpkgs' fetchhg does with
    fetchSubrepos, because the checkout Meson makes for a wrap-hg (`hg
    clone`, then `hg checkout`) includes the subrepositories.

    Returns the full node id and the NAR hash of the archive at `into`.
    """
    clone = into.parent / (into.name + ".hg-clone")
    run(["hg", "clone", "--quiet", url, str(clone)])
    rev = revision or "tip"
    node = run(
        ["hg", "log", "--cwd", str(clone), "-r", rev, "--template", "{node}"],
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    run(["hg", "archive", "-qS", "-y", "-r", node, "--cwd", str(clone), str(into)])
    archival = into / ".hg_archival.txt"
    if archival.exists():
        archival.unlink()
    shutil.rmtree(clone)
    return node, nix_hash_path(into)


def svn_config_dir(work: Path) -> Path:
    """A Subversion config directory with the proxy of the environment.

    Subversion ignores http_proxy and https_proxy and reads proxies only
    from its `servers` file.
    """
    config = work / "svn-config"
    config.mkdir(exist_ok=True)
    proxy = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY")
    lines = ["[global]"]
    if proxy:
        parts = urllib.parse.urlsplit(proxy)
        lines += [
            f"http-proxy-host = {parts.hostname}",
            f"http-proxy-port = {parts.port or 80}",
        ]
        if parts.username:
            lines.append(
                f"http-proxy-username = {urllib.parse.unquote(parts.username)}"
            )
            lines.append(
                f"http-proxy-password = {urllib.parse.unquote(parts.password or '')}"
            )
    (config / "servers").write_text("\n".join(lines) + "\n")
    return config


def fetch_svn(url: str, revision: str, into: Path, work: Path) -> tuple:
    """Exports a Subversion revision the way nixpkgs' fetchsvn does.

    Returns the revision number as a string and the NAR hash of the export
    at `into`.
    """
    svn = ["svn", "--config-dir", str(svn_config_dir(work)), "--non-interactive"]
    rev = revision or "HEAD"
    number = run(
        [*svn, "info", "--show-item", "revision", f"{url}@{rev}"],
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    # svn expands keywords such as $Date$ in the local time zone and
    # language; fetchsvn exports in the build sandbox, which has UTC and
    # English.
    env = dict(os.environ, TZ="UTC", LC_ALL="C.UTF-8")
    run([*svn, "export", "--quiet", "-r", number, url, str(into)], env=env)
    return number, nix_hash_path(into)


# ---------------------------------------------------------------------------
# The lock run


def lock_wrap(wrap, cache: Path, work: Path, artifacts: dict) -> None:
    """Fetches what one wrap names into the lock run's package cache, and
    records it."""
    from mesonbuild.wrap.wrap import WrapType

    def add(entry: dict) -> None:
        previous = artifacts.get(entry["path"])
        if previous is not None and previous != entry:
            raise PurifierError(
                f"two wraps put different files at {entry['path']} in the package cache"
            )
        artifacts[entry["path"]] = entry

    values = wrap.values
    if wrap.type is WrapType.FILE:
        for what in ("source", "patch"):
            if f"{what}_url" not in values:
                # A file in packagefiles/, which the project carries itself.
                continue
            filename = values[f"{what}_filename"]
            expected = sri_from_hex(values[f"{what}_hash"].lower())
            url = values[f"{what}_url"]
            mirrors = (
                [values[f"{what}_fallback_url"]]
                if f"{what}_fallback_url" in values
                else []
            )
            _, store_path = prefetch_file([url, *mirrors], filename, expected)
            target = cache / filename
            if not target.exists():
                target.symlink_to(store_path)
            add({"path": filename, "url": url, "mirrors": mirrors, "hash": expected})
    elif wrap.type is WrapType.GIT:
        submodules = values.get("clone-recursive", "").lower() == "true"
        rev, nar, store_path = prefetch_git(
            values["url"], values.get("revision", "HEAD"), submodules
        )
        target = cache / wrap.directory
        if not target.exists():
            target.symlink_to(store_path)
        # Meson copies a checkout from the package cache into the subproject
        # directory as plain files, so the checkout carries no .git.
        add(
            {
                "path": wrap.directory,
                "git": {
                    "url": values["url"],
                    "rev": rev,
                    "submodules": submodules,
                    "leaveDotGit": False,
                    "commitObject": None,
                },
                "hash": nar,
            }
        )
    elif wrap.type is WrapType.HG:
        node, nar = fetch_hg(
            values["url"], values.get("revision", "tip"), cache / wrap.directory
        )
        add(
            {
                "path": wrap.directory,
                "hg": {"url": values["url"], "rev": node, "subrepos": True},
                "hash": nar,
            }
        )
    elif wrap.type is WrapType.SVN:
        number, nar = fetch_svn(
            values["url"], values.get("revision", "HEAD"), cache / wrap.directory, work
        )
        # Meson checks a wrap-svn out with a plain `svn checkout`, which
        # fetches externals and expands keywords.
        add(
            {
                "path": wrap.directory,
                "svn": {
                    "url": values["url"],
                    "rev": number,
                    "ignoreExternals": False,
                    "ignoreKeywords": False,
                },
                "hash": nar,
            }
        )
    else:
        raise PurifierError(f"{wrap.name}: unsupported wrap type {wrap.type}")


def nixpkgs_setup_flags(prefix: Path) -> list:
    """The directory and feature options the nixpkgs Meson setup hook
    passes, for a single-output package installed at `prefix`, with
    downloads allowed."""
    return [
        f"--prefix={prefix}",
        f"--libdir={prefix}/lib",
        f"--libexecdir={prefix}/libexec",
        f"--bindir={prefix}/bin",
        f"--sbindir={prefix}/sbin",
        f"--includedir={prefix}/include",
        f"--mandir={prefix}/share/man",
        f"--infodir={prefix}/share/info",
        f"--localedir={prefix}/share/locale",
        "-Dauto_features=enabled",
        "-Dwrap_mode=default",
        "--buildtype=plain",
    ]


def introspect(build: Path, what: str):
    out = run(
        [real_meson(), "introspect", f"--{what}", str(build)],
        stdout=subprocess.PIPE,
        text=True,
    )
    return json.loads(out.stdout)


def outputs_of(build: Path, prefix: Path) -> dict:
    """What the configured project installs, relative to its prefix.

    `targets` maps the name of each installed build target of the main
    project to its type and its installed files. `files` lists every file
    `meson install` installs, the subprojects' included.
    """

    def relative(path: str) -> str:
        rel = os.path.relpath(path, prefix)
        if rel.startswith(".."):
            raise PurifierError(f"the project installs {path}, outside its prefix")
        return rel

    targets: dict = {}
    for target in introspect(build, "targets"):
        if target.get("subproject") or not target.get("installed"):
            continue
        name = target["name"]
        if name in targets:
            raise PurifierError(f"the project has two installed targets named {name}")
        targets[name] = {
            "type": target["type"],
            "files": sorted(relative(p) for p in target.get("install_filename") or []),
        }
    files = sorted({relative(p) for p in introspect(build, "installed").values()})
    return {
        "targets": {name: targets[name] for name in sorted(targets)},
        "files": files,
    }


def configure_copy(
    project: Path, subprojects_dir: str, work: Path, cache: Path, setup_args: list
) -> tuple:
    """Configures a copy of the project the way nixpkgs' Meson setup hook
    does, with the network and the package cache of the lock run.

    Returns the wraps Meson installed from subprojects/wrapdb.json and the
    outputs of the project. Meson writes a wrap from wrapdb.json into the
    subproject directory the first time a dependency() falls back to a
    WrapDB project that has no wrap file yet, and which ones it writes
    depends on the configuration, as the outputs do.
    """
    copy = work / "configure"
    shutil.copytree(
        project,
        copy,
        symlinks=True,
        ignore=shutil.ignore_patterns(".git", STATE_DIR, "packagecache"),
    )
    (copy / subprojects_dir).mkdir(parents=True, exist_ok=True)
    before = set(os.listdir(copy / subprojects_dir))
    # Meson checks out wrap-svn sources with svn, which reads its proxy from
    # ~/.subversion/servers only.
    home = work / "home"
    (home / ".subversion").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(svn_config_dir(work) / "servers", home / ".subversion" / "servers")
    env = dict(os.environ, MESON_PACKAGE_CACHE_DIR=str(cache), HOME=str(home))
    prefix = work / "prefix"
    build = work / "configure-build"
    log("configuring a copy of the project to find its outputs")
    run(
        [real_meson(), "setup", *nixpkgs_setup_flags(prefix), *setup_args, str(build)],
        cwd=copy,
        env=env,
        stdout=subprocess.DEVNULL,
    )

    installed = []
    wrapdb_file = project / subprojects_dir / "wrapdb.json"
    wrapdb = json.loads(wrapdb_file.read_text()) if wrapdb_file.is_file() else {}
    for name in sorted(set(os.listdir(copy / subprojects_dir)) - before):
        if not name.endswith(".wrap"):
            continue
        project_name = name[: -len(".wrap")]
        info = wrapdb.get(project_name)
        if info is None:
            # A wrap-redirect Meson wrote for a wrap a subproject carries.
            continue
        version = info["versions"][0]
        url = f"{WRAPDB_URL}/{project_name}_{version}/{project_name}.wrap"
        data = (copy / subprojects_dir / name).read_bytes()
        expected = sri_from_hex(hashlib.sha256(data).hexdigest())
        prefetch_file([url], name, expected)
        installed.append({"path": name, "url": url, "mirrors": [], "hash": expected})
    return installed, outputs_of(build, prefix)


def lock(project: Path, setup_args: list) -> dict:
    from mesonbuild.wrap import WrapMode
    from mesonbuild.wrap.wrap import PackageDefinition, Resolver

    subprojects_dir = subprojects_dir_of(project)
    work = Path(tempfile.mkdtemp(prefix="meson-purifier-lock-"))
    saved_cache = os.environ.get("MESON_PACKAGE_CACHE_DIR")
    try:
        cache = work / "cache"
        cache.mkdir()
        os.environ["MESON_PACKAGE_CACHE_DIR"] = str(cache)

        # A copy of the subproject directory, so that extracting
        # subprojects leaves the project alone.
        root = work / "project"
        root.mkdir()
        source_subprojects = project / subprojects_dir
        if source_subprojects.is_dir():
            shutil.copytree(
                source_subprojects,
                root / subprojects_dir,
                symlinks=True,
                ignore=shutil.ignore_patterns("packagecache"),
            )
        else:
            (root / subprojects_dir).mkdir(parents=True)
        if (project / "Cargo.lock").is_file():
            shutil.copy(project / "Cargo.lock", root / "Cargo.lock")

        resolver = Resolver(
            str(root), subprojects_dir, wrap_mode=WrapMode.nodownload, silent=True
        )
        artifacts: dict = {}
        done: set = set()

        def lock_pending() -> None:
            while True:
                pending = [
                    w for w in list(resolver.wraps.values()) if w.name not in done
                ]
                if not pending:
                    return
                for wrap in pending:
                    done.add(wrap.name)
                    if wrap.type is None:
                        # A directory in the subproject directory, without a
                        # wrap.
                        continue
                    log(f"locking {wrap.name}")
                    lock_wrap(wrap, cache, work, artifacts)
                    # Meson extracts the subproject from the lock run's cache
                    # and applies the wrap's patches, so that the wraps the
                    # subproject carries become visible.
                    resolver.resolve(wrap.name)
                    extracted = Path(resolver.dirname)
                    nested = extracted / subprojects_dir_of(extracted)
                    if nested.is_dir():
                        resolver.load_and_merge(
                            os.path.relpath(nested, root), wrap.name
                        )

        lock_pending()

        # The configuration finds every source locked so far in the cache,
        # so that it downloads only the wraps wrapdb.json adds and their
        # sources.
        installed, outputs = configure_copy(
            project, subprojects_dir, work, cache, setup_args
        )
        for entry in installed:
            _, store_path = prefetch_file([entry["url"]], entry["path"], entry["hash"])
            target = root / subprojects_dir / entry["path"]
            shutil.copyfile(store_path, target)
            wrap = PackageDefinition.from_wrap_file(str(target))
            resolver.wraps[wrap.name] = wrap
            resolver.add_wrap(wrap, ignore_dups=True)
        lock_pending()

        return {
            "version": LOCK_VERSION,
            "subprojectsDir": subprojects_dir,
            "inputsHash": inputs_hash(
                project, subprojects_dir, installed_names(installed)
            ),
            "setupArgs": setup_args,
            "outputs": outputs,
            "installedWraps": installed,
            "artifacts": [artifacts[path] for path in sorted(artifacts)],
        }
    finally:
        if saved_cache is None:
            os.environ.pop("MESON_PACKAGE_CACHE_DIR", None)
        else:
            os.environ["MESON_PACKAGE_CACHE_DIR"] = saved_cache
        # Files copied out of the store are read-only.
        for directory, _, _ in os.walk(work):
            os.chmod(directory, 0o755)
        shutil.rmtree(work, ignore_errors=True)


def write_lock(project: Path, data: dict) -> None:
    text = json.dumps(data, indent=2) + "\n"
    (project / LOCK_NAME).write_text(text)
    log(f"wrote {project / LOCK_NAME} with {len(data['artifacts'])} downloads")


# ---------------------------------------------------------------------------
# Interactive use


def find_project(start: Path) -> Path:
    """The nearest directory at or above `start` with a lockfile."""
    for directory in [start, *start.parents]:
        if (directory / LOCK_NAME).is_file():
            return directory
    raise PurifierError(
        f"no {LOCK_NAME} in {start} or above it; run `meson-purifier lock`"
    )


def installed_names(entries: list) -> frozenset:
    return frozenset(entry["path"] for entry in entries)


def check_fresh(project: Path) -> dict:
    data = json.loads((project / LOCK_NAME).read_text())
    if data.get("version") != LOCK_VERSION:
        raise PurifierError(
            f"{project / LOCK_NAME} has lock format version {data.get('version')}; "
            f"this meson-purifier reads version {LOCK_VERSION}. Run `meson-purifier lock`."
        )
    installed = installed_names(data.get("installedWraps", []))
    if inputs_hash(project, data["subprojectsDir"], installed) != data["inputsHash"]:
        raise PurifierError(
            f"the wrap files changed since {LOCK_NAME} was written; run `meson-purifier lock`"
        )
    return data


def realize(project: Path) -> Path:
    """Builds the package cache of the lockfile, with a GC root in the
    project, and returns its store path."""
    if not NIX_LIB or not NIXPKGS:
        raise PurifierError(
            "MESON_PURIFIER_NIX_LIB and MESON_PURIFIER_NIXPKGS must be set"
        )
    state = project / STATE_DIR
    state.mkdir(exist_ok=True)
    gitignore = state / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text("*\n")
    link = state / "package-cache"
    run(
        [
            "nix-build",
            "--quiet",
            f"{NIX_LIB}/interactive.nix",
            "--arg",
            "lockFile",
            str((project / LOCK_NAME).resolve()),
            "--arg",
            "nixpkgs",
            NIXPKGS,
            "--out-link",
            str(link),
        ],
        stdout=subprocess.DEVNULL,
    )
    return link.resolve()


def install_wrapdb_wraps(project: Path, data: dict, state: Path) -> None:
    """Writes the wraps that Meson would install from wrapdb.json, as Meson
    itself does when it configures the project with the network."""
    for entry in data.get("installedWraps", []):
        target = project / data["subprojectsDir"] / entry["path"]
        if not target.exists():
            shutil.copyfile(state / "wrapdb-wraps" / entry["path"], target)
            log(f"installed {target.relative_to(project)} from the lockfile")


def meson_env(project: Path) -> dict:
    data = check_fresh(project)
    state = realize(project)
    install_wrapdb_wraps(project, data, state)
    return dict(os.environ, MESON_PACKAGE_CACHE_DIR=str(state / "cache"))


def meson_args(args: list) -> list:
    """Meson's arguments, with downloads turned off for `meson setup`."""
    if (
        args
        and args[0] == "setup"
        and not any(a.startswith("--wrap-mode") for a in args)
    ):
        return ["setup", "--wrap-mode=nodownload", *args[1:]]
    return args


def exec_meson(args: list, env: dict) -> None:
    meson = real_meson()
    os.execvpe(meson, [meson, *meson_args(args)], env)


# ---------------------------------------------------------------------------
# Commands


def run_meson(args: list) -> int:
    """`meson-purifier meson ARGS`: meson with the locked package cache in a
    project that has a lockfile, and meson as it is elsewhere."""
    try:
        project = find_project(Path.cwd())
    except PurifierError:
        exec_meson(args, dict(os.environ))
    try:
        env = meson_env(project)
    except PurifierError as e:
        log(str(e))
        return 1
    except subprocess.CalledProcessError as e:
        log(f"{e.cmd[0]} failed with exit status {e.returncode}")
        return e.returncode or 1
    exec_meson(args, env)
    return 0


def main(argv: list) -> int:
    # Every argument after `meson` belongs to meson, including the ones that
    # look like options of this command.
    if argv and argv[0] == "meson":
        return run_meson(argv[1:])
    parser = argparse.ArgumentParser(
        prog="meson-purifier",
        description="Nix as the download backend of Meson subprojects.",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p_lock = sub.add_parser("lock", help=f"write {LOCK_NAME} for the project")
    p_lock.add_argument("project", nargs="?", default=".")
    p_lock.add_argument(
        "setup_args",
        nargs="*",
        help="after --: arguments for `meson setup` when the lock run configures the "
        "project, which it does only to find the wraps wrapdb.json installs",
    )
    p_realize = sub.add_parser(
        "realize", help="build the package cache and print its path"
    )
    p_realize.add_argument("project", nargs="?", default=".")
    p_download = sub.add_parser(
        "download", help="extract every locked subproject into the subproject directory"
    )
    p_download.add_argument("project", nargs="?", default=".")
    sub.add_parser(
        "meson", help="run meson with the locked package cache", add_help=False
    )
    args = parser.parse_args(argv)

    try:
        if args.command == "lock":
            project = Path(args.project).resolve()
            write_lock(project, lock(project, args.setup_args))
        elif args.command == "realize":
            project = find_project(Path(args.project).resolve())
            check_fresh(project)
            print(realize(project))
        elif args.command == "download":
            project = find_project(Path(args.project).resolve())
            env = meson_env(project)
            run([real_meson(), "subprojects", "download"], cwd=project, env=env)
    except PurifierError as e:
        log(str(e))
        return 1
    except subprocess.CalledProcessError as e:
        log(f"{e.cmd[0]} failed with exit status {e.returncode}")
        return e.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
