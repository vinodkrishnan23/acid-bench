#!/usr/bin/env bash
# run_perop_scenarios.sh — RWB: 3 per-op scenarios → consolidated summary table.
# ASSUMES 01–03 (and optionally 04_seed_ledger.sh) have already been run; this script
# DOES NOT reseed — preserves whatever ledger size you've ingested. No cash-snapshot /
# conservation check (those COLLSCAN at large ledger sizes).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

SUMMARY_DIR=$(mktemp -d /tmp/rwb_perop_scenarios.XXXXXX)
trap 'rm -rf "$SUMMARY_DIR"' EXIT
SUMMARY_IDX=0

run_one() {
  local sessions=$1 tps=$2 duration=$3
  SUMMARY_IDX=$((SUMMARY_IDX + 1))
  local log
  log=$(printf "%s/%02d_rwb_perop_%d_%d_%d.log" "$SUMMARY_DIR" "$SUMMARY_IDX" "$sessions" "$tps" "$duration")
  echo ""
  echo "=== RWB PER-OP: $sessions sessions / $tps TPS / ${duration}s ==="
  echo "SCENARIO sessions=$sessions tps=$tps duration=$duration" > "$log"
  "$GO_DIR/perop_bin" "$sessions" "$tps" "$duration" | tee -a "$log"
}

run_one 3000 5000 300
run_one 4000 6000 300
run_one 5000 7000 300

echo ""
echo "=== Sustained Concurrent Load Summary — RWB per-op ==="
echo "  Users column = users transacting concurrently against the cluster"
echo "  (closed-loop goroutines, one dedicated MongoDB session per user; rich ~5 KB ledger inserts)."
"$SCRIPT_DIR/scenario_summary.sh" "$SUMMARY_DIR"/*.log
