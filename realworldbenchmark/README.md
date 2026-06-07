# RWB — Real-World Benchmark (rich card-management docs)

> 📊 **Latest results**: see [`RESULTS.md`](RESULTS.md) — both variants pass
> 5/5 at p99 ≤ 12 ms on the 128 GB cluster as of 2026-06-07.

A **separate** benchmark variant in this repo. Same 4-op strict-ACID transaction
flow as the FSS bench, **but every document is realistically sized** — after the
lean-schema reduction, `cards` are ~3 KB (91 fields), `merchants` are ~4 KB,
`txn_ledger` writes are ~3 KB (99 fields). This stresses the cluster on payload
bandwidth, oplog volume, WiredTiger cache turnover, and network ingest in a way
the FSS bench (few-byte docs) does not.

**Nothing in `scripts/` or `terraform/` is touched.** RWB has its own database
(`fss_acid_bench`), its own project tree (`/home/ec2-user/RWB`), and its own binaries.
You can run RWB while the FSS bench is also seeded on the same cluster.

---

## When to run RWB (vs FSS bench)

| | FSS bench (`scripts/`) | RWB (this folder) |
|---|---|---|
| `cards` doc size | ~200 bytes | **~4 KB** |
| `merchants` collection | (none — only `merchant_velocity` counter) | **new collection, ~4 KB/doc** |
| `txn_ledger` insert size | ~150 bytes | **~5 KB** |
| Cluster pressure | CPU + index updates | **Bandwidth + cache + oplog + index** |
| Use when | Isolating contention / IOPS / round-trip cost | **Measuring with realistic production payloads** |

The 4-op transaction shape and the velocity-bucket pattern are intentionally
identical to the FSS bench so results compare directly: any extra cost in RWB
is attributable to doc size, not to a different write pattern.

---

## Schema

`cards`, `merchants`, and `txn_ledger` all have realistic shapes. Highlights below;
the seed enforces ≥ 4 KB for cards/merchants via included history arrays.

### `cards` (~4 KB each, 1,000,000 docs)

```js
{
  _id: "CARD-0000000001",
  card_number_masked: "411111******1234",
  card_number_hash: "sha256:…",
  scheme, type, tier, network,
  issuer: { bank_name, bin, branch_code, branch_name, region, country, swift },
  holder: { title, first_name, middle_name, last_name, full_name, dob, gender,
            phone, alt_phone, email, alt_email, address: {…full address + geo},
            kyc_status, kyc_doc_type, kyc_doc_number_masked, kyc_verified_at },
  status, balance, version, credit_limit, available_credit,
  limits:   { perTxn, dayPos, dayAtm, monthly, annual, international, online, contactless },
  features: { contactless, online, international, atm, magstripe, ecom_otp, auto_pay, rewards },
  fraud_flags, rewards, activity, metadata,
  issued_at, expires_at, last_updated, activated_at,
  tags: [...], campaign_history: [...], notes: "…",
  history: [ {ts, event, channel, session_id, ip, …} × 20 ]
}
```

### `merchants` (~4 KB each, 5,000 docs)

```js
{
  _id: "M0000001",
  legal_name, display_name, dba, mcc, mcc_name, industry, sub_industry, vertical,
  status, kyc_status, risk_tier,
  onboarding: { contract_date, go_live_date, terms_version, signed_by, agreement_ref, salesperson },
  business: { type, gst, pan, cin, incorporated, fy_end, auditor },
  registered_address, billing_address, store_address,
  banking: { settlement_account, ifsc, account_holder_name, settlement_currency, frequency, … },
  pricing: { mdr_slab: [...5 slabs], interchange, scheme_fees, surcharge, discount_program },
  compliance, operational,
  locations: [ {city, state, pincode, lat, lng, terminal_id} × 5 ],
  performance, velocity_limits,
  history: [ {ts, event, channel, …} × 10 ],
  tags, notes, created_at, updated_at, version
}
```

### `txn_ledger` (~5 KB written per txn, grows during runs)

Built by `buildLedgerDoc(...)` in Go. Includes: `card_snapshot`, `merchant_snapshot`,
`auth` (RRN/ARN/STAN/approval), `risk` (score + 10 rules), `velocity_snapshot`
(30d/24h/1h windows), `operational` (trace/span IDs), `settlement` (fees breakdown),
`three_ds` (CAVV/XID/eci), `device` (fingerprint/UA/OS), `geo` (city/lat/lng/IP/ASN),
`audit`, and a 10-step `trace` array.

