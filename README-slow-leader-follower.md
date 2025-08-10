# Slow Leader & Slow Follower Reproduction Guide

This document merges and de-duplicates your **Slow Leader** and **Slow Follower** READMEs
into one authoritative guide. It keeps all the important steps (setup, run, logs, and debug)
without redundancy, and standardizes command naming, file paths, and terminology.

> Works with a 3-node `etcd` cluster (`etcd0`, `etcd1`, `etcd2`) using Docker and Linux NetEm (`tc qdisc netem`).
> Supports **baseline**, **mid-injection**, and **full-run** injections for both **delay** and **loss** (slow follower only).
> Compatible with your existing scripts: `run_slowleader.sh`, `run_slowfollower.sh`, and `sweep_slowfollower.sh`.

---

## Table of Contents

1. [Machine Requirements](#machine-requirements)
2. [Dependencies Installation](#dependencies-installation)
3. [Project Layout](#project-layout)
4. [Start the Cluster](#start-the-cluster)
5. [Verify Health &amp; Find the Leader](#verify-health--find-the-leader)
6. [How to Re-Run: Baseline](#how-to-re-run-baseline)
7. [How to Re-Run: Slow Leader (Mid-Injection)](#how-to-re-run-slow-leader-mid-injection)
8. [How to Re-Run: Slow Follower (Delay/Loss, Full &amp; Mid)](#how-to-re-run-slow-follower-delayloss-full--mid)
9. [Outputs &amp; Folder Structure](#outputs--folder-structure)
10. [Copy Results to Windows (optional)](#copy-results-to-windows-optional)
11. [Plotting Quick-Start (optional)](#plotting-quick-start-optional)
12. [Troubleshooting](#troubleshooting)

---

## Machine Requirements

- **OS**: Linux x86_64 (Ubuntu 20.04/22.04 tested; WSL2 works for client/plotting, but prefer Linux for running experiments).
- **CPU**: ≥ 2 cores (4+ recommended for stable parallel load).
- **RAM**: ≥ 4 GB (8 GB recommended).
- **Disk**: ≥ 5–10 GB free.
- **Network**: Internet access to pull images.
- **Privileges**: User in `docker` group or use `sudo` with Docker.
- **Time source**: GNU `date` with millisecond precision (`%3N`). On macOS, prefer Linux VM or install `coreutils` (use `gdate`).

---

## Dependencies Installation

### Docker Engine & Compose plugin (Ubuntu)

```bash
# Prereqs
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Docker GPG & repo
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Optional: run docker without sudo (re-login required)
sudo usermod -aG docker $USER
```

### Helper Tools (host)

```bash
sudo apt-get install -y jq coreutils tmux
```

### Optional (Plotting)

```bash
python3 -m pip install --user pandas matplotlib
```

### (Optional) Pre-pull Docker Images

```bash
docker pull quay.io/coreos/etcd:latest
docker pull nicolaka/netshoot:latest
```

---

## Project Layout

Use a workspace directory (e.g., `~/cassandra-demo/`) with:

```
cassandra-demo/
├─ docker-compose-etcd.yml      # or docker-compose.yml, 3-node etcd
├─ run_slowleader.sh            # slow leader single-run (mid injection)
├─ run_slowfollower.sh          # slow follower single-run (delay/loss; full/mid)
├─ sweep_slowfollower.sh        # batch sweep (optional)
└─ etcd_bench_results/          # outputs (auto-created)
```

> **Container names must be** `etcd0`, `etcd1`, `etcd2` — scripts rely on these.
> If your compose file is named differently, use `-f <file>` in commands below.

---

## Start the Cluster

```bash
# Start (choose one based on your filename)
docker compose -f docker-compose-etcd.yml up -d
# or
docker compose up -d

# Confirm up
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Wait ~5–15 seconds for stabilization.

---

## Verify Health & Find the Leader

```bash
# Endpoint health
docker exec etcd1 /usr/local/bin/etcdctl \
  --endpoints="http://etcd0:2379,http://etcd1:2379,http://etcd2:2379" \
  endpoint status -w table

# (Optional) Leader discovery (maps member IDs)
docker exec etcd1 /usr/local/bin/etcdctl \
  --endpoints="http://etcd0:2379,http://etcd1:2379,http://etcd2:2379" \
  endpoint status -w json | jq '.[].Status | {{Endpoint, Leader, ID}}'
```

> If you want to inject on the **actual leader**, set `LEADER="etcdX"` in `run_slowleader.sh`
> accordingly (default often `etcd0`).

---

## How to Re-Run: Baseline

Run a no-fault baseline to establish reference throughput/latency.

```bash
# Slow leader baseline (no injection)
./run_slowleader.sh 0ms 0 baseline none 0

# Slow follower baseline (no injection)
./run_slowfollower.sh 0ms 120 baseline delay 0
```

Each run creates a timestamped folder under `etcd_bench_results/` with logs and summaries.

---

## How to Re-Run: Slow Leader (Mid-Injection)

**Purpose:** Degrade the **leader** using `tc netem` (delay) partway through the run.

**Usage**

```bash
./run_slowleader.sh <delay_value> <duration_seconds> <label> <fault_type> <inject_at_seconds>

# Example: inject 20ms at t=30s (mid), label run, duration informational
./run_slowleader.sh 20ms 60 slowleader_mid20ms delay 30
```

**Notes**

- The script launches ~10k PUTs from `etcd1` against all endpoints.
- At `inject_at_seconds`, it applies `tc qdisc netem delay <delay_value>` **inside the leader** container (via `nicolaka/netshoot`).
- On completion, it removes the qdisc and writes results.

**Known Limitation — Duration**
Some versions leave the delay in place until workload ends. To enforce a strict window, add:

```bash
(
  sleep "$DURATION"
  docker run --rm --privileged --net container:"$LEADER" nicolaka/netshoot \
    sh -c "tc qdisc del dev eth0 root 2>/dev/null || true"
) &
```

Place it **immediately after** you add the `tc netem` rule.

---

## How to Re-Run: Slow Follower (Delay/Loss, Full & Mid)

**Purpose:** Degrade **one follower** (default `etcd1`) using **delay** or **packet loss**.
This models sticky gRPC behavior where clients keep using a slow follower.

**Usage**

```bash
./run_slowfollower.sh <fault_value> <duration_s> <label> <fault_type> <inject_at_s>

# Examples
./run_slowfollower.sh 100ms 120 delay100_mid delay 60   # delay, injected at 60s
./run_slowfollower.sh 20%   120 loss20_full  loss  0    # packet loss from start
```

**Batch Sweep (optional)**

```bash
chmod +x sweep_slowfollower.sh
./sweep_slowfollower.sh
```

This typically sweeps `loss` 5–50% and `delay` 10–100ms, both **full** and **mid**.

---

## Outputs & Folder Structure

Each run creates: `etcd_bench_results/<STAMP>_<LABEL>/`

**Common files**

- `latency.log` — CSV: `end_ms,latency_ms` (or `start_ms,latency_ms` in some variants)
- `summary.txt` — Percentiles (p50/p95/p99/max), total ops, elapsed ms, throughput
- `metadata.txt` — Parameters (endpoints, mode, inject_at, label, leader/target)

**Slow follower (additional)**

- `throughput.csv` — `second,ops` (per-second aggregation)
- `anomaly.log` — `end_ms,PUT_FAILED` (if any put failures were caught)

> If a file is missing (e.g., `throughput.csv` on leader runs), it’s expected — scripts differ.
> You can standardize both scripts later if you want uniform outputs.

---

## Copy Results to Windows (optional)

```powershell
scp -i "C:\path\to\key.pem" -r ^
  cc@YOUR_HOST:~/cassandra-demo/etcd_bench_results ^
  C:\Newer-fault
```

Adjust source/destination paths as needed.

---

## Plotting Quick-Start (optional)

Example for throughput (slow follower sweeps) — run locally where results are copied.

```python
import os, re, pandas as pd, matplotlib.pyplot as plt

BASE = r"C:\Newer-fault"
patterns = [
    (r".*_loss(\d+)_full$",  "Loss %",   "Loss Full"),
    (r".*_loss(\d+)_mid$",   "Loss %",   "Loss Mid"),
    (r".*_delay(\d+)_full$", "Delay ms", "Delay Full"),
    (r".*_delay(\d+)_mid$",  "Delay ms", "Delay Mid"),
]

for pat, xlabel, title in patterns:
    runs = []
    for d in os.listdir(BASE):
        if not re.match(pat, d): continue
        fp = os.path.join(BASE, d, "throughput.csv")
        if os.path.isfile(fp):
            df = pd.read_csv(fp).sort_values("second")
            runs.append((d, df))
    if not runs: 
        print(f"[WARN] no matches for {title}")
        continue
    plt.figure(figsize=(12,6))
    for name, df in runs:
        plt.plot(df["second"], df["ops"], label=name)
    plt.title(title); plt.xlabel("Second"); plt.ylabel("ops/sec"); plt.grid(True, linestyle=":")
    plt.legend(loc="center left", bbox_to_anchor=(1,0.5))
    plt.tight_layout()
    plt.show()
```

For latency time-series or CDFs, parse `latency.log` and group/bucket by time.

---

## Troubleshooting

- **Cluster not healthy / no leader**: wait 10–20s; re-check `endpoint status`.
- **Compose fails with “port is already allocated”**: `docker compose down -v` then `up -d` again.
- **NetEm not applied**: show rules with`docker run --rm --privileged --net container:etcd1 nicolaka/netshoot tc qdisc show dev eth0`
- **Remove NetEm manually**:`docker run --rm --privileged --net container:etcd1 nicolaka/netshoot tc qdisc del dev eth0 root 2>/dev/null || true`
- **Very slow runs**: large loss (≥30%) or delay (≥80–100ms) can stretch duration; this is expected.
- **Different file names**: use `docker compose -f <your-compose-file> ...` if your compose file isn’t `docker-compose-etcd.yml`.
- **Duration not respected**: add the background timer snippet right after `tc add` (see Slow Leader notes).

---

### One-Line Recap

```bash
# Up cluster
docker compose -f docker-compose-etcd.yml up -d

# Baselines
./run_slowleader.sh 0ms 0 baseline none 0
./run_slowfollower.sh 0ms 120 baseline delay 0

# Mid injections
./run_slowleader.sh 20ms 60 slowleader_mid20ms delay 30
./run_slowfollower.sh 100ms 120 delay100_mid delay 60
./run_slowfollower.sh 20%   120 loss20_mid  loss  60

# Down cluster
docker compose -f docker-compose-etcd.yml down -v
```

---
