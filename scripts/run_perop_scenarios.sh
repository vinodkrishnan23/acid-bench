#!/usr/bin/env bash
# run_perop_scenarios.sh — reload data, then run 3 per-op scenarios:
#   3000 sessions / 5000 TPS / 300s
#   4000 sessions / 6000 TPS / 300s
#   5000 sessions / 7000 TPS / 300s
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

echo "=== Reloading seed data ==="
"$SCRIPT_DIR/02_seed.sh"

echo ""
echo "=== Cash loaded after seed ==="
"$SCRIPT_DIR/cash_snapshot.sh" seed

SUMMARY_DIR=$(mktemp -d /tmp/perop_scenarios.XXXXXX)
trap 'rm -rf "$SUMMARY_DIR"' EXIT
SUMMARY_IDX=0

run_one() {
  local sessions=$1 tps=$2 duration=$3
  SUMMARY_IDX=$((SUMMARY_IDX + 1))
  local log
  log=$(printf "%s/%02d_perop_%d_%d_%d.log" "$SUMMARY_DIR" "$SUMMARY_IDX" "$sessions" "$tps" "$duration")
  echo ""
  echo "=== GO PER-OP: $sessions sessions / $tps TPS / ${duration}s ==="
  echo "SCENARIO sessions=$sessions tps=$tps duration=$duration" > "$log"
  "$GO_DIR/perop_bin" "$sessions" "$tps" "$duration" | tee -a "$log"
}

run_one 3000 5000 300
run_one 4000 6000 300
run_one 5000 7000 300

echo ""
echo "=== Cash state after all scenarios ==="
"$SCRIPT_DIR/cash_snapshot.sh" final

echo ""
echo "=== Sustained Concurrent Load Summary — per-op ==="
echo "  Users column = users transacting concurrently against the cluster"
echo "  (closed-loop goroutines, one dedicated MongoDB session per user)."
"$SCRIPT_DIR/scenario_summary.sh" "$SUMMARY_DIR"/*.log
