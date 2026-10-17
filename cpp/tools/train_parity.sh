#!/usr/bin/env bash
# Train the shipped example experiments with pwcli and compare each history.csv against the
# Swift CLI reference in cpp/tests/parity/training (same seed, 3 generations).
# usage: train_parity.sh <pwcli> [rtol]   (rtol 0 = bit-identical, used on macOS)
set -euo pipefail
PWCLI="$1"; RTOL="${2:-0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/pw-train-parity"; rm -rf "$OUT"; mkdir -p "$OUT"
PY=$(command -v python3 || command -v python)
fail=0
for e in hold100-ga hover-pid hover-ducted-rocket glide-cmaes; do
  for w in 1 4; do
    "$PWCLI" --train "$ROOT/examples/experiments/$e.json" --generations 3 --workers $w --out "$OUT/$e-w$w" > "$OUT/$e-w$w.log" 2>&1 \
      || { echo "FAIL $e (workers $w): pwcli exited $?"; tail -20 "$OUT/$e-w$w.log"; fail=1; continue; }
    if res=$("$PY" -I "$ROOT/cpp/tools/compare_history.py" "$ROOT/cpp/tests/parity/training/$e.history.csv" "$OUT/$e-w$w/history.csv" --rtol "$RTOL"); then
      echo "ok   $e workers=$w: $res"
    else echo "FAIL $e workers=$w:"; echo "$res"; fail=1; fi
  done
done
exit $fail
