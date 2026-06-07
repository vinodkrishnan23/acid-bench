#!/usr/bin/env bash
# 04_seed_ledger.sh — pre-seed the txn_ledger collection with N rich ~5 KB entries.
#
# Usage:
#   ./04_seed_ledger.sh             # default 500M
#   ./04_seed_ledger.sh 100m        # shortcut: 100,000,000
#   ./04_seed_ledger.sh 250000000   # explicit count
#   TXN_COUNT=300000000 ./04_seed_ledger.sh
#   UPDATE_DERIVED=1 ./04_seed_ledger.sh 200m   # also reconcile cards.balance, cardholder_velocity,
#                                                # and merchant_velocity (cb=0) with the pre-seeded ledger
#
# Uses 8 multiprocess workers + bulk_write. Wall times (rough):
#   100M  ~25–50 min
#   200M  ~50 min – 2 h
#   300M  ~1.5–3 h
#   400M  ~2–3.5 h
#   500M  ~2–4 h
#
# The pre-seeded entries are EXCLUDED from the bench's conservation check by design —
# cash_snapshot.sh records the ledger baseline at `seed` time and compares deltas at `final`.
# Set UPDATE_DERIVED=1 to reconcile cards, cardholder_velocity, and merchant_velocity (cb=0)
# with the pre-seeded ledger via 3 server-side $group passes. Adds ~15–45 min at 500M scale.
# After this completes, verify_acid.sh will report ✓ for the consistency check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# positional arg overrides TXN_COUNT; supports `Nm` / `NM` shortcut for millions.
if [ $# -ge 1 ] && [ -n "$1" ]; then
  arg="$1"
  case "$arg" in
    *m|*M) TXN_COUNT=$(( ${arg%[mM]} * 1000000 )) ;;
    *)     TXN_COUNT="$arg" ;;
  esac
fi

TXN_COUNT="${TXN_COUNT:-500000000}"
WORKERS="${WORKERS:-8}"
BATCH="${LEDGER_BATCH:-1000}"
UPDATE_DERIVED_FLAG="${UPDATE_DERIVED:-0}"

cat > "$SRC_DIR/seed_ledger.py" <<'EOF'
import os, sys, time, random, multiprocessing as mp
from datetime import datetime, timezone, timedelta
from pymongo import MongoClient, InsertOne
import config as C

# Quoted heredoc — these read at runtime from the env exported by the wrapper.
TXN_COUNT      = int(os.environ.get("TXN_COUNT", "500000000"))
WORKERS        = int(os.environ.get("WORKERS", "8"))
BATCH          = int(os.environ.get("LEDGER_BATCH", "1000"))
UPDATE_DERIVED = bool(int(os.environ.get("UPDATE_DERIVED_FLAG", "0")))

SCHEMES = ("VISA","MASTERCARD","RUPAY","AMEX")
STATUSES = ("APPROVED","DECLINED","REVERSED")
RULES = ("VEL_HOUR_OK","VEL_DAY_OK","KYC_VERIFIED","NEW_DEVICE","NO_CHARGEBACK",
         "INTL_OFF","MCC_ALLOWED","TIMEZONE_NORMAL","IP_TRUSTED","DEVICE_BOUND")
CITIES = ("Mumbai","Delhi","Bangalore","Hyderabad","Chennai","Kolkata","Pune","Ahmedabad","Jaipur","Lucknow")
STATES = ("Maharashtra","Delhi","Karnataka","Telangana","Tamil Nadu","West Bengal","Gujarat","Rajasthan","Uttar Pradesh")
TRACE_STEPS = ("AUTH","RISK","FRAUD","VELOCITY","BALANCE","FX","COMMIT","NOTIFY","STMT","SETTLE")
TRACE_NOTE  = "step completed within SLA, no retry needed; standard authorization path executed"

def rhex(r, n):  return ("%x" % r.getrandbits(n*4)).rjust(n, "0")[:n]
def pick(seq, r):return seq[r.randrange(len(seq))]

