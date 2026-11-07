import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "rebuild_diff", Path(__file__).with_name("rebuild-diff.py")
)
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class CollectionTest(unittest.TestCase):
    def test_bounded_deterministic_collection_without_following_links(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            old = root / ("a" * 32 + "-external-fixture-tests-1.0.0")
            new = Path(str(old) + ".check")
            outside = root / "outside"
            outside.mkdir()
            (outside / "must-not-read").write_text("outside data")
            for path in [old, new]:
                path.mkdir()
                (path / "same").write_bytes(b"same")
                (path / "link").symlink_to(outside, target_is_directory=True)
                with (path / "large").open("wb") as file:
                    file.truncate(diagnostic.MAX_FILE_BYTES + 1)
            (old / "changed").write_bytes(b"aaa-old-bbb")
            (new / "changed").write_bytes(b"aaa-new-bbb")
            (new / "added").write_text("new")
            report = diagnostic.collect(old, new)
            self.assertEqual(
                json.dumps(report, sort_keys=True),
                json.dumps(diagnostic.collect(old, new), sort_keys=True),
            )
            files = {entry["path"]: entry for entry in report["files"]}
            self.assertNotIn("link/must-not-read", files)
            self.assertEqual(files["changed"]["byteWindows"][0]["offset"], 4)
            self.assertIn("hashUnavailable", files["large"]["old"])
            self.assertIsNone(files["large"]["changed"])
            self.assertFalse(files["same"]["changed"])
            self.assertIsNone(files["added"]["old"])
            self.assertTrue(report["rebuiltAvailable"])

    def test_missing_retained_output_is_explicit(self):
        with tempfile.TemporaryDirectory() as work:
            old = Path(work) / ("a" * 32 + "-external-fixture-tests-1.0.0")
            old.mkdir()
            self.assertFalse(
                diagnostic.collect(old, Path(str(old) + ".check"))["rebuiltAvailable"]
            )
            with self.assertRaises(ValueError):
                diagnostic.collect(old, Path(work))
            retained = Path(str(old) + ".check")
            retained.symlink_to(old, target_is_directory=True)
            with self.assertRaises(ValueError):
                diagnostic.collect(old, retained)


if __name__ == "__main__":
    unittest.main()
