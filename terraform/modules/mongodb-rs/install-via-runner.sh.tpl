#!/bin/bash
# Executed on the machine running terraform (laptop/CI). Uses runner as SSH jump to DB nodes.
set -euo pipefail

KEY="${private_key_path}"
RUNNER="${runner_public_ip}"
ADMIN_USER="${mongo_admin_user}"
ADMIN_PASS="${mongo_admin_password}"
SSH_BASE=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
MONGO_IPS=(${mongo_private_ips})

RPMDIR=/tmp/mongo-enterprise-rpms

echo "==> Download MongoDB Enterprise RPMs on runner"
ssh "$${SSH_BASE[@]}" "ec2-user@$RUNNER" bash -s <<'REMOTE'
set -euo pipefail
RPMDIR=/tmp/mongo-enterprise-rpms
mkdir -p "$RPMDIR"
cat > /etc/yum.repos.d/mongodb-enterprise-8.0.repo <<'REPO'
[mongodb-enterprise-8.0]
name=MongoDB Enterprise 8.0
baseurl=https://repo.mongodb.com/yum/amazon/2023/mongodb-enterprise/8.0/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
REPO
dnf install -y dnf-plugins-core
dnf download --destdir "$RPMDIR" --resolve \
  mongodb-enterprise-8.0.23 \
  mongodb-enterprise-server-8.0.23
REMOTE

idx=0
for ip in "$${MONGO_IPS[@]}"; do
  echo "==> Node $ip: copy RPMs and install"
  ssh "$${SSH_BASE[@]}" "ec2-user@$RUNNER" "tar -C $RPMDIR -czf - ." | \
    ssh "$${SSH_BASE[@]}" -o ProxyJump="ec2-user@$RUNNER" "ec2-user@$ip" \
      "mkdir -p /tmp/rpms && tar -C /tmp/rpms -xzf -"

  ssh "$${SSH_BASE[@]}" -o ProxyJump="ec2-user@$RUNNER" "ec2-user@$ip" \
    "sudo dnf install -y /tmp/rpms/*.rpm"

  ssh "$${SSH_BASE[@]}" -o ProxyJump="ec2-user@$RUNNER" "ec2-user@$ip" "sudo tee /etc/mongod.conf" <<'CONF'
storage:
  dbPath: /data/db
  wiredTiger:
    engineConfig:
      cacheSizeGB: 32
      journalCompressor: snappy
replication:
  replSetName: rs0
net:
  port: 27017
  bindIp: 0.0.0.0
  maxIncomingConnections: 20000
operationProfiling:
  mode: slowOp
  slowOpThresholdMs: 10
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
processManagement:
  fork: false
CONF

  ssh "$${SSH_BASE[@]}" -o ProxyJump="ec2-user@$RUNNER" "ec2-user@$ip" \
    "sudo chown -R mongod:mongod /data/db /var/log/mongodb && sudo systemctl enable mongod && sudo systemctl start mongod"

  if [ "$idx" -eq 0 ]; then
    sleep 15
    ssh "$${SSH_BASE[@]}" -o ProxyJump="ec2-user@$RUNNER" "ec2-user@$ip" \
      "mongosh --quiet" <<EOSQL
try {
  db.getSiblingDB('admin').getUser('${mongo_admin_user}');
} catch (e) {
  db.getSiblingDB('admin').createUser({
    user: '${mongo_admin_user}',
    pwd: '${mongo_admin_password}',
    roles: [{ role: 'root', db: 'admin' }]
  });
}
EOSQL
  fi
  idx=$((idx + 1))
done

echo ""
echo "MongoDB install via runner complete."
echo "NEXT (manual): from the runner, run rs.initiate() — see:"
echo "  terraform output rs_initiate_mongosh_eval"
echo "  or: bash ~/ACID@Scale/scripts/rs_initiate.sh (after copying the repo to the runner)"
