#!/usr/bin/env bash
# scenarios/iso8583_bulk.sh — ISO 8583 idempotency bench, bulk variant.
#
# Per fresh transaction (2 round-trips, both ClientBulkWrite):
#   Bulk #1:  [InsertOne idem_cache (PENDING), UpdateOne cards (conditional $gte)]
#             → DuplicateKey on cache → retry path
#             → status = APPROVED if cards.matchedCount==1 else DECLINED
#   Bulk #2:  [InsertOne ledger,
#              UpdateOne cardholder_velocity (upsert),
#              UpdateOne merchant_velocity (upsert),
#              UpdateOne idem_cache (status=COMPLETED + response)]
#
# Commits on DECLINED. Same write count as iso8583_perop (6 writes), but
# compressed into 2 network round-trips instead of 6.
#
# Assumes ./scenarios/iso8583_seed.sh has been run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RWB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$RWB_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

SESSIONS="${SESSIONS:-3000}"
TARGET_TPS="${TARGET_TPS:-5000}"
DURATION="${DURATION:-120}"
DUPLICATE_RATE="${DUPLICATE_RATE:-0.08}"
RETRY_WINDOW_SEC="${RETRY_WINDOW_SEC:-30}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/iso8583_bulk_${TS}"
mkdir -p "$OUT_DIR"

echo "--- precondition check ---"
PRECHECK=$(mongosh "$MONGO_URI" --quiet --eval '
  const db_ = db.getSiblingDB("fss_acid_bench");
  const lc = db_.txn_ledger_iso.estimatedDocumentCount();
  const idx = db_.idempotency_cache.getIndexes().find(i => i.name === "ttl_idem_25h");
  if (!idx) { print("MISSING_TTL"); quit(1); }
  if (lc < 1000) { print("LEDGER_NOT_SEEDED " + lc); quit(1); }
  print("OK " + lc);
' 2>&1) || { echo "$PRECHECK"; echo ""; echo "ERROR: run ./scenarios/iso8583_seed.sh first."; exit 1; }
echo "$PRECHECK"
SEEDED_COUNT=$(echo "$PRECHECK" | awk '/^OK/ {print $2}')

echo ""
echo "============================================================"
echo " ISO 8583 idempotency — BULK variant (2 round-trips/txn)"
echo "============================================================"
echo " bench:            $GO_DIR/iso8583_bulk_bin"
echo " sessions:         $SESSIONS"
echo " target_tps:       $TARGET_TPS"
echo " duration:         ${DURATION}s"
echo " duplicate_rate:   $DUPLICATE_RATE"
echo " retry_window:     ${RETRY_WINDOW_SEC}s"
echo " ledger pre-seed:  $SEEDED_COUNT rows in txn_ledger_iso"
echo " output:           $OUT_DIR"
echo "============================================================"

BENCH_START_EPOCH_MS=$(date +%s)000
echo "$BENCH_START_EPOCH_MS" > "$OUT_DIR/bench_start_epoch_ms.txt"

BEFORE=$(mongosh "$MONGO_URI" --quiet --eval 'print(db.adminCommand({serverStatus:1}).metrics.operation.writeConflicts)' | tr -d -c '0-9')
echo "writeConflicts BEFORE: $BEFORE"
echo "$BEFORE" > "$OUT_DIR/writeconflicts_before.txt"

DUPLICATE_RATE="$DUPLICATE_RATE" RETRY_WINDOW_SEC="$RETRY_WINDOW_SEC" \
  "$GO_DIR/iso8583_bulk_bin" "$SESSIONS" "$TARGET_TPS" "$DURATION" 2>&1 | tee "$OUT_DIR/iso8583_bulk.log"

AFTER=$(mongosh "$MONGO_URI" --quiet --eval 'print(db.adminCommand({serverStatus:1}).metrics.operation.writeConflicts)' | tr -d -c '0-9')
DELTA=$((AFTER - BEFORE))
echo "$AFTER" > "$OUT_DIR/writeconflicts_after.txt"

echo ""
echo "============================================================"
echo " WriteConflicts during the run"
echo "============================================================"
echo "  before: $BEFORE   after: $AFTER   delta: $DELTA"

echo ""
echo "============================================================"
echo " Storage-level verification (this run only)"
echo "============================================================"
mongosh "$MONGO_URI" --quiet --eval "
  const db_ = db.getSiblingDB('fss_acid_bench');
  const bs = new Date($BENCH_START_EPOCH_MS);
  const lc = db_.txn_ledger_iso;
  const ic = db_.idempotency_cache;
  const ledgerRows = lc.countDocuments({ createdAt: { \$gte: bs } });
  const approved   = lc.countDocuments({ createdAt: { \$gte: bs }, status: 'APPROVED' });
  const declined   = lc.countDocuments({ createdAt: { \$gte: bs }, status: 'DECLINED' });
  const cacheRows  = ic.countDocuments({ createdAt: { \$gte: bs } });
  const cachePending = ic.countDocuments({ createdAt: { \$gte: bs }, status: 'PENDING' });
  print('ledger rows this run :', ledgerRows);
  print('  APPROVED           :', approved);
  print('  DECLINED           :', declined);
  print('cache entries this run :', cacheRows);
  print('  stuck in PENDING   :', cachePending, '(should be 0 if no errors)');
" | tee "$OUT_DIR/verification.log"

echo ""
echo "Customer takeaway:"
echo "  - fresh p99       = end-to-end strict-ACID auth (2 round-trips: bulk1[cache+cards], bulk2[ledger+vel+vel+cache])"
echo "  - retry p99       = duplicate-key reject on bulk1 + FindOne cached response"
echo "  - DECLINED count  = real ISO 8583 outcome (committed, not aborted)"
echo "  - cache PENDING   = MUST be 0 (no txn left a half-written cache entry)"
