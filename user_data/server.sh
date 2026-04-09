#!/bin/bash
# Benchmark server (c7gn.12xlarge class): installs tooling only — no Redis/Dragonfly/Kivi processes.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee /var/log/user-data-server.log) 2>&1

apt-get update -y
apt-get install -y git curl wget build-essential redis-server

systemctl stop redis-server || true
systemctl disable redis-server || true

cat >> /etc/security/limits.conf << 'LIMITS'
* soft nofile 65535
* hard nofile 65535
LIMITS

# Optional: helps many concurrent benchmark connections
sysctl -w net.core.somaxconn=65535 || true
grep -q '^net.core.somaxconn' /etc/sysctl.conf || echo 'net.core.somaxconn = 65535' >> /etc/sysctl.conf

sudo -u ubuntu -H bash << 'EOSU'
set -euo pipefail
cd /home/ubuntu
if [[ ! -d /home/ubuntu/.cargo ]]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source /home/ubuntu/.cargo/env
if [[ ! -d /home/ubuntu/kivi ]]; then
  git clone https://github.com/kividbio/kivi
fi
cd /home/ubuntu/kivi
git pull --ff-only || true
cargo build --release
cd /home/ubuntu
DF_URL="https://github.com/dragonflydb/dragonfly/releases/latest/download/dragonfly-aarch64.tar.gz"
if [[ ! -x /home/ubuntu/dragonfly-aarch64 ]]; then
  wget -q "$DF_URL" -O dragonfly-aarch64.tar.gz
  tar -xzf dragonfly-aarch64.tar.gz
  chmod +x dragonfly-aarch64
fi
EOSU

echo "Server user-data finished. Kivi build + Dragonfly binary ready under /home/ubuntu."
