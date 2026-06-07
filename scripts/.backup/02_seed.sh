#!/usr/bin/env bash
# 02_seed.sh — generate seed.py and load cards, merchants, counters + ledger index.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

cat > "$SRC_DIR/seed.py" <<'EOF'
import os, time, random
from pymongo import MongoClient, InsertOne
import config as C

cli = MongoClient(os.environ["MONGO_URI"], w=C.WRITE_CONCERN)
db = cli[C.DB_NAME]

def bulk(col, docs, batch=10000):
    ops, n = [], 0
    for d in docs:
        ops.append(InsertOne(d))
        if len(ops) >= batch:
            col.bulk_write(ops, ordered=False); n += len(ops); ops = []
            print(f"  {col.name}: {n:,}", end="\r", flush=True)
    if ops:
        col.bulk_write(ops, ordered=False); n += len(ops)
    print(f"  {col.name}: {n:,} done")

def main():
    t0 = time.time()
    print("Dropping existing collections...")
    for c in [C.COL_CARDS, C.COL_LEDGER, C.COL_CARD_COUNTER, C.COL_MERCH_COUNTER]:
        db[c].drop()

    print(f"Seeding {C.NUM_CARDS:,} cards...")
    bulk(db[C.COL_CARDS],
         ({"_id": i, "balance": 1_000_000_00,
           "merchant_hint": random.randint(0, C.NUM_MERCHANTS-1)}
          for i in range(C.NUM_CARDS)))

    print(f"Seeding {C.NUM_CARDS:,} card-counter docs...")
    bulk(db[C.COL_CARD_COUNTER],
         ({"_id": f"{i}:0", "card_id": i, "count": 0} for i in range(C.NUM_CARDS)))

    print(f"Seeding {C.NUM_MERCHANTS:,} merchants x {C.MERCH_COUNTER_BUCKETS} buckets...")
    def merch():
        for m in range(C.NUM_MERCHANTS):
            for b in range(C.MERCH_COUNTER_BUCKETS):
                yield {"_id": f"{m}:{b}", "merchant_id": m, "count": 0}
    bulk(db[C.COL_MERCH_COUNTER], merch())

    print("Creating txn_ledger index {card_id:1, ts:-1}...")
    db[C.COL_LEDGER].create_index([("card_id", 1), ("ts", -1)])

    print("\nCounts:")
    for c in [C.COL_CARDS, C.COL_CARD_COUNTER, C.COL_MERCH_COUNTER]:
        print(f"  {c}: {db[c].estimated_document_count():,}")
    print(f"Seed complete in {time.time()-t0:.1f}s")

if __name__ == "__main__":
    main()
EOF

echo "=== Seeding (this loads 1M cards, 5K merchants, counters) ==="
( cd "$SRC_DIR" && time $PYBIN seed.py )
echo "=== Seed done. Next: ./03_build_go.sh ==="
