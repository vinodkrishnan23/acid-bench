#!/usr/bin/env bash
# diag_iostat.sh — runner-side IOPS/throughput analysis for RWB.
# Auto-detects the /data/db block device (so it works even after EBS re-attach
# renames nvme1n1 → nvme2n2 etc).
#
# Usage:
#   SESSIONS=3000 TARGET_TPS=5000 ./diag_iostat.sh perop 60
#   ./diag_iostat.sh clientbulk 120
#   IOPS_CAP=16000 TPUT_CAP=500 ./diag_iostat.sh perop 300
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

VARIANT="${1:-perop}"
DURATION="${2:-${DURATION:-60}}"
PEM="${PEM:-$HOME/.ssh/your-key.pem}"
MONGO_PRIMARY="${MONGO_PRIMARY:-10.0.0.200}"
IOPS_CAP="${IOPS_CAP:-3000}"
TPUT_CAP="${TPUT_CAP:-500}"

case "$VARIANT" in
  perop)      BIN="$GO_DIR/perop_bin" ;;
  clientbulk) BIN="$GO_DIR/clientbulk_bin" ;;
  *) echo "usage: $0 [perop|clientbulk] [duration_s]" >&2; exit 1 ;;
esac

# auto-detect the data device on the primary (e.g. nvme1n1 or nvme2n2)
DATA_DEV=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i "$PEM" ec2-user@"$MONGO_PRIMARY" \
  "df --output=source /data/db | tail -1 | xargs basename")
if [ -z "$DATA_DEV" ]; then echo "ERROR: couldn't detect /data/db device on $MONGO_PRIMARY" >&2; exit 1; fi

IOSTAT_LOG="$RESULTS_DIR/diag_iostat_${VARIANT}_$(date +%Y%m%d_%H%M%S).log"
IOSTAT_DUR=$((DURATION + 10))

echo "=== iostat on $MONGO_PRIMARY:$DATA_DEV + $VARIANT $SESSIONS/$TARGET_TPS/${DURATION}s ==="
echo "    gp3 caps assumed: ${IOPS_CAP} IOPS, ${TPUT_CAP} MB/s   (override with IOPS_CAP / TPUT_CAP)"
echo ""

ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i "$PEM" ec2-user@"$MONGO_PRIMARY" \
  "iostat -xt 1 $IOSTAT_DUR $DATA_DEV" > "$IOSTAT_LOG" 2>&1 &
IOSTAT_PID=$!
sleep 3

"$BIN" "$SESSIONS" "$TARGET_TPS" "$DURATION"

wait $IOSTAT_PID || true

echo ""
echo "=== EBS usage analysis ==="
grep "^$DATA_DEV" "$IOSTAT_LOG" | awk -v iops_cap="$IOPS_CAP" -v tput_cap="$TPUT_CAP" -v dev="$DATA_DEV" '
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
  if (samples == 0) { print "  no '"$DATA_DEV"' samples in log — check '"$IOSTAT_LOG"'"; exit }
  printf "  device                           : %s\n", dev
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
    print "  → IOPS-bound. Bump IOPS (or switch to io2 if already at gp3 max 16000)."
  } else if (tput_throttle_samples > samples * 0.10) {
    print "  → Throughput-bound. Bump gp3 throughput (max 1000 MB/s)."
  } else if (peak_util >= 95 && peak_aqu >= 2.0) {
    print "  → Saturated under provisioned caps with queue building → switch volume type:"
    print "    terraform: type = \"io2\", iops = up to 64000 (~4× cost vs gp3)"
  } else if (peak_util >= 95) {
    print "  → %util pinned but neither IOPS nor MB/s near cap. Many small random ops."
  } else {
    print "  → NOT disk-bound. Bottleneck elsewhere (CPU / network / contention / replica)."
    print "    Check srvmon (wc/s, queued, write_avg) and replica oplog lag."
  }
}
'

echo ""
echo "Full iostat log: $IOSTAT_LOG"
