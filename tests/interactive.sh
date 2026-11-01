#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The interactive commands on a copy of the fixture project, without the
# network: `meson setup`, `meson compile` and `meson test` through the
# toolchain's meson, and `meson-purifier download`, which extracts every
# locked subproject into the subproject directory. Interactive commands
# build the package cache through nix-build, so this runs outside the Nix
# sandbox: in CI, and by hand with
#
#   tests/interactive.sh "$(nix build --print-out-paths .#toolchain)"
#
# A C compiler must be on PATH.
set -euo pipefail

toolchain=$(realpath "$1")
fixture=$(realpath "$(dirname "$0")/fixtures/app")
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -r "$fixture" "$work/app"
chmod -R u+w "$work/app"
cd "$work/app"
export PATH="$toolchain/bin:$PATH"
fallbacks=--force-fallback-for=zlib,inih,libcjson,yaml-0.1

# The package cache comes from the Nix store; build it while the network is
# there.
meson-purifier realize >/dev/null

# From here on every connection goes to a closed port, so a download by
# Meson, git, hg or svn fails.
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy ALL_PROXY=$http_proxy

meson setup build "$fallbacks"
# Meson installs cjson.wrap from wrapdb.json when it configures with the
# network; the toolchain installs it from the lockfile.
test -f subprojects/cjson.wrap
meson compile -C build
meson test -C build
./build/purifier-fixture | tee output
grep -qx 'purified by Nix, hello, 14, libyaml 0.2.5, hg [0-9]* bytes, svn [0-9]* bytes' output

# The installed wrap leaves the lockfile current.
meson setup --reconfigure build "$fallbacks"

# The install step, in a fresh copy: every locked subproject of the main
# project, extracted with its patches.
cp -r "$fixture" "$work/download"
chmod -R u+w "$work/download"
cd "$work/download"
meson-purifier download
for directory in zlib-1.3.2 inih hghooks svn-examples cJSON-1.7.19 \
  tinyexpr-ba2e32bbcc2d1e644a7e132d24c2f542821cabe0; do
  test -f "subprojects/$directory/meson.build"
done
grep -q TINYEXPR_PURIFIED subprojects/tinyexpr-ba2e32bbcc2d1e644a7e132d24c2f542821cabe0/tinyexpr.h

# A wrap file that changed after the lock run is refused.
echo "# changed" >>subprojects/zlib.wrap
if meson setup build "$fallbacks" 2>error; then
  echo "meson setup accepted a stale lockfile" >&2
  exit 1
fi
# shellcheck disable=SC2016 # the backquotes are part of the message
grep -q 'run `meson-purifier lock`' error

echo "the interactive commands worked offline"
