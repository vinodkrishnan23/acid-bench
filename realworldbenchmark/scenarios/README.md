# Scenarios — customer-driven demos beyond the steady-state battery

These scripts answer two specific customer questions that the steady-state
battery does not.

| Scenario | Question answered | Script |
|---|---|---|
| 1. Primary stepdown mid-transaction | "If our primary fails during a transaction, what error code does the app see, and what's the retry strategy?" | [`stepdown_mid_txn.sh`](stepdown_mid_txn.sh) |
| 2. Hot-document contention on top of 5K TPS | "When one cardId gets hammered by 50 concurrent authorisations, does the 5000-TPS guarantee survive, and what's the experience of the unlucky cardholder?" | [`hotdoc_with_baseline.sh`](hotdoc_with_baseline.sh) |

Both depend on the bench binaries built by `../03_build_go.sh`:

```bash
cd $RWB_DIR
./03_build_go.sh   # builds perop_bin, clientbulk_bin, hotdoc_bin, srvmon_bin
```

Set `MONGO_URI` to the replica set seed string before running either scenario.

---

## Scenario 1 — Primary stepdown mid-transaction

```bash
# Default: perop variant, 120s run, stepDown at T+60s, freeze 30s
./scenarios/stepdown_mid_txn.sh

# All knobs
./scenarios/stepdown_mid_txn.sh perop 120 60 30
./scenarios/stepdown_mid_txn.sh clientbulk 180 90 30

# Tune workload
SESSIONS=3000 TARGET_TPS=5000 ./scenarios/stepdown_mid_txn.sh perop 120 60 30
```

What you get in `results/stepdown_<variant>_<ts>/`:
- `tps.csv` — per-second commit counts (for plotting the dip-and-recovery curve)
- `bench.log` — bench output (final p50/p95/p99 line, errors, retries)
- `stepdown.log` — mongosh output of the `rs.stepDown()` command

The script also prints a side-by-side comparison of average TPS in three windows:
- **pre**: 0 → stepdown-fire moment
- **during**: stepdown moment → ~5s after the new primary is elected
- **post**: after recovery → end of run

### What it proves

The Go driver's `WithTransaction(...)` callback API catches the
`TransientTransactionError` label that MongoDB returns when a transaction is
aborted due to stepdown, and retries the entire transaction against the new
primary. The application code does not need explicit retry logic — it just
needs to use the callback API (which the bench does).

If the election takes longer than the transaction's `maxTimeMS` (default ~120s
through `WithTransaction`'s own timeout budget), the error escapes to the
application as `mongo.MongoError{Labels: ["TransientTransactionError"]}`. In our
runs that doesn't happen; elections complete in under 10 seconds and the
driver's retry budget absorbs them.

---

## Scenario 2 — Hot-card storm on a 5K-TPS baseline (Shape B)

```bash
# 50 concurrent on the hot card, 120s overlap, default 5000-TPS baseline
./scenarios/hotdoc_with_baseline.sh 50

# Explore the curve
./scenarios/hotdoc_with_baseline.sh 10  120
./scenarios/hotdoc_with_baseline.sh 50  120
./scenarios/hotdoc_with_baseline.sh 100 120
./scenarios/hotdoc_with_baseline.sh 200 120

# Pin a specific card / merchant
HOT_CARD_ID=CARD-0000001234 HOT_MERCHANT_ID=M0000005 \
  ./scenarios/hotdoc_with_baseline.sh 50 120
```

What you get in `results/hotdoc_N<n>_<ts>/`:
- `baseline_tps.csv` + `baseline.log` — perop @ 5K TPS, random cards
- `hotdoc_tps.csv`   + `hotdoc.log`   — N goroutines on the hot card
- `writeconflicts_{before,after}.json` — cluster-wide `metrics.operation.writeConflicts` snapshots

The script prints:
- baseline TPS / p99 — *did we hold 5000 TPS during the storm?*
- hot-card TPS / p99 — *what did the contended cardholder experience?*
- writeConflicts delta — *cluster-wide retry pressure produced by the storm*

### What it proves

A 50-goroutine storm on one cardId tops out in the low-100s of TPS per card
regardless of cluster size — that's the fundamental serialization limit of
transactions on a single document under snapshot isolation. The baseline TPS
on the other 999,999 cards is essentially untouched because the storm consumes
only a sliver of the cluster's write capacity.

End-to-end latency for the hot card grows roughly linearly with N — the driver
retries on `WriteConflict`, each retry conflicts again, the txn's wall-clock
time stretches.

### Recommended customer talking points

- **System guarantee holds**: 5K TPS continues even during the storm
- **Cold cards unaffected**: p99 on the rest of the cardholder population stays
  near the headline number
- **Hot card user experience**: degrades — for the unlucky cardholder, p99 can
  grow into the tens to hundreds of ms depending on N
- **Mitigations** (if hot cards are part of the production traffic pattern):
  - Application-side batching: coalesce concurrent auths for the same card on
    the app tier before they hit MongoDB
  - Sharding key on `{cardId, hour}` if hot cards correlate to specific time
    buckets — distributes the contention
  - Use the same `cb` (bucket count) pattern that `merchant_velocity` already
    uses for hot merchants, applied to `cardholder_velocity` for hot cards
