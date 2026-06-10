# ACID@Scale POC — Runbook

Live-execution sequence for every benchmark scenario built during the POC.
Each scenario lives on its own git branch; switching branches + re-syncing
to the runner is the unit of work between scenarios.

---

## Scenario index

| # | Scenario | Branch | What it proves |
|---|---|---|---|
| 1 | **Battery 5K TPS** (perop + clientbulk × 5 runs) | `main` | Baseline strict-ACID at 5K TPS, p99 ≤ 20 ms |
| 2 | **Scaling study** (5K / 6K / 7K TPS) | `main` | Throughput ceiling per variant |
| 3 | **Primary stepdown mid-txn** | `feature/stepdown-and-hotdoc-scenarios` | Failover doesn't break in-flight txns |
| 4 | **Hot-doc contention (Shape B)** — N concurrent on one card while baseline runs | `feature/stepdown-and-hotdoc-scenarios` | MVCC ceiling per card; N=50/100 OK, N=200 breaks |
| 5 | **Zipfian heavy skew (Shape C)** | `feature/zipfian-distribution` | Heavy-skew upper bound (documented; excluded from customer deck) |
| 6 | **ISO 8583 idempotency** (separate `idempotency_cache`, per-op + bulk variants) | `feature/iso8583-separate-cache` | Exactly-once retry handling; ~5% latency overhead at 5K TPS |

---

## Pre-requisites (one-time per cluster)

```bash
# 1. Cluster provisioned via Terraform (3-node replica set, r7i.4xlarge, 128 GiB)
cd terraform && terraform apply
# capture: runner public IP, internal mongod addresses

# 2. Local environment (NEVER commit these — they are credentials)
export PEM=$HOME/your-key.pem
export RUNNER_IP=<runner.public.ip>
export MONGO_URI='mongodb://<user>:<password>@<mongo_node_1>:27017,<mongo_node_2>:27017,<mongo_node_3>:27017/?replicaSet=rs0&authSource=admin'

# 3. Initial collection seed (cards, ledger, velocities) — only once per cluster
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && ./02_seed.sh && ./04_seed_ledger.sh"
```

---

## Per-scenario execution

Every scenario follows the same shape:

```
1.  git checkout <branch>
2.  scripts/sync_to_runner.sh                       # rsync code to /home/ec2-user/ACID
3.  ssh ... './03_build_go.sh'                       # compile Go binaries on the runner
4.  ssh ... './scenarios/<scenario>.sh'              # run
5.  scp -i $PEM -r ec2-user@$RUNNER_IP:/home/ec2-user/RWB/results/<dir> ./   # pull logs
```

---

### Scenario 1+2: Battery + scaling study  (branch `main`)

```bash
git checkout main
RUNNER_IP=$RUNNER_IP PEM=$PEM scripts/sync_to_runner.sh
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && ./03_build_go.sh"

# Battery 5K (5 runs per variant, ~25 min wall-clock)
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && \
  SESSIONS=3000 TARGET_TPS=5000 DURATION=120 ./run_battery.sh 5 | tee /tmp/battery_5k.log"

# Scaling study (each one ~6 min)
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && \
  SESSIONS=3000 TARGET_TPS=6000 DURATION=120 ./run_battery.sh 3"
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && \
  SESSIONS=3000 TARGET_TPS=7000 DURATION=120 ./run_battery.sh 3"
```

**Expected outcome on 128 GiB cluster:**
- 5K: client-bulk 5/5 PASS, p99 median ~6.94 ms; per-op 5/5 PASS, p99 median ~7.53 ms
- 6K: client-bulk holds, per-op begins to FAIL p99
- 7K: client-bulk still holds, per-op caps out around 5K

---

### Scenario 3: Primary stepdown  (branch `feature/stepdown-and-hotdoc-scenarios`)

```bash
git checkout feature/stepdown-and-hotdoc-scenarios
RUNNER_IP=$RUNNER_IP PEM=$PEM scripts/sync_to_runner.sh
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && ./03_build_go.sh"

ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && \
  ./scenarios/stepdown_mid_txn.sh"
# launches bench, fires rs.stepDown(30) at T+60s, captures pre/during/post TPS via CSV
```

**Expected outcome:** 0 application errors across ~550K txns, election in ~1s.

---

### Scenario 4: Hot-doc contention (Shape B)  (same branch as Scenario 3)

```bash
# Run all three N values back-to-back. Script tops up CARD-0000000001 to 10^12 paise
# before each run, so the hot card never drains.
for N in 50 100 200; do
  ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && \
    N=$N ./scenarios/hotdoc_with_baseline.sh"
done
```

**Expected outcome:**
- N=50: baseline holds 5K TPS, p99 ~11 ms
- N=100: baseline holds, p99 ~18 ms (close to SLO)
- N=200: baseline BREAKS, p99 ~518 ms (this is the failure point — useful in the deck)

---

### Scenario 5: Zipfian heavy skew (Shape C)  (branch `feature/zipfian-distribution`) — optional

Only run if the customer asks about extreme skew. Documented as a "what
breaks the model" disclosure, not a flagship result.

