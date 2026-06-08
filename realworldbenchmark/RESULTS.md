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

## Scaling study — sustained concurrent load beyond 5K TPS

Same cluster (128 GB nodes, default WT cache, 100M+ ledger) as the headline,
but pushing past 5K TPS with longer runs (300 s instead of 120 s) to expose
the breaking point. One run per cell — not a 5/5 battery — so use these to
locate the wall, not as a final certification.

`./run_perop_scenarios.sh` and `./run_clientbulk_scenarios.sh`

### per-op — passes at 5K, breaks at 6K, melts at 7K

| Users | Target TPS | Duration | Committed | Achieved TPS | p50 | p95 | p99 | p99.9 | Max | Retries | Pass |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 3000 | 5000 | 300 s | 1,449,793 | 4987 | 5.40 | 6.69 | **7.50** | 26.69 | 95.17 | 229 | ✅ |
| 4000 | 6000 | 300 s | 1,740,810 | 5986 | 5.70 | 7.15 | **23.74** | 757.38 | 1466.22 | 870 | ❌ |
| 5000 | 7000 | 300 s | 2,025,535 | 6964 | 6.04 | 37.03 | **637.45** | 1196.15 | 2215.03 | 6038 | ❌ |

Per-op makes **four separate round trips** per transaction (card update,
ledger insert, two velocity upserts). Once primary CPU and the disk path
fill up at ~6K TPS × 4 ops = 24K op/s, checkpoint flushes start colliding
with the steady-state write stream and the tail explodes.

### client-bulk — passes at 5K, 6K, AND 7K TPS

| Users | Target TPS | Duration | Committed | Achieved TPS | p50 | p95 | p99 | p99.9 | Max | Retries | Pass |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 3000 | 5000 | 300 s | 1,449,295 | 4985 | 4.82 | 6.04 | **9.34** | 400.94 | 620.78 | 263 | ✅ |
| 4000 | 6000 | 300 s | 1,741,353 | 5988 | 5.11 | 6.51 | **9.96** | 103.63 | 341.75 | 201 | ✅ |
| 5000 | 7000 | 300 s | 2,030,192 | 6980 | 5.30 | 6.85 | **16.17** | 408.46 | 813.08 | 497 | ✅ |

client-bulk's single-round-trip transaction collapses 4 writes into one
`ClientBulkWrite`, so at 7K TPS the cluster does ~7K commands/s on the
write path instead of ~28K. That's why the same hardware that breaks at
6K per-op cleanly passes 7K client-bulk.

### The client-bulk vs per-op gap

| Target TPS | per-op p99 | client-bulk p99 | Δ (×) |
|---|---|---|---|
| 5000 | 7.50 ms | 9.34 ms | ~1× (similar) |
| 6000 | 23.74 ms | 9.96 ms | **2.4× better with client-bulk** |
| 7000 | 637.45 ms | 16.17 ms | **39× better with client-bulk** |

**Customer takeaway**: at the headline 5K TPS both variants pass cleanly. If
production load is expected to grow beyond 5K, **`ClientBulkWrite` is the
high-leverage code change** — it gets us past 7K on the same hardware. The
per-op variant would need either bigger nodes, io2 storage, or sharding to
reach the same TPS.

---

## Shape C — Zipfian card distribution (heavy-skew upper bound)

> **Status:** stress / upper-bound experiment, NOT a production-realistic
> result. Kept in the repo as evidence; deliberately excluded from the
> customer deck.

