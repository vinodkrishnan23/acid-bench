#!/usr/bin/env bash
# 00_install_prereqs.sh — one-time setup on a fresh Amazon Linux 2023 EC2 instance.
# Installs: python3.11 + pip + pymongo, mongosh, Go toolchain, build basics.
# Safe to re-run (idempotent-ish). Run as the ec2-user (uses sudo where needed).
set -euo pipefail

echo "=== 1. System packages ==="
sudo dnf -y update
sudo dnf -y install gcc gcc-c++ make git tar gzip which curl

echo "=== 2. Python 3.11 + pip ==="
sudo dnf -y install python3.11 python3.11-pip
# pymongo into the 3.11 site-packages
python3.11 -m pip install --upgrade pip
python3.11 -m pip install "pymongo>=4.17"
echo "python3.11 -> $(python3.11 --version)"
python3.11 -c "import pymongo; print('pymongo', pymongo.__version__)"

echo "=== 3. mongosh (MongoDB Shell) ==="
# Add the MongoDB yum repo for mongosh
sudo tee /etc/yum.repos.d/mongodb-org-8.0.repo >/dev/null <<'REPO'
[mongodb-org-8.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/8.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
REPO
sudo dnf -y install mongodb-mongosh
echo "mongosh -> $(mongosh --version)"

echo "=== 4. Go toolchain ==="
GO_VERSION="${GO_VERSION:-1.25.10}"
if ! command -v go >/dev/null 2>&1; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tgz
  # add to PATH for current + future shells
  if ! grep -q '/usr/local/go/bin' "$HOME/.bashrc"; then
    echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> "$HOME/.bashrc"
  fi
  export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
fi
echo "go -> $(go version)"

echo "=== 5. Verify egress to Go module proxy ==="
curl -sS -o /dev/null -w "proxy.golang.org: %{http_code}\n" https://proxy.golang.org/ || true

echo ""
echo "=== DONE. Open a new shell (or 'source ~/.bashrc') so 'go' is on PATH. ==="
echo "Next: export your MONGO_URI, then run ./01_init_project.sh"
