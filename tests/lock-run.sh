#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks the fixture projects and fails when a lockfile it writes differs
# from the committed one, among them the lockfiles of the conformance checks
# that tests/negative-locks.py derives from the fixture lockfile. A lock run
# needs the network, so this runs outside the Nix sandbox: in CI, and by
# hand with
#
#   tests/lock-run.sh "$(nix build --print-out-paths .#toolchain)"
#
# The lock run configures a copy of the fixture, to find its outputs and the
# wrap it installs from wrapdb.json: a C compiler and pkg-config must be on
# PATH.
set -euo pipefail

toolchain=$(realpath "$1")
cd "$(dirname "$0")"

"$toolchain/bin/meson-purifier" lock fixtures/app -- --force-fallback-for=zlib,inih,libcjson,yaml-0.1
"$toolchain/bin/meson-purifier" lock fixtures/update -- --force-fallback-for=zlib
"$toolchain/bin/meson-purifier" lock --lockfile lockfiles/external.lock.json fixtures/external \
  -- --force-fallback-for=zlib,inih
python3 negative-locks.py
git diff --exit-code -- fixtures/app/meson-purifier.lock.json \
  fixtures/update/meson-purifier.lock.json lockfiles
echo "the lock runs reproduced the committed lockfiles"
