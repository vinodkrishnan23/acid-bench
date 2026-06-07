# ACID@Scale — MongoDB 5000 TPS Strict-ACID POC

A reproducible proof-of-concept that drives **5000+ transactions/sec** of **strict
multi-document ACID** transactions against MongoDB and verifies **p99 ≤ 20 ms**.

## Headline result (2026-06-07, 100M+ ledger workload)

On a 3-node MongoDB Enterprise 8.3.2 replica set running on `r7i.4xlarge`
(16 vCPU / 128 GiB) with **default WiredTiger cache (~61 GiB)**, gp3 SSD storage
(1500 GB / 16K IOPS / 1000 MB/s), and ~112 million pre-existing ~3 KB ledger
documents:

| Variant | Pass | p99 median | p99 max | p99 stddev |
|---|---|---|---|---|
| client-bulk | **5/5** | **6.94 ms** | 6.98 ms | **0.11 ms** |
| per-op      | **5/5** | **7.53 ms** | 11.71 ms | **1.86 ms** |

Steady-state p50 ≈ 5 ms, p95 ≈ 6 ms, 0 errors, retries 0.01–0.03 %, throughput
~4967 TPS. Full data + journey: [`realworldbenchmark/RESULTS.md`](realworldbenchmark/RESULTS.md).

Each transaction performs four operations, all-or-nothing, inside one
`WithTransaction` (writeConcern `majority`):

1. **`cards`** — atomically check `status == "ACTIVE"` + `balance ≥ amount`, then
   `$inc` balance / version and `$set` lastTxnAt
2. **`txn_ledger`** — `InsertOne` an immutable entry `{cardId, mid, amount, ts}`
3. **`cardholder_velocity`** — `UpdateOne` with upsert; `_id = {cardId, bucket: <day>}`;
   `$inc` count + sum
4. **`merchant_velocity`** — `UpdateOne` with upsert; `_id = {mid, bucket: <hour>, cb: <0..255>}`;
   `$inc` count + sum

Two load generators are provided:
- **per-op** — four separate driver calls per transaction (mirrors typical app code)
- **client-bulk** — MongoDB 8.0 client-level `bulkWrite` collapsing all four writes
  across four collections into a single round trip

---

## 1. Hardware / environment prerequisites

### Two ways to provision

- **Terraform** (recommended for this repo): `terraform/` brings up one runner
  (`c6i.8xlarge`, 32 vCPU / 64 GiB) plus a 3-node MongoDB replica set (`r7i.4xlarge`
  by default — 16 vCPU / 128 GiB each — change `instance_type` in
  `terraform/modules/mongodb-rs/main.tf` if you want a smaller class).
  Storage: **gp3 1500 GiB / 16K IOPS / 1000 MB/s** per node, single AZ, same-VPC.
  User-data on the runner installs Go, Python 3.11+pymongo, mongosh, k6.
- **Bring-your-own EC2 + Atlas / RS**: skip terraform; provision an `c7i.8xlarge`
  load-driver and an M50+ Atlas cluster (or any 8.0 replica set), VPC-peered.

### Load-driver host

| Item | Recommended |
|---|---|
| Instance type | `c6i.8xlarge` or `c7i.8xlarge` — **32 vCPU, ~64 GiB RAM** |
| OS | Amazon Linux 2023 (x86_64) |
| Disk | 30 GiB+ gp3 (the harness writes only small result files) |
| Placement | **Same AWS region as the cluster**, ideally VPC-peered |

The driver is CPU- and connection-bound, not disk-bound. 32 vCPU lets Go schedule
3000 goroutines across real cores.

### Database cluster

