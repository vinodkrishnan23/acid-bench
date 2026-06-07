#!/usr/bin/env bash
# restore_schema.sh — revert the schema generators to their pre-FSS state.
# Restores 01_init_project.sh, 02_seed.sh, 03_build_go.sh from scripts/.backup/.
# After running this, re-run ./02_seed.sh && ./03_build_go.sh on the runner to rebuild
# with the old (acid_bench / int _id / numeric merch buckets) schema.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/.backup"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: $BACKUP_DIR does not exist — nothing to restore." >&2
  exit 1
fi

for f in 01_init_project.sh 02_seed.sh 03_build_go.sh; do
  if [ ! -f "$BACKUP_DIR/$f" ]; then
    echo "ERROR: missing $BACKUP_DIR/$f — cannot complete restore." >&2
    exit 1
  fi
done

echo "Restoring from $BACKUP_DIR/ →"
for f in 01_init_project.sh 02_seed.sh 03_build_go.sh; do
  cp -p "$BACKUP_DIR/$f" "$SCRIPT_DIR/$f"
  echo "  ✓ $f"
done

echo ""
echo "Done. Schema generators reverted to pre-FSS state."
echo "Next steps:"
echo "  1. ./sync_to_runner.sh"
echo "  2. On runner: ./01_init_project.sh && ./02_seed.sh && ./03_build_go.sh"
