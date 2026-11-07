#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# A real upstream consumer, using a fresh platform-specific output lock.
set -euo pipefail
repository=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
source=$(nix eval --impure --raw --expr 'builtins.fetchTarball {
  url = "https://github.com/rizinorg/rizin/archive/5a611eee2999d312317ff90d600e37dde0f58992.tar.gz";
  sha256 = "sha256-+3p3urhcRBASLMAExXbSq0BnmlPqF8OSSnBPmGVTPZU=";
}')
cp -R "$source" "$work/rizin"
chmod -R u+w "$work/rizin"
# Upstream CI supplies this external corpus too (test/README.md). Pin the
# latest corpus commit preceding the sample commit; do not skip its tests.
corpus=$(nix eval --impure --raw --expr 'builtins.fetchTarball {
  url = "https://github.com/rizinorg/rizin-testbins/archive/e80f49b37314108c6e8f2dcd51a9fb4f2271cefc.tar.gz";
  sha256 = "1w074azm422jj1nhf51sr9pn7q6kczjh7p7wwqa7mld5nyrkgpcr";
}')
cp -R "$corpus" "$work/rizin/test/bins"
chmod -R u+w "$work/rizin/test/bins"
cd "$work/rizin"
meson-purifier lock . -- -Dregenerate_cmds=disabled
if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$TIER2_EVIDENCE_DIR"
  cp meson-purifier.lock.json "$TIER2_EVIDENCE_DIR/rizin.lock.json"
  printf '%s\n' 'rizin 5a611eee2999d312317ff90d600e37dde0f58992 sha256-+3p3urhcRBASLMAExXbSq0BnmlPqF8OSSnBPmGVTPZU=' \
    'testbins e80f49b37314108c6e8f2dcd51a9fb4f2271cefc 1w074azm422jj1nhf51sr9pn7q6kczjh7p7wwqa7mld5nyrkgpcr' \
    >"$TIER2_EVIDENCE_DIR/rizin-sources.txt"
fi
cache=$(meson-purifier prefetch)
test -d "$cache"
nix build --impure --option allow-import-from-derivation false --file "$repository/tests/tier2-build.nix" \
  --argstr repository "$repository" --argstr project "$PWD" \
  --argstr pname rizin --argstr version 0.8.2 \
  --out-link "$work/pure" --print-build-logs
"$work/pure/bin/rizin" -v | grep -q 'rizin 0.8.2'
test "$(echo 'mov eax, 1' | "$work/pure/bin/rz-asm" -a x86 -b 32 -)" = b801000000
if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
  nix path-info --json "$work/pure" >"$TIER2_EVIDENCE_DIR/rizin-output.json"
  nix derivation show "$work/pure" >"$TIER2_EVIDENCE_DIR/rizin-derivation.json"
  cp -f "$work/pure/sdk.json" "$TIER2_EVIDENCE_DIR/rizin-sdk.json"
fi
export NIX_CONFIG="${NIX_CONFIG:-}
substitute = false
substituters =
"
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy ALL_PROXY=$http_proxy
MESON_PACKAGE_CACHE_DIR="$cache/cache" "$MESON_PURIFIER_PLAIN_MESON" setup build \
  --wrap-mode=nodownload -Dregenerate_cmds=disabled
meson compile -C build rizin rz-asm
./build/binrz/rizin/rizin -v | grep -q 'rizin 0.8.2'
test "$(echo 'mov eax, 1' | ./build/binrz/rz-asm/rz-asm -a x86 -b 32 -)" = b801000000
echo "Rizin runtime passed on $(uname -sm)"
