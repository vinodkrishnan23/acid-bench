#!/usr/bin/env bash
# run_clientbulk.sh — single run of the client-level bulkWrite (MongoDB 8.0) ACID harness.
# Customize the 3 values inline:
#   SESSIONS=2000 TARGET_TPS=4000 DURATION=120 ./run_clientbulk.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

echo "=== GO CLIENT-BULK: $SESSIONS sessions / $TARGET_TPS TPS / ${DURATION}s ==="
"$GO_DIR/clientbulk_bin" "$SESSIONS" "$TARGET_TPS" "$DURATION"
