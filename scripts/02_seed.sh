#!/usr/bin/env bash
# 02_seed.sh — generate seed.py and load cards + pre-warm velocity collections.
# Schema: FSS-flavored cards with string _id, hybrid merchant_velocity (hour + 256 contention shards),
# cardholder_velocity (day bucket, no shards), txn_ledger indexes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

cat > "$SRC_DIR/seed.py" <<'EOF'
import os, time, random
from datetime import datetime, timezone
from pymongo import MongoClient, InsertOne, UpdateOne
import config as C

BATCH = 5000

def card_id(i):    return f"CARD-{i:010d}"
def merch_id(i):   return f"M{i:07d}"
def hour_str(dt):  return dt.strftime("%Y%m%d%H")
def day_str(dt):   return dt.strftime("%Y%m%d")

def bulk(col, ops, batch=BATCH):
    n = 0; buf = []
    for op in ops:
        buf.append(op)
        if len(buf) >= batch:
            col.bulk_write(buf, ordered=False); n += len(buf); buf = []
            print(f"  {col.name}: {n:,}", end="\r", flush=True)
    if buf:
        col.bulk_write(buf, ordered=False); n += len(buf)
    print(f"  {col.name}: {n:,} done")

def main():
    t0 = time.time()
    cli = MongoClient(os.environ["MONGO_URI"], w=C.WRITE_CONCERN)
    db = cli[C.DB_NAME]

    print("Dropping existing collections...")
    for c in [C.COL_CARDS, C.COL_LEDGER, C.COL_MERCH_VEL, C.COL_CARD_VEL]:
        db[c].drop()

    print(f"Seeding {C.NUM_CARDS:,} cards (FSS shape, string _id)...")
    now = datetime.now(timezone.utc)
    rng = random.Random(42)
    def card_docs():
        for i in range(1, C.NUM_CARDS + 1):
            yield InsertOne({
                "_id":       card_id(i),
                "status":    "ACTIVE",
                "balance":   rng.randint(C.BALANCE_MIN_PAISE, C.BALANCE_MAX_PAISE),
                "version":   0,
                "limits":    {"perTxn": C.LIMIT_PER_TXN_PAISE, "dayPos": C.LIMIT_DAY_POS_PAISE},
                "scheme":    rng.choice(C.SCHEMES),
                "issuedAt":  now,
                "lastTxnAt": None,
            })
    bulk(db[C.COL_CARDS], card_docs())

    print(f"Pre-warming merchant_velocity ({C.NUM_MERCHANTS:,} × {C.MERCH_BUCKETS} cb, current hour)...")
    hb = hour_str(now)
    def mv_docs():
        for m in range(1, C.NUM_MERCHANTS + 1):
            mid = merch_id(m)
            for cb in range(C.MERCH_BUCKETS):
                _id = {"mid": mid, "bucket": hb, "cb": cb}
                yield InsertOne({"_id": _id, "count": 0, "sum": 0, "updatedAt": now})
    bulk(db[C.COL_MERCH_VEL], mv_docs())

    print(f"Pre-warming cardholder_velocity ({C.NUM_CARDS:,}, current day)...")
    db_str = day_str(now)
    def cv_docs():
        for i in range(1, C.NUM_CARDS + 1):
            _id = {"cardId": card_id(i), "bucket": db_str}
            yield InsertOne({"_id": _id, "count": 0, "sum": 0, "updatedAt": now})
    bulk(db[C.COL_CARD_VEL], cv_docs())

    lean = os.environ.get("BENCH_LEAN_INDEXES", "").strip().lower() in ("1", "true", "yes")
    print(f"Creating indexes (lean={lean})...")
    # Velocity secondaries are free on writes ($inc doesn't touch _id) — always create.
    db[C.COL_MERCH_VEL].create_index([("_id.mid", 1), ("_id.bucket", -1)],    name="mid_bucket_idx",    background=True)
    db[C.COL_CARD_VEL].create_index ([("_id.cardId", 1), ("_id.bucket", -1)], name="cardId_bucket_idx", background=True)
    if lean:
        print("  BENCH_LEAN_INDEXES=1 → skipping cards.status_balance_idx and txn_ledger.{cardId_ts,mid_ts}")
    else:
        db[C.COL_CARDS].create_index([("status", 1), ("balance", -1)], name="status_balance_idx", background=True)
        db[C.COL_LEDGER].create_index([("cardId", 1), ("ts", -1)], name="cardId_ts_idx", background=True)
        db[C.COL_LEDGER].create_index([("mid", 1), ("ts", -1)],    name="mid_ts_idx",    background=True)

    print("\nCounts:")
    for c in [C.COL_CARDS, C.COL_MERCH_VEL, C.COL_CARD_VEL]:
        print(f"  {c}: {db[c].estimated_document_count():,}")
    print(f"Seed complete in {time.time()-t0:.1f}s")

if __name__ == "__main__":
    main()
EOF

echo "=== Seeding (1M cards, 1.28M merchant_velocity, 1M cardholder_velocity) ==="
( cd "$SRC_DIR" && time $PYBIN seed.py )
echo "=== Seed done. Next: ./03_build_go.sh ==="
