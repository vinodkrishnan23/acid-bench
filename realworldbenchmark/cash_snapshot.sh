#!/usr/bin/env bash
# cash_snapshot.sh — RWB cash snapshot with DELTA conservation check.
# Why delta: the ledger may already have pre-seeded entries (e.g. 500M historical txns).
# We record BOTH cards.balance total AND txn_ledger.amount total at `seed` time, then at
# `final` we compare (loaded - remaining) against (ledger_now - ledger_at_seed). That
# isolates the bench's impact regardless of how much history is already in the ledger.
set -euo pipefail

DB="${BENCH_DB_NAME:-fss_acid_proof}"
LOADED_FILE="/tmp/${DB}_loaded_cards.paise"
LEDGER_BASE_FILE="/tmp/${DB}_ledger_baseline.paise"

mode="${1:-}"
case "$mode" in seed|final) ;; *) echo "usage: $0 [seed|final]" >&2; exit 1 ;; esac

fmt_paise() { printf "%'d" "$1"; }
fmt_inr()   { printf "%'.2f" "$(echo "scale=2; $1/100" | bc -l)"; }
mq()        { mongosh "$MONGO_URI" --quiet --eval "$1" | tail -1; }

aggregate_sum_or_zero='var r = db.getSiblingDB("'$DB'").DDDcollection.aggregate([{$group: {_id: null, t: {$sum: "$FFF"}}}]).toArray()[0]; print(r ? r.t.toString() : "0");'

sum_cards()  { mq "var r = db.getSiblingDB('$DB').cards.aggregate([{\$group: {_id: null, t: {\$sum: '\$balance'}}}]).toArray()[0]; print(r ? r.t.toString() : '0')"; }
sum_ledger() { mq "var r = db.getSiblingDB('$DB').txn_ledger.aggregate([{\$group: {_id: null, t: {\$sum: '\$amount'}}}]).toArray()[0]; print(r ? r.t.toString() : '0')"; }
count_cards()  { mq "print(db.getSiblingDB('$DB').cards.countDocuments({}).toString())"; }
count_ledger() { mq "print(db.getSiblingDB('$DB').txn_ledger.countDocuments({}).toString())"; }

if [ "$mode" = "seed" ]; then
  CARDS_TOTAL=$(sum_cards)
  CARDS_COUNT=$(count_cards)
  LEDGER_TOTAL=$(sum_ledger)
  LEDGER_COUNT=$(count_ledger)
  echo "  cards loaded         : $(fmt_paise "$CARDS_COUNT")"
  echo "  total card balance   : $(fmt_paise "$CARDS_TOTAL") paise  (₹$(fmt_inr "$CARDS_TOTAL"))"
  echo "  ledger entries (pre) : $(fmt_paise "$LEDGER_COUNT")"
  echo "  ledger sum (pre)     : $(fmt_paise "$LEDGER_TOTAL") paise  (₹$(fmt_inr "$LEDGER_TOTAL"))"
  echo "$CARDS_TOTAL"  > "$LOADED_FILE"
  echo "$LEDGER_TOTAL" > "$LEDGER_BASE_FILE"
  exit 0
fi

# final
LOADED=0;       [ -f "$LOADED_FILE" ]      && LOADED=$(cat "$LOADED_FILE")
LEDGER_BASE=0;  [ -f "$LEDGER_BASE_FILE" ] && LEDGER_BASE=$(cat "$LEDGER_BASE_FILE")

REMAIN=$(sum_cards)
SPENT_NOW=$(sum_ledger)
ENTRIES=$(count_ledger)
DELTA_LEDGER=$((SPENT_NOW - LEDGER_BASE))

echo "  cards before          : $(fmt_paise "$LOADED") paise  (₹$(fmt_inr "$LOADED"))"
echo "  cards after           : $(fmt_paise "$REMAIN") paise  (₹$(fmt_inr "$REMAIN"))"
echo "  ledger before (pre)   : $(fmt_paise "$LEDGER_BASE") paise"
echo "  ledger after          : $(fmt_paise "$SPENT_NOW") paise"
echo "  spent during bench    : $(fmt_paise "$DELTA_LEDGER") paise  (₹$(fmt_inr "$DELTA_LEDGER"))"
echo "  ledger entries (now)  : $(fmt_paise "$ENTRIES")"

if [ "$LOADED" -gt 0 ]; then
  DELTA_CARDS=$((LOADED - REMAIN))
  if [ "$DELTA_CARDS" = "$DELTA_LEDGER" ]; then
    echo "  ✓ CONSERVATION (delta): cards_before - cards_after == ledger_delta  ($(fmt_paise "$DELTA_CARDS") paise)"
    STATUS="✓"
  else
    DRIFT=$((DELTA_CARDS - DELTA_LEDGER))
    echo "  ✗ CONSERVATION FAIL: cards_delta=$(fmt_paise "$DELTA_CARDS"), ledger_delta=$(fmt_paise "$DELTA_LEDGER"), drift=$(fmt_paise "$DRIFT") paise"
    STATUS="✗"
  fi
  echo ""
  echo "=== ACID Proof (all values in paise; deltas from bench window) ==="
  printf "| %-22s | %-22s | %-22s | %-22s | %-5s |\n" \
    "Cards before" "Cards after" "Ledger delta (bench)" "Cards delta (bench)" "ACID"
  echo "|------------------------|------------------------|------------------------|------------------------|-------|"
  printf "| %-22s | %-22s | %-22s | %-22s | %-5s |\n" \
    "$(fmt_paise "$LOADED")" "$(fmt_paise "$REMAIN")" "$(fmt_paise "$DELTA_LEDGER")" "$(fmt_paise "$DELTA_CARDS")" "$STATUS"
  echo ""
  echo "  Cards delta MUST equal Ledger delta for the bench window to be strictly ACID."
  echo "  (Pre-seeded ledger entries are excluded from the check by design.)"
fi
