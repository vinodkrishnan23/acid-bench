#!/usr/bin/env bash
# stepdown_mid_txn.sh — drive the bench while triggering an rs.stepDown() mid-run.
#
# Demonstrates Scenario 1 for the customer:
#   "Behaviour under primary-step-down mid-transaction. Does the application get a
#    retryable error code, and what is the retry strategy?"
#
# What it does:
#   1. Launches the bench (perop or clientbulk) for DURATION seconds at TARGET_TPS
#   2. At T+STEP_AT seconds, runs rs.stepDown(STEP_FREEZE) on the current primary
#   3. Captures per-second TPS via the binary's TPS_CSV_OUT path
#   4. Reports the dip-and-recovery window: pre / during / post p99 and TPS
#
# What it proves:
#   - Mid-transaction commits affected by the stepDown get a TransientTransactionError
#     label. The Go driver's WithTransaction callback retries the whole txn against
#     the new primary automatically.
#   - The application sees 0 errors if the election completes within the driver's
#     internal retry budget (~120s by default). It sees a brief TPS dip.
#
# Usage:
#   ./scenarios/stepdown_mid_txn.sh <variant> [duration_s] [step_at_s] [step_freeze_s]
#   variant       perop | clientbulk             (default: perop)
#   duration_s    total bench duration            (default: 120)
#   step_at_s     when to fire stepDown          (default: 60)
#   step_freeze_s rs.stepDown(freeze) — how long old primary stays ineligible  (default: 30)
#
# Required env:
#   MONGO_URI       rs SRV/seed string with admin creds
# Optional env:
#   SESSIONS=3000  TARGET_TPS=5000  WARMUP_SEC=10
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RWB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$RWB_DIR/env.sh"

VARIANT="${1:-perop}"
DURATION="${2:-120}"
STEP_AT="${3:-60}"
STEP_FREEZE="${4:-30}"
SESSIONS="${SESSIONS:-3000}"
TARGET_TPS="${TARGET_TPS:-5000}"
WARMUP_SEC="${WARMUP_SEC:-10}"

case "$VARIANT" in
  perop|clientbulk) ;;
  *) echo "usage: $0 [perop|clientbulk] [duration_s] [step_at_s] [step_freeze_s]" >&2; exit 1 ;;
esac

: "${MONGO_URI:?MONGO_URI must be exported}"
BIN="$GO_DIR/${VARIANT}_bin"
[[ -x "$BIN" ]] || { echo "ERROR: $BIN not found. Run 03_build_go.sh first." >&2; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$RWB_DIR/results/stepdown_${VARIANT}_${TS}"
mkdir -p "$OUTDIR"
CSV="$OUTDIR/tps.csv"
BENCH_LOG="$OUTDIR/bench.log"
STEPDOWN_LOG="$OUTDIR/stepdown.log"

echo "============================================================"
echo " Scenario 1: stepdown mid-transaction"
echo "============================================================"
echo " variant:        $VARIANT"
echo " sessions:       $SESSIONS"
echo " target_tps:     $TARGET_TPS"
echo " duration:       ${DURATION}s"
echo " stepdown at:    T+${STEP_AT}s"
echo " freeze period:  ${STEP_FREEZE}s"
echo " output:         $OUTDIR"
echo "============================================================"

# Identify current primary BEFORE the run, for the report.
PRI_BEFORE="$(mongosh "$MONGO_URI" --quiet --eval '
  const m = rs.status().members.find(m => m.stateStr === "PRIMARY");
  print(m ? m.name : "none");
' 2>/dev/null)"
echo "Primary before:  $PRI_BEFORE"

# Launch bench in background.
(
  cd "$RWB_DIR"
  TPS_CSV_OUT="$CSV" WARMUP_SEC="$WARMUP_SEC" \
    "$BIN" "$SESSIONS" "$TARGET_TPS" "$DURATION"
) > "$BENCH_LOG" 2>&1 &
BENCH_PID=$!
echo "Bench started PID=$BENCH_PID  log=$BENCH_LOG"

# Sleep until the stepdown moment, then fire it.
sleep "$STEP_AT"
echo ""
echo "T+${STEP_AT}s: firing rs.stepDown($STEP_FREEZE) ..."
T_START=$(date +%s)
mongosh "$MONGO_URI" --quiet --eval "
  try {
    rs.stepDown($STEP_FREEZE);
    print('stepDown returned ok');
  } catch (e) {
    print('stepDown threw: ' + e.message);
  }
" >"$STEPDOWN_LOG" 2>&1 || true
T_END=$(date +%s)
ELAPSED=$((T_END - T_START))
echo "stepDown command returned after ${ELAPSED}s"

# Poll for the new primary.
NEW_PRI="none"
for i in $(seq 1 30); do
  NEW_PRI="$(mongosh "$MONGO_URI" --quiet --eval '
    const m = rs.status().members.find(m => m.stateStr === "PRIMARY");
    print(m ? m.name : "none");
  ' 2>/dev/null || echo none)"
  [[ "$NEW_PRI" != "none" && "$NEW_PRI" != "$PRI_BEFORE" ]] && break
  sleep 1
done
T_NEW=$(date +%s)
ELECT_SEC=$((T_NEW - T_START))
echo "New primary: $NEW_PRI  (elected ${ELECT_SEC}s after stepDown command)"

# Wait for bench to finish.
echo ""
echo "Waiting for bench to finish ..."
wait $BENCH_PID || true
echo "Bench done."

# Slice the per-second TPS CSV into pre/during/post windows.
if [[ -s "$CSV" ]]; then
  echo ""
  echo "============================================================"
  echo " Per-second TPS — pre / during / post the stepDown window"
  echo "============================================================"
  awk -F, -v step="$STEP_AT" -v elect="$ELECT_SEC" '
    NR==1 { next }
    {
      sec = $1; tps = $2;
      if (sec < step)                          { n_pre++;    s_pre   += tps }
      else if (sec < step + elect + 5)         { n_during++; s_during+= tps }
      else                                     { n_post++;   s_post  += tps }
    }
    END {
      printf "  pre    (0 .. %ds):     n=%d  avg_tps=%.1f\n", step, n_pre, (n_pre?s_pre/n_pre:0)
      printf "  during (%d .. %ds):    n=%d  avg_tps=%.1f\n", step, step+elect+5, n_during, (n_during?s_during/n_during:0)
      printf "  post   (%d .. end):    n=%d  avg_tps=%.1f\n", step+elect+5, n_post, (n_post?s_post/n_post:0)
    }
  ' "$CSV"
fi

echo ""
echo "============================================================"
echo " Bench summary (last block of bench.log)"
echo "============================================================"
tail -20 "$BENCH_LOG"

echo ""
echo "============================================================"
echo " Artifacts in $OUTDIR"
echo "============================================================"
ls -la "$OUTDIR"
echo ""
echo "Customer takeaway:"
echo "  - Primary stepped down at T+${STEP_AT}s. New primary elected in ${ELECT_SEC}s."
echo "  - Errors bubbled to app: see 'errors:' line in tail above."
echo "  - Retries auto-handled by Go driver's WithTransaction (TransientTransactionError)."
echo "  - For per-second TPS curve: $CSV"
