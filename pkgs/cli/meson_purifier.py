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
import time
import urllib.parse
from pathlib import Path

LOCK_NAME = "meson-purifier.lock.json"
LOCK_VERSION = 3
# Where interactive commands keep the GC root of the realized package cache,
# relative to the project root.
STATE_DIR = ".meson-purifier"
WRAPDB_URL = "https://wrapdb.mesonbuild.com/v2"
# The start of a wrap file that only redirects to a wrap in a subproject.
REDIRECT = b"[wrap-redirect]"

# Set by the toolchain package: the directory of this purifier's Nix
# library, the nixpkgs and the source of the purifier library that the
# interactive commands build the package cache with.
NIX_LIB = os.environ.get("MESON_PURIFIER_NIX_LIB", "")
NIXPKGS = os.environ.get("MESON_PURIFIER_NIXPKGS", "")
LIBRARY = os.environ.get("MESON_PURIFIER_LIBRARY", "")


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
    """A store path name for a cache path, by the rule of storeName in
    nix/lib/entries.nix of the purifier library, which names the downloads
    of the builds; the lock run and the builds then share store paths.

    Store path names allow [A-Za-z0-9+._?=-], must not start with a dot, and
    are at most 211 characters. Every other character becomes "_", and a
    long name keeps its start.
    """
    replaced = re.sub(r"[^A-Za-z0-9+._?=-]", "_", path)
    undotted = replaced.lstrip(".")
    return (undotted or "download")[:200]


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


