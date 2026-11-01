#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The interactive commands on copies of the fixture project, the way a
# developer uses them: `meson setup`, `meson compile` and `meson test`
# through the toolchain's meson without the network, an edit to meson.build,
# clangd on the build directory, `meson-purifier download`, and the errors
# for the common mistakes. Interactive commands build the package cache
# through nix-build, so this runs outside the Nix sandbox: in CI, and by
# hand with
#
#   tests/interactive.sh "$(nix build --print-out-paths .#toolchain)"
#
# A C compiler, python3 and clangd must be on PATH.
set -euo pipefail

toolchain=$(realpath "$1")
fixture=$(realpath "$(dirname "$0")/fixtures/app")
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
export PATH="$toolchain/bin:$PATH"

copy() {
  cp -r "$fixture" "$work/$1"
  chmod -R u+w "$work/$1"
  cd "$work/$1"
}

# Runs a command that must fail, and checks that its output names the
# problem and `meson-purifier lock`.
fails_with() {
  local pattern=$1
  shift
  if "$@" >"$work/output" 2>&1; then
    echo "expected a failure: $*" >&2
    exit 1
  fi
  if ! grep -q -- "$pattern" "$work/output" || ! grep -q 'meson-purifier lock' "$work/output"; then
    cat "$work/output" >&2
    echo "the error of '$*' does not name '$pattern' and \`meson-purifier lock\`" >&2
    exit 1
  fi
}

offline() {
  export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
  export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy ALL_PROXY=$http_proxy
}

online() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
}

# A hash changed by hand no longer matches the contentHash of the lockfile.
copy tampered
sed -i 's|"sha256-jnMGOncnH+ffgtyNzA8tZPtxPCR/yq9jmPsJZE4BhXo="|"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="|' meson-purifier.lock.json
fails_with 'edited by hand' meson-purifier prefetch

# The package cache comes from the Nix store; build it while the network is
# there.
copy app
meson-purifier prefetch >/dev/null

# From here on every connection goes to a closed port, so a download by
# Meson, git, hg or svn fails.
offline
fallbacks=--force-fallback-for=zlib,inih,libcjson,yaml-0.1

meson setup build "$fallbacks"
# Meson installs cjson.wrap from wrapdb.json when it configures with the
# network; the toolchain installs it from the lockfile.
test -f subprojects/cjson.wrap
meson compile -C build
meson test -C build
./build/purifier-fixture | tee "$work/run"
grep -qx 'purified by Nix, hello, 14, libyaml 0.2.5, hg [0-9]* bytes, svn [0-9]* bytes' "$work/run"

# The installed wrap leaves the lockfile current.
meson setup --reconfigure build "$fallbacks"

# An edit to the build definition leaves the downloads current, so the
# everyday loop goes on without a relock.
echo "# an edit" >>meson.build
meson compile -C build

# clangd reads the build directory's compile_commands.json, which points
# into the subprojects Meson extracted from the package cache.
# An empty --tweaks leaves out clangd's self-test of its refactorings,
# which reports failures of its own that say nothing about the build.
clangd --check=main.c --tweaks= --compile-commands-dir=build >"$work/clangd" 2>&1 || {
  cat "$work/clangd" >&2
  exit 1
}

# A changed wrap file makes the lockfile stale: commands that need the
# downloads refuse, and the commands that change wraps still run.
echo "# changed" >>subprojects/zlib.wrap
fails_with 'wrap files changed' meson setup build-stale "$fallbacks"
meson subprojects foreach true >/dev/null

# A lockfile without a download stops Meson at that subproject, with a
# hint. The script writes the lockfile with a matching contentHash, as
# `meson-purifier lock` does.
copy missing
python3 - meson-purifier.lock.json <<'EOF'
import hashlib, json, sys
path = sys.argv[1]
data = json.load(open(path))
data["wrapFiles"] = [name for name in data["wrapFiles"] if name != "zlib.wrap"]
del data["contentHash"]
text = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
data["contentHash"] = hashlib.sha256(text.encode()).hexdigest()
open(path, "w").write(json.dumps(data, indent=2) + "\n")
EOF
fails_with 'does not hold' meson setup build "$fallbacks"

# A lockfile left with merge conflict markers.
copy conflict
sed -i '2i <<<<<<< HEAD' meson-purifier.lock.json
fails_with 'not valid JSON' meson setup build "$fallbacks"

# The install step, in a fresh copy: every locked subproject of the main
# project, extracted with its patches.
copy download
meson-purifier download
for directory in zlib-1.3.2 inih hghooks svn-examples cJSON-1.7.19 \
  tinyexpr-ba2e32bbcc2d1e644a7e132d24c2f542821cabe0; do
  test -f "subprojects/$directory/meson.build"
done
grep -q TINYEXPR_PURIFIED subprojects/tinyexpr-ba2e32bbcc2d1e644a7e132d24c2f542821cabe0/tinyexpr.h

online
echo "the interactive commands worked offline"
