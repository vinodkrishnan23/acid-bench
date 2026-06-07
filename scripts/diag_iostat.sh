#!/usr/bin/env bash
# diag_iostat.sh — run from your Mac. Coordinates iostat on mongo-0 (primary)
# with a bench on the runner, so you can correlate per-second disk activity
# (await, %util, MB/s) against the bench's tail-latency spikes.
#
# Why Mac-orchestrated: the runner does not have a private key to SSH to
# mongo-0 directly; your Mac already does (via the existing -J jump host).
#
# Usage:
#   MONGO_URI='mongodb://...' ./scripts/diag_iostat.sh                       # perop, 60s
#   MONGO_URI='...' ./scripts/diag_iostat.sh clientbulk 120
#   MONGO_URI='...' SESSIONS=4000 TARGET_TPS=6000 ./scripts/diag_iostat.sh perop 90

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$PROJECT_DIR/terraform"

VARIANT="${1:-perop}"
DURATION="${2:-60}"
SESSIONS="${SESSIONS:-3000}"
TARGET_TPS="${TARGET_TPS:-5000}"

: "${PEM:=$HOME/.ssh/your-key.pem}"
: "${MONGO_URI:?MONGO_URI must be exported in this shell}"

case "$VARIANT" in
  perop|clientbulk) ;;
  *) echo "usage: $0 [perop|clientbulk] [duration_s]" >&2; exit 1 ;;
esac

RUNNER_IP=$(cd "$TF_DIR" && terraform output -raw runner_public_ip)
MONGO0=$(cd "$TF_DIR" && terraform output -json mongodb_private_ips | jq -r '.[0]')

SSH_OPTS="-o StrictHostKeyChecking=no -o LogLevel=ERROR -i $PEM"
# Explicit ProxyCommand so the jump hop also uses $PEM (ssh -J does not propagate -i).
PROXY_CMD="ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i $PEM -W %h:%p ec2-user@$RUNNER_IP"
IOSTAT_DUR=$((DURATION + 10))

LOG_IOSTAT="/tmp/diag_iostat.log"
LOG_BENCH="/tmp/diag_bench.log"

echo "Runner: $RUNNER_IP    Mongo-0 (primary): $MONGO0"
echo "Variant: $VARIANT     Sessions: $SESSIONS    TPS: $TARGET_TPS    Duration: ${DURATION}s"
echo ""

echo "→ Starting iostat on mongo-0 (samples 1s × ${IOSTAT_DUR})…"
ssh $SSH_OPTS -o ProxyCommand="$PROXY_CMD" "ec2-user@$MONGO0" \
  "iostat -xt 1 $IOSTAT_DUR nvme1n1" > "$LOG_IOSTAT" 2>&1 &
IOSTAT_PID=$!

# Let iostat take a few baseline samples before the bench kicks in
sleep 3

echo "→ Running bench on runner…"
echo ""
ssh $SSH_OPTS "ec2-user@$RUNNER_IP" \
  "export MONGO_URI='$MONGO_URI' && cd /home/ec2-user/ACID/scripts && SESSIONS=$SESSIONS TARGET_TPS=$TARGET_TPS DURATION=$DURATION ./run_${VARIANT}.sh" \
  | tee "$LOG_BENCH"

wait "$IOSTAT_PID" || true

echo ""
echo "=== iostat on mongo-0:nvme1n1 (data volume) ==="
cat "$LOG_IOSTAT"

echo ""
echo "Logs saved:"
echo "  bench : $LOG_BENCH"
echo "  iostat: $LOG_IOSTAT"
echo ""
echo "Key iostat columns to watch:"
echo "  %util  — 90–100% sustained = disk-bound"
echo "  await  — total wait per I/O in ms; spikes during your cmd_avg blips = EBS throttling"
echo "  wMB/s  — sustained near 125 = gp3 throughput cap (we have 125 baseline)"
echo "  w/s    — write IOPS; sustained near 3000 = gp3 IOPS cap (we have 3000 baseline)"
