#!/usr/bin/env bash
# 01_init_project.sh — create project dirs, write config.py, verify connectivity.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

echo "=== Create project structure at $PROJECT_DIR ==="
mkdir -p "$SRC_DIR" "$RESULTS_DIR" "$GO_DIR" "$PROJECT_DIR/logs"

echo "=== Write config.py ==="
cat > "$SRC_DIR/config.py" <<EOF
# Central config — single source of truth (Python harness + seed).
MONGO_URI = None  # read from environment at runtime; never hard-coded
DB_NAME = "acid_bench"

COL_CARDS = "cards"
COL_LEDGER = "txn_ledger"
COL_CARD_COUNTER = "card_op_counter"
COL_MERCH_COUNTER = "merchant_op_counter"

NUM_CARDS = 1_000_000
NUM_MERCHANTS = 5_000

CARD_COUNTER_BUCKETS = 1      # 1 doc/card (card contention negligible)
MERCH_COUNTER_BUCKETS = 256   # heavy bucketing for skewed hot merchants

HOT_MERCHANT_FRACTION = 0.02      # 2% of merchants are "hot"
HOT_MERCHANT_TRAFFIC_SHARE = 0.80 # take 80% of traffic

WRITE_CONCERN = "majority"
P_LATENCY_TARGET_MS = 20
EOF
echo "config.py written."

echo "=== Verify connectivity + warm RTT (peered path should be ~0.5ms) ==="
$PYBIN - <<'PY'
import os, time
from pymongo import MongoClient
cli = MongoClient(os.environ["MONGO_URI"], serverSelectionTimeoutMS=8000)
for _ in range(5):
    cli.admin.command("ping")           # warm the connection
t = time.perf_counter(); cli.admin.command("ping")
print("warm rtt_ms: %.3f" % ((time.perf_counter()-t)*1000))
h = cli.admin.command("hello")
print("primary:", h.get("primary"))
print("hosts  :", h.get("hosts"))
print("setName:", h.get("setName"))
ver = cli.admin.command("buildInfo")["version"]
print("server version:", ver)
PY
echo "=== Connectivity OK. Next: ./02_seed.sh ==="
