# SPDX-License-Identifier: MIT
#
# Writes the lockfiles of the conformance checks into tests/lockfiles/, each
# the fixture lockfile with one fault. The checks read them as files, because
# `nix flake check --no-build` evaluates without writing to the store, so a
# check cannot make a file at evaluation. tests/lock-run.sh runs this after
# each relock, and its `git diff --exit-code` fails when a committed file is
# out of date.
#
#   python3 tests/negative-locks.py
import hashlib
import json
from pathlib import Path

tests = Path(__file__).resolve().parent
fixture = json.loads((tests / "fixtures/app/meson-purifier.lock.json").read_text())


def content_hash(data: dict) -> str:
    # The rule of content_hash in pkgs/cli/meson_purifier.py.
    rest = {key: value for key, value in data.items() if key != "contentHash"}
    text = json.dumps(rest, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(text.encode()).hexdigest()


def text(data: dict) -> str:
    return json.dumps(data, indent=2) + "\n"


def relocked(**fields) -> str:
    """The fixture lockfile with `fields`, and a contentHash that matches,
    as `meson-purifier lock` would write it."""
    data = {key: value for key, value in fixture.items() if key != "contentHash"}
    data.update(fields)
    for key in [key for key, value in fields.items() if value is None]:
        del data[key]
    data["contentHash"] = content_hash(data)
    return text(data)


def tampered() -> str:
    data = json.loads(json.dumps(fixture))
    for entry in data["artifacts"]:
        if entry["path"] == "inih":
            entry["hash"] = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    return text(data)


fixture_text = text(fixture)
lockfiles = {
    # Wrap files that changed since the lock run.
    "stale.json": relocked(wrapsHash="0"),
    # A build definition that changed since the lock run, which is a warning.
    "stale-definition.json": relocked(definitionHash="0"),
    # A hash changed by hand.
    "tampered.json": tampered(),
    # A lockfile without the archives of zlib.
    "missing.json": relocked(
        wrapFiles=[name for name in fixture["wrapFiles"] if name != "zlib.wrap"]
    ),
    # A merge that left conflict markers.
    "conflicted.json": "{\n<<<<<<< HEAD\n" + fixture_text[2:],
    "no-outputs.json": relocked(outputs=None),
    "no-source.json": relocked(
        artifacts=[{"path": "x.tar.gz", "mirrors": [], "hash": "sha256-x"}]
    ),
    "escaping-path.json": relocked(
        artifacts=[
            {
                "path": "../escape",
                "url": "https://example.org/x",
                "mirrors": [],
                "hash": "sha256-x",
            }
        ]
    ),
    "bad-wrap-file.json": relocked(wrapFiles=["../zlib.wrap"]),
    "old-version.json": relocked(version=2),
}

directory = tests / "lockfiles"
directory.mkdir(exist_ok=True)
for name, content in lockfiles.items():
    (directory / name).write_text(content)
