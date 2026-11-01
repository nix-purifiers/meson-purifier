#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-update: `meson-purifier update` on a copy of the update
# fixture, whose zlib wrap pins WrapDB release 1.3.1-1. The update moves
# the wrap to a newer release and writes the lockfile again. Then
# `meson-purifier prefetch` passes the stale checks of the command and of
# readLock in Nix, and builds the package cache of the new release. It
# needs the network, so it runs in CI, and by hand with
#
#   tests/update.sh "$(nix build --print-out-paths .#toolchain)"
#
# A C compiler must be on PATH.
set -euo pipefail

toolchain=$(realpath "$1")
fixture=$(realpath "$(dirname "$0")/fixtures/update")
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
export PATH="$toolchain/bin:$PATH"

cp -r "$fixture" "$work/update"
chmod -R u+w "$work/update"
cd "$work/update"

grep -qx 'wrapdb_version = 1.3.1-1' subprojects/zlib.wrap
meson-purifier update
if grep -qx 'wrapdb_version = 1.3.1-1' subprojects/zlib.wrap; then
  echo "meson-purifier update left zlib at 1.3.1-1" >&2
  exit 1
fi
cache=$(meson-purifier prefetch)
version=$(sed -n 's/^directory = zlib-//p' subprojects/zlib.wrap)
test -f "$cache/cache/zlib-$version.tar.gz" || test -f "$cache/cache/zlib-$version.tar.xz"
echo "updated zlib to $version"
