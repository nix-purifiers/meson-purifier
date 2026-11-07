#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Independent upstream source and its full C/C++ test suite. inih has no
# external wraps; tier2.sh covers the nonempty zlib + inih wrap graph.
set -euo pipefail
repository=$(cd "$(dirname "$0")/.." && pwd)
sandbox_setting=$(nix config show sandbox)
test "$sandbox_setting" = true
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
source=$(nix eval --impure --raw --expr 'builtins.fetchTarball {
  url = "https://github.com/benhoyt/inih/archive/611ab51f8dd7ec583543815b0de693495045fbf8.tar.gz";
  sha256 = "0ranssdihn9b8q46nnqhx2ikxi4mcx93vwfl6iqdikn2djnn898y";
}')
test -d "$source"
cp -R "$source" "$work/inih"
chmod -R u+w "$work/inih"
cd "$work/inih"
meson-purifier lock . -- -Dtests=true
cache=$(meson-purifier prefetch)
test -d "$cache"
if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$TIER2_EVIDENCE_DIR"
  cp meson-purifier.lock.json "$TIER2_EVIDENCE_DIR/inih.lock.json"
  printf 'source=%s\nsandbox=%s\ninih=611ab51f8dd7ec583543815b0de693495045fbf8\nnar=0ranssdihn9b8q46nnqhx2ikxi4mcx93vwfl6iqdikn2djnn898y\n' \
    "$(git -C "$repository" rev-parse HEAD)" "$sandbox_setting" >"$TIER2_EVIDENCE_DIR/inih-run.txt"
fi
nix build --impure --option sandbox true --option allow-import-from-derivation false \
  --file "$repository/tests/tier2-build.nix" \
  --argstr repository "$repository" --argstr project "$PWD" \
  --argstr pname inih --argstr version 63 \
  --out-link "$work/pure" --print-build-logs
"$work/pure/bin/inih-proof" | grep -qx 'inih parsed 42'
if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
  nix path-info --json "$work/pure" >"$TIER2_EVIDENCE_DIR/inih-output.json"
  nix derivation show "$work/pure" >"$TIER2_EVIDENCE_DIR/inih-derivation.json"
  cp -f "$work/pure/sdk.json" "$TIER2_EVIDENCE_DIR/inih-sdk.json"
fi
export NIX_CONFIG="${NIX_CONFIG:-}
substitute = false
substituters =
"
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy ALL_PROXY=$http_proxy
MESON_PACKAGE_CACHE_DIR="$cache/cache" "$MESON_PURIFIER_PLAIN_MESON" setup build \
  --wrap-mode=nodownload -Dtests=true
meson compile -C build -j "${TIER2_JOBS:-2}"
meson test -C build
python3 - <<'PY'
import json
tests = json.load(open('build/meson-info/intro-tests.json'))
assert len(tests) == 18, tests
PY
echo "inih full suite and installed-library consumer passed on $(uname -sm)"
