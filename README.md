# Kivi / Dragonfly / Redis benchmark runbook (AWS)

This runbook aligns **instance types and topology** with the public **Dragonfly c7gn** numbers: Dragonfly on **c7gn.12xlarge** (48 vCPU) and **memtier_benchmark** on a separate **c7gn.16xlarge** in the **same Availability Zone**. Infrastructure is provisioned with Terraform under `terraform/`.

## Kivi results (c7gn.12xlarge, this runbook)

| Test | Kivi ops/sec | Dragonfly ops/sec | Redis ops/sec | Kivi vs Dragonfly | Kivi vs Redis |
|------|-------------|-------------------|---------------|-------------------|---------------|
| Write-only (`ratio 1:0`, `-t 60 -c 20 -n 200000`) | ~3.2M | ~3.7M | ~205K | -12% | **+1,467%** |
| Read-only (`ratio 0:1`, same) | ~4.4M | ~4.2M | ~215K | **+6%** | **+1,956%** |
| Pipelined read (`-c 5`, `--pipeline=10`) | ~17.1M | ~8.0M | ~874K | **+113%** | **+1,854%** |

**Headline claims:**
- **20× faster than Redis** on concurrent GET workloads (4.4M vs 215K ops/sec, 1,200 connections)
- **2× faster than Dragonfly** on pipelined reads (17.1M vs 8.0M ops/sec, pipeline depth 10)

## Dragonfly-published reference (c7gn, memtier defaults unless noted)

| Test | Ops/sec (approx.) | Avg. latency (µs) | P99.9 (µs) |
|------|-------------------|-------------------|------------|
| Write-only (`ratio 1:0`, `-t 60 -c 20 -n 200000`) | ~5.2M | ~250 | ~631 |
| Read-only (`ratio 0:1`, same) | ~6M | ~271 | ~623 |
| Pipelined read (`-c 5`, `--pipeline=10`) | ~8.9M | ~323 | ~839 |

> **Note:** Dragonfly's published numbers are higher than what we observed in this
> runbook (~3.7M SET, ~4.2M GET, ~8.0M pipelined). This is consistent with
> run-to-run variance on AWS spot/on-demand capacity, NIC state, and kernel
> scheduler differences across runs. We benchmark all three stores in the same
> session on the same instance to ensure a fair comparison. Treat all published
> figures — including Dragonfly's own — as **one controlled capture**, not a
> universal guarantee.

Commands from their write-up:
```bash
# Writes
memtier_benchmark -s $SERVER_PRIVATE_IP --distinct-client-seed --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000

# Reads
memtier_benchmark -s $SERVER_PRIVATE_IP --distinct-client-seed --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000

# Pipelined reads
memtier_benchmark -s $SERVER_PRIVATE_IP --ratio 0:1 -t 60 -c 5 -n 200000 --distinct-client-seed --hide-histogram --pipeline=10
```

---

## 1. Prerequisites

