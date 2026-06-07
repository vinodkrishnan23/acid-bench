#!/usr/bin/env bash
# sync_to_runner.sh — rsync this project to the benchmark runner.
# Excludes terraform/, .git/, .DS_Store, .claude/, and anything matched by .gitignore.
#
# Usage:
#   ./sync_to_runner.sh                          # runner IP from `terraform output`
#   RUNNER_IP=1.2.3.4 ./sync_to_runner.sh        # override IP
#   PEM=/path/to/key.pem ./sync_to_runner.sh     # override key
#   REMOTE_DIR=/home/ec2-user/foo ./sync_to_runner.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$PROJECT_DIR/terraform"

: "${PEM:=$HOME/.ssh/your-key.pem}"
: "${REMOTE_USER:=ec2-user}"
: "${REMOTE_DIR:=/home/ec2-user/ACID}"
: "${RUNNER_IP:=$(cd "$TF_DIR" && terraform output -raw runner_public_ip)}"

SSH_OPTS="-i $PEM -o StrictHostKeyChecking=no"

echo "→ $REMOTE_USER@$RUNNER_IP:$REMOTE_DIR/"

ssh $SSH_OPTS "$REMOTE_USER@$RUNNER_IP" "mkdir -p $REMOTE_DIR"

rsync -avz \
  -e "ssh $SSH_OPTS" \
  --exclude='terraform/' \
  --exclude='.git/' \
  --exclude='.DS_Store' \
  --exclude='.claude/' \
  --filter=':- .gitignore' \
  "$PROJECT_DIR/" \
  "$REMOTE_USER@$RUNNER_IP:$REMOTE_DIR/"