```bash
git checkout feature/zipfian-distribution
RUNNER_IP=$RUNNER_IP PEM=$PEM scripts/sync_to_runner.sh
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && ./03_build_go.sh"

ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/RWB && export MONGO_URI='$MONGO_URI' && \
  CARD_DIST=zipf ZIPF_S=1.1 ./run_battery.sh 5"
```

**Expected outcome:** both variants FAIL (top card demands ~670 TPS, MVCC ceiling is ~450-485 TPS per card). Document the result — do not put in the customer deck.

---

### Scenario 6: ISO 8583 idempotency  (branch `feature/iso8583-separate-cache`)

```bash
git checkout feature/iso8583-separate-cache
RUNNER_IP=$RUNNER_IP PEM=$PEM scripts/sync_to_runner.sh
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/ACID/realworldbenchmark && export MONGO_URI='$MONGO_URI' && ./03_build_go.sh"

# One-time setup: drop + reseed txn_ledger_iso (100M rows) + TTL'd idempotency_cache.
# Wall-clock: ~9 min seed + ~24 min createdAt index build = ~33 min.
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/ACID/realworldbenchmark && export MONGO_URI='$MONGO_URI' && \
  ./scenarios/iso8583_seed.sh"

# Per-op variant (6 round-trips per txn)
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/ACID/realworldbenchmark && export MONGO_URI='$MONGO_URI' && \
  ./scenarios/iso8583_perop.sh"

# Bulk variant (2 ClientBulkWrite round-trips per txn)
ssh -i $PEM ec2-user@$RUNNER_IP "cd /home/ec2-user/ACID/realworldbenchmark && export MONGO_URI='$MONGO_URI' && \
  ./scenarios/iso8583_bulk.sh"
```

**Knobs (set as env vars before the scenario):**
- `SESSIONS` (default 3000)
- `TARGET_TPS` (default 5000)
- `DURATION` (default 70 s; the script will compute the verification window as `bench_start + DURATION + 10`)
- `DUPLICATE_RATE` (default 0.08 — fraction of attempts that replay a recent (rrn, stan, acquirerCode) tuple)
- `RETRY_WINDOW_SEC` (default 30 — how far back a replayable tuple can be)

**Expected outcome (matches results from this engagement):**
- iso8583_perop: 5,691 TPS, fresh p99 **7.90 ms**, retry p99 6.39 ms, PASS
- iso8583_bulk: 5,702 TPS, fresh p99 **7.27 ms**, retry p99 6.49 ms, PASS
- Both: storage verification clean (ledger rows = cache entries = bench counter, zero `PENDING`)
- Idempotency overhead vs documented baselines: **~+0.3-0.4 ms p99, no throughput cost**

---

## Recommended end-to-end demo order

When demoing fresh to a customer:

1. **Cluster up + initial seed**          *(pre-requisites, one-time)*
2. **Battery 5K**                          *(Scenario 1 — baseline proof)*
3. **Scaling study**                       *(Scenario 2 — ceiling)*
4. **Stepdown mid-txn**                    *(Scenario 3 — failover safety)*
5. **Hot-doc N=50, 100, 200**              *(Scenario 4 — contention boundary)*
6. **ISO 8583 seed + perop + bulk**        *(Scenario 6 — exactly-once cost)*

Skip Zipfian (Scenario 5) unless the customer explicitly asks about extreme skew.

Total wall-clock end-to-end for items 2-6, assuming the cluster is already seeded:
**~2-2.5 hours** (dominated by the iso8583 seed + index build at ~33 min).

---

## Where logs land

- **Per-run output dir**: `/home/ec2-user/RWB/results/<scenario>_<TS>/` on the runner.
  Contains the bench log, verification log, writeConflict before/after, and any CSVs.
- **Pull back to local**:
  ```bash
  scp -i $PEM -r ec2-user@$RUNNER_IP:/home/ec2-user/RWB/results/<dir> ./
  ```
- **Battery summary** (top-level p99 table): in the `| tee` capture file passed to `run_battery.sh`.

---

## Caveats and gotchas

- **Existing `txn_ledger`** has accumulated ~149M rows from prior bench runs. Not a problem — just be aware when citing "ledger size" externally.
- **`iso8583_seed.sh` is destructive** for `txn_ledger_iso` and `idempotency_cache`. It drops and re-creates both. Don't run it casually mid-engagement.
- **Hot-doc N=200** drains the hot card balance. The script tops it up to 10^12 paise before each run; if you bypass the script and run the binary directly, you must top up first or you'll silently get 0 commits.
- **Stepdown scenario** needs admin rights to issue `rs.stepDown()`. Use the admin user provisioned by the userdata script.
- **`MONGO_URI` is a credential.** Never commit it. Never `echo $MONGO_URI` into a log file that ends up in the repo. The scenarios pull it from the environment.
- **`.pem` keys never go into the repo.** They live under `$HOME`, are sourced via the `PEM` env var, and are listed in `.gitignore`.

---

## Branch summary

```
main                                       ← baseline benches, scaling study, RESULTS.md
feature/stepdown-and-hotdoc-scenarios      ← Scenarios 3 & 4
feature/zipfian-distribution               ← Scenario 5 (optional)
feature/iso8583-separate-cache             ← Scenario 6 (per-op + bulk + seed)
```

All four branches are pushed to `origin` on https://github.com/vinodkrishnan23/acid-bench.