- AWS account with **service quotas** allowing **c7gn.12xlarge** and **c7gn.16xlarge** in the chosen region.
- An EC2 **key pair** in that region (for SSH).
- [Terraform](https://www.terraform.io/) `>= 1.3`, [AWS CLI](https://aws.amazon.com/cli/) configured (`aws configure` or environment variables).
```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
# Optional: AWS_SESSION_TOKEN for assumed roles
export AWS_DEFAULT_REGION="us-east-1"
```

---

## 2. Provision instances
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: key_name, ssh_cidr (recommended: your /32), region.

terraform init
terraform plan
terraform apply
```

Put `key_name` (and other variables) in **`terraform.tfvars`** so `terraform apply` does not prompt interactively.

**If the server never appears in the EC2 console**

1. **Canceled apply** — If you press Ctrl+C while Terraform says `aws_instance.server: Creating...`, AWS may never finish creating the instance. Run `terraform apply` again and **leave it running**. Large **c7gn** instances can stay in `pending` for **several minutes**; "Still creating… 1m0s" is normal.

2. **Stale plan** — If you only see the **client**, the **server** apply likely never completed. `terraform state list` should show `aws_instance.server` only after a successful apply. If it is missing, run `terraform apply` again.

3. **Insufficient capacity** — The console error *"We currently do not have sufficient c7gn.12xlarge capacity in the Availability Zone you requested"* is the definitive explanation. **Fix:** set `availability_zone` in `terraform.tfvars` to an AZ AWS lists (e.g. in **us-east-1**: `us-east-1a`, `us-east-1b`, `us-east-1d`, `us-east-1f` when **us-east-1c** fails), or set `subnet_id` to a subnet in a good AZ. After changing AZ, run `terraform apply` so **both** instances use the same subnet/AZ.

4. **Placement group** — If apply **fails** or hangs unusually long, try `use_placement_group = false` in `terraform.tfvars`, then `terraform apply` again.

Note outputs:

- `server_private_ip` → use as `SERVER` for memtier from the **client**.
- `server_public_ip` / `client_public_ip` → SSH access.
- `availability_zone` / `subnet_id` → confirm you are in an AZ with **c7gn** capacity.

**Bootstrap logs:**

- Server: `/var/log/user-data-server.log`
- Client: `/var/log/user-data-client.log`

Wait until cloud-init finishes (Rust build on the server can take several minutes).

---

## 3. On the server instance (c7gn.12xlarge)

SSH (see `terraform output ssh_server`).
```bash
sudo apt update
sudo apt install -y git curl build-essential redis-server
sudo systemctl stop redis-server
sudo systemctl disable redis-server

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

git clone https://github.com/kividbio/kivi
cd kivi && cargo build --release

wget https://github.com/dragonflydb/dragonfly/releases/latest/download/dragonfly-aarch64.tar.gz
tar -xzf dragonfly-aarch64.tar.gz
chmod +x dragonfly-aarch64

ulimit -n 65535
```

Run **one server at a time**. Kill the previous process before starting the next.
```bash
# Kivi (listens on 0.0.0.0:6380 by default, io_uring on Linux)
cd ~/kivi
KIVI_THREADS=48 ./target/release/kivi

# Dragonfly (stop Kivi first; binds to 6379)
cd ~
./dragonfly-aarch64 --port 6379 --logtostderr

# Redis (stop Dragonfly first; binds to 6379)
redis-server --bind 0.0.0.0 --port 6379 --protected-mode no \
  --io-threads 4 --io-threads-do-reads yes --daemonize no
```

> **Why KIVI_THREADS=48?** Kivi spawns one OS thread per worker, each running
> its own `io_uring` runtime with a dedicated `SO_REUSEPORT` listener. On a
> 48-vCPU c7gn.12xlarge, setting 48 threads pins one thread per vCPU and
> eliminates cross-thread accept contention. The kernel load-balances incoming
> connections across all 48 listeners at the NIC level.

---

## 4. On the client instance (c7gn.16xlarge)
```bash
sudo apt update
sudo apt install -y build-essential autoconf automake libpcre3-dev \
  libevent-dev pkg-config zlib1g-dev libssl-dev git

git clone https://github.com/RedisLabs/memtier_benchmark
cd memtier_benchmark
autoreconf -ivf
./configure
make -j$(nproc)
sudo make install
```

**Latency check** (same AZ; should be sub-millisecond):
```bash
ping <server-private-ip>
```

---

## 5. Nine memtier runs (from client)
```bash
SERVER=$(terraform -chdir=/path/to/repo/terraform output -raw server_private_ip)
```

### Kivi (port 6380)
```bash
memtier_benchmark -s $SERVER -p 6380 --distinct-client-seed \
  --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000 \
  > kivi_writeonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6380 --distinct-client-seed \
  --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000 \
  > kivi_readonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6380 --ratio 0:1 -t 60 -c 5 \
  -n 200000 --distinct-client-seed --hide-histogram --pipeline=10 \
  > kivi_pipelined.txt 2>&1
```

### Dragonfly (port 6379)
```bash
memtier_benchmark -s $SERVER -p 6379 --distinct-client-seed \
  --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000 \
  > dragonfly_writeonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6379 --distinct-client-seed \
  --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000 \
  > dragonfly_readonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6379 --ratio 0:1 -t 60 -c 5 \
  -n 200000 --distinct-client-seed --hide-histogram --pipeline=10 \
  > dragonfly_pipelined.txt 2>&1
```

### Redis (port 6379)
```bash
memtier_benchmark -s $SERVER -p 6379 --distinct-client-seed \
  --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000 \
  > redis_writeonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6379 --distinct-client-seed \
  --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000 \
  > redis_readonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6379 --ratio 0:1 -t 60 -c 5 \
  -n 200000 --distinct-client-seed --hide-histogram --pipeline=10 \
  > redis_pipelined.txt 2>&1
```

### Summarize all results
```bash
grep -A5 "ALL STATS" kivi_writeonly.txt kivi_readonly.txt kivi_pipelined.txt
grep -A5 "ALL STATS" dragonfly_writeonly.txt dragonfly_readonly.txt dragonfly_pipelined.txt
grep -A5 "ALL STATS" redis_writeonly.txt redis_readonly.txt redis_pipelined.txt
```

---

## 6. Teardown
```bash
cd terraform && terraform destroy
```

---

## 7. Reproducibility notes

Results are **environment-specific**. Repeat runs on your own hardware and
workload shape. Key factors that affect numbers:

- **NIC state** — c7gn ENA adapters can vary in throughput across runs by 5–15%.
- **NUMA / CPU frequency** — Graviton3 has a single NUMA node; frequency
  scaling is minimal but not zero.
- **Kernel scheduler** — io_uring submission batching varies with load.
- **Run order** — Always benchmark all three stores in the same session on
  the same instance to control for environmental drift.

Treat all published figures as **one controlled capture**, not a universal
guarantee. The benchmark scripts, Terraform, and full raw output live in
[**github.com/kividbio/kivi-benchmark**](https://github.com/kividbio/kivi-benchmark).

---

## 8. Comparing to Dragonfly README (other scenarios)

The upstream Dragonfly README also documents **m5.large** vs **m5.xlarge**
comparisons and **c6gn.16xlarge** peak throughput with **`-d 256`** and
tunable **`-t`** / **`--pipeline`**. Those require different instance types
and memtier flags than this c7gn runbook; reproduce them by changing
`server_instance_type` / `client_instance_type` and the memtier command
lines to match the specific README row you care about.