def build_ledger_doc(card_id_str, mid_str, amount, now, r):
    """Lean shape — target ~93 leaf fields, matches the Go bench-time builder exactly."""
    city = pick(CITIES, r); state = pick(STATES, r)
    # 5 entries × 5 fields = 25 trace leaves
    trace_steps = ("AUTH","RISK","VELOCITY","COMMIT","SETTLE")
    trace = [{
        "step":    step,
        "ts":      now + timedelta(milliseconds=i),
        "latency": r.randint(0, 20),
        "outcome": "ok",
        "node":    f"auth-node-{r.randint(0,49):02d}",
    } for i, step in enumerate(trace_steps)]
    return {
        # 8 identification
        "type":            "PURCHASE",
        "amount":          amount,
        "currency":        "INR",
        "original_amount": amount,
        "status":          pick(STATUSES, r),
        "cardId":          card_id_str,
        "mid":             mid_str,
        "ts":              now,
        # 10 card_snapshot
        "card_snapshot": {
            "masked_pan": "411111******" + f"{r.randint(0,9999):04d}",
            "scheme":     pick(SCHEMES, r),
            "type":       "credit",
            "tier":       "platinum",
            "network":    "VisaNet",
            "bin":        "411111",
            "issuer":     "HDFC Bank",
            "country":    "IN",
            "region":     "South",
            "verified":   True,
        },
        # 9 merchant_snapshot
        "merchant_snapshot": {
            "brand":      "BrandName",
            "mcc":        5411,
            "mcc_name":   "GROCERY_STORES",
            "terminal":   "T" + rhex(r, 8),
            "city":       city,
            "state":      state,
            "country":    "IN",
            "risk_tier":  "LOW",
            "settlement": "T+1",
        },
        # 6 auth
        "auth": {
            "rrn":           rhex(r, 32),
            "arn":           rhex(r, 32),
            "stan":          f"{r.randint(0, 999999):06d}",
            "approval_code": f"{r.randint(0, 999999):06d}",
            "auth_method":   "chip_contactless",
            "acquirer_id":   "ACQ001",
        },
        # 4 risk (rules_triggered is a single array field)
        "risk": {
            "score":           r.randint(0, 100),
            "rules_triggered": list(RULES)[:3],
            "decision":        "approve",
            "engine_version":  "risk-engine-v4.2",
        },
        # 4 velocity_snapshot
        "velocity_snapshot": {
            "card_count_24h": r.randint(0, 50),
            "card_sum_24h":   r.randint(0, 100_000),
            "merch_count_1h": r.randint(0, 500),
            "merch_sum_1h":   r.randint(0, 500_000),
        },
        # 4 operational
        "operational": {
            "response_time_ms": r.randint(0, 50),
            "network_path":     "primary",
            "correlation_id":   rhex(r, 16),
            "trace_id":         rhex(r, 16),
        },
        # 5 settlement
        "settlement": {
            "batch_id":          rhex(r, 16),
            "settled_at":        now + timedelta(days=1),
            "settlement_amount": amount,
            "interchange_fee":   int(amount * 0.011),
            "net":               int(amount * 0.984),
        },
        # 4 three_ds
        "three_ds": {
            "enrolled":      True,
            "authenticated": True,
            "eci":           "05",
            "cavv":          rhex(r, 32),
        },
        # 4 device
        "device": {
            "device_id": rhex(r, 32),
            "ua":        "Mozilla/5.0 (compatible) RWBClient/1.0",
            "ip_hash":   rhex(r, 32),
            "os":        "iOS 18.2",
        },
        # 6 geo
        "geo": {
            "city":    city,
            "state":   state,
            "country": "IN",
            "lat":     12.97 + r.random(),
            "lng":     77.59 + r.random(),
            "ip":      f"{r.randint(1,254)}.{r.randint(0,254)}.{r.randint(0,254)}.{r.randint(0,254)}",
        },
        # 3 audit
        "audit": {
            "createdAt":   now,
            "processedBy": "auth-cluster-01",
            "version":     1,
        },
        # 1 notes
        "notes": "Authorization completed within SLA.",
        # 25 trace leaves (5 × 5)
        "trace": trace,
    }


def _worker(args):
    uri, db_name, count, seed = args
    cli = MongoClient(uri)
    col = cli[db_name][C.COL_LEDGER]
    r   = random.Random(seed)
    base_now = datetime.now(timezone.utc)
    window_days = 30
    ops, written, last_log = [], 0, time.time()
    for i in range(count):
        c = r.randint(1, C.NUM_CARDS)
        m = r.randint(1, C.NUM_MERCHANTS)
        amount = r.randint(C.TXN_AMOUNT_MIN_PAISE, C.TXN_AMOUNT_MAX_PAISE)
        ts = base_now - timedelta(seconds=r.randint(0, window_days * 86400))
        ops.append(InsertOne(build_ledger_doc(f"CARD-{c:010d}", f"M{m:07d}", amount, ts, r)))
        if len(ops) >= BATCH:
            col.bulk_write(ops, ordered=False); written += len(ops); ops = []
            if time.time() - last_log > 30:
                print(f"  worker seed={seed}: {written:,} written", flush=True); last_log = time.time()
    if ops:
        col.bulk_write(ops, ordered=False); written += len(ops)
    cli.close()
    return written


