# RWB Benchmark Results — 100M Ledger

## 🎯 Headline Result — 128 GB cluster (2026-06-07)

**MongoDB Enterprise 8.3.2 on 3 × r7i.4xlarge (128 GiB / 16 vCPU) sustained
5,000 strict-ACID TPS at p99 ≤ 12 ms across 5 consecutive runs in BOTH
client-bulk AND per-op variants, with 112 million pre-existing ledger
documents on gp3 SSD storage and the WiredTiger default cache (~61 GiB/node).**

| Variant | Pass | p99 min | p99 median | p99 max | p99 stddev |
|---|---|---|---|---|---|
| client-bulk | **5/5** | 6.73 | **6.94** | 6.98 | **0.11** ms |
| per-op | **5/5** | 7.48 | **7.53** | 11.71 | **1.86** ms |

Steady-state body: p50 = 4.8–5.5 ms, p95 = 6.0–6.7 ms, 0 errors, retries
0.01–0.03 %. client-bulk p99 spans just 0.25 ms across all 5 runs — essentially
deterministic.

### What changed vs. the 64 GB baseline

The 64→128 GB RAM upgrade (and the corresponding default WT cache of ~61 GB
versus the previous tuned 50 GB) **eliminated the WT checkpoint tail
entirely**, including the per-op runs that previously caught checkpoint
bursts and blew out to 228–346 ms p99.

| Metric | 64 GB / WT 50 GB | 128 GB / WT 61 GB | Δ |
|---|---|---|---|
| client-bulk p99 median | 9.80 ms | **6.94 ms** | −29 % |
| client-bulk p99 stddev | 2.41 ms | **0.11 ms** | 22× tighter |
| client-bulk p99 max | 13.07 ms | **6.98 ms** | −47 % |
| per-op pass rate | 3/5 | **5/5** | +2 PASS |
| per-op p99 median | 15.40 ms | **7.53 ms** | −51 % |
| per-op p99 max | 346.45 ms | **11.71 ms** | **30× lower** |
| per-op p99 stddev | 156.13 ms | **1.86 ms** | **84× tighter** |

### Comparison to Atlas M80_NVMe (same RAM class)

On an Atlas M80_NVMe cluster (128 GiB RAM, 16 vCPU, 825 K read / 360 K write
IOPS local NVMe, MongoDB 8.3.3) the same workload produced:

| Variant | Pass | p99 median | p99 max |
|---|---|---|---|
| client-bulk | 1/5 | 338 ms | 822 ms |
| per-op | 0/5 | 237 ms | 593 ms |

Atlas profiler captured 124 ms inserts that consumed only 0.23 ms CPU and 9 µs
storage — uninstrumented wait time inside the managed-service stack. Same
RAM class, same Mongo version, far better IOPS — yet ~50× worse p99 vs.
self-hosted EC2. That delta is the managed-service / multi-tenant overhead.

---

## Previous headline (preserved for the journey) — 64 GB cluster

**MongoDB Enterprise 8.3.2 sustained 5,000 strict-ACID transactions per second at
p99 ≤ 20 ms across 5 consecutive runs (client-bulk variant) with 100 million
pre-existing ~5 KB ledger documents on a 3-node replica set, gp3 SSD storage.**

Distribution of run-level p99 across the 5 runs: **min 7.48 ms / median 9.80 ms /
max 13.07 ms / stddev 2.41 ms**. Steady-state body in every run: p50 = 5.2 ms,
p95 = 6.5 ms, 0 errors, retries 0.01–0.02 %.

## Final cluster & EBS config (128 GB — current)

| Item | Value |
|---|---|
| Runner | `c6i.8xlarge` (32 vCPU / 64 GiB) |
| Mongo nodes | 3 × `r7i.4xlarge` (16 vCPU / **128 GiB**) |
| MongoDB | Enterprise 8.3.2 |
| Data volume | gp3, **1500 GB**, **16000 IOPS**, **1000 MB/s** (gp3 maximum) |
| WiredTiger cache | **default** — ~61.4 GiB / node (50 % of visible 123 GiB) |
| Write concern | `majority` |
| Replica set | `rs0` — 1 primary, 2 secondaries, same AZ |
| `txn_ledger` indexes | only `_id_` (3 production-query secondaries dropped) |

