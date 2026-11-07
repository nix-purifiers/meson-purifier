"""Compare complete canonical fixture outputs from distinct native CI stores."""

import argparse
import base64
import json
import re
from pathlib import Path


def receipt(directory):
    def read(name):
        return json.loads((directory / name).read_text())

    context = read("fixture-context.json")
    sdk = read("fixture-sdk.json")
    outputs = read("fixture-tests-output.json")
    if len(outputs) != 1:
        raise ValueError("expected exactly one compiled fixture output")
    output, info = next(iter(outputs.items()))
    if not re.fullmatch(
        r"/nix/store/[a-z0-9]{32}-external-fixture-tests-1\.0\.0", output
    ):
        raise ValueError("receipt is not the compiled fixture output")
    if info.get("deriver") != sdk["tests"]:
        raise ValueError("compiled output does not match executed tests derivation")
    if (
        context["expectedOutput"] != output
        or context["expectedDerivation"] != info["deriver"]
    ):
        raise ValueError("absence precondition concerns a different compiled target")
    if sdk["system"] != "aarch64-darwin" or context["uname"] != ["Darwin", "arm64"]:
        raise ValueError("comparison requires actual native Darwin receipts")
    if (
        context["outputAbsentBeforeBuild"] is not True
        or context["mode"] != "fresh-store"
    ):
        raise ValueError("compiled output was not absent before its normal build")
    if context["sandbox"] is not True:
        raise ValueError("normal build did not require sandbox=true")
    if sdk["meson"]["version"] != "1.12.1":
        raise ValueError("unexpected Meson SDK point")
    if not sdk["compiler"] or not sdk["python"] or not sdk["meson"]["derivation"]:
        raise ValueError("incomplete native SDK identity")
    algorithm, digest = info["narHash"].split("-", 1)
    if algorithm != "sha256" or len(base64.b64decode(digest, validate=True)) != 32:
        raise ValueError("invalid full-output NAR hash")
    if not isinstance(info["narSize"], int) or info["narSize"] <= 0:
        raise ValueError("missing complete NAR size")
    source = (directory / "versions.txt").read_text().splitlines()[0]
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("missing immutable source revision")
    return {
        "context": context,
        "sdk": sdk,
        "output": output,
        "info": info,
        "source": source,
        "lock": read("fixture.lock.json"),
    }


def compare(first, second):
    a, b = receipt(first), receipt(second)
    for key in ["source", "sdk", "output", "lock"]:
        if a[key] != b[key]:
            raise ValueError(f"different {key} across normal builds")
    for key in ["runId", "runAttempt", "nixVersion"]:
        if not a["context"][key] or a["context"][key] != b["context"][key]:
            raise ValueError(f"different or missing {key}")
    # Runner names need not be unique. Matrix indices identify separate
    # jobs; each also asserted absence of the same canonical output.
    if not a["context"]["runnerName"] or not b["context"]["runnerName"]:
        raise ValueError("missing native runner identity")
    for key in ["jobIndex", "replica"]:
        if (
            not a["context"][key]
            or not b["context"][key]
            or a["context"][key] == b["context"][key]
        ):
            raise ValueError(f"receipts must come from distinct {key} values")
    for key in ["deriver", "narHash", "narSize"]:
        if a["info"][key] != b["info"][key]:
            raise ValueError(f"compiled outputs have different {key}")
    return {
        "source": a["source"],
        "sdk": a["sdk"],
        "output": a["output"],
        "derivation": a["info"]["deriver"],
        "narHash": a["info"]["narHash"],
        "narSize": a["info"]["narSize"],
        "contexts": [a["context"], b["context"]],
        "comparison": "full NAR equality, including signatures; no normalization",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("first", type=Path)
    parser.add_argument("second", type=Path)
    parser.add_argument("result", type=Path)
    args = parser.parse_args()
    args.result.write_text(
        json.dumps(compare(args.first, args.second), indent=2, sort_keys=True) + "\n"
    )
