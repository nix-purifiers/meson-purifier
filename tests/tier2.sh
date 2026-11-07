#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run with nix develop .#tier2 -c tests/tier2.sh. Generate the lock on
# each platform: installed library filenames are platform dependent.
set -euo pipefail
repository=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
cp -R "$repository/tests/fixtures/external" "$work/app"
chmod -R u+w "$work/app"
cd "$work/app"
plain=${MESON_PURIFIER_PLAIN_MESON:?run in the tier2 dev shell}
fallbacks=--force-fallback-for=zlib,inih
python3 - <<'PY'
from pathlib import Path
p = Path('meson.build')
p.write_text(p.read_text().replace('executable(', 'app = executable(') + "\ntest('runtime', app)\n")
PY
meson --version
"$plain" --version
cc --version
meson-purifier lock . -- "$fallbacks"
cp meson-purifier.lock.json "$work/first-lock.json"
meson-purifier lock . -- "$fallbacks"
cmp "$work/first-lock.json" meson-purifier.lock.json
if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$TIER2_EVIDENCE_DIR"
  cp meson-purifier.lock.json "$TIER2_EVIDENCE_DIR/fixture.lock.json"
  { git -C "$repository" rev-parse HEAD; uname -sm; meson --version; cc --version; } \
    >"$TIER2_EVIDENCE_DIR/versions.txt"
fi
cp -R . "$work/pure-source"
cache=$(meson-purifier prefetch)
test -d "$cache"

# Prime the pure derivation before disabling Nix substitution. Its build
# is sandboxed; the following rebuild verifies it from those same inputs.
nix build --impure --option allow-import-from-derivation false --file "$repository/tests/tier2-build.nix" \
  --argstr repository "$repository" --argstr project "$work/pure-source" \
  --out-link "$work/pure" --print-build-logs
"$work/pure/bin/external-fixture" | grep -qx 'external, zlib 1.3.2'
if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
  nix path-info --json "$work/pure" >"$TIER2_EVIDENCE_DIR/fixture-output.json"
  nix derivation show "$work/pure" >"$TIER2_EVIDENCE_DIR/fixture-derivation.json"
  cp -f "$work/pure/sdk.json" "$TIER2_EVIDENCE_DIR/fixture-sdk.json"
fi

# Nix substitution is disabled; Meson is explicitly nodownload. Closed proxies are an
# additional guard for HTTP clients, not a claim of OS network isolation.
export NIX_CONFIG="${NIX_CONFIG:-}
substitute = false
substituters =
"
export http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy ALL_PROXY=$http_proxy

# A cold ordinary configure must really need the prefetched archives,
# rather than reusing subprojects extracted by an earlier configuration.
cp -R "$work/pure-source" "$work/plain-source"
mkdir "$work/empty-cache"
if MESON_PACKAGE_CACHE_DIR="$work/empty-cache" "$plain" setup \
  "$work/missing-build" "$work/plain-source" --wrap-mode=nodownload "$fallbacks" \
  >"$work/missing-cache.log" 2>&1; then
  echo 'ordinary Meson unexpectedly configured with an empty cache' >&2
  exit 1
fi
grep -q 'Automatic wrap-based subproject downloading is disabled' "$work/missing-cache.log"
MESON_PACKAGE_CACHE_DIR="$cache/cache" "$plain" setup \
  "$work/plain-build" "$work/plain-source" --wrap-mode=nodownload "$fallbacks"
"$plain" compile -C "$work/plain-build" -j "${TIER2_JOBS:-2}"
"$plain" test -C "$work/plain-build"
"$work/plain-build/external-fixture" | grep -qx 'external, zlib 1.3.2'

meson setup build "$fallbacks"
meson compile -C build -j "${TIER2_JOBS:-2}"
meson test -C build
./build/external-fixture | grep -qx 'external, zlib 1.3.2'

# Switch the existing build directory between the wrapper and ordinary
# upstream Meson, with the exact cache the purifier prefetched.
MESON_PACKAGE_CACHE_DIR="$cache/cache" "$plain" setup --reconfigure build \
  --wrap-mode=nodownload "$fallbacks"
"$plain" compile -C build -j "${TIER2_JOBS:-2}"
./build/external-fixture | grep -qx 'external, zlib 1.3.2'
meson setup --reconfigure build "$fallbacks"
meson compile -C build -j "${TIER2_JOBS:-2}"

nix build --offline --rebuild --impure --option allow-import-from-derivation false --file "$repository/tests/tier2-build.nix" \
  --argstr repository "$repository" --argstr project "$work/pure-source" \
  --argstr result tests \
  --out-link "$work/pure-after" --print-build-logs
"$work/pure-after/bin/external-fixture" | grep -qx 'external, zlib 1.3.2'

# A changed dependency declaration must be refused, before resolution.
echo '# changed wrap' >>subprojects/zlib.wrap
if meson setup stale "$fallbacks" >"$work/stale.log" 2>&1; then
  echo 'accepted a stale wrap lock' >&2
  exit 1
fi
grep -q 'wrap files changed' "$work/stale.log"
grep -q 'meson-purifier lock' "$work/stale.log"
echo "Tier 2 runtime passed on $(uname -sm)"
