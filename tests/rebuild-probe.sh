#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Explicit backend diagnostic, separate from strict canonical-output equality.
set -euo pipefail
repository=$(cd "$(dirname "$0")/.." && pwd)
evidence=${TIER2_EVIDENCE_DIR:?missing evidence directory}
test_output=$(python3 - "$evidence/fixture-tests-output.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert len(value) == 1
print(next(iter(value)))
PY
)
test_drv=$(python3 - "$evidence/fixture-sdk.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['tests'])
PY
)
if nix build "${test_drv}^out" --offline --rebuild --keep-failed --no-link \
  --option sandbox true --print-build-logs >"$evidence/backend-rebuild.log" 2>&1; then
  rebuild_status=0
else
  rebuild_status=$?
fi
cat "$evidence/backend-rebuild.log"
printf '{"exitCode":%s,"diagnosticOnly":true}\n' "$rebuild_status" >"$evidence/backend-rebuild-status.json"
if [ "$rebuild_status" -ne 0 ]; then
  python3 "$repository/tests/rebuild-diff.py" "$test_output" "$test_output.check" \
    "$evidence/backend-rebuild-diff.json"
fi
exit "$rebuild_status"
