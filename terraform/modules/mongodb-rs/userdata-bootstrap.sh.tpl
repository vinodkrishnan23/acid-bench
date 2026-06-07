#!/bin/bash
# Bootstrap only — used when mongodb_install_via_runner=true (no dnf on this host).
set -euo pipefail

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

if ! blkid /dev/nvme1n1 | grep -q xfs; then
  mkfs.xfs /dev/nvme1n1
fi

mkdir -p /data/db /var/log/mongodb
if ! grep -q '/dev/nvme1n1' /etc/fstab; then
  echo '/dev/nvme1n1 /data/db xfs defaults,noatime 0 0' >> /etc/fstab
fi
mount -a

echo "bootstrap complete - awaiting package install from runner"
