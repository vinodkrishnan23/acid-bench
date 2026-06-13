# FSS ACID Proof — Execution Steps

Run sequence for the **standard RWB benchmark** (rich card-management docs,
4-op strict-ACID transaction) on its **dedicated database `fss_acid_proof`**.

This branch (`feature/fss-acid-proof`) is segregated: it writes to
`fss_acid_proof` only, so it runs side-by-side with anything on `fss_acid_bench`
or `fss_bench` without colliding. The ledger starts **empty** and fills from the
run; cards / merchants / velocity collections are **primed** by the seed step.

> **Credentials:** `MONGO_URI`, the runner IP, and the `.pem` key are never
> committed. Export them in your shell; the scripts read `MONGO_URI` from the
> environment and refuse to run if it is unset.

---

## 0. Prerequisites (one-time)

- 3-node replica set `rs0` is up and reachable.
- Runner host has Go (`/usr/local/go/bin`) and `python3.11` with `pymongo`.
  If not: `./00_install_prereqs.sh` on the runner.
- You have these in your shell (placeholders — fill in your real values):

```bash
export PEM=$HOME/your-key.pem
export RUNNER_IP=<runner.public.ip>
export MONGO_URI='mongodb://<user>:<pass>@<n1>:27017,<n2>:27017,<n3>:27017/?replicaSet=rs0&authSource=admin'
```

---

## 1. Sync this branch to the runner

From your laptop, on the `feature/fss-acid-proof` branch, push the
`realworldbenchmark/` tree to the runner's project dir (`/home/ec2-user/RWB`):

```bash
git checkout feature/fss-acid-proof
rsync -az -e "ssh -i $PEM" \
  ./realworldbenchmark/ ec2-user@$RUNNER_IP:/home/ec2-user/RWB/
```

All remaining steps run **on the runner**, from `/home/ec2-user/RWB`, with
`MONGO_URI` exported.

```bash
ssh -i $PEM ec2-user@$RUNNER_IP
cd /home/ec2-user/RWB
export MONGO_URI='...'        # same URI as above
```

---

## 2. Initialise the project + config

Scaffolds `src/config.py` (with `DB_NAME = "fss_acid_proof"`), creates the
`results/` / `goharness/` dirs, and verifies cluster connectivity.

```bash
./01_init_project.sh
```

---

## 3. Seed (prime collections, leave the ledger empty)

Drops and re-creates the five RWB collections, then seeds **cards (1M, ~4 KB),
merchants, cardholder_velocity, merchant_velocity** — and leaves **`txn_ledger`
empty** (it fills at runtime). Also records the initial `cards.balance` total to
`/tmp/fss_acid_proof_initial_cards.paise` for the ACID check in step 6.

```bash
./02_seed.sh
```

Re-run this any time you want a clean slate; every run re-primes from scratch.

---

## 4. Build the Go binaries

Compiles `perop_bin` and `clientbulk_bin` (both target `fss_acid_proof`).

```bash
./03_build_go.sh
```

---

## 5. Run the benchmark

**Battery (both variants, recommended):**

```bash
SESSIONS=3000 TARGET_TPS=5000 DURATION=120 ./run_battery.sh 5 \
  | tee /tmp/fss_acid_proof_battery_$(date +%Y%m%d_%H%M%S).log
```

**Single variant:**

```bash
SESSIONS=3000 TARGET_TPS=5000 DURATION=120 ./run_perop.sh
SESSIONS=3000 TARGET_TPS=5000 DURATION=120 ./run_clientbulk.sh
```

**Knobs** (env vars, defaults from `env.sh`): `SESSIONS` (3000),
`TARGET_TPS` (5000), `DURATION` (70s), `WARMUP_SEC` (10), `MIN_POOL`/`MAX_POOL`
(500/1000).

**Pass criteria:** fresh p99 ≤ 20 ms at 5K TPS (on the 128 GB cluster both
variants have run 5/5 PASS at p99 ≤ 12 ms — see `RESULTS.md`).

---

## 6. Verify ACID invariant

Run with **no live transactions in flight**. Confirms all four quantities match:
cards balance delta = `sum(txn_ledger.amount)` = `sum(cardholder_velocity.sum)`
= `sum(merchant_velocity.sum)`.

```bash
./verify_acid.sh
```

---

## 7. Confirm the data landed in `fss_acid_proof`

```bash
mongosh "$MONGO_URI" --quiet --eval '
  const db_ = db.getSiblingDB("fss_acid_proof");
  ["cards","merchants","txn_ledger","cardholder_velocity","merchant_velocity"]
    .forEach(c => print(c.padEnd(22), db_[c].estimatedDocumentCount()));
'
```

Expect `cards` ≈ 1,000,000, the velocity collections pre-warmed, and
`txn_ledger` ≈ the number of committed transactions from the run.

---

## End-to-end (fresh proof, copy-paste)

```bash
# laptop
git checkout feature/fss-acid-proof
rsync -az -e "ssh -i $PEM" ./realworldbenchmark/ ec2-user@$RUNNER_IP:/home/ec2-user/RWB/

# runner
cd /home/ec2-user/RWB && export MONGO_URI='...'
./01_init_project.sh
./02_seed.sh
./03_build_go.sh
SESSIONS=3000 TARGET_TPS=5000 DURATION=120 ./run_battery.sh 5 | tee /tmp/proof.log
./verify_acid.sh
```
