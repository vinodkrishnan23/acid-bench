#!/bin/bash
set -euo pipefail

# 1. Wait for EBS data volume
for i in $(seq 1 60); do
  if [ -b /dev/nvme1n1 ]; then
    break
  fi
  sleep 5
done
if [ ! -b /dev/nvme1n1 ]; then
  echo "ERROR: /dev/nvme1n1 not found" >&2
  exit 1
fi

# 2. Format with XFS if needed
if ! blkid /dev/nvme1n1 | grep -q xfs; then
  mkfs.xfs /dev/nvme1n1
fi

# 3. Mount at /data/db
mkdir -p /data/db
if ! grep -q '/dev/nvme1n1' /etc/fstab; then
  echo '/dev/nvme1n1 /data/db xfs defaults,noatime 0 0' >> /etc/fstab
fi
mount -a

# 4. Log directory
mkdir -p /var/log/mongodb

# 5. MongoDB Enterprise 8.3 yum repo (rapid release; latest GA as of upgrade)
cat > /etc/yum.repos.d/mongodb-enterprise-8.3.repo <<'REPO'
[mongodb-enterprise-8.3]
name=MongoDB Enterprise 8.3
baseurl=https://repo.mongodb.com/yum/amazon/2023/mongodb-enterprise/8.3/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
REPO

# 6. Install Enterprise server 8.3.2
dnf install -y mongodb-enterprise-8.3.2 mongodb-enterprise-server-8.3.2

# mongosh (latest is version-independent of the server; pull from 8.3 org repo for consistency)
cat > /etc/yum.repos.d/mongodb-org-8.3.repo <<'MONGOSHREPO'
[mongodb-org-8.3]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/8.3/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
MONGOSHREPO
dnf install -y mongodb-mongosh

# 7. mongod.conf
cat > /etc/mongod.conf <<'CONF'
storage:
  dbPath: /data/db
  wiredTiger:
    engineConfig:
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

chown -R mongod:mongod /data/db /var/log/mongodb

# 8. Start mongod
systemctl enable mongod
systemctl start mongod

# 9. Node 0 only: create admin user (rs.initiate is manual — see README / terraform output)
if [ "${is_init_node}" = "true" ]; then
  for i in $(seq 1 60); do
    if mongosh --quiet --eval 'db.adminCommand({ ping: 1 })' 2>/dev/null; then
      break
    fi
    sleep 5
  done

  mongosh --quiet <<EOSQL
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
