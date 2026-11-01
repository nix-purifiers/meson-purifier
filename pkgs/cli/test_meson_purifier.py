# SPDX-License-Identifier: MIT
"""Unit tests of meson-purifier that need neither the network nor Nix."""

import hashlib
import io
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import meson_purifier as mp


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def tarball(path: Path, top: str, files: dict) -> str:
    """Writes a .tar.gz with `files` under the directory `top`, and returns
    its SHA-256 hex digest."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w:gz") as tar:
        for name, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(f"{top}/{name}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Helpers(unittest.TestCase):
    def test_sri_from_hex(self):
        digest = hashlib.sha256(b"").hexdigest()
        self.assertEqual(
            mp.sri_from_hex(digest),
            "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=",
        )

    def test_store_name(self):
        self.assertEqual(mp.store_name("zlib-1.3.2.tar.xz"), "zlib-1.3.2.tar.xz")
        self.assertEqual(mp.store_name("a b/c"), "a_b_c")
        self.assertEqual(mp.store_name(".hidden"), "hidden")
        self.assertEqual(mp.store_name("..."), "file")
        self.assertEqual(mp.store_name("x" * 250), "x" * 200)

    def test_subprojects_dir_of(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            self.assertEqual(mp.subprojects_dir_of(project), "subprojects")
            write(
                project / "meson.build", "project('p', 'c', subproject_dir: 'deps')\n"
            )
            self.assertEqual(mp.subprojects_dir_of(project), "deps")

    def test_wraps_hash_reads_only_wraps(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            write(project / "subprojects" / "b.wrap", "B")
            write(project / "subprojects" / "a.wrap", "A")
            write(project / "subprojects" / "wrapdb.json", "{}")
            expected = hashlib.sha256(
                b"a.wrap\nA\nb.wrap\nB\nwrapdb.json\n{}\n"
            ).hexdigest()
            self.assertEqual(mp.wraps_hash(project, "subprojects"), expected)
            # Extracted subprojects, other files and the build definition
            # leave the hash alone.
            write(project / "subprojects" / "a-1.0" / "meson.build", "x")
            write(project / "subprojects" / "packagecache" / "a.tar.gz", "x")
            write(project / "subprojects" / "notes.txt", "x")
            write(project / "meson.build", "project('p')\n")
            self.assertEqual(mp.wraps_hash(project, "subprojects"), expected)
            # So do the redirects Meson writes, and the wraps the lockfile
            # installs.
            write(
                project / "subprojects" / "c.wrap",
                "[wrap-redirect]\nfilename = a-1.0/subprojects/c.wrap\n",
            )
            write(project / "subprojects" / "d.wrap", "D")
            self.assertEqual(
                mp.wraps_hash(project, "subprojects", frozenset({"d.wrap"})), expected
            )
            (project / "subprojects" / "d.wrap").unlink()
            write(project / "Cargo.lock", "C")
            self.assertEqual(
                mp.wraps_hash(project, "subprojects"),
                hashlib.sha256(
                    b"a.wrap\nA\nb.wrap\nB\nwrapdb.json\n{}\nCargo.lock\nC\n"
                ).hexdigest(),
            )

    def test_definition_files_and_hash(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            write(project / "meson.build", "R")
            write(project / "meson.options", "O")
            write(project / "src" / "meson.build", "S")
            write(project / "src" / "main.c", "x")
            # Left out: the subproject directory, dot directories and build
            # directories.
            write(project / "subprojects" / "a" / "meson.build", "x")
            write(project / ".git" / "meson.build", "x")
            write(project / "build" / "meson-private" / "x", "x")
            write(project / "build" / "meson.build", "x")
            self.assertEqual(
                mp.definition_files(project, "subprojects"),
                ["meson.build", "meson.options", "src/meson.build"],
            )
            self.assertEqual(
                mp.definition_hash(project, "subprojects"),
                hashlib.sha256(
                    b"meson.build\nR\nmeson.options\nO\nsrc/meson.build\nS\n"
                ).hexdigest(),
            )

    def test_meson_args(self):
        self.assertEqual(
            mp.meson_args(["setup", "build"]),
            ["setup", "--wrap-mode=nodownload", "build"],
        )
        self.assertEqual(
            mp.meson_args(["setup", "--wrap-mode=forcefallback", "build"]),
            ["setup", "--wrap-mode=forcefallback", "build"],
        )
        self.assertEqual(
            mp.meson_args(["compile", "-C", "build"]), ["compile", "-C", "build"]
        )

    def test_pick_git_commit(self):
        refs = {
            "HEAD": "a" * 40,
            "refs/heads/main": "a" * 40,
            "refs/heads/v4": "b" * 40,
            "refs/tags/v5": "c" * 40,
            "refs/tags/v5^{}": "d" * 40,
            "refs/tags/r1": "e" * 40,
            "refs/heads/r1": "f" * 40,
        }
        self.assertEqual(mp.pick_git_commit(refs, "HEAD"), "a" * 40)
        # A branch, as rizin's capstone-v4.wrap names one.
        self.assertEqual(mp.pick_git_commit(refs, "v4"), "b" * 40)
        # An annotated tag, peeled to its commit.
        self.assertEqual(mp.pick_git_commit(refs, "v5"), "d" * 40)
        # A tag before a branch of the same name, as `git checkout` does.
        self.assertEqual(mp.pick_git_commit(refs, "r1"), "e" * 40)
        self.assertEqual(mp.pick_git_commit(refs, "refs/heads/r1"), "f" * 40)
        self.assertEqual(mp.pick_git_commit(refs, "1" * 40), "1" * 40)
        self.assertIsNone(mp.pick_git_commit(refs, "missing"))
        self.assertIsNone(mp.pick_git_commit(refs, "1234567"))

    def test_needs_lock(self):
        for args in (
            ["setup", "build"],
            ["compile", "-C", "build"],
            ["test"],
            ["install"],
            ["configure", "build"],
            ["subprojects", "download"],
            ["-Dfoo=bar", "build"],
        ):
            self.assertTrue(mp.needs_lock(args), args)
        for args in (
            [],
            ["--version"],
            ["wrap", "install", "zlib"],
            ["wrap", "update", "zlib"],
            ["subprojects", "update"],
            ["init"],
        ):
            self.assertFalse(mp.needs_lock(args), args)


def lockfile(project: Path, **fields) -> dict:
    data = {
        "version": mp.LOCK_VERSION,
        "subprojectsDir": "subprojects",
        "wrapsHash": mp.wraps_hash(project, "subprojects"),
        "definitionHash": mp.definition_hash(project, "subprojects"),
        "setupArgs": [],
        "outputs": {"targets": {}, "files": []},
        "installedWraps": [],
        "artifacts": [],
    }
    data.update(fields)
    return data


class Lockfile(unittest.TestCase):
    def test_fresh_lockfile(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            write(project / "subprojects" / "a.wrap", "A")
            write(project / "meson.build", "project('p')\n")
            lock = lockfile(project)
            mp.write_lock(project, lock)
            self.assertEqual(mp.check_fresh(project), lock)
            # An edited build definition leaves the downloads current.
            write(project / "meson.build", "project('p', 'c')\n")
            self.assertEqual(mp.check_fresh(project), lock)

    def test_stale_lockfile(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            write(project / "subprojects" / "a.wrap", "A")
            mp.write_lock(project, lockfile(project))
            write(project / "subprojects" / "a.wrap", "changed")
            with self.assertRaisesRegex(mp.PurifierError, "run `meson-purifier lock`"):
                mp.check_fresh(project)

    def test_malformed_lockfile(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            (project / mp.LOCK_NAME).write_text('{\n<<<<<<< HEAD\n  "version": 2\n')
            with self.assertRaisesRegex(mp.PurifierError, "not valid JSON"):
                mp.read_lock(project)

    def test_lockfile_of_another_version(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            mp.write_lock(project, lockfile(project, version=1))
            with self.assertRaisesRegex(mp.PurifierError, "lock format version 1"):
                mp.read_lock(project)

    def test_lockfile_missing_a_field(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            lock = lockfile(project)
            del lock["artifacts"]
            mp.write_lock(project, lock)
            with self.assertRaisesRegex(mp.PurifierError, "lacks artifacts"):
                mp.read_lock(project)


class Entries(unittest.TestCase):
    """The entry the lock run records for each kind of wrap, with the
    fetchers replaced."""

    def entry(self, wrap_text: str, **fetchers) -> list:
        from mesonbuild.wrap.wrap import PackageDefinition

        with tempfile.TemporaryDirectory() as d:
            work = Path(d)
            write(work / "subprojects" / "w.wrap", wrap_text)
            (work / "cache").mkdir()
            wrap = PackageDefinition.from_wrap_file(
                str(work / "subprojects" / "w.wrap")
            )
            artifacts: dict = {}
            with mock.patch.multiple(mp, **fetchers):
                mp.lock_wrap(wrap, work / "cache", work, artifacts)
            return list(artifacts.values())

    def test_wrap_file(self):
        digest = hashlib.sha256(b"x").hexdigest()
        calls = []

        def prefetch(urls, name, expected):
            calls.append((urls, name, expected))
            return urls[0], "/nix/store/x"

        entries = self.entry(
            "[wrap-file]\ndirectory = z-1\nsource_url = https://a/z.tar.gz\n"
            "source_fallback_url = https://b/z.tar.gz\nsource_filename = z.tar.gz\n"
            f"source_hash = {digest.upper()}\npatch_url = https://a/p.zip\n"
            f"patch_filename = p.zip\npatch_hash = {digest}\n",
            prefetch_file=prefetch,
        )
        sri = mp.sri_from_hex(digest)
        self.assertEqual(
            entries,
            [
                {
                    "path": "z.tar.gz",
                    "url": "https://a/z.tar.gz",
                    "mirrors": ["https://b/z.tar.gz"],
                    "hash": sri,
                },
                {"path": "p.zip", "url": "https://a/p.zip", "mirrors": [], "hash": sri},
            ],
        )
        self.assertEqual(calls[0][0], ["https://a/z.tar.gz", "https://b/z.tar.gz"])

    def test_wrap_file_in_packagefiles(self):
        # An archive the project carries needs no download.
        digest = hashlib.sha256(b"x").hexdigest()
        entries = self.entry(
            f"[wrap-file]\ndirectory = z\nsource_filename = z.tar.gz\nsource_hash = {digest}\n",
            prefetch_file=mock.Mock(side_effect=AssertionError("no download")),
        )
        self.assertEqual(entries, [])

    def test_wrap_git(self):
        prefetch = mock.Mock(return_value=("c" * 40, "sha256-git", "/nix/store/g"))
        entries = self.entry(
            "[wrap-git]\nurl = https://example.org/g.git\nrevision = v1\n"
            "directory = g-1\nclone-recursive = true\n",
            prefetch_git=prefetch,
        )
        prefetch.assert_called_once_with("https://example.org/g.git", "v1", True)
        self.assertEqual(
            entries,
            [
                {
                    "path": "g-1",
                    "git": {
                        "url": "https://example.org/g.git",
                        "rev": "c" * 40,
                        "submodules": True,
                        "leaveDotGit": False,
                        "commitObject": None,
                    },
                    "hash": "sha256-git",
                }
            ],
        )

    def test_wrap_hg(self):
        fetch = mock.Mock(return_value=("n" * 40, "sha256-hg"))
        entries = self.entry(
            "[wrap-hg]\nurl = https://example.org/h\nrevision = tip\n", fetch_hg=fetch
        )
        self.assertEqual(
            entries,
            [
                {
                    "path": "w",
                    "hg": {
                        "url": "https://example.org/h",
                        "rev": "n" * 40,
                        "subrepos": True,
                    },
                    "hash": "sha256-hg",
                }
            ],
        )

    def test_wrap_svn(self):
        fetch = mock.Mock(return_value=("123", "sha256-svn"))
        entries = self.entry(
            "[wrap-svn]\nurl = https://example.org/s/trunk\nrevision = HEAD\n",
            fetch_svn=fetch,
        )
        self.assertEqual(
            entries,
            [
                {
                    "path": "w",
                    "svn": {
                        "url": "https://example.org/s/trunk",
                        "rev": "123",
                        "ignoreExternals": False,
                        "ignoreKeywords": False,
                    },
                    "hash": "sha256-svn",
                }
            ],
        )

    def test_svn_proxy_config(self):
        with tempfile.TemporaryDirectory() as d:
            with mock.patch.dict(
                "os.environ", {"https_proxy": "http://user:p%40ss@proxy.example:3128"}
            ):
                config = mp.svn_config_dir(Path(d))
            servers = (config / "servers").read_text()
            self.assertIn("http-proxy-host = proxy.example", servers)
            self.assertIn("http-proxy-port = 3128", servers)
            self.assertIn("http-proxy-username = user", servers)
            self.assertIn("http-proxy-password = p@ss", servers)


class LockRun(unittest.TestCase):
    """The lock loop on wraps whose archives the project carries, so that
    Meson extracts them without the network."""

    def test_nested_wraps_are_promoted_and_locked(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d) / "project"
            subprojects = project / "subprojects"
            write(project / "meson.build", "project('p', 'c')\n")

            # b: a wrap that only the patch directory of a carries.
            b_hash = tarball(
                Path(d) / "b.tar.gz", "b-1.0", {"meson.build": "project('b', 'c')\n"}
            )
            a_patch = subprojects / "packagefiles" / "a-patch"
            write(a_patch / "meson.build", "project('a', 'c')\n")
            write(
                a_patch / "subprojects" / "b.wrap",
                "[wrap-file]\ndirectory = b-1.0\nsource_filename = b.tar.gz\n"
                f"source_hash = {b_hash}\n",
            )
            (a_patch / "subprojects" / "packagefiles").mkdir(parents=True)
            (Path(d) / "b.tar.gz").rename(
                a_patch / "subprojects" / "packagefiles" / "b.tar.gz"
            )

            a_hash = tarball(
                subprojects / "packagefiles" / "a.tar.gz", "a-1.0", {"a.c": "int a;\n"}
            )
            write(
                subprojects / "a.wrap",
                "[wrap-file]\ndirectory = a-1.0\nsource_filename = a.tar.gz\n"
                f"source_hash = {a_hash}\npatch_directory = a-patch\n",
            )
            # A directory without a wrap is not locked.
            write(subprojects / "c" / "meson.build", "project('c', 'c')\n")

            seen = []
            outputs = {"targets": {}, "files": []}
            # Configuring needs a C compiler, which the unit tests do not
            # have; the fixture checks configure for real.
            with (
                mock.patch.object(
                    mp,
                    "lock_wrap",
                    lambda wrap, cache, work, artifacts: seen.append(wrap.name),
                ),
                mock.patch.object(mp, "configure_copy", lambda *args: ([], outputs)),
            ):
                lock = mp.lock(project, ["-Dx=y"])

            self.assertEqual(sorted(seen), ["a", "b"])
            self.assertEqual(lock["artifacts"], [])
            self.assertEqual(lock["outputs"], outputs)
            self.assertEqual(lock["setupArgs"], ["-Dx=y"])
            self.assertEqual(lock["wrapsHash"], mp.wraps_hash(project, "subprojects"))
            self.assertEqual(
                lock["definitionHash"], mp.definition_hash(project, "subprojects")
            )
            # The lock run extracts subprojects in a copy, not in the project.
            self.assertFalse((subprojects / "a-1.0").exists())


if __name__ == "__main__":
    unittest.main()
