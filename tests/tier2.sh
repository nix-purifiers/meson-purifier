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
sandbox_setting=$(nix config show sandbox)
test "$sandbox_setting" = true
repro_mode=${TIER2_REPRO_MODE:-in-place}
case "$repro_mode" in in-place|fresh-store) ;; *) exit 2 ;; esac
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
  printf 'sandbox=%s\n' "$sandbox_setting" >>"$TIER2_EVIDENCE_DIR/versions.txt"
fi
cp -R . "$work/pure-source"
cache=$(meson-purifier prefetch)
test -d "$cache"

# Evaluation establishes only the expected identity and absence precondition.
# The following normal build must compile and execute the target itself.
TIER2_REPO_FOR_EVAL="$repository" TIER2_SOURCE_FOR_EVAL="$work/pure-source" \
nix eval --impure --json --option allow-import-from-derivation false \
  --file "$repository/tests/tier2-build.nix" \
  --apply 'f: let d = f {
    repository = builtins.getEnv "TIER2_REPO_FOR_EVAL";
    project = builtins.getEnv "TIER2_SOURCE_FOR_EVAL";
    result = "tests";
  }; in { derivation = d.drvPath; output = d.outPath; }' \
  >"$work/expected-tests.json"
python3 - "$work/expected-tests.json" "$work/context.json" "$repro_mode" "$sandbox_setting" <<'PY'
import json, os, subprocess, sys
identity = json.load(open(sys.argv[1]))
absent = not os.path.lexists(identity['output'])
if sys.argv[3] == 'fresh-store' and not absent:
    raise SystemExit('canonical compiled output already exists before normal build')
context = {
    'mode': sys.argv[3], 'outputAbsentBeforeBuild': absent,
    'sandbox': sys.argv[4] == 'true',
    'expectedOutput': identity['output'], 'expectedDerivation': identity['derivation'],
    'uname': [os.uname().sysname, os.uname().machine],
    'nixVersion': subprocess.check_output(['nix', '--version'], text=True).strip(),
    'runId': os.environ.get('GITHUB_RUN_ID'), 'runAttempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
    'runnerName': os.environ.get('RUNNER_NAME'), 'replica': os.environ.get('TIER2_REPLICA'),
    'jobIndex': os.environ.get('TIER2_JOB_INDEX'),
}
json.dump(context, open(sys.argv[2], 'w'), indent=2)
print('normal-build output absent before compilation:', absent, identity['output'])
PY

# Prime the pure derivation before disabling Nix substitution. Its build
# is sandboxed; the following rebuild verifies it from those same inputs.
nix build --impure --option sandbox true --option allow-import-from-derivation false --file "$repository/tests/tier2-build.nix" \
  --argstr repository "$repository" --argstr project "$work/pure-source" \
  --out-link "$work/pure" --print-build-logs 2>&1 | tee "$work/normal-build.log"
"$work/pure/bin/external-fixture" | grep -qx 'external, zlib 1.3.2'
test_output=$(dirname "$(readlink "$work/pure/bin")")
if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
  nix path-info --json "$work/pure" >"$TIER2_EVIDENCE_DIR/fixture-output.json"
  nix derivation show "$work/pure" >"$TIER2_EVIDENCE_DIR/fixture-derivation.json"
  cp -f "$work/pure/sdk.json" "$TIER2_EVIDENCE_DIR/fixture-sdk.json"
  cp "$work/context.json" "$TIER2_EVIDENCE_DIR/fixture-context.json"
  nix path-info --json --json-format 1 "$test_output" >"$TIER2_EVIDENCE_DIR/fixture-tests-output.json"
  nix derivation show "$test_output" >"$TIER2_EVIDENCE_DIR/fixture-tests-derivation.json"
  tail -c 4194304 "$work/normal-build.log" >"$TIER2_EVIDENCE_DIR/fixture-normal-build.log"
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

if [ "$repro_mode" = in-place ]; then
# Nix documents --keep-failed as retaining a differing output at .check:
# https://nix.dev/manual/nix/2.30/advanced-topics/diff-hook.html
if nix build --offline --rebuild --keep-failed --impure --option sandbox true --option allow-import-from-derivation false --file "$repository/tests/tier2-build.nix" \
  --argstr repository "$repository" --argstr project "$work/pure-source" \
  --argstr result tests \
  --out-link "$work/pure-after" --print-build-logs >"$work/rebuild.log" 2>&1; then
  cat "$work/rebuild.log"
else
  rebuild_status=$?
  cat "$work/rebuild.log"
  if [ -n "${TIER2_EVIDENCE_DIR:-}" ]; then
    cp "$work/rebuild.log" "$TIER2_EVIDENCE_DIR/rebuild.log"
    if ! python3 "$repository/tests/rebuild-diff.py" "$test_output" "$test_output.check" \
      "$TIER2_EVIDENCE_DIR/rebuild-diff.json"; then
      echo 'bounded rebuild diagnostics could not be collected' >&2
    fi
  fi
  exit "$rebuild_status"
fi
"$work/pure-after/bin/external-fixture" | grep -qx 'external, zlib 1.3.2'
else
  echo 'Whole-output equality is required by the separate fresh-store Nix comparison job.'
fi

# A changed dependency declaration must be refused, before resolution.
echo '# changed wrap' >>subprojects/zlib.wrap
if meson setup stale "$fallbacks" >"$work/stale.log" 2>&1; then
  echo 'accepted a stale wrap lock' >&2
  exit 1
fi
grep -q 'wrap files changed' "$work/stale.log"
grep -q 'meson-purifier lock' "$work/stale.log"
echo "Tier 2 runtime passed on $(uname -sm)"
