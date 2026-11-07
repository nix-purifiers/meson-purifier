#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# A real upstream consumer, using a fresh platform-specific output lock.
set -euo pipefail
repository=$(cd "$(dirname "$0")/.." && pwd)
sandbox_setting=$(nix config show sandbox)
test "$sandbox_setting" = true
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
source=$(nix eval --impure --raw --expr 'builtins.fetchTarball {
  url = "https://github.com/rizinorg/rizin/archive/c3a90e9226d977f58f4e9c75f78fa6b07afe13c7.tar.gz";
  sha256 = "1sa4n832gzyjn5hmj2j26fgglw2nv8fwb402wifs1kj1qnrxnnsp";
}')
cp -R "$source" "$work/rizin"
chmod -R u+w "$work/rizin"
# Upstream CI supplies this external corpus too (test/README.md). Pin the
# latest corpus commit preceding the sample commit; do not skip its tests.
corpus=$(nix eval --impure --raw --expr 'builtins.fetchTarball {
  url = "https://github.com/rizinorg/rizin-testbins/archive/7f54b4970d413fe163f4f09dcfd9a328376133f0.tar.gz";
  sha256 = "1wy5ad59fax35a2mn1awmwx84sr4mafrp58cpmf1hswjn2kly3px";
}')
cp -R "$corpus" "$work/rizin/test/bins"
chmod -R u+w "$work/rizin/test/bins"
cd "$work/rizin"
# Use the fallback declared by the upstream wrap. Some development
# networks cannot reach libzip.org; both URLs must yield this same hash.
nix store prefetch-file --hash-type sha256 \
  --expected-hash 82e9f2f2421f9d7c2466bbc3173cd09595a88ea37db0d559a9d0a2dc60dc722e \
  --name libzip-1.11.4.tar.gz \
  https://github.com/nih-at/libzip/releases/download/v1.11.4/libzip-1.11.4.tar.gz >/dev/null
meson-purifier lock . -- -Dregenerate_cmds=disabled
if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$TIER2_EVIDENCE_DIR"
  cp meson-purifier.lock.json "$TIER2_EVIDENCE_DIR/rizin.lock.json"
  printf 'source=%s\nsandbox=%s\n' "$(git -C "$repository" rev-parse HEAD)" "$sandbox_setting" \
    >"$TIER2_EVIDENCE_DIR/rizin-run.txt"
  printf '%s\n' 'rizin c3a90e9226d977f58f4e9c75f78fa6b07afe13c7 1sa4n832gzyjn5hmj2j26fgglw2nv8fwb402wifs1kj1qnrxnnsp' \
    'testbins 7f54b4970d413fe163f4f09dcfd9a328376133f0 1wy5ad59fax35a2mn1awmwx84sr4mafrp58cpmf1hswjn2kly3px' \
    >"$TIER2_EVIDENCE_DIR/rizin-sources.txt"
fi
cache=$(meson-purifier prefetch)
test -d "$cache"
nix build --impure --option sandbox true --option allow-import-from-derivation false --file "$repository/tests/tier2-build.nix" \
  --argstr repository "$repository" --argstr project "$PWD" \
  --argstr pname rizin --argstr version 0.9.1 \
  --out-link "$work/pure" --print-build-logs
"$work/pure/bin/rizin" -v | grep -q 'rizin 0.9.1'
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
meson compile -C build -j "${TIER2_JOBS:-2}" rizin rz-asm
./build/binrz/rizin/rizin -v | grep -q 'rizin 0.9.1'
test "$(echo 'mov eax, 1' | ./build/binrz/rz-asm/rz-asm -a x86 -b 32 -)" = b801000000
echo "Rizin runtime passed on $(uname -sm)"
