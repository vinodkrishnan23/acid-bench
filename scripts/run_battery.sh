#!/usr/bin/env bash
# run_battery.sh — run a variant N times back-to-back to confirm p99 repeatability.
# Usage:
#   ./run_battery.sh perop        # 5x per-op
#   ./run_battery.sh clientbulk   # 5x client-bulk
#   RUNS=10 SESSIONS=2000 TARGET_TPS=4000 DURATION=90 ./run_battery.sh clientbulk
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

VARIANT="${1:-clientbulk}"
RUNS="${RUNS:-5}"
case "$VARIANT" in
  perop)      BIN="$GO_DIR/perop_bin" ;;
  clientbulk) BIN="$GO_DIR/clientbulk_bin" ;;
  *) echo "usage: $0 [perop|clientbulk]"; exit 1 ;;
esac

echo "=== ${RUNS}x BATTERY: $VARIANT @ $SESSIONS/$TARGET_TPS/${DURATION}s ==="
for i in $(seq 1 "$RUNS"); do
  echo "--- RUN $i ---"
  "$BIN" "$SESSIONS" "$TARGET_TPS" "$DURATION" | grep -E "windowed TPS|median|p99|PASS"
done
echo "=== battery done ==="
