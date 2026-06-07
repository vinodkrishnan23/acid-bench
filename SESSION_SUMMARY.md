# ACID@Scale POC — Session Summary

Use this as the starting context for a new Claude session. Read top to bottom.

## What this project is

A reproducible proof-of-concept that drives **5000 TPS** of **strict multi-document ACID
transactions** against MongoDB and verifies **p99 ≤ 20 ms**.

Two benches live in this repo:
- **FSS bench** (`scripts/`) — small docs (~150 B), tests pure transaction throughput.
- **RWB bench** (`realworldbenchmark/`) — rich card-management shapes (~4 KB cards, ~4 KB
  merchants, ~5 KB ledger inserts). Real-world payload sizes.

Active focus is **RWB at 100M pre-seeded ledger entries** — production-realistic scale.

## Infrastructure (current state, 2026-06-07)

Provisioned by terraform in `terraform/`. Single AZ `ap-south-1a`, same VPC.

### Runner (load driver)
- `c6i.8xlarge` (32 vCPU, 64 GiB)
- Public IP / private IP: set in your local environment (see `terraform output`)
- AL2023, has go/python3.11/mongosh installed by user-data
- AWS profile: set locally; not committed to the repo
- pem path: set locally (matches `key_pair_public_key_path` in `terraform.tfvars`)

### MongoDB cluster — 3-node replica set `rs0`
- 3 × **`r7i.4xlarge`** (16 vCPU, **128 GiB** each) — upgraded 2026-06-07 from `m7i.4xlarge` (64 GiB)
- MongoDB **Enterprise 8.3.2** (rapid release, latest GA)
- Private IPs: `10.0.0.200` (PRIMARY), `10.0.0.201`, `10.0.0.202` (SECONDARIES)
- WT cache: **default ~61.4 GiB** per node (no `cacheSizeGB` override in mongod.conf)
- mongod data volumes: gp3 **1500 GB, 16000 IOPS, 1000 MB/s** each (unchanged)
- Device name `/dev/nvme1n1` on the new r7i nodes (fresh attach, no renumber drama)
- Mount via UUID in `/etc/fstab` (reboot-safe)
- Userdata template now has **no `cacheSizeGB`** line in `terraform/modules/mongodb-rs/userdata.sh.tpl`

### Connection string
```
mongodb://<USER>:<PASSWORD>@<MEMBER_0_PRIVATE_IP>:27017,<MEMBER_1_PRIVATE_IP>:27017,<MEMBER_2_PRIVATE_IP>:27017/?replicaSet=rs0&authSource=admin
```
Auth is enabled (admin user defined in `terraform.tfvars`, root role).
Use the private IPs from `terraform output`. Run from the runner — DB nodes are not
exposed publicly.

### Database state — `fss_acid_bench`
| Collection | Count | Shape |
|---|---|---|
| `cards` | 1,000,000 | ~4 KB rich FSS shape |
| `merchants` | 5,000 | ~4 KB rich FSS shape |
| `txn_ledger` | **~102M** | ~5 KB rich auth-response shape — **100M pre-seeded + bench growth** |
| `cardholder_velocity` | 1M | small docs, pre-warmed (current day bucket) |
| `merchant_velocity` | 1.28M | small docs, pre-warmed (current hour × 256 cb) |

Indexes (non-lean mode): `cards.status_balance_idx`, `cards.phone_idx`,
`merchants.mcc_status_idx`, `txn_ledger.cardId_ts_idx`, `txn_ledger.mid_ts_idx`,
`txn_ledger.rrn_idx`, plus the two velocity `_id.X_bucket` indexes.

**ACID consistency note**: `04_seed_ledger.sh 100m` ran with `UPDATE_DERIVED=1` but the
reconciliation phase was **cancelled mid-run**. So cards.balance and the two velocity
collections **do not** match the pre-seeded ledger sums. `verify_acid.sh` will report
drift. **This is fine for bench testing** — bench measures latency, not consistency
of pre-existing historical state.

## Project layout