| Item | Recommended |
|---|---|
| Tier | **r7i.4xlarge × 3** (self-hosted RS — what this repo's headline is on) or M200+ Atlas |
| Version | **8.0+** (required for the client-bulk variant) |
| Topology | 3-node replica set |
| EBS (if self-hosted) | **gp3 1500 GiB / 16K IOPS / 1000 MB/s** — for the 100M+ ledger workload, throughput is the wall before IOPS |
| Network | **Same region + VPC peering** to the EC2 host |

> **Network co-location is non-negotiable.** Warm round-trip on a peered same-region
> path is ~0.5 ms. Routing over the public internet can add 60 ms+ and makes a
> 20 ms SLA physically impossible regardless of tuning.

---

## 2. One-time software install on the EC2 host

When you use the terraform stack the runner's user-data already installs everything
(`go`, `python3.11+pymongo`, `mongosh`, `xk6+k6`). The ready-marker is
`/var/log/acid-scale-runner-ready.log`. You can skip section 2 in that case.

For a bring-your-own host:

```bash
git clone <your-repo> acid-poc      # or copy the scripts/ folder over
cd acid-poc/scripts
chmod +x *.sh
./00_install_prereqs.sh
```

`00_install_prereqs.sh` installs gcc/make/git, Python 3.11 + pymongo ≥ 4.17,
mongosh, and Go 1.25.x. After it finishes, open a new shell so `go` is on PATH.

> **Iterating from your Mac**: edit the scripts locally and push to the runner
> with `./scripts/sync_to_runner.sh` (rsync; IP auto-resolved from
> `terraform output`). Excludes `terraform/`, `.git/`, anything in `.gitignore`.

---

## 3. Provide the connection string (every session)

The scripts read `MONGO_URI` from the environment — never written to disk.

```bash
read -rsp 'Paste MongoDB SRV URI: ' MONGO_URI && export MONGO_URI
```

Use the **private / peered** SRV string. For the terraform stack, grab it with
`terraform output -raw mongodb_connection_string`.

---

## 4. Schema (what the seed creates on the cluster)

Database: **`fss_bench`**. Four collections; all FSS-flavored, all paise-typed
(1 paise = ₹0.01).

### `cards` — 1,000,000 docs

```js
{
  _id: "CARD-0000000001",       // string, "CARD-" + 10-digit
  status: "ACTIVE",
  balance: 50000000,            // int paise; seeded random in [35M, 60M]
  version: 0,                   // optimistic-lock counter, $inc per txn
  limits: { perTxn: 50000, dayPos: 500000 },
  scheme: "VISA" | "MASTERCARD" | "RUPAY",
  issuedAt: ISODate(...),
  lastTxnAt: null               // $set per txn
}
```

### `txn_ledger` — empty at seed; grows during runs

```js
{ _id: ObjectId(...), cardId: "CARD-…", mid: "M…", amount: 4250, ts: ISODate(...) }
```

### `merchant_velocity` — pre-warmed 5K × 256 docs for current hour

```js
{ _id: { mid: "M0000001", bucket: "2026060619", cb: 47 },
  count: 0, sum: 0, updatedAt: ISODate(...) }
```

`cb` (0..255) shards write contention across docs so hot merchants don't serialise
on a single doc. The hour bucket gives time-windowed velocity for free.

### `cardholder_velocity` — pre-warmed 1M docs for current day

```js
{ _id: { cardId: "CARD-…", bucket: "20260606" },
  count: 0, sum: 0, updatedAt: ISODate(...) }
```

No `cb` shard — cardholders don't experience hot-doc contention.

### Indexes

| Collection | Index | Created by | Used by hot path? |
|---|---|---|---|
| all | `_id` (auto) | system | **yes** (PK lookups for all 4 ops) |
| `cards` | `{status:1, balance:-1}` *(named `status_balance_idx`)* | seed (skipped under lean mode) | no — production-query only |
| `txn_ledger` | `{cardId:1, ts:-1}` | seed (skipped under lean mode) | no — production-query only |
| `txn_ledger` | `{mid:1, ts:-1}` | seed (skipped under lean mode) | no — production-query only |
| `merchant_velocity` | `{_id.mid:1, _id.bucket:-1}` | seed | no for upsert; **yes** for velocity reads |
| `cardholder_velocity` | `{_id.cardId:1, _id.bucket:-1}` | seed | no for upsert; **yes** for velocity reads |

`BENCH_LEAN_INDEXES=1 ./02_seed.sh` skips the 3 production-only secondaries —
saves ~15K extra index writes/sec at 5K TPS, useful when isolating bench cost.

---

## 5. Script catalog — when to use what

### One-time setup (per fresh environment)

| Script | Purpose | Skip when |
|---|---|---|
| `00_install_prereqs.sh` | Installs gcc/make/git, Python 3.11 + pymongo, mongosh, Go 1.25.x | Terraform user-data already did this |
| `01_init_project.sh` | Creates `$PROJECT_DIR` (`/home/ec2-user/ACID/{src,goharness,results,logs}`), writes `config.py`, verifies `MONGO_URI` + prints warm RTT | First-time only |
| `02_seed.sh` | Drops + seeds 4 collections (1M cards + 1.28M merchant_velocity + 1M cardholder_velocity), creates indexes | First-time + whenever you want clean data |
| `03_build_go.sh` | Generates Go sources for `perop`, `clientbulk`, `srvmon`; compiles all three binaries | First-time + whenever you change schema/Go code |

### Routine benchmark runs

| Script | What it does | Knobs |
|---|---|---|
| `run_perop.sh` | One per-op run | `SESSIONS`, `TARGET_TPS`, `DURATION` env vars |
| `run_clientbulk.sh` | One client-bulk run | same |
| `run_battery.sh perop` / `clientbulk` | N back-to-back runs **of the same params** — confirms p99 isn't a fluke | `RUNS=5` (default) + env vars above |

### Scenario sweeps (seed + 3 load points, fixed)

| Script | Sequence | End-of-run artefacts |
|---|---|---|
| `run_perop_scenarios.sh` | reseed → 3000/5000/300s → 4000/6000/300s → 5000/7000/300s (per-op) | Sustained-Concurrent-Load table + Cash state + ACID Proof table |
| `run_clientbulk_scenarios.sh` | same 3 load points (client-bulk) | same |

These hardcode their parameters — `SESSIONS`/`TARGET_TPS`/`DURATION` env vars are
**ignored**. See §7 for the exact format of the three end-of-run tables.

Both call two internal helpers automatically:

- `cash_snapshot.sh` — sums `cards.balance` before + after, sums `txn_ledger.amount`,
  prints the conservation breakdown and ACID Proof table.
- `scenario_summary.sh` — parses per-scenario logs and prints the consolidated
  Sustained Concurrent Load table.

### Diagnostics & tail-latency forensics

| Script | What it adds | Run from |
|---|---|---|
| `run_with_srvmon.sh perop` / `clientbulk` | Original Python monitor: avg writes/cmd latency every 5s | runner |
| `run_with_srvmon_go.sh perop` / `clientbulk` | **Newer Go monitor**: writes/cmd avg + `wc/s` (writeConflicts/sec) + WT write tickets + queue length | runner |
| `diag_iostat.sh perop \| clientbulk [seconds]` | Coordinates `iostat -xt 1` on the **primary** alongside a bench. Reveals EBS-layer queuing not visible to MongoDB. | **your Mac** (uses `terraform output` + jump SSH) |
| `cash_snapshot.sh seed \| final` | Sum `cards.balance` + sum `txn_ledger.amount`, conservation check. Called automatically by the scenarios scripts. | runner |

### Operations / safety nets

| Script | Purpose |
|---|---|
| `sync_to_runner.sh` | rsync project (minus `terraform/`, `.git/`, `.gitignore` entries) to the runner. Run from your Mac. |
| `restore_schema.sh` | Reverts `01_init_project.sh`, `02_seed.sh`, `03_build_go.sh` to pre-FSS state from `scripts/.backup/`. Rebuild on the runner after. |

### Recommended order on a fresh runner

```bash
# (already done by terraform user-data) ./00_install_prereqs.sh

./01_init_project.sh
./02_seed.sh                            # or: BENCH_LEAN_INDEXES=1 ./02_seed.sh
./03_build_go.sh

# baseline single runs
./run_perop.sh
./run_clientbulk.sh

# repeatability
./run_battery.sh clientbulk

# 3-point sweep with reseed + conservation check
./run_perop_scenarios.sh
./run_clientbulk_scenarios.sh

# diagnose tail latency (if p99 fails)
./run_with_srvmon_go.sh perop
# and from your Mac:  ./scripts/diag_iostat.sh perop 60
```

---

## 6. Customizing workload parameters

`run_*.sh` (single runs) accept the three knobs as env vars; `run_*_scenarios.sh`
ignore them (params are hardcoded). Defaults: `SESSIONS=3000 TARGET_TPS=5000 DURATION=70`.

| Variable | Meaning | Default |
|---|---|---|
| `SESSIONS` | concurrent closed-loop sessions | 3000 |
| `TARGET_TPS` | aggregate target transactions/sec | 5000 |
| `DURATION` | run length in seconds | 70 |
| `WARMUP_SEC` | seconds excluded from steady-state percentiles | 10 |
| `MIN_POOL` / `MAX_POOL` | connection pool floor/ceiling | 500 / 1000 |
| `PYBIN` | python interpreter with pymongo | python3.11 |
| `PROJECT_DIR` | where generated tree lives | `/home/ec2-user/ACID` |
| `BENCH_LEAN_INDEXES` | If `1`, `02_seed.sh` skips 3 unused-by-bench secondaries | unset (= create all) |
| `BENCH_DB_NAME` | DB name (used by `cash_snapshot.sh`) | `fss_bench` |

Examples:

```bash
# heavier custom run
SESSIONS=4000 TARGET_TPS=6000 DURATION=120 ./run_clientbulk.sh

# lean indexes (fewer write amplifications during bench)
BENCH_LEAN_INDEXES=1 ./02_seed.sh

# 10-run battery at custom load
RUNS=10 SESSIONS=2000 TARGET_TPS=4000 DURATION=90 ./run_battery.sh clientbulk
```

> **Why a warmup window?** Bringing thousands of sessions online creates a one-time
> ramp burst. Steady-state percentiles (excluding the first `WARMUP_SEC`) reflect
> sustained behavior.
>
> **Pool sizing.** Defaults suit ~3000 sessions at ~5000 TPS, where only a few
> hundred connections are concurrently in use. Raise `MAX_POOL` if you raise SESSIONS.

---

## 7. Reading the output

Each run prints, for the measured (post-warmup) window:

```
GO PER-OP STEADY-STATE (300.7s total, 290.7s measured)
  committed (post-warmup): 1449983  windowed TPS: 4988  errors: 0
  retries: 308  (0.02% of committed)
  median 5.07  p95 6.41  p99 6.90  p99.9 111.48  max 404.08
  PASS (p99<=20ms)? true
```

- **windowed TPS** — sustained rate over the measured window (excludes warmup).
- **p99** — the SLA metric; must be ≤ 20 ms to pass.
- **retries** — count of `WithTransaction` callback re-invocations across all
  sessions. Each retry costs ~10–30 ms; >1 % typically explains a fat tail.
- **errors** — failed/aborted txns (insufficient-funds is tracked separately,
  not counted).

`run_with_srvmon_go.sh` additionally prints, every 5 s:

```
  t+5s  write_avg=0.18ms  cmd_avg=1.40ms  wc/s=0  w_tickets=2/13  queued=0
```

- `wc/s` — server-side `metrics.operation.writeConflicts` delta. Confirms or
  refutes the retry hypothesis from the client side.
- `w_tickets=out/total` — MongoDB 8.0 dynamic execution-control ticket pool.
- `queued` — `normalPriority.queueLength`. **Any non-zero sustained** = the
  server has internal write contention.

If client p99 is high but `wc/s`, `retries`, and `queued` are all near zero,
the latency is **below** MongoDB — network jitter, replication ack jitter, or
EBS. That's when you reach for `diag_iostat.sh` (see below).

After the scenarios scripts, you get **three additional artefacts** at the bottom:

#### 1. Sustained Concurrent Load Summary

A one-row-per-scenario table for fast comparison across load points. "Users" =
concurrent closed-loop users hitting the cluster simultaneously, not sequentially.

```
=== Sustained Concurrent Load Summary — per-op ===
  Users column = users transacting concurrently against the cluster
  (closed-loop goroutines, one dedicated MongoDB session per user).
| Users    | TargetTPS | Duration | Committed   | TPS     | p50    | p95    | p99    | p99.9  | Max    | Retries | Pass  |
|----------|-----------|----------|-------------|---------|--------|--------|--------|--------|--------|---------|-------|
| 3000     | 5000      | 300s     | 1449983     | 4988    | 5.07   | 6.41   | 6.90   | 111.48 | 404.08 | 308     | true  |
| 4000     | 6000      | 300s     | 1739000     | 5985    | 5.20   | 7.10   | 8.50   | 95.00  | 312.00 | 412     | true  |
| 5000     | 7000      | 300s     | 2090000     | 6979    | 5.45   | 8.20   | 11.30  | 85.00  | 280.00 | 510     | true  |
```

#### 2. Cash state breakdown (vertical, in paise + INR)

```
=== Cash state after all scenarios ===
  loaded         : 47,500,000,000,000 paise  (₹475,000,000,000.00)
  remaining      : 47,499,996,250,000 paise  (₹474,999,962,500.00)
  spent          :          3,750,000 paise  (₹37,500.00)
  ledger entries : 750,000
  ✓ CONSERVATION: loaded - remaining = spent  (3,750,000 paise)
```

#### 3. ACID Proof table

```
=== ACID Proof (all values in paise) ===
| Loaded (before)        | Remaining (after)      | Ledger total           | Loaded - Remaining     | ACID  |
|------------------------|------------------------|------------------------|------------------------|-------|
| 47,500,000,000,000     | 47,499,996,250,000     | 3,750,000              | 3,750,000              | ✓     |

  Loaded - Remaining MUST equal Ledger total for the workload to be strictly ACID.
```

The conservation line + ACID Proof row are the actual ACID check: every paise that
left a card must exist in the ledger. A `✗` in the ACID column indicates a lost or
duplicated write — i.e. the strict-ACID claim doesn't hold. Under WC=majority +
`WithTransaction`, you should always see `✓`.

---

## 8. Diagnosing tail latency — a workflow

When p99 fails, work down this ladder. Each step is cheap and rules in/out one suspect.

1. **`run_battery.sh perop`** — is the failure repeatable? If 2/5 runs pass at the
   same params, you're hitting hypervisor/network jitter, not a systemic issue.
2. **`run_with_srvmon_go.sh perop`** — read `retries:` and `wc/s`.
   - Both > 1 % → contention in the transaction layer. Bump `MERCH_BUCKETS`
     (config.py) higher or split the hot path.
   - Both near 0 → cluster is innocent of contention; latency is below.
3. **`diag_iostat.sh perop 60`** — run from your Mac. Look at:
   - `%util` near 100 % sustained, `wMB/s` ≈ baseline → throughput cap.
   - `w/s` ≈ baseline IOPS → IOPS cap.
   - `%util` < 50 % despite tail → not disk; suspect replication ack.
4. If steps 1–3 acquit the cluster, look at **replication**: secondary apply lag,
   network jitter on the RS network, oplog window — out of scope for this README.

> **Concrete example from this POC**: at one point p99 was 34 ms with retries=0.02 %
> and `wc/s`=0. `diag_iostat.sh` showed WiredTiger checkpoints briefly pushing
> 232 MB/s on a volume capped at 125 MB/s. Bumping gp3 throughput to 500 MB/s
> dropped p99 to 6.9 ms. EBS was the wall, invisible to MongoDB's internal metrics.

---

## 9. Files and directory layout

### (a) The delivered package

```
acid-poc/
├── README.md
├── claude.md
├── terraform/                       # IaC for runner + 3-node mongo RS (optional path)
└── scripts/
    ├── env.sh                       # shared config — tunable defaults
    ├── 00_install_prereqs.sh
    ├── 01_init_project.sh
    ├── 02_seed.sh
    ├── 03_build_go.sh
    ├── cash_snapshot.sh             # called by scenarios scripts; prints balances + ACID Proof table
    ├── scenario_summary.sh          # called by scenarios scripts; prints the consolidated Sustained Concurrent Load table
    ├── restore_schema.sh            # reverts to pre-FSS schema from .backup/
    ├── run_perop.sh
    ├── run_clientbulk.sh
    ├── run_battery.sh
    ├── run_with_srvmon.sh           # original Python monitor
    ├── run_with_srvmon_go.sh        # newer Go monitor (writeConflicts + tickets)
    ├── run_perop_scenarios.sh       # reseed + 3-point sweep (per-op) + cash check
    ├── run_clientbulk_scenarios.sh  # reseed + 3-point sweep (client-bulk) + cash check
    ├── diag_iostat.sh               # run from your Mac; iostat on primary + bench
    ├── sync_to_runner.sh            # run from your Mac; rsync project → runner
    └── .backup/                     # pre-FSS originals (restored by restore_schema.sh)
```

### (b) The generated tree (`$PROJECT_DIR`, default `/home/ec2-user/ACID`)

```
$PROJECT_DIR/
├── src/
│   ├── config.py     # written by 01_init_project.sh
│   ├── seed.py       # written by 02_seed.sh
│   └── srvmon.py     # written by run_with_srvmon.sh
├── goharness/
│   ├── perop/main.go        + perop_bin        # written/built by 03_build_go.sh
│   ├── clientbulk/main.go   + clientbulk_bin   # written/built by 03_build_go.sh
│   ├── srvmon/main.go       + srvmon_bin       # written/built by 03_build_go.sh
│   └── go.mod / go.sum
└── results/          # server-monitor logs
```

`$PROJECT_DIR` is intentionally separate from the delivered package so generated
artifacts never collide with the scripts. Override with
`PROJECT_DIR=/data/acid ./01_init_project.sh`.

---

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ModuleNotFoundError: pymongo` | Wrong interpreter — use `python3.11` (set `PYBIN`). |
| Warm RTT is tens of ms | Not on the peered path. Use the **private** SRV string; confirm VPC peering + IP access list. |
| `go: command not found` | Open a new shell or `source ~/.bashrc` after install. |
| `clientbulk` errors on `BulkWrite` | Cluster is not 8.0+; needs MongoDB 8.0 for client-level bulkWrite. Use `perop` instead. |
| Atlas / RS shows fewer connections than `MIN_POOL` | Expected — the pool only grows to real demand (~hundreds at 5000 TPS); `MIN_POOL` is a floor. |
| p99 fails on the full (non-windowed) run but passes steady-state | Startup ramp dominates a short run; raise `DURATION`. |
| **p99 high, `retries` & `wc/s` near 0, `queued`=0** | EBS throughput cap. Confirm with `diag_iostat.sh`; bump gp3 `throughput` (in terraform). |
| **p99 high with `retries` > 1 %** | Transaction-layer contention. Bump `merchBuckets`, or split the hot doc. |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` on SSH to mongo-N | Previous instance with same private IP got replaced. Clean with `ssh-keygen -R <ip>`. |
| Seed runs forever on `01_init_project.sh` connectivity check | `MONGO_URI` not exported, or SRV-record DNS not resolving from the host. |
| Apply hangs on `RunInstances` for minutes | Possible AZ capacity issue. Switch instance family (e.g., `m7i.4xlarge` → `m6i.4xlarge`). |

---

## 11. What this POC demonstrates

- MongoDB sustains **5000 strict-ACID TPS at p99 ≤ 20 ms** in steady state with
  the FSS-shaped schema (4 collections, time-bucketed velocity, 256-shard
  contention spread on hot merchants).
- The **client-bulk** variant collapses 4 round trips into 1 — tail latency
  becomes essentially driver-side variance.
- The **per-op** variant (no code rewrite) passes at the same SLA in steady state.
- Throughout, server-side `write_avg` stays sub-millisecond and MongoDB's
  internal write queue (`queues.execution.write.normalPriority.queueLength`)
  stays at 0 — the cluster has large headroom.
- **The infrastructure can shadow the database.** On gp3 storage,
  WiredTiger checkpoint dumps briefly exceed steady-state throughput by 5×.
  If the provisioned EBS throughput is below the burst, writes queue inside
  EBS — invisible to MongoDB but visible as a fat client p99 tail. Provisioning
  for the *peak*, not the average, is essential.
- The **conservation check** (`cash_snapshot.sh`) ensures the bench's strict-ACID
  claim isn't aspirational: every paise leaving a card lands in the ledger.
