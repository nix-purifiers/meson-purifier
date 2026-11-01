#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks the fixture project and fails when the lockfile it writes differs
# from the committed one. A lock run needs the network, so this runs outside
# the Nix sandbox: in CI, and by hand with
#
#   tests/lock-run.sh "$(nix build --print-out-paths .#toolchain)"
#
# The lock run configures a copy of the fixture, to find its outputs and the
# wrap it installs from wrapdb.json: a C compiler and pkg-config must be on
# PATH.
set -euo pipefail

toolchain=$(realpath "$1")
cd "$(dirname "$0")/fixtures/app"

"$toolchain/bin/meson-purifier" lock . -- --force-fallback-for=zlib,inih,libcjson,yaml-0.1
git diff --exit-code -- meson-purifier.lock.json
echo "the lock run reproduced tests/fixtures/app/meson-purifier.lock.json"