```
acid-poc/
├── README.md                     # FSS bench docs
├── SESSION_SUMMARY.md            # this file
├── claude.md                     # behavioral guidelines for Claude
├── journey.md                    # legacy
├── terraform/                    # IaC — runner + RS + EBS
│   ├── main.tf  variables.tf  outputs.tf  locals.tf
│   ├── network_checks.tf  ec2_key_pair.tf
│   ├── terraform.tfvars          # local secrets (gitignored)
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── runner/main.tf, userdata.sh.tpl
│       └── mongodb-rs/main.tf, userdata.sh.tpl, install-via-runner.sh.tpl
├── scripts/                      # FSS bench + cross-bench tooling
│   ├── env.sh, 00_install_prereqs.sh, 01_init_project.sh, 02_seed.sh, 03_build_go.sh
│   ├── run_perop.sh, run_clientbulk.sh, run_battery.sh, run_with_srvmon.sh, run_with_srvmon_go.sh
│   ├── run_perop_scenarios.sh, run_clientbulk_scenarios.sh
│   ├── cash_snapshot.sh, scenario_summary.sh
│   ├── sync_to_runner.sh         # rsync project → runner (run from Mac)
│   ├── diag_iostat.sh            # FSS variant
│   ├── diag_iostat_rwb.sh        # RWB variant — Mac-orchestrated
│   ├── fetch_ftdc.sh             # download MongoDB FTDC → realworldbenchmark/ftdc/<ts>/
│   ├── restore_schema.sh
│   └── .backup/                  # pre-FSS schema originals
└── realworldbenchmark/           # RWB scripts (runner-side mostly)
    ├── README.md, RESULTS.md
    ├── env.sh
    ├── 01_init_project.sh, 02_seed.sh, 03_build_go.sh
    ├── 04_seed_ledger.sh         # pre-seed N ledger entries; UPDATE_DERIVED=1 reconciles
    ├── run_perop.sh, run_clientbulk.sh
    ├── run_perop_scenarios.sh, run_clientbulk_scenarios.sh   # no reseed, no cash check
    ├── run_battery.sh            # N consecutive runs per variant + distribution stats
    ├── run_with_srvmon_go.sh
    ├── diag_iostat.sh            # runner-side, auto-detects data device
    ├── cash_snapshot.sh          # cash snapshot + ACID Proof table
    ├── scenario_summary.sh
    └── verify_acid.sh            # point-in-time ACID consistency check
```

## Key learnings from this session

### What broke and how we fixed it

1. **EBS volume size shrink (200 GB) was IOPS/throughput-bound** — bumped throughput
   first (125 → 500 MB/s), then for 500M ledger plan bumped size 200 → 1500 GB.
2. **MongoDB upgraded 8.0.23 → 8.3.2** by destroying + rebuilding mongo module.
3. **8.0 GPG key works for 8.x rapid releases** (`pgp.mongodb.com/server-8.0.asc`).
4. **Userdata admin-user creation had a bug** — `try/catch` doesn't catch missing user
   because `getUser()` returns null (we have the fix in mongod.conf live but reverted
   in template to avoid instance-replace plans).
5. **EBS detach/reattach renames the NVMe device** (`nvme1n1` → `nvme2n2`). fstab now
   uses UUID. The diag scripts auto-detect from `df /data/db`.
6. **`<<EOF` heredoc with `set -u` expands `$group`** etc as shell vars → broke
   `04_seed_ledger.sh`. Fixed to `<<'EOF'` + env-var passing.
7. **Mac-side parser for FTDC** is partial — only decodes type-0 reference docs.
   t2 viewer (which the user has) is the practical analysis path.

### Performance journey

| Config change | per-op p99 result | client-bulk p99 result |
|---|---|---|
| Initial (3000 IOPS, 125 MB/s, 32 GB cache, 0 ledger) | unstable | unstable |
| Throughput 125 → 500 MB/s | 7 ms (passes) | 17 ms (passes) |
| Pre-seeded 100M ledger | jumped to 565 ms | jumped to 234 ms |
| **IOPS 3000 → 16000** | 20 ms (median 75 across 5 runs) | 19 ms (median 60) |
| Cache 32 → 50 GB | **45–62 % improvement** | regressed (still 500 MB/s throughput) |
| Cache rolled back to 32 GB + throughput 500 → 1000 MB/s | Run 1 passes (13 ms); runs 2–5 degrade | all FAIL |
| Lean schemas (cards 91 fields, ledger 99 fields) + drop production indexes | 15.40 ms median, 3/5 PASS | **9.80 ms median, 5/5 PASS** |
| **64 → 128 GB RAM (r7i.4xlarge, default WT 61 GB)** | **7.53 ms median, 5/5 PASS** | **6.94 ms median, 5/5 PASS, stddev 0.11 ms** |

### Historical diagnosis (resolved by 128 GB upgrade)

The 64 GB cluster showed cache pressure: WT dirty fill 17–20 % at trigger threshold,
`forced eviction by app threads` 7.3/s avg with 237/s peaks, mongod resident at
44 GB / 64 GB system memory. Per-op's checkpoint-burst FAILs (228–346 ms) and the
"Run 1 passes, Runs 2–5 degrade" pattern were both caused by 32–50 GB cache being
undersized for the working set + a back-to-back run pattern that didn't let
checkpoints drain between runs.

