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

    def test_inputs_hash_reads_only_wraps(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            write(project / "subprojects" / "b.wrap", "B")
            write(project / "subprojects" / "a.wrap", "A")
            write(project / "subprojects" / "wrapdb.json", "{}")
            expected = hashlib.sha256(
                b"a.wrap\nA\nb.wrap\nB\nwrapdb.json\n{}\n"
            ).hexdigest()
            self.assertEqual(mp.inputs_hash(project, "subprojects"), expected)
            # Extracted subprojects and other files leave the hash alone.
            write(project / "subprojects" / "a-1.0" / "meson.build", "x")
            write(project / "subprojects" / "packagecache" / "a.tar.gz", "x")
            write(project / "subprojects" / "notes.txt", "x")
            self.assertEqual(mp.inputs_hash(project, "subprojects"), expected)
            # So do the redirects Meson writes, and the wraps the lockfile
            # installs.
            write(
                project / "subprojects" / "c.wrap",
                "[wrap-redirect]\nfilename = a-1.0/subprojects/c.wrap\n",
            )
            write(project / "subprojects" / "d.wrap", "D")
            self.assertEqual(
                mp.inputs_hash(project, "subprojects", frozenset({"d.wrap"})), expected
            )
            (project / "subprojects" / "d.wrap").unlink()
            write(project / "Cargo.lock", "C")
            self.assertEqual(
                mp.inputs_hash(project, "subprojects"),
                hashlib.sha256(
                    b"a.wrap\nA\nb.wrap\nB\nwrapdb.json\n{}\nCargo.lock\nC\n"
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

    def test_check_fresh(self):
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            write(project / "subprojects" / "a.wrap", "A")
            lock = {
                "version": mp.LOCK_VERSION,
                "subprojectsDir": "subprojects",
                "inputsHash": mp.inputs_hash(project, "subprojects"),
                "installedWraps": [],
                "artifacts": [],
            }
            mp.write_lock(project, lock)
            self.assertEqual(mp.check_fresh(project), lock)
            write(project / "subprojects" / "a.wrap", "changed")
            with self.assertRaises(mp.PurifierError):
                mp.check_fresh(project)


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
            self.assertEqual(lock["inputsHash"], mp.inputs_hash(project, "subprojects"))
            # The lock run extracts subprojects in a copy, not in the project.
            self.assertFalse((subprojects / "a-1.0").exists())


if __name__ == "__main__":
    unittest.main()
