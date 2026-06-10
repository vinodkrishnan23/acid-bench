#!/usr/bin/env bash
# scenarios/iso8583_seed.sh — one-time setup for the iso8583 idempotency benches.
#
# Creates:
#   - txn_ledger_iso         (NEW, primed with N rows; default 100M)
#   - idempotency_cache      (NEW, empty; TTL on createdAt = 25h)
#
# Leaves alone:
#   - cards, cardholder_velocity, merchant_velocity   (seeded by 02_seed.sh)
#   - txn_ledger                                       (the existing 111M-row ledger)
#
# Seeded txn_ledger_iso rows reference cardIds in [CARD-0000000001..CARD-numCards]
# and merchant ids from the same pickMerchant() distribution as the live bench,
# so they line up with cards / merchant_velocity / cardholder_velocity.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RWB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$RWB_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

NUM_ROWS="${NUM_ROWS:-${1:-100000000}}"
SEED_WORKERS="${SEED_WORKERS:-32}"
SEED_BATCH="${SEED_BATCH:-1000}"
SEED_SPAN_HOURS="${SEED_SPAN_HOURS:-23}"
TTL_SECONDS="${TTL_SECONDS:-90000}"   # 25h — wider than ISO 8583 retry SLA

if [[ ! -x "$GO_DIR/iso8583seed_bin" ]]; then
  echo "ERROR: $GO_DIR/iso8583seed_bin not found. Run ./03_build_go.sh first." >&2
  exit 1
fi

echo "============================================================"
echo " ISO 8583 idempotency — one-time seed"
echo "============================================================"
echo " num_rows (txn_ledger_iso):  $NUM_ROWS"
echo " workers:                    $SEED_WORKERS"
echo " batch:                      $SEED_BATCH"
echo " createdAt span:             ${SEED_SPAN_HOURS}h"
echo " idempotency_cache TTL:      ${TTL_SECONDS}s"
echo "============================================================"

# 1. Drop + recreate test collections. Other collections are untouched.
echo ""
echo "--- step 1/3: drop + recreate test collections ---"
mongosh "$MONGO_URI" --quiet --eval '
  const db_ = db.getSiblingDB("fss_acid_bench");
  db_.txn_ledger_iso.drop();
  db_.idempotency_cache.drop();
  db_.createCollection("txn_ledger_iso");
  db_.createCollection("idempotency_cache");
  print("txn_ledger_iso     : dropped + recreated");
  print("idempotency_cache  : dropped + recreated");
'

# 2. Bulk seed N rows into txn_ledger_iso
echo ""
echo "--- step 2/3: bulk seed $NUM_ROWS rows into txn_ledger_iso ---"
SEED_WORKERS="$SEED_WORKERS" SEED_BATCH="$SEED_BATCH" SEED_SPAN_HOURS="$SEED_SPAN_HOURS" \
  "$GO_DIR/iso8583seed_bin" "$NUM_ROWS"

ACTUAL=$(mongosh "$MONGO_URI" --quiet --eval 'print(db.getSiblingDB("fss_acid_bench").txn_ledger_iso.estimatedDocumentCount())' | tr -d -c '0-9')
echo "verified rows in txn_ledger_iso: $ACTUAL"

# 3. Build the TTL index on idempotency_cache. _id is automatically unique
#    (string concat of "rrn|stan|acquirerCode"), so no extra unique index needed.
#    Also add a non-TTL index on txn_ledger_iso.createdAt so post-bench
#    verification can do bounded range queries fast (rather than 100M-row scans).
echo ""
echo "--- step 3/3: indexes (idempotency_cache TTL + ledger createdAt) ---"
mongosh "$MONGO_URI" --quiet --eval "
  const db_ = db.getSiblingDB('fss_acid_bench');
  db_.idempotency_cache.createIndex(
    { createdAt: 1 },
    { name: 'ttl_idem_25h', expireAfterSeconds: $TTL_SECONDS }
  );
  print('idempotency_cache: TTL index ttl_idem_25h created (expireAfterSeconds=$TTL_SECONDS)');
  db_.txn_ledger_iso.createIndex(
    { createdAt: 1 },
    { name: 'createdAt_1' }
  );
  print('txn_ledger_iso: createdAt index created (for verification queries)');
"

# 4. Final stats
echo ""
echo "============================================================"
echo " Final state"
echo "============================================================"
mongosh "$MONGO_URI" --quiet --eval '
  const db_ = db.getSiblingDB("fss_acid_bench");
  const collections = ["txn_ledger_iso", "idempotency_cache", "cards", "cardholder_velocity", "merchant_velocity", "txn_ledger"];
  for (const name of collections) {
    const c = db_.getCollection(name);
    try {
      const count = c.estimatedDocumentCount();
      const s = c.stats();
      print(name.padEnd(25), "docs:", String(count).padStart(12), " data:", (s.size/1024/1024/1024).toFixed(2)+" GB", " indexes:", Object.keys(s.indexSizes).length);
    } catch (e) {
      print(name.padEnd(25), "(missing)");
    }
  }
'

echo ""
echo "Ready. Next:"
echo "  ./scenarios/iso8583_perop.sh   # 6 round-trips per txn"
echo "  ./scenarios/iso8583_bulk.sh    # 2 round-trips per txn (ClientBulkWrite)"
