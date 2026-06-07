#!/usr/bin/env bash
# diag_iostat_rwb.sh — run from your Mac. Same shape as scripts/diag_iostat.sh but
# drives the RWB bench (/home/ec2-user/ACID/realworldbenchmark/run_*.sh) instead of
# the FSS bench, and prints an EBS-cap analysis at the end so you know whether to
# bump IOPS, throughput, both, or switch volume type.
#
# Why Mac-orchestrated: the runner doesn't have a private key to SSH to the mongo
# primary; your Mac does (via ProxyCommand to runner → mongo-0).
#
# Usage:
#   MONGO_URI='mongodb://...' ./scripts/diag_iostat_rwb.sh                    # perop, 60s
#   MONGO_URI='...' ./scripts/diag_iostat_rwb.sh clientbulk 120
#   MONGO_URI='...' SESSIONS=4000 TARGET_TPS=6000 ./scripts/diag_iostat_rwb.sh perop 90
#
# Provisioned EBS caps are read from env (override if you've changed them):
#   IOPS_CAP=3000  TPUT_CAP=500

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$PROJECT_DIR/terraform"

VARIANT="${1:-perop}"
DURATION="${2:-60}"
SESSIONS="${SESSIONS:-3000}"
TARGET_TPS="${TARGET_TPS:-5000}"
IOPS_CAP="${IOPS_CAP:-3000}"
TPUT_CAP="${TPUT_CAP:-500}"

: "${PEM:=$HOME/.ssh/your-key.pem}"
: "${MONGO_URI:?MONGO_URI must be exported in this shell}"

case "$VARIANT" in
  perop|clientbulk) ;;
  *) echo "usage: $0 [perop|clientbulk] [duration_s]" >&2; exit 1 ;;
esac

RUNNER_IP=$(cd "$TF_DIR" && terraform output -raw runner_public_ip)
MONGO0=$(cd "$TF_DIR" && terraform output -json mongodb_private_ips | jq -r '.[0]')

SSH_OPTS="-o StrictHostKeyChecking=no -o LogLevel=ERROR -i $PEM"
PROXY_CMD="ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i $PEM -W %h:%p ec2-user@$RUNNER_IP"
IOSTAT_DUR=$((DURATION + 10))

LOG_IOSTAT="/tmp/diag_iostat_rwb.log"
LOG_BENCH="/tmp/diag_bench_rwb.log"

echo "Runner: $RUNNER_IP    Mongo primary: $MONGO0"
echo "Variant: RWB $VARIANT     Sessions: $SESSIONS    TPS: $TARGET_TPS    Duration: ${DURATION}s"
echo "EBS caps assumed: ${IOPS_CAP} IOPS / ${TPUT_CAP} MB/s   (override with IOPS_CAP, TPUT_CAP)"
echo ""

echo "→ Starting iostat on mongo primary (1s × ${IOSTAT_DUR})…"
ssh $SSH_OPTS -o ProxyCommand="$PROXY_CMD" "ec2-user@$MONGO0" \
  "iostat -xt 1 $IOSTAT_DUR nvme1n1" > "$LOG_IOSTAT" 2>&1 &
IOSTAT_PID=$!

sleep 3

echo "→ Running RWB bench on runner…"
echo ""
ssh $SSH_OPTS "ec2-user@$RUNNER_IP" \
  "export MONGO_URI='$MONGO_URI' && cd /home/ec2-user/ACID/realworldbenchmark && SESSIONS=$SESSIONS TARGET_TPS=$TARGET_TPS DURATION=$DURATION ./run_${VARIANT}.sh" \
  | tee "$LOG_BENCH"

wait "$IOSTAT_PID" || true

echo ""
echo "=== EBS usage analysis (mongo primary, nvme1n1) ==="
grep "^nvme1n1" "$LOG_IOSTAT" | awk -v iops_cap="$IOPS_CAP" -v tput_cap="$TPUT_CAP" '
{
  samples++
  r=$4; w=$8
  rmb=$5*0.001024; wmb=$9*0.001024
  iops=r+w; mb=rmb+wmb
  util=$NF+0
  aqu=$(NF-1)
  iops_sum += iops; mb_sum += mb; util_sum += util; aqu_sum += aqu
  if (iops > peak_iops)  peak_iops = iops
  if (mb > peak_mb)      peak_mb = mb
  if (util > peak_util)  peak_util = util
  if (aqu > peak_aqu)    peak_aqu = aqu
  if (iops >= iops_cap*0.95) iops_throttle_samples++
  if (mb   >= tput_cap*0.95) tput_throttle_samples++
  if (util >= 95)            sat_samples++
}
END {
  if (samples == 0) { print "  no iostat samples found in log"; exit }
  printf "  samples (1s each)                : %d\n", samples
  printf "\n"
  printf "  avg IOPS                         : %6.0f   (cap %d)\n", iops_sum/samples, iops_cap
  printf "  peak IOPS                        : %6.0f\n", peak_iops
  printf "  %% samples within 5%% of IOPS cap   : %5.1f%%\n", 100*iops_throttle_samples/samples
  printf "\n"
  printf "  avg throughput MB/s              : %6.1f   (cap %d)\n", mb_sum/samples, tput_cap
  printf "  peak throughput MB/s             : %6.1f\n", peak_mb
  printf "  %% samples within 5%% of tput cap   : %5.1f%%\n", 100*tput_throttle_samples/samples
  printf "\n"
  printf "  avg %%util                        : %5.0f\n", util_sum/samples
  printf "  peak %%util                       : %5.0f\n", peak_util
  printf "  %% samples %%util >= 95             : %5.1f%%\n", 100*sat_samples/samples
  printf "  avg queue depth (aqu-sz)         : %5.2f\n", aqu_sum/samples
  printf "  peak queue depth                 : %5.2f\n", peak_aqu
  printf "\n=== Recommendation ===\n"
  if (iops_throttle_samples > samples * 0.10 && tput_throttle_samples > samples * 0.10) {
    print "  → BOTH IOPS and throughput hitting cap. Go to gp3 max:"
    print "    terraform: aws_ebs_volume.mongodb_data { iops = 16000, throughput = 1000 }"
  } else if (iops_throttle_samples > samples * 0.10) {
    print "  → IOPS-bound. Bump gp3 IOPS:"
    print "    terraform: aws_ebs_volume.mongodb_data { iops = 6000 (or up to 16000 = gp3 max) }"
  } else if (tput_throttle_samples > samples * 0.10) {
    print "  → Throughput-bound. Bump gp3 throughput:"
    print "    terraform: aws_ebs_volume.mongodb_data { throughput = 1000 (gp3 max) }"
  } else if (peak_util >= 95 && peak_aqu >= 2.0) {
    print "  → Saturated under provisioned caps with queue building → switch volume type:"
    print "    terraform: type = \"io2\", iops = up to 64000 (~4× cost vs gp3)"
  } else if (peak_util >= 95) {
    print "  → %util pinned but neither IOPS nor MB/s near cap. Many small random ops."
    print "    Try bumping IOPS first (cheap); if still pinned, consider io2."
  } else {
    print "  → NOT disk-bound. Bottleneck is elsewhere (CPU / network / contention / replica)."
    print "    Re-check srvmon (wc/s, queued, write_avg) and replica oplog lag."
  }
}
'

echo ""
echo "Logs saved:"
echo "  bench : $LOG_BENCH"
echo "  iostat: $LOG_IOSTAT"
