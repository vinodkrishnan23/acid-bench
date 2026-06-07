#!/usr/bin/env bash
# run_with_srvmon_go.sh — RWB variant with Go server monitor in parallel.
# Usage:
#   ./run_with_srvmon_go.sh perop
#   SESSIONS=3000 TARGET_TPS=5000 DURATION=60 ./run_with_srvmon_go.sh clientbulk
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

VARIANT="${1:-clientbulk}"
case "$VARIANT" in
  perop)      BIN="$GO_DIR/perop_bin" ;;
  clientbulk) BIN="$GO_DIR/clientbulk_bin" ;;
  *) echo "usage: $0 [perop|clientbulk]"; exit 1 ;;
esac

MON_LOG="$RESULTS_DIR/rwb_srvmon_go.log"

echo "=== RWB $VARIANT + Go server monitor: $SESSIONS/$TARGET_TPS/${DURATION}s ==="
"$GO_DIR/srvmon_bin" $((DURATION + 4)) > "$MON_LOG" 2>&1 &
MON=$!
sleep 1
"$BIN" "$SESSIONS" "$TARGET_TPS" "$DURATION"
wait "$MON" || true

echo "=== SERVER-SIDE TRACE ==="
cat "$MON_LOG"
