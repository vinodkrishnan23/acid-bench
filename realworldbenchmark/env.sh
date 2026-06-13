#!/usr/bin/env bash
# env.sh — shared configuration for the realworldbenchmark variant.
# Distinct PROJECT_DIR / DB so it runs side-by-side with the FSS bench.

# ---- Project layout ----
export PROJECT_DIR="${PROJECT_DIR:-/home/ec2-user/RWB}"
export SRC_DIR="$PROJECT_DIR/src"
export GO_DIR="$PROJECT_DIR/goharness"
export RESULTS_DIR="$PROJECT_DIR/results"

# ---- Python interpreter with pymongo ----
export PYBIN="${PYBIN:-python3.11}"

# ---- Workload defaults ----
export SESSIONS="${SESSIONS:-3000}"
export TARGET_TPS="${TARGET_TPS:-5000}"
export DURATION="${DURATION:-70}"
export WARMUP_SEC="${WARMUP_SEC:-10}"
export MIN_POOL="${MIN_POOL:-500}"
export MAX_POOL="${MAX_POOL:-1000}"

# ---- DB used by cash_snapshot.sh ----
export BENCH_DB_NAME="${BENCH_DB_NAME:-fss_acid_proof}"

# ---- MONGO_URI required from environment (never written to disk) ----
if [[ -z "${MONGO_URI:-}" ]]; then
  echo "ERROR: MONGO_URI is not set. Run:" >&2
  echo "  read -rsp 'Paste Mongo SRV URI: ' MONGO_URI && export MONGO_URI" >&2
  return 1 2>/dev/null || exit 1
fi

mkdir -p "$RESULTS_DIR"
echo "[rwb-env] SESSIONS=$SESSIONS TARGET_TPS=$TARGET_TPS DURATION=$DURATION WARMUP=${WARMUP_SEC}s POOL=${MIN_POOL}/${MAX_POOL} PY=$PYBIN DB=$BENCH_DB_NAME"
