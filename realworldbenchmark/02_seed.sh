#!/usr/bin/env bash
# 02_seed.sh — generate seed.py and load realistic card-management data.
# Targets: cards & merchants ~4 KB each, pre-warm cardholder_velocity / merchant_velocity.
# Uses ProcessPoolExecutor for cards/merchants seeding to keep wall-clock reasonable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

cat > "$SRC_DIR/seed.py" <<'EOF'
import os, time, random, hashlib, multiprocessing as mp
from datetime import datetime, timezone, timedelta
from pymongo import MongoClient, InsertOne
import bson
import config as C

BATCH = 2000   # smaller batch — docs are 4-5 KB each, keeps message under wire limits
WORKERS = 8

# ---------- shared random pools (cheap to look up) ----------
FIRST_NAMES = ("Aarav","Vivaan","Aditya","Vihaan","Arjun","Sai","Reyansh","Ayaan","Krishna","Ishaan",
               "Ananya","Aadhya","Pari","Diya","Saanvi","Aaradhya","Riya","Myra","Anika","Anaya") * 50
LAST_NAMES  = ("Sharma","Verma","Patel","Kumar","Singh","Yadav","Reddy","Nair","Iyer","Joshi",
               "Gupta","Mehta","Shah","Bhat","Rao","Khan","Das","Pillai","Naidu","Agarwal") * 50
STREETS     = ("MG Road","Brigade Road","Park Street","Linking Road","FC Road","Anna Salai",
               "Connaught Place","Sector 17","Indira Nagar","Banjara Hills") * 50

KYC_DOCS = ("AADHAAR","PAN","PASSPORT","VOTER_ID","DRIVING_LICENSE")
GENDERS  = ("M","F","O")
CHANNELS = ("web","mobile","branch","partner","agent")
SEGMENTS = ("mass","mass-affluent","affluent","hni","premium","student")
CAMPAIGNS = ("WELCOME2024","TRAVEL_GOLD","FUEL_REWARDS","NEW_YEAR_BONUS","LOUNGE_PASS",
             "CASHBACK_PLUS","UPI_EXTRA","WEEKEND_5X","MOVIE_TICKETS","DINING_DELIGHT")