def update_derived_state(uri):
    """Reconcile cards.balance, cardholder_velocity, and merchant_velocity with
    the pre-seeded txn_ledger entries. Three server-side $group passes."""
    from pymongo import UpdateOne
    cli = MongoClient(uri)
    db  = cli[C.DB_NAME]
    now = datetime.now(timezone.utc)

    # 1. cards.balance -= sum_of_ledger.amount per cardId
    print("\n[1/3] $group ledger by cardId → updating cards.balance...")
    t0 = time.time()
    cur = db[C.COL_LEDGER].aggregate(
        [{"$group": {"_id": "$cardId", "spent": {"$sum": "$amount"}}}],
        allowDiskUse=True, batchSize=5000)
    ops = []; updated = 0
    for r in cur:
        ops.append(UpdateOne({"_id": r["_id"]}, {"$inc": {"balance": -int(r["spent"])}}))
        if len(ops) >= 1000:
            db[C.COL_CARDS].bulk_write(ops, ordered=False); updated += len(ops); ops = []
    if ops:
        db[C.COL_CARDS].bulk_write(ops, ordered=False); updated += len(ops)
    print(f"      cards updated: {updated:,} in {time.time()-t0:.0f}s")

    # 2. cardholder_velocity: upsert per (cardId, day_bucket)
    print("[2/3] $group ledger by (cardId, day) → upserting cardholder_velocity...")
    t0 = time.time()
    cur = db[C.COL_LEDGER].aggregate([
        {"$group": {
            "_id": {"cardId": "$cardId",
                     "bucket": {"$dateToString": {"format": "%Y%m%d", "date": "$ts"}}},
            "n": {"$sum": 1},
            "spent": {"$sum": "$amount"},
        }}
    ], allowDiskUse=True, batchSize=5000)
    ops = []; updated = 0
    for r in cur:
        ops.append(UpdateOne(
            {"_id": r["_id"]},
            {"$inc": {"count": int(r["n"]), "sum": int(r["spent"])},
             "$set": {"updatedAt": now}},
            upsert=True))
        if len(ops) >= 1000:
            db[C.COL_CARD_VEL].bulk_write(ops, ordered=False); updated += len(ops); ops = []
    if ops:
        db[C.COL_CARD_VEL].bulk_write(ops, ordered=False); updated += len(ops)
    print(f"      cardholder_velocity upserts: {updated:,} in {time.time()-t0:.0f}s")

    # 3. merchant_velocity: upsert per (mid, hour_bucket, cb=0)
    print("[3/3] $group ledger by (mid, hour) → upserting merchant_velocity (cb=0)...")
    t0 = time.time()
    cur = db[C.COL_LEDGER].aggregate([
        {"$group": {
            "_id": {"mid": "$mid",
                     "bucket": {"$dateToString": {"format": "%Y%m%d%H", "date": "$ts"}},
                     "cb": {"$literal": 0}},
            "n": {"$sum": 1},
            "spent": {"$sum": "$amount"},
        }}
    ], allowDiskUse=True, batchSize=5000)
    ops = []; updated = 0
    for r in cur:
        ops.append(UpdateOne(
            {"_id": r["_id"]},
            {"$inc": {"count": int(r["n"]), "sum": int(r["spent"])},
             "$set": {"updatedAt": now}},
            upsert=True))
        if len(ops) >= 1000:
            db[C.COL_MERCH_VEL].bulk_write(ops, ordered=False); updated += len(ops); ops = []
    if ops:
        db[C.COL_MERCH_VEL].bulk_write(ops, ordered=False); updated += len(ops)
    print(f"      merchant_velocity upserts: {updated:,} in {time.time()-t0:.0f}s")

    cli.close()
    print("Derived state reconciled with txn_ledger.")


def main():
    uri = os.environ["MONGO_URI"]
    print(f"Seeding {TXN_COUNT:,} txn_ledger docs ({WORKERS} workers, batch={BATCH})")
    per_worker = (TXN_COUNT + WORKERS - 1) // WORKERS
    tasks = []
    remaining = TXN_COUNT
    for w in range(WORKERS):
        count = min(per_worker, remaining)
        if count <= 0: break
        tasks.append((uri, C.DB_NAME, count, w * 1000 + 7))
        remaining -= count

    t0 = time.time()
    ctx = mp.get_context("spawn")
    with ctx.Pool(processes=len(tasks)) as pool:
        results = list(pool.imap(_worker, tasks))
    elapsed = time.time() - t0
    total = sum(results)
    rate = total / elapsed if elapsed > 0 else 0
    print(f"\nTotal written: {total:,} in {elapsed:.0f}s  ({rate:,.0f} docs/sec aggregate)")

    if UPDATE_DERIVED:
        update_derived_state(uri)

if __name__ == "__main__":
    mp.freeze_support()
    main()
EOF

echo "=== Pre-seeding ledger (${TXN_COUNT} docs, ${WORKERS} workers, batch=${BATCH}) ==="
echo "    This is long-running. Expected: 2–4 hours at 500M; ~minutes at 1M for validation."
LEDGER_BATCH="$BATCH"
export TXN_COUNT WORKERS LEDGER_BATCH UPDATE_DERIVED_FLAG
( cd "$SRC_DIR" && time $PYBIN seed_ledger.py )
echo "=== Ledger seed complete. ==="
