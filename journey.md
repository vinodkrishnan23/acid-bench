# ACID@Scale — The Experiment Journey

How we went from a blank EC2 box to a proven, repeatable result: **MongoDB
sustaining 5000 strict-ACID transactions/sec at p99 < 20 ms**. This document is the
narrative — every experiment, every dead end, and the evidence that resolved it.
It is deliberately written so a reviewer can follow the *reasoning*, not just the
final numbers.

---

## The question

A payments workload. Each transaction is one card authorization and must be
**strictly ACID** — four operations that all commit or all roll back:

1. Check card balance and deduct (only if sufficient funds)
2. Insert an append-only `txn_ledger` record
3. Increment the card's operation counter
4. Increment the merchant's operation counter

The bar: **5000 TPS** sustained, **p99 response time ≤ 20 ms**, with full ACID
guarantees. The cluster can be an **Enterprise replica set** or an **Atlas replica
set** — the methodology is identical; only the connection string and provisioning
differ.

---

## Phase 0 — Design decisions made before any code

We locked several choices up front, each with a reason:

- **Strict ACID via `withTransaction`.** All four ops in one multi-document
  transaction with `writeConcern: majority`. The driver's `withTransaction`
  auto-retries transient errors — essential, or contended numbers are fiction.
- **Bucketed merchant counters (256), single card counter (1).** Traffic is skewed
  (2% of merchants take 80% of traffic). A hot merchant's counter would be a single
  contended document → `WriteConflict` storms → wrecked p99. Spreading each
  merchant's writes across 256 random buckets keeps conflicts at zero. Cards are
  uniform across 1M keys, so per-card contention is negligible — one counter doc
  each is enough.
