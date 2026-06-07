#!/usr/bin/env bash
# run_clientbulk.sh — single RWB client-bulk run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

echo "=== RWB CLIENT-BULK: $SESSIONS sessions / $TARGET_TPS TPS / ${DURATION}s ==="
"$GO_DIR/clientbulk_bin" "$SESSIONS" "$TARGET_TPS" "$DURATION"
