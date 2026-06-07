#!/usr/bin/env bash
# hotdoc_with_baseline.sh — Shape B: hot-card burst layered on a 5K-TPS baseline.
#
# Demonstrates Scenario 2 for the customer:
#   "Hot-document contention: same cardId hit by N concurrent authorisations.
#    WriteConflict rate, retry storm, end-to-end latency degradation."
#
# What it does:
#   1. Launches perop at 5000 TPS across random cardIds (baseline, ~background)
#   2. Simultaneously launches hotdoc with N goroutines all hitting one cardId
#   3. Snapshots serverStatus().metrics.operation.writeConflicts before/after
#   4. Reports the side-by-side: baseline overall TPS+p99 vs hot-card TPS+p99
#      vs total WriteConflicts produced
#
# What it proves:
#   - Whether the 5K-TPS guarantee survives a hot-card event (most likely yes —
#     the hot card max-throughputs in the 100s of TPS, leaves plenty of headroom).
#   - Cross-contamination: how much does hot-card retry storm degrade cold-card p99.
#   - Hot-card user experience: p99 latency for the unlucky cardholder.
#
# Usage:
#   ./scenarios/hotdoc_with_baseline.sh [hot_concurrency] [duration_s] [target_tps] [baseline_sessions]
#   hot_concurrency    goroutines hammering the hot card    (default: 50)
#   duration_s         length of overlapping run             (default: 120)
#   target_tps         baseline TPS target                   (default: 5000)
#   baseline_sessions  perop sessions                        (default: 3000)
#
# Required env:
#   MONGO_URI       rs SRV/seed string with admin creds
# Optional env:
#   HOT_CARD_ID=CARD-0000000001     which card to hammer
#   HOT_MERCHANT_ID=""              empty = random merchant per txn (recommended);
#                                   set e.g. M0000001 to also contend on a single merchant
#   WARMUP_SEC=10                   baseline warmup
#   HOT_WARMUP_SEC=5                hotdoc warmup
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RWB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$RWB_DIR/env.sh"

HOT_N="${1:-50}"
DURATION="${2:-120}"
TARGET_TPS="${3:-5000}"
BASELINE_SESSIONS="${4:-3000}"
WARMUP_SEC="${WARMUP_SEC:-10}"
HOT_WARMUP_SEC="${HOT_WARMUP_SEC:-5}"
HOT_CARD_ID="${HOT_CARD_ID:-CARD-0000000001}"
HOT_MERCHANT_ID="${HOT_MERCHANT_ID:-}"

PEROP_BIN="$GO_DIR/perop_bin"
HOTDOC_BIN="$GO_DIR/hotdoc_bin"
[[ -x "$PEROP_BIN"  ]] || { echo "ERROR: $PEROP_BIN  not found. Run 03_build_go.sh first." >&2; exit 1; }
[[ -x "$HOTDOC_BIN" ]] || { echo "ERROR: $HOTDOC_BIN not found. Run 03_build_go.sh first." >&2; exit 1; }

: "${MONGO_URI:?MONGO_URI must be exported}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$RWB_DIR/results/hotdoc_N${HOT_N}_${TS}"
mkdir -p "$OUTDIR"
BASELINE_CSV="$OUTDIR/baseline_tps.csv"
HOTDOC_CSV="$OUTDIR/hotdoc_tps.csv"
BASELINE_LOG="$OUTDIR/baseline.log"
HOTDOC_LOG="$OUTDIR/hotdoc.log"
WC_BEFORE="$OUTDIR/writeconflicts_before.json"
WC_AFTER="$OUTDIR/writeconflicts_after.json"

echo "============================================================"
echo " Scenario 2 (Shape B): hot card burst on 5K-TPS baseline"
echo "============================================================"
echo " baseline:       perop, sessions=$BASELINE_SESSIONS, target_tps=$TARGET_TPS"
echo " hot card:       $HOT_CARD_ID  with $HOT_N concurrent goroutines"
echo " hot merchant:   ${HOT_MERCHANT_ID:-<random per txn>}"
echo " duration:       ${DURATION}s   (overlapping)"
echo " output:         $OUTDIR"
echo "============================================================"