Same 128 GB cluster, same 100M+ ledger, same 5K-TPS battery shape — but
instead of drawing cardIds uniformly across the 1M cards, each goroutine
draws from a **Zipfian distribution** with skew parameter `s=1.1` (the
loosest skew Go's `math/rand.NewZipf` supports). 5 runs × 2 variants × 120s.

Build flag (added to `perop` and `clientbulk` binaries on this branch):

```bash
CARD_DIST=zipf ZIPF_S=1.1 SESSIONS=3000 TARGET_TPS=5000 DURATION=120 \
  ./run_battery.sh 5
```

### What `s=1.1` actually means in card-distribution terms

`rand.NewZipf(r, s=1.1, v=1.0, imax=999_999)` produces this concentration
over 1M cards at 5,000 TPS:

| Rank slice | Share of total traffic | Implied TPS on slice |
|---|---|---|
| Top 1 card | **~13.4%** | ~670 TPS on a single document |
| Top 100 cards | ~27 % | ~1370 TPS |
| Top 1000 cards | ~67 % | ~3350 TPS |
| Bottom 999,000 cards | ~33 % | ~1650 TPS combined |

The top card alone is asked to absorb ~670 TPS. Scenario 2 already
measured a single document's serialization ceiling at ~450–485 TPS under
MVCC. So this skew is asking ~50 % more than the document can physically
admit, which manifests as a sustained retry storm.

### Per-op — 0/5 PASS

| Run | TPS | p50 | p95 | p99 | p99.9 | Max | Retry% | Pass |
|---|---|---|---|---|---|---|---|---|
| 1 | 4196 | 5.75 | 266.87 | 1246.39 | 1892.95 | 2481.10 | 136.49 | ❌ |
| 2 | 4110 | 5.61 | 108.82 | 961.82 | 1870.83 | 2012.11 | 102.27 | ❌ |
| 3 | 3863 | 5.59 | 153.24 | 1084.61 | 1880.63 | 2003.78 | 108.28 | ❌ |
| 4 | 3666 | 5.59 | 226.59 | 1104.64 | 1896.47 | 2003.51 | 112.46 | ❌ |
| 5 | 3674 | 5.51 | 81.36 | 934.25 | 1861.70 | 2003.87 | 99.72 | ❌ |

p99 distribution: min 934 / median 1085 / max 1246 / stddev 125 ms.
TPS dropped to 73–84 % of target. Retry rate consistently >100 %
(every commit averaged more than one retry).

### Client-bulk — 0/5 PASS

| Run | TPS | p50 | p95 | p99 | p99.9 | Max | Retry% | Pass |
|---|---|---|---|---|---|---|---|---|
| 1 | 3714 | 4.72 | 17.56 | 87.42 | 775.17 | 2000.64 | 26.48 | ❌ |
| 2 | 3644 | 4.68 | 13.18 | 36.09 | 109.19 | 1115.64 | 19.55 | ❌ |
| 3 | 3532 | 4.70 | 20.82 | 115.75 | 876.22 | 2001.98 | 30.91 | ❌ |
| 4 | 3425 | 4.74 | 78.71 | 740.13 | 1568.28 | 2178.71 | 50.54 | ❌ |
| 5 | 3460 | 4.71 | 31.35 | 297.35 | 1522.97 | 2003.18 | 38.08 | ❌ |

p99 distribution: min 36 / median 116 / max 740 / stddev 288 ms.
TPS 3425–3714 (69–74 % of target). Note: median p99 is lower than per-op
because client-bulk's single-round-trip txns fail-and-retry faster, but
the tail is more variable.

### Why this is *not* production-realistic

Real-world payments card distributions are typically much milder than
Zipf `s=1.1`. Even fraud-heavy environments rarely have ~13 % of all
authorisations concentrated on one card. More realistic models look
like:

- **Mild skew (recommended for production-rep test)**: 80 % of traffic
  uniform across all 1M cards + 20 % concentrated on the top 1000 cards.
  Top card sees ~5–10 TPS, no document is contended.
- **Moderate skew**: top 0.1 % of cards (1000 cards) get 30 % of traffic,
  rest uniform. Still no card approaches the ~450 TPS serialization
  ceiling.

To run a production-realistic Shape C, we'd add a `SKEW_MODE=mixed`
flag with `HOT_FRAC` and `HOT_SET` parameters. Not done yet — this run
was an unintended upper bound. The hypothesis for the mild-skew run:
passes 5K TPS at p99 ≤ 20 ms since no individual card approaches its
ceiling.

### What this DOES prove

Consistent with Scenario 2:

- **Single-document throughput is bounded at ~450–485 TPS** by MongoDB's
  MVCC serialization. Demand above that ceiling forces retries.
- **Cluster-wide TPS drops** when a sustained retry storm consumes primary
  CPU and WiredTiger write tickets. At Zipf `s=1.1`, effective TPS
  drops to ~70–80 % of target.
- **Mitigation pattern is the same as Scenario 2**: app-tier coalescing,
  cardholder_velocity sharding (256-way pattern), or a sharded cluster
  with `{cardId, hash}` shard key for cases where one card genuinely
  must absorb >450 TPS.

---

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