### Velocity collections (unchanged from FSS)

- `cardholder_velocity`: `{_id: {cardId, bucket: <day>}, count, sum, updatedAt}` —
  1M pre-warmed for current day.
- `merchant_velocity`: `{_id: {mid, bucket: <hour>, cb: 0..255}, count, sum, updatedAt}` —
  1.28M pre-warmed for current hour (5K merchants × 256 contention shards).

---

## Run sequence

```bash
# (Runner is already set up by terraform user-data — no 00_install_prereqs.)

cd /home/ec2-user/ACID/realworldbenchmark   # synced from your Mac
export MONGO_URI='mongodb://...'

./01_init_project.sh    # creates /home/ec2-user/RWB/{src,goharness,results,logs}, writes config.py, verifies RTT
./02_seed.sh            # drops + seeds: 1M cards (rich), 5K merchants (rich), velocity pre-warm; prints sample doc sizes
./03_build_go.sh        # builds perop_bin / clientbulk_bin / srvmon_bin in /home/ec2-user/RWB/goharness

# OPTIONAL — pre-seed the txn_ledger with N historical entries.
# Accepts positional arg (with `m` shortcut) OR TXN_COUNT env var:
./04_seed_ledger.sh 100m         # 100,000,000  (~25–50 min)
./04_seed_ledger.sh 500m         # 500,000,000  (~2–4 h; use tmux/nohup)
./04_seed_ledger.sh 1000000      # explicit count; validate the shape first
# Add UPDATE_DERIVED=1 to also reconcile cards.balance, cardholder_velocity, and merchant_velocity:
UPDATE_DERIVED=1 ./04_seed_ledger.sh 200m

# Then verify the 4 collections are strictly consistent (any point in time, no live txns):
./verify_acid.sh

./run_perop.sh                  # single run (uses SESSIONS/TARGET_TPS/DURATION env vars)
./run_clientbulk.sh             # single run
./run_with_srvmon_go.sh perop   # with server-side monitor

# 3-point sweep + cash check + summary table:
./run_perop_scenarios.sh
./run_clientbulk_scenarios.sh

# Variance study — N runs per variant, side-by-side p99 distribution:
./run_battery.sh                                 # default 5 runs each variant
SESSIONS=3000 TARGET_TPS=5000 DURATION=300 ./run_battery.sh 5
VARIANTS=perop ./run_battery.sh 10               # only one variant

# IOPS / throughput analysis (runs from runner OR Mac):
SESSIONS=3000 TARGET_TPS=5000 IOPS_CAP=16000 ./diag_iostat.sh perop 300

# FTDC diagnostic.data download (Mac-orchestrated → realworldbenchmark/ftdc/<ts>/):
# from your Mac:
../scripts/fetch_ftdc.sh                # primary only
FETCH_ALL=1 ../scripts/fetch_ftdc.sh    # all 3 nodes
```

---

## Tunables

Same env vars as the FSS bench:

| Variable | Meaning | Default |
|---|---|---|
| `SESSIONS` | concurrent users | 3000 |
| `TARGET_TPS` | target txn/sec | 5000 |
| `DURATION` | seconds | 70 |
| `MIN_POOL` / `MAX_POOL` | connection pool floor/ceiling | 500 / 1000 |
| `WARMUP_SEC` | excluded from steady-state percentiles | 10 |
| `BENCH_LEAN_INDEXES` | If `1`, `02_seed.sh` skips production-query secondaries on cards / merchants / ledger | unset |
| `BENCH_DB_NAME` | DB name | `fss_acid_bench` |
| `PROJECT_DIR` | generated tree location | `/home/ec2-user/RWB` |

---

## End-of-run artefacts (scenarios scripts)

Identical structure to FSS — just labelled "RWB" so you don't confuse traces:

1. **Sustained Concurrent Load Summary — RWB ⟨variant⟩** — one row per scenario, latencies + TPS + retries + pass.
2. **Cash state breakdown** — paise + ₹ for loaded / remaining / spent / ledger entries.
3. **ACID Proof table** — `Loaded - Remaining = Ledger total` ? `✓` else `✗`.

