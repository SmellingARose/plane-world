#!/usr/bin/env bash
# Train the shipped example experiments with pwcli and compare each history.csv against the
# Swift CLI reference in cpp/tests/parity/training (same seed, 3 generations).
# usage: train_parity.sh <pwcli> [mode]
#   mode "exact" (macOS): every generation bit-identical to Swift, for 1 and 4 workers.
#   mode "loose" (Windows: MSVC libm + QuickJS): long chaotic episodes amplify last-bit math differences,
#     so generation-0 best/mean/median/worst must be within 5% of Swift, and 4 workers must be
#     bit-identical to 1 worker (determinism).
set -euo pipefail
PWCLI="$1"; MODE="${2:-exact}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/pw-train-parity"; rm -rf "$OUT"; mkdir -p "$OUT"
PY=$(command -v python3 || command -v python)
# Slow shared CI machines: widen the JS watchdog so no candidate times out (results are unaffected unless it fires).
export PW_SCRIPT_BUDGET_SCALE="${PW_SCRIPT_BUDGET_SCALE:-20}"
fail=0
for e in hold100-ga hover-pid hover-ducted-rocket glide-cmaes; do
  for w in 1 4; do
    "$PWCLI" --train "$ROOT/examples/experiments/$e.json" --generations 3 --workers $w --out "$OUT/$e-w$w" > "$OUT/$e-w$w.log" 2>&1 \
      || { echo "FAIL $e (workers $w): pwcli exited $?"; tail -20 "$OUT/$e-w$w.log"; fail=1; continue; }
    REF="$ROOT/cpp/tests/parity/training/$e.history.csv"; ARGS=(--rtol 0)
    [[ "$MODE" == loose ]] && ARGS=(--rtol 0.05 --rows 1 --cols best,mean,median,worst)
    if [[ "$MODE" == loose && $w != 1 ]]; then REF="$OUT/$e-w1/history.csv"; ARGS=(--rtol 0); fi
    if res=$("$PY" -I "$ROOT/cpp/tools/compare_history.py" "$REF" "$OUT/$e-w$w/history.csv" "${ARGS[@]}"); then
      echo "ok   $e workers=$w: $res"
    else echo "FAIL $e workers=$w:"; echo "$res"; fail=1; fi
  done
done
exit $fail
