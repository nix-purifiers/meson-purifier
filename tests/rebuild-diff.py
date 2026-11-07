"""Bounded diagnostics for this fixture's retained Nix .check output."""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

MAX_FILES = 128
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_WINDOWS = 8
CONTEXT = 24


def inventory(root):
    result = {}
    if not root.is_dir():
        return result
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if len(result) >= MAX_FILES:
                raise ValueError("fixture output exceeds diagnostic file limit")
            info = path.lstat()
            entry = {"mode": stat.S_IMODE(info.st_mode), "size": info.st_size}
            if stat.S_ISLNK(info.st_mode):
                entry.update(type="symlink", target=os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                entry = {"type": "directory", "mode": entry["mode"]}
            elif stat.S_ISREG(info.st_mode):
                entry["type"] = "file"
                if info.st_size <= MAX_FILE_BYTES:
                    entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                else:
                    entry["hashUnavailable"] = "file exceeds diagnostic byte limit"
            else:
                entry["type"] = "other"
            result[relative] = entry
    return result


def differences(old, new):
    left, right = old.read_bytes(), new.read_bytes()
    result = []
    offset = 0
    while offset < max(len(left), len(right)) and len(result) < MAX_WINDOWS:
        if left[offset : offset + 1] == right[offset : offset + 1]:
            offset += 1
            continue
        start = max(0, offset - CONTEXT)
        end = offset + CONTEXT + 1
        result.append(
            {
                "offset": offset,
                "start": start,
                "oldHex": left[start:end].hex(),
                "newHex": right[start:end].hex(),
            }
        )
        offset = end
    return result


def macho_metadata(path):
    # Host inspection only; never execute the produced binary.
    tool = shutil.which("otool")
    if tool is None or path.read_bytes()[:4] not in (
        b"\xcf\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
    ):
        return None
    result = subprocess.run(
        [tool, "-l", str(path)], capture_output=True, timeout=10, check=False
    )
    return {
        "exitCode": result.returncode,
        "loadCommands": result.stdout[:16384].decode(errors="replace"),
    }


def collect(old, new):
    if not re.fullmatch(r"[a-z0-9]{32}-external-fixture-tests-1\.0\.0", old.name):
        raise ValueError(
            "only the known external-fixture-tests output may be collected"
        )
    if str(new) != str(old) + ".check":
        raise ValueError("rebuilt output must be the exact original path plus .check")
    if old.is_symlink() or new.is_symlink():
        raise ValueError("fixture output roots must be physical directories")
    before, after = inventory(old), inventory(new)
    report = {
        "old": str(old),
        "rebuilt": str(new),
        "oldAvailable": old.is_dir(),
        "rebuiltAvailable": new.is_dir(),
        "files": [],
    }
    for name in sorted(before.keys() | after.keys()):
        a, b = before.get(name), after.get(name)
        unmeasured = any(x and "hashUnavailable" in x for x in [a, b])
        entry = {
            "path": name,
            "old": a,
            "rebuilt": b,
            "changed": None if unmeasured else a != b,
        }
        if a != b and a and b and "sha256" in a and "sha256" in b:
            entry["byteWindows"] = differences(old / name, new / name)
            for label, path in [("oldMachO", old / name), ("rebuiltMachO", new / name)]:
                metadata = macho_metadata(path)
                if metadata:
                    entry[label] = metadata
        report["files"].append(entry)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old", type=Path)
    parser.add_argument("rebuilt", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    args.report.write_text(
        json.dumps(collect(args.old, args.rebuilt), indent=2, sort_keys=True) + "\n"
    )