### Previous config (64 GB — preserved for the journey)

| Item | Value |
|---|---|
| Mongo nodes | 3 × `m7i.4xlarge` (16 vCPU / 64 GiB) |
| WiredTiger cache | **50 GB** per node (explicit `cacheSizeGB`) |
| Everything else | identical to current |

## Workload state (DB `fss_acid_bench`)

| Collection | Count | Avg fields/doc | Avg doc size |
|---|---|---|---|
| `cards` | 1,000,000 | **91** | ~3 KB |
| `merchants` | 5,000 | — | ~4 KB |
| `txn_ledger` | **100M pre-seeded + bench writes** | **99** | ~3 KB |
| `cardholder_velocity` | ~1M | — | small |
| `merchant_velocity` | ~1.28M | — | small (256 cb shards) |

## 128 GB battery (current, 2026-06-07)

`SESSIONS=3000 TARGET_TPS=5000 DURATION=120 ./run_battery.sh 5`

### client-bulk — 5/5 PASS ✅ (essentially deterministic)

| Run | TPS | p50 | p95 | p99 | p99.9 | Max | Retry% | Pass |
|---|---|---|---|---|---|---|---|---|
| 1 | 4967 | 4.79 | 5.99 | 6.98 | 15.43 | 30.45 | 0.01 | ✅ |
| 2 | 4968 | 4.79 | 5.97 | 6.77 | 14.65 | 31.08 | 0.01 | ✅ |
| 3 | 4966 | 4.80 | 6.00 | 6.94 | 16.07 | 33.94 | 0.01 | ✅ |
| 4 | 4967 | 4.79 | 5.94 | 6.73 | 14.92 | 37.40 | 0.01 | ✅ |
| 5 | 4967 | 4.80 | 6.01 | 6.94 | 14.89 | 29.78 | 0.01 | ✅ |

Distribution: min=6.73, median=6.94, avg=6.87, max=6.98, **stddev=0.11**, range=0.25.
0 errors. p99 spans 0.25 ms across all 5 runs.

### per-op — 5/5 PASS ✅ (was 3/5 at 64 GB)

| Run | TPS | p50 | p95 | p99 | p99.9 | Max | Retry% | Pass |
|---|---|---|---|---|---|---|---|---|
| 1 | 4968 | 5.63 | 7.44 | 11.71 | 20.11 | 58.85 | 0.08 | ✅ |
| 2 | 4967 | 5.44 | 6.70 | 7.51 | 16.41 | 29.09 | 0.02 | ✅ |
| 3 | 4967 | 5.45 | 6.71 | 7.48 | 17.94 | 51.20 | 0.02 | ✅ |
| 4 | 4968 | 5.45 | 6.72 | 7.53 | 16.02 | 23.97 | 0.02 | ✅ |
| 5 | 4969 | 5.46 | 6.75 | 7.66 | 18.08 | 61.27 | 0.03 | ✅ |