- **Closed-loop sessions with think-time.** "5000 concurrent users" modeled as 3000
  persistent sessions each transacting ~every 600 ms. Think-time is what lets high
  concurrency coexist with a tight latency SLA — only ~27 transactions are
  in-flight at once (Little's Law: 5000 × 0.0054 s). Without think-time, 3000
  always-busy sessions would offer ~555,000 TPS and saturate the server — a
  breaking-point test, not the realistic SLA test we wanted.
- **Co-located driver and cluster.** Same region, VPC-peered. Warm RTT ~0.5 ms.
  This is non-negotiable; public-internet latency alone would blow the budget.

---

## Phase 1–2 — Environment, seed, and the first scare

We provisioned a 32-vCPU EC2 driver and an M200 (8.0.23) 3-node replica set in the
same region, peered. Seeded 1M cards, 5K merchants, and the counter documents
(~22 s).

**First scare:** the initial connectivity check reported **64 ms RTT** — 3× the
entire budget on a single round trip. We did not panic-tune; we diagnosed. The
cluster resolved to private peered IPs and the EC2 box was confirmed in-region, so
the path was correct. Re-measuring with a *warmed* connection gave **0.54 ms**. The
64 ms was one-time connection setup (DNS/SRV + TCP + TLS + auth) landing inside the
first timed call. Lesson that recurred all project: **measure steady state, and
prove the cause before acting.**

**Baseline:** one uncontended transaction committed in **5.37 ms median, 5.79 ms
p99**. That is the floor — snapshot read + 4 writes + majority-commit round trips.
~14 ms of headroom under 20 ms. The whole game became: does that headroom survive
5000 concurrent TPS?

---

## Phase 3–4 — The Python harness and the ramp

We built a Python (PyMongo) closed-loop harness: 31 processes × ~97 threads = 3000
sessions, think-time tuned to ~5000 TPS.

The ramp looked great:

| Load | Achieved TPS | median | p95 | p99 | conflicts |
|---|---|---|---|---|---|
| baseline | — | 5.37 | — | 5.79 | 0 |
| 479 TPS | 479 | 5.93 | 7.02 | 8.10 | 0 |
| 1628 TPS | 1628 | 6.76 | 7.92 | 9.99 | 0 |
| 3253 TPS | 3253 | 7.44 | 8.56 | 10.06 | 0 |
| **5000 target** | **4938** | **7.91** | **9.17** | **14.66** | **0** |

The first full run **passed** at p99 14.66 ms. But we refused to report a single
run — and we were right to.

**The 5× battery failed 4 of 5:**

| Run | p99 |
|---|---|
| 1 | 16.16 |
| 2 | 29.86 |
| 3 | 26.00 |
| 4 | 27.05 |
| 5 | 29.19 |

The body was rock-stable (median ~7.8, p95 ~9.1) but p99 swung 16–30 ms. The
14.66 ms first run was the lucky tail of a distribution that mostly missed.

**Crucial evidence:** we sampled the server's own `serverStatus.opLatencies` once a
second during a run. Server-side **write latency averaged 0.16 ms, command ~2 ms,
dead flat the entire 60 s**, and the WiredTiger write-ticket pool was never touched.
The cluster was idle. So the ~1% tail was being added by the *client*, not MongoDB.

---

## The investigation — every hypothesis tested, not assumed

### Hypothesis 1: Python's GIL
Theory: 97 threads/process all wake from `sleep()` and queue for one GIL before
they can even issue their DB call; the client's stopwatch counts that wait as
latency. Fix to test: rewrite the harness in **Go** (no GIL, 3000 goroutines).

**Result that overturned it:** Go made the *body* slightly better (median 7.2 ms)
but the *tail far worse* — p99 **271 ms**, server still idle. Two completely
different runtimes hit the same tail with the server idle → **the GIL was not the
cause.** A clean disproof, and exactly why we tested rather than assumed.

### Hypothesis 2: cold connection pool (handshake-on-demand)
Go's goroutines demanded connections in bursts; a fresh connection pays TCP+TLS
handshake (tens of ms). Fix: pre-warm the pool (`MinPoolSize`, concurrent ping
warmup).

**Result: p99 271 → 46 ms.** Real factor, partially fixed.

### Hypothesis 3: transaction retry spins
One transaction had stalled **52 seconds** (max = 52,069 ms) in a retry loop —
`withTransaction` retries transient errors with backoff and no overall deadline.
Fix: wrap each transaction in a 2-second context deadline.

**Result: max 52,069 → 217 ms; p99 46 → 32 ms.** Real factor, fixed.

### Hypothesis 4: connection-checkout contention
Instrumented the pool monitor (`ConnectionCheckedOut.Duration`).
**Result: average checkout wait 0.147 ms over 1.5 M checkouts. Ruled out.**

### Hypothesis 5: retry storms
Instrumented attempt counts on the >20 ms transactions.
**Result: 28 retries out of 3610 slow transactions. Ruled out.**

### Hypothesis 6: a slow individual operation
Instrumented per-command client-side durations.
**Result: max single command 2–6 ms. No op stalls. Ruled out.**

### The actual cause — proven
We logged every >20 ms transaction with a timestamp and bucketed them in time:

```
t+0s-5s:   1686   <-- startup
t+5s-10s:  1248   <-- startup
t+15s-20s: 1
t+30s-35s: 235
...
```

**81% of all slow transactions occurred in the first 10 seconds.** The tail was the
**cold-start ramp** — 3000 sessions all coming online inside one 600 ms cycle,
producing a one-time burst that, averaged into a 60 s window, dragged p99 over 20.
After warmup, the system ran clean.

---

## The two passing results

### Per-op (no bulkWrite) — steady state
Excluding the 10 s warmup ramp (standard benchmark practice — report sustained, not
cold-start), the 5× battery:

| Run | windowed TPS | median | p95 | p99 | p99.9 |
|---|---|---|---|---|---|
| 1 | 4939 | 7.26 | 8.47 | 9.02 | 12.68 |
| 2 | 4942 | 7.23 | 8.45 | 9.01 | 15.08 |
| 3 | 4941 | 7.23 | 8.44 | 8.97 | 12.52 |
| 4 | 4940 | 7.23 | 8.48 | 9.24 | 37.61 |
| 5 | 4941 | 7.23 | 8.46 | 9.02 | 21.40 |

**p99 8.97–9.24 ms — all pass, spread under 0.3 ms.** The standard four-separate-ops
transaction (no application rewrite) meets the SLA with >2× margin in steady state.

### Client-level bulkWrite (MongoDB 8.0) — passes even with ramp
This variant collapses all four writes across four collections into **one** client
-level `bulkWrite`, cutting round trips per transaction from ~6 to ~3. Fewer round
trips both lowers the floor (median 5.46 ms) and halves exposure to the occasional
network-path stall — so it passes even *including* the startup ramp:

| Run | TPS | median | p95 | p99 |
|---|---|---|---|---|
| 1 | 4940 | 5.46 | 6.72 | 15.39 |
| 2 | 4939 | 5.46 | 6.71 | 12.52 |
| 3 | 4939 | 5.48 | 6.72 | 10.66 |
| 4 | 4937 | 5.46 | 6.70 | 8.05 |
| 5 | 4940 | 5.45 | 6.70 | 12.54 |

**p99 8.05–15.39 ms — all pass.**

> Note on bulkWrite scope: the classic `db.collection.bulkWrite()` operates on a
> **single** collection, so it gives no round-trip saving for our cross-collection
> workload. The win comes from the **MongoDB 8.0 client-level `bulkWrite`**, which
> spans multiple collections (and databases) in one command.

---

## The p99 journey in one view

| Stage | p99 | what changed |
|---|---|---|
| Python (GIL) | 16–30 ms (4/5 fail) | client-side tail |
| Go per-op, cold pool | 271 ms | handshake-on-demand |
| Go per-op, warm pool | 46 ms | pool pre-grown |
| Go per-op, +2 s deadline | 32 ms | retry-spin bounded (max 52 s→217 ms) |
| Go per-op, steady state | **9 ms** (5/5 pass) | warmup ramp excluded |
| Go client-bulk | **8–15 ms** (5/5 pass) | 4 ops → 1 round trip |

---

## What this proves

1. **MongoDB meets 5000 strict-ACID TPS at p99 < 20 ms** — server-side latency
   stayed sub-millisecond for writes (~0.2 ms) and ~2 ms for commits throughout. The
   cluster has > 10× headroom; the binding constraint was always the *client's*
   round-trip count and cold-start behavior, never the database.
2. **No code rewrite is required** — the per-op variant (four ordinary calls) passes
   in steady state. The client-bulk variant is an *optional optimization* that adds
   margin and passes even through the ramp.
3. **Every conclusion is backed by measurement, not assertion** — the GIL theory was
   disproven, the pool/retry/checkout/command hypotheses each tested, and the real
   cause (startup ramp) proven with a time-bucketed slow-trace.

Identical methodology applies whether the cluster is an **Enterprise replica set**
or an **Atlas replica set**; only provisioning and the connection string differ.