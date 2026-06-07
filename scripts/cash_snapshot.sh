#!/usr/bin/env bash
# cash_snapshot.sh — print sums from cards / txn_ledger. Two phases:
#   seed   : prints + saves total cards.balance to /tmp for the final compare
#   final  : prints cards remaining + txn_ledger spent + conservation check
# Requires $MONGO_URI in env.
set -euo pipefail

DB="${BENCH_DB_NAME:-fss_bench}"
INITIAL_FILE="/tmp/fss_bench_loaded_total.paise"

mode="${1:-}"
case "$mode" in
  seed|final) ;;
  *) echo "usage: $0 [seed|final]" >&2; exit 1 ;;
esac

fmt_paise() { printf "%'d" "$1"; }
fmt_inr()   { printf "%'.2f" "$(echo "scale=2; $1/100" | bc -l)"; }

# helper — extract single integer from a mongosh --eval call
mq() { mongosh "$MONGO_URI" --quiet --eval "$1" | tail -1; }

if [ "$mode" = "seed" ]; then
  TOTAL=$(mq "print(db.getSiblingDB('$DB').cards.aggregate([{\$group: {_id: null, t: {\$sum: '\$balance'}}}]).toArray()[0].t.toString())")
  COUNT=$(mq "print(db.getSiblingDB('$DB').cards.countDocuments({}).toString())")
  echo "  cards loaded   : $(fmt_paise "$COUNT")"
  echo "  total balance  : $(fmt_paise "$TOTAL") paise  (₹$(fmt_inr "$TOTAL"))"
  echo "$TOTAL" > "$INITIAL_FILE"
  exit 0
fi

# final
LOADED=0
[ -f "$INITIAL_FILE" ] && LOADED=$(cat "$INITIAL_FILE")

REMAIN=$(mq "print(db.getSiblingDB('$DB').cards.aggregate([{\$group: {_id: null, t: {\$sum: '\$balance'}}}]).toArray()[0].t.toString())")
SPENT=$(mq "var l = db.getSiblingDB('$DB').txn_ledger.aggregate([{\$group: {_id: null, t: {\$sum: '\$amount'}}}]).toArray()[0]; print(l ? l.t.toString() : '0')")
ENTRIES=$(mq "print(db.getSiblingDB('$DB').txn_ledger.countDocuments({}).toString())")

echo "  loaded         : $(fmt_paise "$LOADED") paise  (₹$(fmt_inr "$LOADED"))"
echo "  remaining      : $(fmt_paise "$REMAIN") paise  (₹$(fmt_inr "$REMAIN"))"
echo "  spent          : $(fmt_paise "$SPENT") paise  (₹$(fmt_inr "$SPENT"))"
echo "  ledger entries : $(fmt_paise "$ENTRIES")"

if [ "$LOADED" -gt 0 ]; then
  DIFF=$((LOADED - REMAIN))
  if [ "$DIFF" = "$SPENT" ]; then
    echo "  ✓ CONSERVATION: loaded - remaining = spent  ($(fmt_paise "$DIFF") paise)"
    STATUS="✓"
  else
    DRIFT=$((DIFF - SPENT))
    echo "  ✗ CONSERVATION FAIL: loaded-remaining=$(fmt_paise "$DIFF"), spent=$(fmt_paise "$SPENT"), drift=$(fmt_paise "$DRIFT") paise"
    STATUS="✗"
  fi
  echo ""
  echo "=== ACID Proof (all values in paise) ==="
  printf "| %-22s | %-22s | %-22s | %-22s | %-5s |\n" \
    "Loaded (before)" "Remaining (after)" "Ledger total" "Loaded - Remaining" "ACID"
  echo "|------------------------|------------------------|------------------------|------------------------|-------|"
  printf "| %-22s | %-22s | %-22s | %-22s | %-5s |\n" \
    "$(fmt_paise "$LOADED")" "$(fmt_paise "$REMAIN")" "$(fmt_paise "$SPENT")" "$(fmt_paise "$DIFF")" "$STATUS"
  echo ""
  echo "  Loaded - Remaining MUST equal Ledger total for the workload to be strictly ACID."
fi
