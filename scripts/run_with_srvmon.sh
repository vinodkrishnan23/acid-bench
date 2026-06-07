#!/usr/bin/env bash
# run_with_srvmon.sh — run a variant with the server-side latency monitor alongside,
# proving where latency lives (client vs cluster).
# Usage:
#   ./run_with_srvmon.sh clientbulk
#   SESSIONS=3000 TARGET_TPS=5000 DURATION=70 ./run_with_srvmon.sh perop
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

# write srvmon if missing
cat > "$SRC_DIR/srvmon.py" <<'EOF'
import os, time, sys
from pymongo import MongoClient
dur = int(sys.argv[1]) if len(sys.argv) > 1 else 64
cli = MongoClient(os.environ["MONGO_URI"])
last = cli.admin.command("serverStatus")
lw = last["opLatencies"]["writes"]; lc = last["opLatencies"]["commands"]
t_end = time.time() + dur; time.sleep(5)
print("server opLatencies (avg ms per 5s window):")
while time.time() < t_end:
    ss = cli.admin.command("serverStatus")
    w = ss["opLatencies"]["writes"]; c = ss["opLatencies"]["commands"]
    dwo = w["ops"]-lw["ops"]; dco = c["ops"]-lc["ops"]
    wavg = round((w["latency"]-lw["latency"])/dwo/1000.0,2) if dwo else None
    cavg = round((c["latency"]-lc["latency"])/dco/1000.0,2) if dco else None
    print(f"  write_avg={wavg}ms  cmd_avg={cavg}ms")
    lw, lc = w, c; time.sleep(5)
EOF

MON_DUR=$((DURATION + 5))
echo "=== $VARIANT + server monitor: $SESSIONS/$TARGET_TPS/${DURATION}s ==="
$PYBIN "$SRC_DIR/srvmon.py" "$MON_DUR" > "$RESULTS_DIR/srvmon_${VARIANT}.log" 2>&1 &
MON=$!
sleep 1
"$BIN" "$SESSIONS" "$TARGET_TPS" "$DURATION"
wait $MON
echo "=== SERVER-SIDE LATENCY (proves cluster is/ isn't the bottleneck) ==="
cat "$RESULTS_DIR/srvmon_${VARIANT}.log"