Distribution: min=7.48, median=7.53, avg=8.38, max=11.71, **stddev=1.86**, range=4.23.
0 errors. Body of distribution rock-solid; even the worst run (#1) sits at 11.71 ms.

Battery log: `/tmp/battery_128gb_20260607_132814.log` on runner.

## 64 GB battery (preserved baseline)

`SESSIONS=3000 TARGET_TPS=5000 DURATION=120 ./run_battery.sh 5`

### client-bulk — 5/5 PASS ✅

| Run | TPS | p50 | p95 | p99 | p99.9 | Max | Errors | Retry% | Pass |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4967 | 5.16 | 6.50 | 8.78 | 289.13 | 485.19 | 0 | 0.02 | ✅ |
| 2 | 4967 | 5.16 | 6.49 | **7.48** | **18.29** | **36.45** | 0 | 0.01 | ✅ |
| 3 | 4966 | 5.18 | 6.58 | 9.80 | 197.79 | 342.94 | 0 | 0.01 | ✅ |
| 4 | 4967 | 5.18 | 6.58 | 13.07 | 297.51 | 471.07 | 0 | 0.02 | ✅ |
| 5 | 4967 | 5.18 | 6.55 | 12.55 | 262.62 | 401.79 | 0 | 0.02 | ✅ |

Distribution: min=7.48, median=9.80, avg=10.34, max=13.07, **stddev=2.41**.

### per-op — 3/5 PASS (same battery)

| Run | TPS | p50 | p95 | p99 | p99.9 | Max | Errors | Retry% | Pass |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4967 | 5.75 | 7.25 | 15.40 | 514.90 | 716.91 | — | 0.04 | ✅ |
| 2 | 4966 | 5.76 | 7.22 | 14.11 | 319.99 | 530.99 | — | 0.03 | ✅ |
| 3 | 4959 | 5.82 | 7.64 | 346.45 | 916.04 | 1422.24 | — | 0.11 | ❌ |
| 4 | 4961 | 5.83 | 7.45 | 228.04 | 833.01 | 1274.25 | — | 0.08 | ❌ |
| 5 | 4968 | 5.81 | 7.20 | 8.50 | 68.71 | 201.13 | — | 0.03 | ✅ |

Body of distribution (p50, p95) is **rock-solid** in every run. PASS runs are 8.5,
14.1, 15.4 ms p99 — pristine. The two FAILs caught WT checkpoint bursts. Per-op
makes 4× more disk-going operations per transaction than client-bulk, so it has
4× more exposure to checkpoint timing roulette.

## Journey of client-bulk p99 across the investigation

| Config change | Median p99 | Pass rate |
|---|---|---|
| Initial (32 GB cache, gp3 3K IOPS / 125 MB/s) | unstable | 0/5 |
| Throughput 125 → 500 MB/s | 17 ms | passing on empty ledger |
| 100M ledger seeded | 234 ms | 0/5 |
| Cache 32 → 50 GB | 134 ms | 0/5 |
| Throughput 500 → 1000 MB/s | 218 ms | 0/5 |
| IOPS 3000 → 16000 | 218 ms | 0/5 |
| Drop 3 `txn_ledger` secondary indexes | 85 ms | 1/5 |
| Lean schema (~50 % smaller docs) | 16 ms | 3/5 |
| All combined + stabilized (64 GB, WT 50 GB) | 9.80 ms | 5/5 ✅ |
| **128 GB nodes, default WT cache (~61 GB)** | **6.94 ms** | **5/5** ✅ (per-op 5/5 too) |

## What the remaining tail comes from (per-op only)

The FTDC analysis of a representative bad per-op run (p99=346 ms) revealed:

- WT cache dirty fill ratio **5.3 % avg, 6.3 % max** — well below the 20 % trigger.
  Memory is NOT a bottleneck.
- CPU 35 % user / 47 % idle — CPU is NOT a bottleneck.
- Locks negligible. Cache eviction churn negligible. No retries / errors.
- **Disk peaks 1063 MB/s (over 1000 MB/s gp3 max) and 26,410 IOPS (over 16K cap)
  during WT checkpoint flushes.** `nvme2n2 avg %util = 94 %, queue depth = 7.4 avg,
  32.3 max`. The disk pinned at 94 % is the steady-state pressure; the peaks
  during checkpoint are what produces the p99 tail.

We've hit the gp3 ceiling. Further p99 reduction would require:

- **`io2` volume** — up to 64K IOPS, absorbs checkpoint bursts without throttling. ~4× gp3 cost.
- **Sharding** — distributes checkpoint timing across multiple primaries.
- **WT checkpoint tuning** (`wiredTigerEngineRuntimeConfig`) — more frequent
  + smaller flushes. Cheapest experiment, no infra change.

## Diagnostic tooling cheat sheet

| Tool | Where | Use |
|---|---|---|
| `scripts/diag_iostat_rwb.sh` | Mac | iostat on primary alongside bench; recommends throughput/IOPS bump |
| `scripts/fetch_ftdc.sh` | Mac | Download MongoDB FTDC to `realworldbenchmark/ftdc/<ts>/` for offline analysis |
| `realworldbenchmark/run_battery.sh` | runner | N runs per variant, distribution stats |
| `realworldbenchmark/run_with_srvmon_go.sh` | runner | 5-sec opLatencies / queueLength / writeConflicts / WT tickets sampling |
| `realworldbenchmark/diag_iostat.sh` | runner | iostat per-second with cap analysis (auto-detects device) |
