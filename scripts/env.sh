#!/usr/bin/env bash
# env.sh — shared configuration sourced by every script.
# Override any value inline, e.g.:  SESSIONS=2000 TARGET_TPS=4000 DURATION=120 ./run_clientbulk.sh
#
# This file is the single place to change defaults.

# ---- Project layout ----
export PROJECT_DIR="${PROJECT_DIR:-/home/ec2-user/ACID}"
export SRC_DIR="$PROJECT_DIR/src"
export GO_DIR="$PROJECT_DIR/goharness"
export RESULTS_DIR="$PROJECT_DIR/results"

# ---- Python interpreter that actually has pymongo ----
# On Amazon Linux the system python3 may be 3.9 WITHOUT pymongo; 3.11 has it.
export PYBIN="${PYBIN:-python3.11}"

# ---- Workload parameters (THE THREE YOU CUSTOMIZE) ----
# SESSIONS    = number of concurrent closed-loop sessions (e.g. 3000)
# TARGET_TPS  = target transactions/sec the sessions aim for (e.g. 5000)
# DURATION    = run length in seconds (e.g. 70)
export SESSIONS="${SESSIONS:-3000}"
export TARGET_TPS="${TARGET_TPS:-5000}"
export DURATION="${DURATION:-70}"

# ---- Warmup window (seconds) excluded from steady-state percentiles ----
export WARMUP_SEC="${WARMUP_SEC:-10}"

# ---- Connection pool (right-sized; override if you scale concurrency) ----
export MIN_POOL="${MIN_POOL:-500}"
export MAX_POOL="${MAX_POOL:-1000}"

# ---- Atlas connection string (NEVER hard-code; read from environment) ----
# Export MONGO_URI in your shell before running:
#   read -rsp 'Paste Atlas SRV URI: ' MONGO_URI && export MONGO_URI
if [[ -z "${MONGO_URI:-}" ]]; then
  echo "ERROR: MONGO_URI is not set. Run:" >&2
  echo "  read -rsp 'Paste Atlas SRV URI: ' MONGO_URI && export MONGO_URI" >&2
  return 1 2>/dev/null || exit 1
fi

mkdir -p "$RESULTS_DIR"
echo "[env] SESSIONS=$SESSIONS TARGET_TPS=$TARGET_TPS DURATION=$DURATION WARMUP=${WARMUP_SEC}s POOL=${MIN_POOL}/${MAX_POOL} PY=$PYBIN"
