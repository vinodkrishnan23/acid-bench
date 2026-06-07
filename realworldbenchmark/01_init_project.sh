#!/usr/bin/env bash
# 01_init_project.sh — RWB project scaffold + config.py + connectivity check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

echo "=== Create RWB project structure at $PROJECT_DIR ==="
mkdir -p "$SRC_DIR" "$RESULTS_DIR" "$GO_DIR" "$PROJECT_DIR/logs"

echo "=== Write config.py ==="
cat > "$SRC_DIR/config.py" <<EOF
# RWB (Real-World Benchmark) config — rich card-management schema.
MONGO_URI = None
DB_NAME = "fss_acid_bench"

COL_CARDS     = "cards"
COL_MERCHANTS = "merchants"
COL_LEDGER    = "txn_ledger"
COL_MERCH_VEL = "merchant_velocity"
COL_CARD_VEL  = "cardholder_velocity"

NUM_CARDS     = 1_000_000
NUM_MERCHANTS = 5_000

MERCH_BUCKETS = 256

HOT_MERCHANT_FRACTION       = 0.02
HOT_MERCHANT_TRAFFIC_SHARE  = 0.80

# Money in paise (1/100 INR).
BALANCE_MIN_PAISE      = 35_000_000   # ₹350,000
BALANCE_MAX_PAISE      = 60_000_000   # ₹600,000
LIMIT_PER_TXN_PAISE    = 50_000
LIMIT_DAY_POS_PAISE    = 500_000
TXN_AMOUNT_MIN_PAISE   = 100
TXN_AMOUNT_MAX_PAISE   = 5_000

# Target serialized BSON sizes (informational; seeder pads to hit them).
TARGET_CARD_SIZE_BYTES     = 4096
TARGET_MERCHANT_SIZE_BYTES = 4096
TARGET_LEDGER_SIZE_BYTES   = 5120

SCHEMES   = ("VISA", "MASTERCARD", "RUPAY", "AMEX")
CARD_TYPES = ("credit", "debit", "prepaid", "forex")
TIERS     = ("classic", "gold", "platinum", "signature", "infinite")
BANK_BINS = (
    ("HDFC Bank",       "411111"),
    ("ICICI Bank",      "422222"),
    ("Axis Bank",       "433333"),
    ("Kotak Mahindra",  "444444"),
    ("SBI Cards",       "455555"),
    ("Yes Bank",        "466666"),
    ("IndusInd Bank",   "477777"),
)
CITIES = (
    ("Mumbai",     "Maharashtra", "400001"),
    ("Delhi",      "Delhi",       "110001"),
    ("Bangalore",  "Karnataka",   "560001"),
    ("Hyderabad",  "Telangana",   "500001"),
    ("Chennai",    "Tamil Nadu",  "600001"),
    ("Kolkata",    "West Bengal", "700001"),
    ("Pune",       "Maharashtra", "411001"),
    ("Ahmedabad",  "Gujarat",     "380001"),
    ("Jaipur",     "Rajasthan",   "302001"),
    ("Lucknow",    "Uttar Pradesh","226001"),
)
# Merchant Category Codes (MCC) — sample subset.
MCCS = (
    (5411, "GROCERY_STORES"),
    (5812, "EATING_PLACES_RESTAURANTS"),
    (5912, "DRUG_STORES_PHARMACIES"),
    (5732, "ELECTRONICS_STORES"),
    (4111, "TRANSPORTATION_SUBURBAN"),
    (7011, "LODGING_HOTELS"),
    (5311, "DEPARTMENT_STORES"),
    (5541, "SERVICE_STATIONS"),
    (5651, "FAMILY_CLOTHING"),
    (5942, "BOOK_STORES"),
)

WRITE_CONCERN = "majority"
P_LATENCY_TARGET_MS = 20
EOF
echo "config.py written."

echo "=== Verify connectivity + warm RTT ==="
$PYBIN - <<'PY'
import os, time
from pymongo import MongoClient
cli = MongoClient(os.environ["MONGO_URI"], serverSelectionTimeoutMS=8000)
for _ in range(5):
    cli.admin.command("ping")
t = time.perf_counter(); cli.admin.command("ping")
print("warm rtt_ms: %.3f" % ((time.perf_counter()-t)*1000))
h = cli.admin.command("hello")
print("primary:", h.get("primary"))
print("server version:", cli.admin.command("buildInfo")["version"])
PY
echo "=== Connectivity OK. Next: ./02_seed.sh ==="