# Snapshot cluster-wide writeConflicts BEFORE.
mongosh "$MONGO_URI" --quiet --eval '
  const s = db.adminCommand({serverStatus: 1});
  print(JSON.stringify({
    writeConflicts: s.metrics.operation.writeConflicts,
    ts: new Date().toISOString()
  }));
' > "$WC_BEFORE" 2>/dev/null || echo '{"writeConflicts":0}' > "$WC_BEFORE"
WC_PRE=$(awk -F'[:,}]' '{for(i=1;i<=NF;i++) if($i~/writeConflicts/){print $(i+1)+0; exit}}' "$WC_BEFORE")
echo "writeConflicts BEFORE: $WC_PRE"
echo ""

# Launch baseline (perop, random cards).
(
  cd "$RWB_DIR"
  TPS_CSV_OUT="$BASELINE_CSV" WARMUP_SEC="$WARMUP_SEC" \
    "$PEROP_BIN" "$BASELINE_SESSIONS" "$TARGET_TPS" "$DURATION"
) > "$BASELINE_LOG" 2>&1 &
PEROP_PID=$!
echo "Baseline (perop) PID=$PEROP_PID"

# Brief stagger so baseline finishes its warm-up pings before hot card starts.
sleep 3

# Launch hot-card storm.
(
  cd "$RWB_DIR"
  TPS_CSV_OUT="$HOTDOC_CSV" WARMUP_SEC="$HOT_WARMUP_SEC" \
    HOT_CARD_ID="$HOT_CARD_ID" HOT_MERCHANT_ID="$HOT_MERCHANT_ID" \
    "$HOTDOC_BIN" "$HOT_N" "$((DURATION - 3))"
) > "$HOTDOC_LOG" 2>&1 &
HOT_PID=$!
echo "Hot card storm (hotdoc) PID=$HOT_PID"

# Wait for both.
wait "$PEROP_PID" || true
wait "$HOT_PID"   || true

# Snapshot writeConflicts AFTER.
mongosh "$MONGO_URI" --quiet --eval '
  const s = db.adminCommand({serverStatus: 1});
  print(JSON.stringify({
    writeConflicts: s.metrics.operation.writeConflicts,
    ts: new Date().toISOString()
  }));
' > "$WC_AFTER" 2>/dev/null || echo '{"writeConflicts":0}' > "$WC_AFTER"
WC_POST=$(awk -F'[:,}]' '{for(i=1;i<=NF;i++) if($i~/writeConflicts/){print $(i+1)+0; exit}}' "$WC_AFTER")
WC_DELTA=$((WC_POST - WC_PRE))

# Pull the summary lines out of each bench log.
echo ""
echo "============================================================"
echo " Baseline (perop, random cards across 1M)"
echo "============================================================"
tail -8 "$BASELINE_LOG"

echo ""
echo "============================================================"
echo " Hot card storm ($HOT_N goroutines on $HOT_CARD_ID)"
echo "============================================================"
tail -8 "$HOTDOC_LOG"

echo ""
echo "============================================================"
echo " WriteConflicts during the overlap"
echo "============================================================"
printf "  before:  %d\n" "$WC_PRE"
printf "  after:   %d\n" "$WC_POST"
printf "  delta:   %d  (cluster-wide WriteConflicts produced during run)\n" "$WC_DELTA"

echo ""
echo "============================================================"
echo " Artifacts in $OUTDIR"
echo "============================================================"
ls -la "$OUTDIR"
echo ""
echo "Customer takeaway:"
echo "  - Compare baseline TPS to your 5000 target — did the hot card storm steal headroom?"
echo "  - Compare baseline p99 to the no-storm baseline in RESULTS.md — was cold-card latency degraded?"
echo "  - Hot card p99 is the worst-case user experience for the contended cardholder."
echo "  - Total writeConflicts delta is the cluster-wide retry pressure produced by the storm."