def rstr(n):                                     return os.urandom((n+1)//2).hex()[:n]
def rint(lo, hi, r):                             return r.randint(lo, hi)
def pick(seq, r):                                return seq[r.randrange(len(seq))]

def address(r):
    city, state, pin = pick(C.CITIES, r)
    return {
        "line1": f"{rint(1, 999, r)} {pick(STREETS, r)}",
        "line2": f"Apt {rint(1, 50, r)}",
        "city": city,
        "state": state,
        "pincode": pin,
        "landmark": f"Near {pick(STREETS, r)}",
        "country": "IN",
        "geo": {"lat": round(8.0 + r.random()*30.0, 6),
                "lng": round(68.0 + r.random()*30.0, 6)}
    }

def history_entry(i, r, now):
    return {
        "ts": now - timedelta(days=rint(1, 365, r)),
        "event": pick(("LOGIN","PAYMENT","STATEMENT_VIEW","LIMIT_CHANGE","KYC_REFRESH","CARD_BLOCK","CARD_UNBLOCK"), r),
        "channel": pick(CHANNELS, r),
        "session_id": rstr(32),
        "ip": f"{rint(10,254,r)}.{rint(0,254,r)}.{rint(0,254,r)}.{rint(0,254,r)}",
        "agent": "Mozilla/5.0 (compatible) CardOpsClient/2.1",
        "ref": rstr(20),
        "amount": rint(100, 500000, r),
        "merchant": f"M{rint(1, C.NUM_MERCHANTS, r):07d}",
        "outcome": pick(("SUCCESS","FAILURE","PARTIAL","REVERSED","TIMEOUT"), r),
        "notes": "Routine event recorded by audit subsystem; retained 7y per RBI guidelines."
    }

def card_id(i):   return f"CARD-{i:010d}"
def merch_id(i):  return f"M{i:07d}"
def hour_str(dt): return dt.strftime("%Y%m%d%H")
def day_str(dt):  return dt.strftime("%Y%m%d")


def make_card(i, r, now):
    """Lean shape — target ~92 leaf fields (was ~340 with the rich history array)."""
    bank_name, bin_ = pick(C.BANK_BINS, r)
    city, state, pin = pick(C.CITIES, r)
    return {
        # 7 root identification
        "_id": card_id(i),
        "card_number_masked": f"{bin_}******{rint(1000,9999,r)}",
        "card_number_hash":   "sha256:" + hashlib.sha256(card_id(i).encode()).hexdigest(),
        "scheme":  pick(C.SCHEMES, r),
        "type":    pick(C.CARD_TYPES, r),
        "tier":    pick(C.TIERS, r),
        "network": "VisaNet",
        # 7 issuer
        "issuer": {
            "bank_name":   bank_name,
            "bin":         bin_,
            "branch_code": f"BR{rint(1,999,r):03d}",
            "branch_name": f"{city} Main Branch",
            "region":      pick(("North","South","East","West"), r),
            "country":     "IN",
            "swift":       f"{bank_name[:4].upper()}INBB",
        },
        # 15 holder (10 direct + 5 address)
        "holder": {
            "first_name":  pick(FIRST_NAMES, r),
            "last_name":   pick(LAST_NAMES, r),
            "full_name":   f"{pick(FIRST_NAMES, r)} {pick(LAST_NAMES, r)}",
            "dob":         (now - timedelta(days=rint(7000, 25000, r))).isoformat(),
            "gender":      pick(GENDERS, r),
            "phone":       f"+91-{rint(7000000000,9999999999,r)}",
            "email":       f"user{i}@example.com",
            "kyc_status":  pick(("VERIFIED","PENDING","RE_KYC_DUE","REJECTED"), r),
            "kyc_doc_type": pick(KYC_DOCS, r),
            "kyc_doc_number_masked": f"XXXX-XXXX-{rint(1000,9999,r)}",
            "address": {
                "line1":   f"{rint(1,999,r)} {pick(STREETS, r)}",
                "city":    city,
                "state":   state,
                "pincode": pin,
                "country": "IN",
            },
        },
        # 5 status block
        "status":           "ACTIVE",
        "balance":          r.randint(C.BALANCE_MIN_PAISE, C.BALANCE_MAX_PAISE),
        "version":          0,
        "credit_limit":     rint(100000, 5000000, r) * 100,
        "available_credit": rint(100000, 5000000, r) * 100,
        # 5 limits
        "limits": {
            "perTxn":  C.LIMIT_PER_TXN_PAISE,
            "dayPos":  C.LIMIT_DAY_POS_PAISE,
            "dayAtm":  200000,
            "monthly": 5000000,
            "annual":  50000000,
        },
        # 6 features
        "features": {
            "contactless":   True,
            "online":        True,
            "international": pick((True, False), r),
            "atm":           True,
            "ecom_otp":      True,
            "rewards":       True,
        },
        # 4 fraud_flags
        "fraud_flags": {
            "high_risk":  False,
            "watch_list": False,
            "risk_score": rint(0, 30, r),
            "last_scan":  now.isoformat(),
        },
        # 4 rewards
        "rewards": {
            "program":   pick(("EDGE","INFINITY","SELECT","REWARDZ","SMART"), r),
            "points":    rint(0, 50000, r),
            "tier":      pick(("BLUE","SILVER","GOLD","PLATINUM"), r),
            "earn_rate": round(r.random() * 5, 2),
        },
        # 6 activity
        "activity": {
            "last_txn_at":          None,
            "last_login_at":        (now - timedelta(hours=rint(1,720,r))).isoformat(),
            "total_lifetime_txns":  rint(0, 5000, r),
            "total_lifetime_spend": rint(0, 100000000, r),
            "last_30d_count":       rint(0, 200, r),
            "last_30d_amount":      rint(0, 1000000, r),
        },
        # 4 lifecycle dates
        "issued_at":    (now - timedelta(days=rint(30, 2000, r))).isoformat(),
        "expires_at":   (now + timedelta(days=rint(365, 1825, r))).isoformat(),
        "last_updated": now.isoformat(),
        "activated_at": (now - timedelta(days=rint(30, 1900, r))).isoformat(),
        # 4 metadata
        "metadata": {
            "channel": pick(CHANNELS, r),
            "source":  f"campaign-{rint(1,500,r):03d}",
            "promo":   pick(CAMPAIGNS, r),
            "segment": pick(SEGMENTS, r),
        },
        # 3 scalars/arrays
        "tags":  ["premium","welcome-bonus","auto-pay-enabled"],
        "notes": "Premium card issued under welcome campaign.",
        # 5 entries × 5 fields = 25 history leaves → total ~94
        "history": [{
            "ts":       now - timedelta(days=rint(1,365,r)),
            "event":    pick(("LOGIN","PAYMENT","STATEMENT_VIEW","LIMIT_CHANGE"), r),
            "channel":  pick(CHANNELS, r),
            "amount":   rint(100, 500000, r),
            "merchant": f"M{rint(1, C.NUM_MERCHANTS, r):07d}",
        } for _ in range(5)],
    }


def make_merchant(i, r, now):
    mcc, mcc_name = pick(C.MCCS, r)
    return {
        "_id":             merch_id(i),
        "legal_name":      f"Merchant {i:07d} Pvt Ltd",
        "display_name":    f"Brand {i:07d}",
        "dba":             f"DBA-{i:07d}",
        "mcc":             mcc,
        "mcc_name":        mcc_name,
        "industry":        pick(("retail","food","travel","health","entertainment","fuel","education","services"), r),
        "sub_industry":    pick(("quick_service","casual_dining","specialty","ecommerce","brick_and_mortar"), r),
        "vertical":        pick(("b2c","b2b","b2b2c"), r),
        "status":          "ACTIVE",
        "kyc_status":      "VERIFIED",
        "risk_tier":       pick(("LOW","MEDIUM","HIGH"), r),
        "onboarding": {
            "contract_date":   (now - timedelta(days=rint(30, 2000, r))).isoformat(),
            "go_live_date":    (now - timedelta(days=rint(20, 1900, r))).isoformat(),
            "terms_version":   "v3.2",
            "signed_by":       f"{pick(FIRST_NAMES, r)} {pick(LAST_NAMES, r)}",
            "agreement_ref":   rstr(24),
            "salesperson":     f"SP{rint(1,500,r):04d}",
        },
        "business": {
            "type":     pick(("private_ltd","public_ltd","sole_prop","partnership","llp"), r),
            "gst":      f"{rint(10,99,r)}AAAAA{rint(1000,9999,r)}A1Z{rint(1,9,r)}",
            "pan":      f"AAAAA{rint(1000,9999,r)}A",
            "cin":      f"U{rint(10000,99999,r)}MH{rint(1990,2020,r)}PTC{rint(100000,999999,r)}",
            "incorporated": (now - timedelta(days=rint(1000, 10000, r))).isoformat(),
            "fy_end":   "MARCH",
            "auditor":  f"Auditors {pick(LAST_NAMES, r)} & Co.",
        },
        "registered_address": address(r),
        "billing_address":    address(r),
        "store_address":      address(r),
        "banking": {
            "settlement_account":   rstr(16),
            "ifsc":                 f"HDFC{rint(1000,9999,r):04d}",
            "account_holder_name":  f"Merchant {i:07d} Settlement A/C",
            "settlement_currency":  "INR",
            "frequency":            pick(("T+1","T+2","T+3","WEEKLY"), r),
            "min_settlement":       1000,
            "cutoff_time":          "23:00",
        },
        "pricing": {
            "mdr_slab": [
                {"min": 0,       "max": 2000,    "rate": 0.85},
                {"min": 2000,    "max": 10000,   "rate": 1.10},
                {"min": 10000,   "max": 50000,   "rate": 1.50},
                {"min": 50000,   "max": 250000,  "rate": 1.80},
                {"min": 250000,  "max": 1000000, "rate": 1.95},
            ],
            "interchange":   round(r.random()*1.5, 3),
            "scheme_fees":   round(r.random()*0.5, 3),
            "surcharge":     pick((True, False), r),
            "discount_program": "FESTIVE_2024",
        },
        "compliance": {
            "pci_dss_level":    pick((1,2,3,4), r),
            "last_audit":       (now - timedelta(days=rint(30, 365, r))).isoformat(),
            "certifications":   ["PCI-DSS","ISO27001","SOC2"],
            "dispute_policy":   "STANDARD_30D",
            "chargeback_program":"VPP",
            "kyc_doc_refs":     [rstr(32) for _ in range(4)],
        },
        "operational": {
            "timezone":         "Asia/Kolkata",
            "business_hours":   "09:00-21:00",
            "terminal_count":   rint(1, 100, r),
            "store_count":      rint(1, 50, r),
            "online_presence":  pick((True, False), r),
            "support_email":    f"merchant{i}@example.com",
            "support_phone":    f"+91-{rint(7000000000,9999999999,r)}",
            "escalation_email": f"merchant{i}-escal@example.com",
        },
        "locations": [{"city": c[0], "state": c[1], "pincode": c[2], "lat": round(8+r.random()*30,4), "lng": round(68+r.random()*30,4),
                       "terminal_id": rstr(12)}
                      for c in [pick(C.CITIES, r) for _ in range(5)]],
        "performance": {
            "lifetime_volume":  rint(100000, 100000000, r),
            "lifetime_count":   rint(100, 1000000, r),
            "last_30d_volume":  rint(10000, 5000000, r),
            "last_30d_count":   rint(10, 50000, r),
            "approval_rate":    round(0.85 + r.random()*0.1, 4),
            "refund_rate":      round(r.random()*0.05, 4),
            "chargeback_rate":  round(r.random()*0.01, 4),
            "avg_ticket":       rint(100, 50000, r),
        },
        "velocity_limits": {
            "daily_limit":    rint(100000, 10000000, r),
            "monthly_limit":  rint(1000000, 100000000, r),
            "txn_limit":      rint(10000, 500000, r),
            "txn_count_daily":rint(100, 10000, r),
        },
        "history": [history_entry(i, r, now) for _ in range(10)],
        "tags":  ["partner-onboarded","priority-support","analytics-pro"],
        "notes": "Tier-1 merchant with multi-store retail presence; participates in festive offers "
                 "program. Eligible for next-day settlement; subject to RBI MDR caps and scheme fees.",
        "created_at": (now - timedelta(days=rint(30,2000,r))).isoformat(),
        "updated_at": now.isoformat(),
        "version":     0,
    }


def _cards_worker(args):
    uri, db_name, lo, hi, seed = args
    cli  = MongoClient(uri)
    col  = cli[db_name][C.COL_CARDS]
    r    = random.Random(seed)
    now  = datetime.now(timezone.utc)
    ops, written = [], 0
    for i in range(lo, hi + 1):
        ops.append(InsertOne(make_card(i, r, now)))
        if len(ops) >= BATCH:
            col.bulk_write(ops, ordered=False); written += len(ops); ops = []
    if ops:
        col.bulk_write(ops, ordered=False); written += len(ops)
    cli.close()
    return written


def _merchants_worker(args):
    uri, db_name, lo, hi, seed = args
    cli = MongoClient(uri)
    col = cli[db_name][C.COL_MERCHANTS]
    r   = random.Random(seed)
    now = datetime.now(timezone.utc)
    ops, written = [], 0
    for i in range(lo, hi + 1):
        ops.append(InsertOne(make_merchant(i, r, now)))
        if len(ops) >= BATCH:
            col.bulk_write(ops, ordered=False); written += len(ops); ops = []
    if ops:
        col.bulk_write(ops, ordered=False); written += len(ops)
    cli.close()
    return written


def parallel_seed(worker, total, label):
    uri = os.environ["MONGO_URI"]
    chunk = max(1, (total + WORKERS - 1) // WORKERS)
    tasks = []
    for w in range(WORKERS):
        lo = w * chunk + 1
        hi = min((w + 1) * chunk, total)
        if lo > hi: continue
        tasks.append((uri, C.DB_NAME, lo, hi, lo))
    ctx = mp.get_context("spawn")
    t0 = time.time()
    with ctx.Pool(processes=len(tasks)) as pool:
        results = list(pool.imap(worker, tasks))
    print(f"  {label}: {sum(results):,} done in {time.time()-t0:.1f}s")


def main():
    t0 = time.time()
    cli = MongoClient(os.environ["MONGO_URI"], w=C.WRITE_CONCERN)
    db  = cli[C.DB_NAME]

    print("Dropping existing RWB collections...")
    for c in [C.COL_CARDS, C.COL_MERCHANTS, C.COL_LEDGER, C.COL_MERCH_VEL, C.COL_CARD_VEL]:
        db[c].drop()

    # --- quick size probe ---
    r0 = random.Random(0); now0 = datetime.now(timezone.utc)
    card_sz  = len(bson.encode(make_card(1, r0, now0)))
    merch_sz = len(bson.encode(make_merchant(1, r0, now0)))
    print(f"  card sample size:     {card_sz} bytes  (target {C.TARGET_CARD_SIZE_BYTES})")
    print(f"  merchant sample size: {merch_sz} bytes (target {C.TARGET_MERCHANT_SIZE_BYTES})")

    print(f"Seeding {C.NUM_CARDS:,} cards (rich shape, {WORKERS} workers)...")
    parallel_seed(_cards_worker, C.NUM_CARDS, "cards")

    print(f"Seeding {C.NUM_MERCHANTS:,} merchants (rich shape)...")
    parallel_seed(_merchants_worker, C.NUM_MERCHANTS, "merchants")

    now = datetime.now(timezone.utc)
    print(f"Pre-warming merchant_velocity ({C.NUM_MERCHANTS:,} × {C.MERCH_BUCKETS} cb, current hour)...")
    hb = hour_str(now)
    ops = []; written = 0
    for m in range(1, C.NUM_MERCHANTS + 1):
        for cb in range(C.MERCH_BUCKETS):
            _id = {"mid": merch_id(m), "bucket": hb, "cb": cb}
            ops.append(InsertOne({"_id": _id, "count": 0, "sum": 0, "updatedAt": now}))
            if len(ops) >= 5000:
                db[C.COL_MERCH_VEL].bulk_write(ops, ordered=False); written += len(ops); ops = []
    if ops:
        db[C.COL_MERCH_VEL].bulk_write(ops, ordered=False); written += len(ops)
    print(f"  merchant_velocity: {written:,} done")

    print(f"Pre-warming cardholder_velocity ({C.NUM_CARDS:,}, current day)...")
    db_str = day_str(now); ops = []; written = 0
    for i in range(1, C.NUM_CARDS + 1):
        _id = {"cardId": card_id(i), "bucket": db_str}
        ops.append(InsertOne({"_id": _id, "count": 0, "sum": 0, "updatedAt": now}))
        if len(ops) >= 5000:
            db[C.COL_CARD_VEL].bulk_write(ops, ordered=False); written += len(ops); ops = []
    if ops:
        db[C.COL_CARD_VEL].bulk_write(ops, ordered=False); written += len(ops)
    print(f"  cardholder_velocity: {written:,} done")

    lean = os.environ.get("BENCH_LEAN_INDEXES", "").strip().lower() in ("1", "true", "yes")
    print(f"Creating indexes (lean={lean})...")
    # Always create velocity secondaries — free on $inc writes.
    db[C.COL_MERCH_VEL].create_index([("_id.mid", 1), ("_id.bucket", -1)],    name="mid_bucket_idx",    background=True)
    db[C.COL_CARD_VEL ].create_index([("_id.cardId", 1), ("_id.bucket", -1)], name="cardId_bucket_idx", background=True)
    if lean:
        print("  BENCH_LEAN_INDEXES=1 → skipping cards/merchants/ledger production-query indexes")
    else:
        db[C.COL_CARDS].create_index([("status", 1), ("balance", -1)], name="status_balance_idx", background=True)
        db[C.COL_CARDS].create_index([("holder.phone", 1)],            name="phone_idx",          background=True)
        db[C.COL_MERCHANTS].create_index([("mcc", 1), ("status", 1)],  name="mcc_status_idx",     background=True)
        db[C.COL_LEDGER].create_index([("cardId", 1), ("ts", -1)],     name="cardId_ts_idx",      background=True)
        db[C.COL_LEDGER].create_index([("mid", 1), ("ts", -1)],        name="mid_ts_idx",         background=True)
        db[C.COL_LEDGER].create_index([("rrn", 1)],                    name="rrn_idx",            background=True)

    print("\nCounts:")
    for c in [C.COL_CARDS, C.COL_MERCHANTS, C.COL_MERCH_VEL, C.COL_CARD_VEL]:
        print(f"  {c}: {db[c].estimated_document_count():,}")
    print(f"Seed complete in {time.time()-t0:.1f}s")

if __name__ == "__main__":
    main()
EOF

echo "=== Seeding RWB (rich shapes: cards 4KB, merchants 4KB, ledger 5KB at runtime) ==="
( cd "$SRC_DIR" && time $PYBIN seed.py )

# Record the initial cards.balance sum so verify_acid.sh has a reference point.
INIT_FILE="/tmp/${BENCH_DB_NAME}_initial_cards.paise"
INITIAL_TOTAL=$(mongosh "$MONGO_URI" --quiet --eval \
  "print(db.getSiblingDB('$BENCH_DB_NAME').cards.aggregate([{\$group:{_id:null,t:{\$sum:'\$balance'}}}]).toArray()[0].t.toString())" \
  | tail -1)
echo "$INITIAL_TOTAL" > "$INIT_FILE"
echo "Recorded initial cards.balance total → $INIT_FILE  ($(printf "%'d" "$INITIAL_TOTAL") paise)"

echo "=== Seed done. Next: ./03_build_go.sh ==="
