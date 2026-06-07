#!/usr/bin/env bash
# fetch_ftdc.sh — pull MongoDB FTDC (diagnostic.data) from a cluster node to your Mac.
# Run from your Mac. By default targets the primary; override with PRIMARY=10.0.0.201 etc.
#
# Why: FTDC files contain server-side opLatencies, WT cache stats, queue length, replication
# lag, page-faults, ticket usage, etc. — far more than what srvmon samples every 5s. Use them
# to determine whether the bottleneck is IOPS, memory pressure (WT cache eviction), commit
# wait, or something else.
#
# Usage:
#   ./scripts/fetch_ftdc.sh                                     # pull from PRIMARY (10.0.0.200) → realworldbenchmark/ftdc/<ts>/
#   PRIMARY=10.0.0.201 ./scripts/fetch_ftdc.sh                  # pull from a specific node
#   DEST=/tmp/ftdc ./scripts/fetch_ftdc.sh                      # override destination
#   FETCH_ALL=1 ./scripts/fetch_ftdc.sh                         # pull from all 3 nodes into separate subdirs

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$PROJECT_DIR/terraform"

: "${PEM:=$HOME/.ssh/your-key.pem}"
PRIMARY="${PRIMARY:-10.0.0.200}"
TS=$(date +%Y%m%d_%H%M%S)
DEST="${DEST:-$PROJECT_DIR/realworldbenchmark/ftdc/$TS}"
FETCH_ALL="${FETCH_ALL:-0}"

RUNNER_IP=$(cd "$TF_DIR" && terraform output -raw runner_public_ip)
PROXY="ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i $PEM -W %h:%p ec2-user@$RUNNER_IP"

pull_one() {
  local ip="$1" subdir="$2"
  local out="$DEST/$subdir"
  mkdir -p "$out"
  echo "→ $ip → $out"

  # diagnostic.data is owned by mongod:mongod (mode 700). Use sudo on the remote.
  # tar over ssh streams the tree; faster + handles perms cleanly.
  ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i "$PEM" \
      -o ProxyCommand="$PROXY" ec2-user@"$ip" \
      "sudo tar -C /data/db -cf - diagnostic.data" \
    | tar -xf - -C "$out"

  local n; n=$(find "$out/diagnostic.data" -type f 2>/dev/null | wc -l | tr -d ' ')
  local sz; sz=$(du -sh "$out/diagnostic.data" 2>/dev/null | awk '{print $1}')
  echo "  ${n} files, ${sz}"
}

mkdir -p "$DEST"
if [ "$FETCH_ALL" = "1" ]; then
  echo "Pulling FTDC from all 3 mongo nodes → $DEST"
  pull_one 10.0.0.200 mongo-0
  pull_one 10.0.0.201 mongo-1
  pull_one 10.0.0.202 mongo-2
else
  echo "Pulling FTDC from $PRIMARY → $DEST"
  pull_one "$PRIMARY" .
fi

echo ""
echo "✓ Done. Files in: $DEST"
echo ""
echo "Analysis options:"
echo "  • MongoDB Compass → Performance → diagnostic data viewer. Point at $DEST/[mongo-0/]diagnostic.data"
echo "  • keyhole (https://github.com/simagix/keyhole):"
echo "      brew install simagix/tap/keyhole   # then:"
echo "      keyhole --diag $DEST/diagnostic.data"
echo "  • t2 (MongoDB internal tool) or mtools' mlogfilter for raw inspection."