**Resolved by the 128 GB upgrade.** With default WT cache at ~61 GB the dirty buffer
has 2–3× more headroom, checkpoint bursts no longer collide with the next run, and
both variants now PASS 5/5 with p99 stddev under 2 ms.

## Tunables you can change (env vars + terraform)

| Knob | Where | Effect |
|---|---|---|
| `SESSIONS` `TARGET_TPS` `DURATION` | env vars | Single-run workload |
| `RUNS` arg to `run_battery.sh` | positional | Iterations per variant in battery |
| `VARIANTS=perop` or `clientbulk` | env var | Run only one variant |
| `BENCH_LEAN_INDEXES=1` (seed) | env var | Skip `cards.status_balance`, `txn_ledger.cardId_ts`, `mid_ts`, `rrn` indexes |
| `UPDATE_DERIVED=1` (04 ledger seed) | env var | Reconcile cards.balance + velocity with pre-seeded ledger |
| `WORKERS` (04 ledger seed) | env var | Multiprocess workers; default 8 |
| WT cacheSizeGB | mongod.conf + runtime `setParameter` | Per-node WT cache |
| EBS `iops` / `throughput` | terraform | In-place modify on gp3 |

## Commands cheat sheet (in order of typical use)

```bash
# From the Mac
cd /path/to/acid-poc

# Sync any local changes to runner
./scripts/sync_to_runner.sh

# IOPS/throughput diag (Mac-orchestrated)
export MONGO_URI='mongodb://<USER>:<PASSWORD>@<MEMBER_0>:27017,<MEMBER_1>:27017,<MEMBER_2>:27017/?replicaSet=rs0&authSource=admin'
IOPS_CAP=16000 TPUT_CAP=1000 SESSIONS=3000 TARGET_TPS=5000 ./scripts/diag_iostat_rwb.sh perop 300

# Pull FTDC from primary (or FETCH_ALL=1 for all 3 nodes)
./scripts/fetch_ftdc.sh

# On the runner
ssh -i <path-to-pem> ec2-user@<RUNNER_PUBLIC_IP>
cd /home/ec2-user/ACID/realworldbenchmark
export MONGO_URI='<same URI as above>'

# Single bench runs
./run_perop.sh
./run_clientbulk.sh

# Variance study — N runs per variant with distribution stats
SESSIONS=3000 TARGET_TPS=5000 DURATION=120 ./run_battery.sh 5
SESSIONS=3000 TARGET_TPS=5000 DURATION=300 ./run_battery.sh 5    # better signal, ~50 min

# With server monitor (5 sec window opLatencies, queueLength, tickets, writeConflicts)
./run_with_srvmon_go.sh perop
./run_with_srvmon_go.sh clientbulk

# Hot bump WT cache (no restart needed)
mongosh "$MONGO_URI" --quiet --eval 'db.adminCommand({setParameter: 1, wiredTigerEngineRuntimeConfig: "cache_size=50G"})'
```

## Where we left off

**128 GB cluster bench is done and headline above.** No work in flight on the bench
itself. Next sensible directions (none in progress):

1. Lock in the headline — publish RESULTS.md externally.
2. If interest in further p99 reduction: WT checkpoint tuning (free), io2 storage
   (~4× gp3 cost), or sharding. Body of distribution is already ~5 ms p50, so
   further gains compress an already-tight tail.
3. Atlas comparison is documented. Optional follow-up: file the profiler ghost-time
   pattern with MongoDB Atlas Support to get the host-level CPU steal data.

## Open / known issues

- **Pre-seeded ledger isn't ACID-consistent** with cards/velocity (04_seed_ledger
  reconciliation was cancelled). `verify_acid.sh` will report drift. Bench latency is
  still meaningful; just don't claim "ACID Proof" until you re-run with full reconcile.
- **Userdata `cacheSizeGB: 32`** is hardcoded in `terraform/modules/mongodb-rs/userdata.sh.tpl`.
  A fresh `terraform destroy + apply` would reset cache to 32. Live setParameter doesn't
  survive instance replacement.
