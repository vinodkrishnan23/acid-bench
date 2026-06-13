#!/usr/bin/env bash
# verify_acid.sh — point-in-time ACID consistency check across all 4 RWB collections.
#
# Compares four quantities that MUST be equal if every transaction is strictly ACID:
#   1. cards delta:          initial_cards_balance_sum - current_cards_balance_sum
#   2. txn_ledger total:     sum(txn_ledger.amount)
#   3. cardholder_velocity:  sum(cardholder_velocity.sum)
#   4. merchant_velocity:    sum(merchant_velocity.sum)
#
# Requires /tmp/${BENCH_DB_NAME}_initial_cards.paise (written by 02_seed.sh at seed time).
# Run with NO live txns in flight — otherwise mid-flight transactions break the invariant.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

DB="${BENCH_DB_NAME:-fss_acid_proof}"
INIT_FILE="/tmp/${DB}_initial_cards.paise"

if [ ! -f "$INIT_FILE" ]; then
  echo "ERROR: $INIT_FILE not found. Re-run ./02_seed.sh to record the initial cards baseline." >&2
  exit 1
fi

INITIAL=$(cat "$INIT_FILE")

fmt() { printf "%'d" "$1"; }
mq()  { mongosh "$MONGO_URI" --quiet --eval "$1" | tail -1; }

agg_sum() {
  local coll="$1" field="$2"
  mq "var r = db.getSiblingDB('$DB').${coll}.aggregate([{\$group: {_id: null, t: {\$sum: '\$${field}'}}}]).toArray()[0]; print(r ? r.t.toString() : '0')"
}

CARDS_NOW=$(agg_sum cards balance)
LEDGER_TOTAL=$(agg_sum txn_ledger amount)
CV_TOTAL=$(agg_sum cardholder_velocity sum)
MV_TOTAL=$(agg_sum merchant_velocity sum)

CARDS_DELTA=$((INITIAL - CARDS_NOW))

echo "=== ACID Verification — DB '$DB' (paise) ==="
printf "| %-36s | %-22s |\n" "Metric" "Value"
echo "|--------------------------------------|------------------------|"
printf "| %-36s | %-22s |\n" "1. Initial cards balance (recorded)"  "$(fmt "$INITIAL")"
printf "| %-36s | %-22s |\n" "2. Current cards balance"             "$(fmt "$CARDS_NOW")"
printf "| %-36s | %-22s |\n" "   Cards delta  (1 - 2)"              "$(fmt "$CARDS_DELTA")"
printf "| %-36s | %-22s |\n" "3. txn_ledger total amount"           "$(fmt "$LEDGER_TOTAL")"
printf "| %-36s | %-22s |\n" "4. cardholder_velocity total sum"     "$(fmt "$CV_TOTAL")"
printf "| %-36s | %-22s |\n" "5. merchant_velocity total sum"       "$(fmt "$MV_TOTAL")"
echo ""

if [ "$CARDS_DELTA" = "$LEDGER_TOTAL" ] && [ "$LEDGER_TOTAL" = "$CV_TOTAL" ] && [ "$CV_TOTAL" = "$MV_TOTAL" ]; then
  echo "✓ ACID HOLDS"
  echo "    cards_delta = ledger_total = cardholder_velocity_sum = merchant_velocity_sum = $(fmt "$CARDS_DELTA") paise"
  exit 0
fi

echo "✗ ACID FAILS — quantities do NOT all match. Drifts (vs cards_delta = $(fmt "$CARDS_DELTA")):"
echo "    ledger_total                drift: $(fmt "$((LEDGER_TOTAL - CARDS_DELTA))")"
echo "    cardholder_velocity_sum     drift: $(fmt "$((CV_TOTAL - CARDS_DELTA))")"
echo "    merchant_velocity_sum       drift: $(fmt "$((MV_TOTAL - CARDS_DELTA))")"
echo ""
echo "  Common causes:"
echo "    • Pre-seeded ledger without UPDATE_DERIVED=1 (cards/velocities will be 0 drift, ledger non-zero)"
echo "    • Live transactions in flight (re-run after bench fully stops)"
echo "    • Lost or duplicated transaction (actual ACID failure)"
exit 1
