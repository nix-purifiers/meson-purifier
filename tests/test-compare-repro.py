import base64
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "compare_repro", Path(__file__).with_name("compare-repro.py")
)
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class CanonicalComparisonTest(unittest.TestCase):
    def test_complete_identity_and_negative_controls(self):
        with tempfile.TemporaryDirectory() as work:
            a, b = Path(work) / "a", Path(work) / "b"
            output = "/nix/store/" + "a" * 32 + "-external-fixture-tests-1.0.0"
            drv = "/nix/store/" + "b" * 32 + "-external-fixture-tests-1.0.0.drv"
            data = {
                "fixture-context.json": {
                    "mode": "fresh-store",
                    "sandbox": True,
                    "outputAbsentBeforeBuild": True,
                    "expectedOutput": output,
                    "expectedDerivation": drv,
                    "uname": ["Darwin", "arm64"],
                    "runId": "1",
                    "runAttempt": "1",
                    "nixVersion": "nix 2.35.2",
                    "runnerName": "runner-one",
                    "replica": "one",
                },
                "fixture-sdk.json": {
                    "system": "aarch64-darwin",
                    "tests": drv,
                    "compiler": "21.1.8",
                    "python": "3.14.8",
                    "meson": {
                        "version": "1.12.1",
                        "derivation": "/nix/store/meson-1.12.1.drv",
                    },
                },
                "fixture-tests-output.json": {
                    output: {
                        "deriver": drv,
                        "narHash": "sha256-" + base64.b64encode(b"a" * 32).decode(),
                        "narSize": 100,
                    }
                },
                "fixture.lock.json": {"contentHash": "locked"},
            }
            for directory in [a, b]:
                directory.mkdir()
                for name, value in data.items():
                    (directory / name).write_text(json.dumps(value))
                (directory / "versions.txt").write_text("a" * 40 + "\n")
            other = copy.deepcopy(data)
            other["fixture-context.json"].update(runnerName="runner-two", replica="two")

            def write_other():
                for name, value in other.items():
                    (b / name).write_text(json.dumps(value))

            write_other()
            self.assertEqual(comparison.compare(a, b)["narSize"], 100)
            for file, key, value in [
                ("fixture-context.json", "outputAbsentBeforeBuild", False),
                ("fixture-context.json", "sandbox", False),
                ("fixture-context.json", "runnerName", "runner-one"),
                ("fixture-context.json", "runId", "different-run"),
                ("fixture-sdk.json", "system", "x86_64-linux"),
            ]:
                original = other[file][key]
                other[file][key] = value
                write_other()
                with self.assertRaises(ValueError):
                    comparison.compare(a, b)
                other[file][key] = original
            other["fixture-tests-output.json"][output]["narHash"] = (
                "sha256-" + base64.b64encode(b"b" * 32).decode()
            )
            write_other()
            with self.assertRaisesRegex(ValueError, "different narHash"):
                comparison.compare(a, b)


if __name__ == "__main__":
    unittest.main()