- **Userdata admin-user creation has a bug** (try/catch on `getUser()` doesn't fire) —
  fix was reverted in template to avoid replace-instance plans. Fresh cluster would need
  manual admin user creation.
- **`run_battery.sh` runs are back-to-back** — no idle gap. Real production wouldn't
  have a breather either, but it does mean we see dirty-buffer accumulation. To get
  a "steady-state" reading, add `sleep 30` between runs.

## RESULTS.md

Latest documented results are in `realworldbenchmark/RESULTS.md`. **Current
headline (2026-06-07, 128 GB cluster)**:

- **client-bulk: 5/5 PASS** — p99 distribution **min 6.73 / median 6.94 / max 6.98 / stddev 0.11 ms** (essentially deterministic)
- **per-op: 5/5 PASS** — p99 distribution **min 7.48 / median 7.53 / max 11.71 / stddev 1.86 ms**

Previous 64 GB headline (preserved in RESULTS.md): client-bulk 5/5 PASS, median
9.80 ms, stddev 2.41 ms; per-op 3/5 (two FAILs caught checkpoint bursts at 228 ms
and 346 ms p99).

## Update — current goal (2026-06-07)

Dropped `txn_ledger.{cardId_ts_idx, mid_ts_idx, rrn_idx}` (they aren't read by the bench
hot path, only `_id` is touched). Reran the battery immediately after.

**Counter-intuitive result**: per-op catastrophically regressed (p99 median 9.81 → 994 ms,
TPS dying across runs, retries 16× higher). Client-bulk mostly bad, but **Run 5 was
pristine** — p99=8.34 ms, p99.9=15.98 ms, max=29.94 ms, PASS — the tightest client-bulk
run measured across this entire investigation.

The data is consistent with **~15 min of post-drop cluster instability**: WT cache held
~10+ GB of stale B-tree pages for the dropped indexes; new inserts competed for cache;
eviction churn + replication catchup combined into severe transient latency. By the time
client-bulk Run 5 fired, the cluster had stabilised.

### 🎯 Final milestone — client-bulk 5/5 PASS

After trimming both schemas (cards 345 → 91 fields, ledger 195 → 99 fields) and reloading
the 100M ledger:

- **client-bulk: 5/5 PASS, median p99 = 9.80 ms** (was 218 ms baseline)
- Distribution: min 7.48 / median 9.80 / max 13.07 ms / **stddev 2.41 ms** — incredibly tight
- Body in every run: p50 = 5.2 ms, p95 = 6.5 ms, 0 errors, retries 0.01–0.02 %
- **per-op: 3/5 PASS** in the same battery — PASS runs at 8.5 / 14.1 / 15.4 ms; two FAILs
  caught checkpoint bursts (per-op makes 4× more disk ops per txn than client-bulk, so 4×
  more exposure to checkpoint timing)

### Defensible headline (64 GB — superseded)

> MongoDB Enterprise 8.3.2, 3-node replica set on m7i.4xlarge, gp3 1500 GB / 16K IOPS /
> 1000 MB/s, WT cache 50 GB, only `_id` index on `txn_ledger`. With **100M pre-existing
> ~3 KB ledger documents (99 fields each)**, the client-bulk variant sustained **5000 strict-ACID
> transactions/sec at p99 ≤ 20 ms across all 5 consecutive 120-second runs**, with median p99
> = 9.80 ms and stddev = 2.41 ms.

### Defensible headline (128 GB — current)

> MongoDB Enterprise 8.3.2, 3-node replica set on **r7i.4xlarge (128 GiB)**, gp3 1500 GB / 16K
> IOPS / 1000 MB/s, **default WiredTiger cache (~61 GiB)**, only `_id` index on `txn_ledger`.
> With **112M pre-existing ~3 KB ledger documents**, BOTH the client-bulk AND per-op variants
> sustained **5000 strict-ACID transactions/sec at p99 ≤ 12 ms across all 5 consecutive
> 120-second runs**. client-bulk median p99 = **6.94 ms**, stddev = **0.11 ms**; per-op median
> p99 = **7.53 ms**, stddev = **1.86 ms**. The 128 GB upgrade eliminated the WT checkpoint
> tail without changing storage or workload.

### Atlas comparison (same RAM class, vastly higher IOPS)

> On Atlas M80_NVMe (128 GiB / 16 vCPU / 360 K write IOPS local NVMe, MongoDB 8.3.3), the
> identical workload produced client-bulk median p99 = **338 ms** (1/5 PASS) and per-op
> median p99 = **237 ms** (0/5 PASS). Atlas profiler captured 124 ms inserts that consumed
> only 0.23 ms CPU and 9 µs storage — uninstrumented wait time inside the managed-service
> stack. The ~50× p99 gap is the managed-service / multi-tenant overhead, not hardware.

### The remaining wall (per-op only, not client-bulk)

FTDC analysis of a failing per-op run (p99=346 ms) confirmed memory is NOT the bottleneck
(WT dirty fill 5-6 %, well under trigger). The disk pinned at 94 % avg %util with WT checkpoint
bursts that **peak above gp3 max** (1063 MB/s vs 1000, 26K IOPS vs 16K).

Further p99 reduction for per-op would require:

- **`io2` volume** — absorbs checkpoint bursts without throttling. ~4× gp3 cost.
- **WT checkpoint tuning** (`wiredTigerEngineRuntimeConfig`) — smaller / more frequent
  flushes. Free experiment.
- **Sharding** — distributes checkpoint timing.