def wraps_hash(
    project: Path, subprojects_dir: str, installed: frozenset = frozenset()
) -> str:
    """The hash of the files that decide what a lock run downloads;
    lib-overlays/default/inputs-hash.nix has the same rule.

    They are the wrap files and wrapdb.json in the subproject directory, and
    a Cargo.lock at the project root, each as its name, a newline, its
    contents and a newline, in byte order of the names. Two kinds of wrap
    file are left out. The ones named in `installed` are the wraps the
    lockfile itself installs from wrapdb.json. A file that starts with
    [wrap-redirect] only selects a wrap that a subproject carries; Meson
    writes one when it uses such a wrap. Wraps in downloaded subprojects are
    locked recursively; vendored checkouts remain part of the source input.
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
    return hashlib.sha256(data).hexdigest()


def definition_hash(project: Path, subprojects_dir: str) -> str:
    """The hash of the build definition, which decides the outputs the lock
    run records; lib-overlays/default/inputs-hash.nix has the same rule.

    Each file of definition_files counts as its path, a newline, its
    contents and a newline, in byte order of the paths.
    """
    data = b""
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


def pick_git_commit(refs: dict, revision: str):
    """The commit that `revision` names among the refs `git ls-remote`
    printed, or None.

    Meson checks a wrap-git out with `git checkout <revision>`, which takes a
    tag before a branch of the same name, and a commit hash as it is.
    """
    if not revision or revision.upper() == "HEAD":
        return refs.get("HEAD")
    if revision.startswith("refs/"):
        candidates = [f"{revision}^{{}}", revision]
    else:
        candidates = [
            f"refs/tags/{revision}^{{}}",
            f"refs/tags/{revision}",
            f"refs/heads/{revision}",
        ]
    for candidate in candidates:
        if candidate in refs:
            return refs[candidate]
    if re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", revision):
        return revision.lower()
    return None


def resolve_git_commit(url: str, revision: str) -> str:
    """The commit a wrap-git revision names: a tag, a branch, HEAD or a full
    commit hash."""
    out = run(["git", "ls-remote", url], stdout=subprocess.PIPE, text=True).stdout
    refs = {}
    for line in out.splitlines():
        sha, _, name = line.partition("\t")
        if name:
            refs[name] = sha
    commit = pick_git_commit(refs, revision)
    if commit is None:
        raise PurifierError(
            f"{url} has no tag or branch named {revision!r}; a wrap-git revision must be a "
            "tag, a branch, HEAD or a full commit hash"
        )
    return commit


def prefetch_git(url: str, revision: str, submodules: bool) -> tuple:
    """Fetches a git revision the way nixpkgs' fetchgit does.

    Returns the commit, the NAR hash and the store path.
    """
    args = [
        "nix-prefetch-git",
        "--quiet",
        "--url",
        url,
        "--rev",
        resolve_git_commit(url, revision),
    ]
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


def lock_wrap(wrap, cache: Path, work: Path, artifacts: dict, wrap_file=None) -> None:
    """Fetches what one wrap names into the lock run's package cache, and
    records it.

    `wrap_file` names a wrap file of the project whose archives Nix reads
    from the wrap file itself (lib-overlays/default/wrap-file.nix); their entries carry
    it as `wrapFile`, and the lockfile lists the wrap file instead of them.
    """
    from mesonbuild.wrap.wrap import WrapType

    def add(entry: dict) -> None:
        previous = artifacts.get(entry["path"])
        if previous is not None:
            same = {k: v for k, v in previous.items() if k != "wrapFile"} == entry
            if not same:
                raise PurifierError(
                    f"two wraps put different files at {entry['path']} in the package cache"
                )
            if "wrapFile" in previous:
                return
        if wrap_file is not None:
            entry = {**entry, "wrapFile": wrap_file}
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
    # Preserve each checkout's identity, including submodules and linked
    # worktrees, without copying their object databases into the build copy.
    for directory, _, _ in os.walk(copy):
        target = Path(directory)
        original = project / target.relative_to(copy)
        if (original / ".git").exists():
            gitdir = run(
                ["git", "-C", str(original), "rev-parse", "--absolute-git-dir"],
                stdout=subprocess.PIPE,
                text=True,
            ).stdout.strip()
            (target / ".git").write_text("gitdir: " + gitdir + "\n")
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
    # Keep successful captures quiet, but retain Meson's native explanation
    # when a dependency or selected toolchain cannot configure the project.
    with tempfile.TemporaryFile(
        mode="w+", encoding="utf-8", errors="replace"
    ) as output:
        try:
            run(
                [
                    real_meson(),
                    "setup",
                    *nixpkgs_setup_flags(prefix),
                    *setup_args,
                    str(build),
                ],
                cwd=copy,
                env=env,
                stdout=output,
            )
        except subprocess.CalledProcessError:
            output.seek(0)
            shutil.copyfileobj(output, sys.stderr)
            raise

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


# Set by `lock --record-all`: the lockfile records the archives of every
# wrap, for a build whose source a derivation builds, where Nix cannot read
# the wrap files at evaluation.
RECORD_ALL = False


def derivable(project: Path, root: Path, wrap):
    """The name of the wrap file of `wrap`, if Nix can read the archives of
    the wrap from the wrap file instead of the lockfile.

    That holds for a [wrap-file] wrap that lies in the subproject directory
    of the project: a wrap file names its archives with URLs and SHA-256
    hashes, and the build reads it from its source at evaluation. The
    lockfile records the archives of every other wrap: a wrap inside a
    downloaded archive or a patch directory, and a wrap that Meson installs
    from wrapdb.json at configure time.
    """
    from mesonbuild.wrap.wrap import WrapType

    if RECORD_ALL or wrap.type is not WrapType.FILE or wrap.redirected:
        return None
    path = Path(wrap.original_filename)
    subprojects_dir = subprojects_dir_of(project)
    if path.parent != root / subprojects_dir:
        return None
    if not (project / subprojects_dir / path.name).is_file():
        return None
    return path.name


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
        wrapped_directories = {
            wrap.directory
            for wrap in resolver.wraps.values()
            if wrap.type is not None and not wrap.redirected
        }
        vendored_directories = (
            {
                path.name
                for path in source_subprojects.iterdir()
                if path.is_dir() and path.name not in wrapped_directories
            }
            if source_subprojects.is_dir()
            else set()
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
                    if wrap.redirected and wrap.directory in vendored_directories:
                        # Generated aliases selecting source already vendored
                        # at the root must not add downloads on relock. Nested
                        # wraps owned by downloaded projects remain locked.
                        origin = (
                            Path(wrap.subprojects_dir)
                            .relative_to(root / subprojects_dir)
                            .parts
                        )
                        owner = origin[0] if origin else None
                        buildfile = {
                            "meson": "meson.build",
                            "cmake": "CMakeLists.txt",
                            "cargo": "Cargo.toml",
                        }.get(wrap.values.get("method", "meson"))
                        if (
                            owner in vendored_directories
                            and buildfile is not None
                            and (
                                source_subprojects / wrap.directory / buildfile
                            ).is_file()
                        ):
                            continue
                    log(f"locking {wrap.name}")
                    lock_wrap(
                        wrap,
                        cache,
                        work,
                        artifacts,
                        wrap_file=derivable(project, root, wrap),
                    )
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
            "wrapsHash": wraps_hash(
                project, subprojects_dir, installed_names(installed)
            ),
            "definitionHash": definition_hash(project, subprojects_dir),
            "setupArgs": setup_args,
            "outputs": outputs,
            "installedWraps": installed,
            "wrapFiles": sorted(
                {
                    entry["wrapFile"]
                    for entry in artifacts.values()
                    if "wrapFile" in entry
                }
            ),
            "artifacts": [
                artifacts[path]
                for path in sorted(artifacts)
                if "wrapFile" not in artifacts[path]
            ],
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


def content_hash(data: dict) -> str:
    """The hash of a lockfile's content, which the lockfile records as
    `contentHash`; nix/lib/lock.nix has the same rule.

    It is the SHA-256 of the lockfile without `contentHash`, as compact JSON
    with sorted keys, which is what Nix's builtins.toJSON writes.
    """
    rest = {key: value for key, value in data.items() if key != "contentHash"}
    text = json.dumps(rest, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(text.encode()).hexdigest()


# The lockfile that --lockfile or MESON_PURIFIER_LOCKFILE names, for a
# lockfile kept outside the project; None means the one next to meson.build.
LOCKFILE: "Path | None" = None


def lock_path(project: Path) -> Path:
    return LOCKFILE if LOCKFILE is not None else project / LOCK_NAME


def write_lock(project: Path, data: dict) -> None:
    data = {key: value for key, value in data.items() if key != "contentHash"}
    data["contentHash"] = content_hash(data)
    text = json.dumps(data, indent=2) + "\n"
    path = lock_path(project)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    log(
        f"wrote {path} with {len(data.get('artifacts', []))} downloads; Nix reads the "
        f"archives of {len(data.get('wrapFiles', []))} wrap files from the wrap files"
    )


# ---------------------------------------------------------------------------
# Interactive use


def find_project(start: Path) -> Path:
    """The project at or above `start`: the nearest directory with a
    lockfile, or, with a lockfile kept outside the project, the nearest
    directory whose meson.build calls project()."""
    for directory in [start, *start.parents]:
        if LOCKFILE is None:
            if (directory / LOCK_NAME).is_file():
                return directory
        else:
            build = directory / "meson.build"
            if build.is_file() and re.search(
                r"^\s*project\s*\(", build.read_text(errors="replace"), re.MULTILINE
            ):
                return directory
    if LOCKFILE is None:
        raise PurifierError(
            f"no {LOCK_NAME} in {start} or above it; run `meson-purifier lock`"
        )
    raise PurifierError(f"no Meson project at or above {start}")


def installed_names(entries: list) -> frozenset:
    return frozenset(entry["path"] for entry in entries)


LOCK_FIELDS = (
    "subprojectsDir",
    "wrapsHash",
    "definitionHash",
    "setupArgs",
    "outputs",
    "installedWraps",
    "wrapFiles",
    "artifacts",
    "contentHash",
)


def read_lock(project: Path) -> dict:
    """The lockfile of the project, with its format checked."""
    path = lock_path(project)
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise PurifierError(
            f"{path} is not valid JSON ({e}); if a merge left conflict markers in it, "
            "run `meson-purifier lock` to write it again"
        ) from e
    if not isinstance(data, dict) or data.get("version") != LOCK_VERSION:
        version = data.get("version") if isinstance(data, dict) else None
        raise PurifierError(
            f"{path} has lock format version {version}; this meson-purifier reads version "
            f"{LOCK_VERSION}. Run `meson-purifier lock`."
        )
    missing = [field for field in LOCK_FIELDS if field not in data]
    if missing:
        raise PurifierError(
            f"{path} lacks {', '.join(missing)}; run `meson-purifier lock` to write it again"
        )
    if content_hash(data) != data["contentHash"]:
        raise PurifierError(
            f"{path} differs from what `meson-purifier lock` wrote (its contentHash does not "
            "match): it was edited by hand. Run `meson-purifier lock` to write it again."
        )
    return data


def check_fresh(project: Path) -> dict:
    """The lockfile, if it holds every download the wrap files name.

    An edited meson.build leaves the downloads alone, so interactive commands
    accept it; only the outputs the lockfile records can be out of date
    then, which the Nix build reports.
    """
    data = read_lock(project)
    installed = installed_names(data["installedWraps"])
    if wraps_hash(project, data["subprojectsDir"], installed) != data["wrapsHash"]:
        raise PurifierError(
            f"the wrap files changed since {LOCK_NAME} was written, so it may lack a "
            "download; run `meson-purifier lock`"
        )
    return data


def prefetch(project: Path) -> Path:
    """Builds the package cache of the lockfile, with a GC root in
    .meson-purifier/ beside the lockfile, and returns its store path.

    The package cache is everything day-to-day work needs from the network:
    Meson, ninja and the compilers come from the Nix store already, and
    clangd reads the build directory, whose headers Meson extracts from the
    package cache.
    """
    if not (NIX_LIB and NIXPKGS and LIBRARY):
        raise PurifierError(
            "MESON_PURIFIER_NIX_LIB, MESON_PURIFIER_NIXPKGS and MESON_PURIFIER_LIBRARY "
            "are not set; run meson-purifier from the toolchain package"
        )
    state = lock_path(project).parent / STATE_DIR
    state.mkdir(parents=True, exist_ok=True)
    gitignore = state / ".gitignore"
    if not gitignore.exists():
        gitignore.write_text("*\n")
    link = state / "package-cache"
    try:
        run(
            [
                "nix-build",
                "--quiet",
                f"{NIX_LIB}/interactive.nix",
                "--arg",
                "lockFile",
                str(lock_path(project).resolve()),
                "--argstr",
                "projectDir",
                str(project.resolve()),
                "--arg",
                "nixpkgs",
                NIXPKGS,
                "--arg",
                "purifier",
                LIBRARY,
                "--out-link",
                str(link),
            ],
            stdout=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError as e:
        raise PurifierError(
            f"Nix could not build the package cache of {LOCK_NAME} (see its error above). "
            "A hash mismatch means a download differs from the one the lockfile records: "
            "the lockfile was edited, or an upstream file changed. Run `meson-purifier lock` "
            "to record the current files."
        ) from e
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
    state = prefetch(project)
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
    os.execvpe(meson, [meson, *args], env)


# Meson commands that change wrap files or need the network by design: they
# run as they are, so that a dependency can be added or upgraded before the
# lockfile is renewed.
UNLOCKED_COMMANDS = ("wrap", "init", "env2mfile", "format", "fmt", "rewrite", "help")
# What Meson reports when a subproject is missing from the package cache.
NOT_DOWNLOADABLE = "Automatic wrap-based subproject downloading is disabled"


def needs_lock(args: list) -> bool:
    if not args or args[0].startswith("-"):
        # `meson --version`, or the old `meson [options] builddir` form of
        # setup, which takes the lock like `meson setup`.
        return bool(args) and args[0] not in ("-v", "--version", "-h", "--help")
    if args[0] in UNLOCKED_COMMANDS:
        return False
    if args[0] == "subprojects":
        return len(args) > 1 and args[1] == "download"
    return True


def missing_subproject_hint(project: Path, started: float) -> None:
    """After a failed meson command, says what to do if Meson stopped at a
    subproject that the lockfile does not hold."""
    for log_file in project.glob("**/meson-logs/meson-log.txt"):
        try:
            if log_file.stat().st_mtime < started:
                continue
            if NOT_DOWNLOADABLE in log_file.read_text(errors="replace"):
                log(
                    f"Meson needs a subproject that {LOCK_NAME} does not hold, so it would "
                    "have downloaded it. Run `meson-purifier lock`, with the options you "
                    "configure with after `--` if they choose the subprojects."
                )
                return
        except OSError:
            continue


# ---------------------------------------------------------------------------
# Commands


def run_meson(args: list) -> int:
    """`meson-purifier meson ARGS`: meson with the locked package cache in a
    project that has a lockfile, and meson as it is elsewhere."""
    try:
        project = find_project(Path.cwd())
    except PurifierError:
        log(
            "warning: no meson-purifier.lock.json found; running meson impurely. Run `meson-purifier lock` to use Nix-resolved dependencies."
        )
        exec_meson(args, dict(os.environ))
    if not needs_lock(args):
        exec_meson(args, dict(os.environ))
    try:
        env = meson_env(project)
    except PurifierError as e:
        log(str(e))
        return 1
    except subprocess.CalledProcessError as e:
        log(f"{e.cmd[0]} failed with exit status {e.returncode}")
        return e.returncode or 1
    started = time.time()
    meson = real_meson()
    try:
        result = subprocess.run([meson, *meson_args(args)], env=env, check=False)
    except KeyboardInterrupt:
        # Meson received the interrupt as well and stops on its own.
        return 130
    if result.returncode != 0:
        missing_subproject_hint(project, started)
    return result.returncode


def release_files(paths: list) -> list:
    """The files of the store paths a release build printed: a file as it
    is, and the files directly inside a directory."""
    files = []
    for path in map(Path, paths):
        if path.is_dir():
            files += sorted(p for p in path.iterdir() if p.is_file())
        else:
            files.append(path)
    return files


def publish(tag: str, installable: str, repo, dry_run: bool) -> None:
    """Builds the release with Nix and uploads its files to the GitHub
    release `tag`, which it creates when it does not exist."""
    out = run(
        ["nix", "build", "--no-link", "--print-out-paths", installable],
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.split()
    files = release_files(out)
    if not files:
        raise PurifierError(f"{installable} built no files to publish")
    repo_args = ["--repo", repo] if repo else []
    exists = (
        subprocess.run(
            ["gh", "release", "view", tag, *repo_args],
            capture_output=True,
            check=False,
        ).returncode
        == 0
        if not dry_run
        else False
    )
    if exists:
        command = [
            "gh",
            "release",
            "upload",
            tag,
            *map(str, files),
            "--clobber",
            *repo_args,
        ]
    else:
        command = [
            "gh",
            "release",
            "create",
            tag,
            *map(str, files),
            "--title",
            tag,
            *repo_args,
        ]
    if dry_run:
        print(" ".join(command))
        return
    run(command)
    log(f"published {', '.join(f.name for f in files)} to the release {tag}")


def update(project: Path, names: list) -> None:
    """Updates the wraps from WrapDB with `meson wrap update`, all of them
    or the named ones, and locks the project again with the `meson setup`
    arguments of its lockfile."""
    try:
        setup_args = json.loads(lock_path(project).read_text())["setupArgs"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise PurifierError(
            f"{lock_path(project)} holds no setupArgs to lock with again ({e}); "
            "run `meson-purifier lock . -- ARGS`"
        ) from e
    run([real_meson(), "wrap", "update", *names], cwd=project)
    write_lock(project, lock(project, setup_args))


def main(argv: list) -> int:
    global LOCKFILE, RECORD_ALL
    # --lockfile comes before the command or after it; the toolchain's meson,
    # whose arguments all belong to meson, reads MESON_PURIFIER_LOCKFILE.
    if os.environ.get("MESON_PURIFIER_LOCKFILE"):
        LOCKFILE = Path(os.environ["MESON_PURIFIER_LOCKFILE"]).resolve()
    while argv and (argv[0] == "--lockfile" or argv[0].startswith("--lockfile=")):
        if argv[0] == "--lockfile":
            if len(argv) < 2:
                log("--lockfile needs a path")
                return 2
            LOCKFILE = Path(argv[1]).resolve()
            argv = argv[2:]
        else:
            LOCKFILE = Path(argv[0].split("=", 1)[1]).resolve()
            argv = argv[1:]
    # Every argument after `meson` belongs to meson, including the ones that
    # look like options of this command.
    if argv and argv[0] == "meson":
        return run_meson(argv[1:])
    parser = argparse.ArgumentParser(
        prog="meson-purifier",
        description="Nix as the download backend of Meson subprojects.",
    )
    lockfile_option = argparse.ArgumentParser(add_help=False)
    lockfile_option.add_argument(
        "--lockfile",
        help=f"the lockfile, when it lives outside the project (default: {LOCK_NAME} "
        "next to meson.build)",
    )
    record_all_option = argparse.ArgumentParser(add_help=False)
    record_all_option.add_argument(
        "--record-all",
        action="store_true",
        help="record the archives of every wrap, for a build whose source a derivation "
        "builds, where Nix cannot read the wrap files at evaluation",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    p_lock = sub.add_parser(
        "lock",
        help=f"write {LOCK_NAME} for the project",
        parents=[lockfile_option, record_all_option],
    )
    p_lock.add_argument("project", nargs="?", default=".")
    p_lock.add_argument(
        "setup_args",
        nargs="*",
        help="after --: arguments for `meson setup` when the lock run configures the "
        "project to find its outputs and the wraps wrapdb.json installs",
    )
    p_update = sub.add_parser(
        "update",
        help="update the wraps with `meson wrap update`, all of them or the named ones, "
        f"and write {LOCK_NAME} again",
        parents=[lockfile_option, record_all_option],
    )
    p_update.add_argument("wraps", nargs="*", help="the wraps to update (default: all)")
    p_prefetch = sub.add_parser(
        "prefetch",
        help="build everything day-to-day work downloads, with a GC root in the project, "
        "and print its path",
        parents=[lockfile_option],
    )
    p_prefetch.add_argument("project", nargs="?", default=".")
    # publish builds the release from the Nix expression, which names its
    # lockfile itself; it takes --lockfile like every command, for scripts
    # that pass it to all of them.
    p_publish = sub.add_parser(
        "publish",
        help="upload the release Nix builds to a GitHub release",
        parents=[lockfile_option],
    )
    p_publish.add_argument("tag", help="the tag of the GitHub release")
    p_publish.add_argument(
        "--installable",
        default=".#release",
        help="the Nix installable of the release (default: .#release)",
    )
    p_publish.add_argument("--repo", help="the GitHub repository, OWNER/NAME")
    p_publish.add_argument(
        "--dry-run",
        action="store_true",
        help="build, and print the upload command only",
    )
    p_download = sub.add_parser(
        "download",
        help="extract every locked subproject into the subproject directory",
        parents=[lockfile_option],
    )
    p_download.add_argument("project", nargs="?", default=".")
    sub.add_parser(
        "meson", help="run meson with the locked package cache", add_help=False
    )
    args = parser.parse_args(argv)
    if getattr(args, "lockfile", None):
        LOCKFILE = Path(args.lockfile).resolve()
    RECORD_ALL = getattr(args, "record_all", False)

    try:
        if args.command == "lock":
            project = Path(args.project).resolve()
            write_lock(project, lock(project, args.setup_args))
        elif args.command == "update":
            update(find_project(Path.cwd()), args.wraps)
        elif args.command == "prefetch":
            project = find_project(Path(args.project).resolve())
            check_fresh(project)
            print(prefetch(project))
        elif args.command == "publish":
            publish(args.tag, args.installable, args.repo, args.dry_run)
        elif args.command == "download":
            project = find_project(Path(args.project).resolve())
            env = meson_env(project)
            run([real_meson(), "subprojects", "download"], cwd=project, env=env)
        elif args.command == "meson":
            # Reached only with no arguments after `meson`.
            return run_meson([])
    except PurifierError as e:
        log(str(e))
        return 1
    except subprocess.CalledProcessError as e:
        log(f"{e.cmd[0]} failed with exit status {e.returncode}")
        return e.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
