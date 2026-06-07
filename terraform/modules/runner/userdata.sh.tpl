#!/bin/bash
set -euo pipefail

# cloud-init runs as root with empty HOME; required for `go install` (uses $HOME/go).
export HOME=/root

# 1. System updates
dnf update -y

# 2. Go + custom k6 with xk6-mongo (stock dnf k6 cannot load k6/x/mongo)
dnf install -y golang git
export PATH="${PATH}:/usr/local/go/bin:$(go env GOPATH)/bin"
go install go.k6.io/xk6/cmd/xk6@latest

K6_VERSION="v0.57.0"
XK6_MONGO="github.com/GhMartingit/xk6-mongo@v1.2.0"
BUILD_DIR="/opt/xk6-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
build_ok=false
for attempt in 1 2 3; do
  if xk6 build "$K6_VERSION" --with "$XK6_MONGO" 2>&1 | tee /var/log/xk6-build.log; then
    build_ok=true
    break
  fi
  echo "xk6 build attempt $attempt failed; retrying in 30s..." >&2
  sleep 30
done
if [ "$build_ok" != true ]; then
  echo "ERROR: xk6 build failed after 3 attempts — see /var/log/xk6-build.log" >&2
  exit 1
fi
if grep -q 'extensions depending on go.k6.io/k6 will not be active' /var/log/xk6-build.log; then
  echo "ERROR: xk6-mongo not linked (wrong k6 version). Expected $K6_VERSION" >&2
  exit 1
fi
install -m 755 ./k6 /usr/local/bin/k6

TEST_JS="$(mktemp /tmp/k6-mongo-smoke.XXXXXX.js)"
cat >"$TEST_JS" <<'K6TEST'
import xk6_mongo from 'k6/x/mongo';
export const options = { vus: 1, iterations: 1 };
export default function () {}
K6TEST
export K6_AUTO_EXTENSION_RESOLUTION=false
if ! /usr/local/bin/k6 run --quiet "$TEST_JS"; then
  echo "ERROR: /usr/local/bin/k6 does not load k6/x/mongo" >&2
  rm -f "$TEST_JS"
  exit 1
fi
rm -f "$TEST_JS"

GOPATH_BIN="$(go env GOPATH)/bin"
cat > /etc/profile.d/acid-scale.sh <<PROFILE
# ACID@Scale benchmark runner — custom k6 with xk6-mongo
export PATH="/usr/local/bin:\${PATH}:${GOPATH_BIN}"
export K6_BIN=/usr/local/bin/k6
export K6_AUTO_EXTENSION_RESOLUTION=false
PROFILE
chmod 644 /etc/profile.d/acid-scale.sh
echo 'K6_AUTO_EXTENSION_RESOLUTION=false' >> /etc/environment

# 3. Python 3.11
dnf install -y python3.11 python3.11-pip
python3.11 -m pip install "pymongo[srv]>=4.7" faker tqdm

# 4. mongosh
cat > /etc/yum.repos.d/mongodb-org-8.0.repo <<'REPO'
[mongodb-org-8.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/8.0/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
REPO
dnf install -y mongodb-mongosh

# 5. Kernel tuning
cat >> /etc/sysctl.conf <<'SYSCTL'
fs.file-max = 2097152
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 1024 65535
SYSCTL
sysctl -p

# 6. ulimits
cat >> /etc/security/limits.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
LIMITS

touch /var/log/acid-scale-runner-ready.log