---

## Expected differences vs FSS bench

Per-txn:
- **Bytes written** are ~30× higher (mostly the 5 KB ledger insert vs ~150 bytes).
- **Cards update payload** modestly larger ($set now also updates `activity.last_txn_at`).
- **Cluster CPU per txn** higher due to bigger BSON encode/decode.
- **EBS write throughput** scales accordingly: 5K TPS × ~7 KB total per txn ≈ 35 MB/s sustained primary (vs ~3 MB/s for FSS). WT checkpoint dumps will be proportionally bigger.

What this tells you that FSS doesn't:
- Whether the **bandwidth + cache + oplog** combination keeps up under realistic doc sizes.
- Whether the **replica majority commit wait** still stays sub-ms when each commit carries 7 KB of writes instead of 0.4 KB.
- Whether `WithTransaction` retry behavior changes when each retry costs proportionally more bytes.

If the FSS bench passes p99 ≤ 20 ms at 5K TPS but the RWB bench doesn't, the answer
is in the payload — and you'd then evaluate compression (`zstd`), schema slimming
for the hot path, or a smaller ledger insert with cold-storage offload.

---

## Approach for variance & root-cause analysis

At realistic ledger sizes (≥100M docs) and when EBS is near saturated, single-run results
are misleading: p99 can swing 50× across consecutive identical-config runs because of
WT checkpoint timing relative to gp3 burst limits. Use this workflow when a single run
fails p99 ≤ 20 ms:

| Step | Script | Purpose |
|---|---|---|
| 1 | `run_battery.sh 5` | 5 consecutive runs per variant; reports the **distribution** (median p99, stddev, range, pass rate). One bad run is signal noise; the distribution is the truth. |
| 2 | `diag_iostat.sh` | Per-second `iostat` on the primary during a single run. Tells you which gp3 cap (IOPS / throughput / queue) is being hit. |
| 3 | `run_with_srvmon_go.sh` | 5-second windows of opLatencies, writeConflicts, WT write tickets, queue length. Confirms whether the latency is on the cluster side. |
| 4 | `../scripts/fetch_ftdc.sh` | Downloads MongoDB's `diagnostic.data/` from the primary (or all 3 nodes). Per-second metrics for WT cache eviction rate, replication lag, ticket usage, page-faults, slow operations — everything `srvmon` doesn't surface. Best for deep forensics on a captured window. |

### Interpreting `run_battery.sh` output

The script outputs three tables. The critical one is the **side-by-side p99 distribution**:

```
| Variant      | n | min   | median | avg   | max    | stddev | range  | Pass rate |
|--------------|---|-------|--------|-------|--------|--------|--------|-----------|
| per-op       | 5 | 16.07 | 75.83  | 218.12| 773.87 | 320.30 | 757.80 | 2/5 (40%) |
| client-bulk  | 5 | 12.32 | 19.25  | 60.30 | 234.09 | 97.21  | 221.77 | 3/5 (60%) |
```

- **`median p99` and `avg p99`** are the meaningful "typical" numbers. Use these for reporting, not min.
- **`stddev` and `range`** show how variance behaves. A high stddev + frequent FAILs means the hardware is at its limit; bumping IOPS / RAM / changing volume type would help.
- **`Pass rate`** is the honest answer to "does it pass the SLA reliably?" — pass rate of 5/5 is a real PASS; 2/5 with a passing run cherry-picked is misleading.

### When to pull FTDC

After a battery run, if you see one of these patterns:

| Symptom | Likely cause | FTDC metric to check |
|---|---|---|
| `p99` varies wildly across runs but `errors=0` | EBS burst contention | `serverStatus.wiredTiger.cache.{bytes read into cache, modified pages evicted}` per-second rate |
| `retries` elevated and `errors` non-zero | WriteConflict storm | `metrics.operation.writeConflicts` delta per-second |
| Median p99 stable but tail explodes | Replication ack jitter | `replSetGetStatus.members[].optime` lag |
| %util pinned + low IOPS/MB usage | Volume queue depth limit | `wiredTiger.concurrentTransactions.write.out` |

Pull the FTDC files spanning the bench window with `../scripts/fetch_ftdc.sh` and load
them into MongoDB Compass (Performance → diagnostic data) or `keyhole` for inspection.
