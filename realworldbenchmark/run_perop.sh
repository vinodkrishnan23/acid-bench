#!/usr/bin/env bash
# run_perop.sh — single RWB per-op run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

echo "=== RWB PER-OP: $SESSIONS sessions / $TARGET_TPS TPS / ${DURATION}s ==="
"$GO_DIR/perop_bin" "$SESSIONS" "$TARGET_TPS" "$DURATION"
