
# Slow Follower Fault Experiment — README

This guide documents **end‑to‑end setup, execution, and analysis** for reproducing the
*Slow Follower (sticky gRPC)* anomaly on a 3‑node `etcd` cluster using Docker and
Linux NetEm. It includes machine requirements, dependency installation, commands,
the exact scripts we used, and debugging tips.

> Fault modeled (from the paper): **Slow follower** — clients keep sending requests
> to a degraded follower because of *sticky gRPC connections*, causing up to **~68%**
> throughput loss even when the leader is healthy.

---

## 1) Machine Requirements

- **Host OS**: Linux (tested on Ubuntu 22.04). WSL2 works too.
- **CPU/RAM**: 4 vCPU / 8 GB RAM minimum (more is better for parallel sweeps).
- **Disk**: 5–10 GB free.
- **Network**: Internet access to pull images.
- **Docker**: 24+ and **docker compose** plugin.
- **Optional (plotting)**: Python 3.10+ with `pandas` and `matplotlib`.

---

## 2) Install Dependencies

```bash
# Docker + compose plugin (Ubuntu)
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Convenience tools
sudo apt-get install -y tmux jq coreutils

# Optional: Python libs for plotting
python3 -m pip install --user pandas matplotlib
```

Add your user to the docker group (optional):
```bash
sudo usermod -aG docker $USER
# then log out/in or: newgrp docker
```

---

## 3) Project Layout

Assume a working directory like this (we used `cassandra-demo/`):

```
cassandra-demo/
├─ docker-compose-etcd.yml      # 3-node etcd cluster
├─ run_slowfollower.sh          # single-run experiment script
├─ sweep_slowfollower.sh        # batch sweep (loss/delay, full & mid)
├─ etcd_bench_results/          # outputs (created automatically)
└─ (optional plotting scripts)
```

### Example `docker-compose-etcd.yml` (3 nodes)

Your compose file should expose three nodes `etcd0`, `etcd1`, `etcd2` on the same
user-defined network so `etcdctl` can reach `http://etcdX:2379`.

*(Use your existing file; this README assumes it’s already in the repo.)*

Bring it up and verify:
```bash
docker compose -f docker-compose-etcd.yml up -d
docker exec etcd0 etcdctl endpoint health \
  --endpoints="http://etcd0:2379,http://etcd1:2379,http://etcd2:2379"
```

---

## 4) What the Experiment Does

We slow **one follower** (default `etcd1`) using **Linux NetEm** (`tc qdisc netem`),
*from inside its network namespace* via the `nicolaka/netshoot` container. We then
hammer the cluster with `etcdctl put` calls and measure:

- **Per‑op latency** → `latency.log` (`end_ms,latency_ms`)
- **Anomalies** (failed puts) → `anomaly.log` (`end_ms,PUT_FAILED`)
- **Per‑second throughput** → `throughput.csv` (`second,ops`)
- **Run metadata + percentiles** → `summary.txt` & `metadata.txt`

We inject either:
- **Delay** (e.g., `100ms`) or
- **Packet Loss** (e.g., `10%`),

either **from the start** (full) or **mid‑run** (inject at 60 s).

---

## 5) Script We Used (Single Run)

`run_slowfollower.sh` (already in your repo) — **do not change file if you’re reproducing**.
Usage:
```bash
./run_slowfollower.sh <fault_value> <duration_s> <label> <fault_type> <inject_at_s>

# Examples
./run_slowfollower.sh 0ms   120 baseline        delay 0
./run_slowfollower.sh 100ms 120 delay100_mid    delay 60
./run_slowfollower.sh 20%   120 loss20_full     loss  0
./run_slowfollower.sh 10%   120 loss10_mid      loss  60
```

What it does (high level):
- Spawns **10 parallel** `etcdctl put` workers (total 10,000 operations).
- Logs **per‑op** latency with end timestamps.
- Every second, computes **throughput** (ops/sec) and appends to `throughput.csv`.
- At `inject_at_s`, applies `tc qdisc netem` on the follower’s `eth0`:
  ```bash
  docker run --rm --privileged --net container:etcd1 nicolaka/netshoot \
    sh -c "tc qdisc del dev eth0 root 2>/dev/null; \
           tc qdisc add dev eth0 root netem <delay|loss> <value>"
  ```
- After the run, it **removes** the qdisc, crunches **p50/p95/p99**, and writes a summary.
- Results land in `etcd_bench_results/<TIMESTAMP>_<label>/`.

Outputs inside each result folder:
```
latency.log         # end_ms,latency_ms
anomaly.log         # end_ms,PUT_FAILED (if any)
throughput.csv      # second,ops
summary.txt         # percentiles + throughput
metadata.txt        # parameters and derived stats
```

---

## 6) Batch Sweep We Used

`sweep_slowfollower.sh` runs everything **sequentially in one terminal**:

```bash
#!/usr/bin/env bash
set -euo pipefail

DURATION=120
INJECT_MID=60

# Loss 5..50% (step 5), full then mid
for loss in $(seq 5 5 50); do
  ./run_slowfollower.sh ${loss}% $DURATION loss${loss}_full loss 0
  ./run_slowfollower.sh ${loss}% $DURATION loss${loss}_mid  loss $INJECT_MID
done

# Delay 10..100ms (step 10), full then mid
for delay in $(seq 10 10 100); do
  ./run_slowfollower.sh ${delay}ms $DURATION delay${delay}_full delay 0
  ./run_slowfollower.sh ${delay}ms $DURATION delay${delay}_mid  delay $INJECT_MID
done

echo "✔︎ Sweep complete. Results under etcd_bench_results/"
```

Run it:
```bash
chmod +x sweep_slowfollower.sh
./sweep_slowfollower.sh
```

> **Tip (optional, parallel):** you can create a `tmux` session and launch several
> windows to run subsets in parallel if you’re comfortable managing multiple runs.

---

## 7) Copy Results to Windows (one‑liner example)

On your Windows machine (PowerShell / CMD), with your SSH key:

```powershell
scp -i "C:\apendable\yizzz-mj-trace.pem" -r ^
  cc@192.5.86.216:~/cassandra-demo/etcd_bench_results/20250727_195003_baseline ^
  cc@192.5.86.216:~/cassandra-demo/etcd_bench_results/20250727_235547_loss5_full ^
  cc@192.5.86.216:~/cassandra-demo/etcd_bench_results/20250727_235732_loss5_mid ^
  cc@192.5.86.216:~/cassandra-demo/etcd_bench_results/20250728_034348_delay100_full ^
  cc@192.5.86.216:~/cassandra-demo/etcd_bench_results/20250728_034728_delay100_mid ^
  C:\Newer-fault
```

*(Adjust the list of folders to the actual timestamps you produced.)*

---

## 8) Plotting (optional, local Windows/Jupyter)

**Throughput:** one figure per sweep (loss full, loss mid, delay full, delay mid).
Point the base directory to your copied results (e.g., `C:\Newer-fault`).

```python
import os, re, pandas as pd, matplotlib.pyplot as plt
from matplotlib import colormaps as cm

BASE_DIR = r"C:\Newer-fault"
SMOOTH_WINDOW = 5
SWEEPS = [
    (r".*_loss(\d+)_full$",  "Loss %",    "Loss Full: Throughput vs Loss %"),
    (r".*_loss(\d+)_mid$",   "Loss %",    "Loss Mid:  Throughput vs Loss %"),
    (r".*_delay(\d+)_full$", "Delay (ms)", "Delay Full: Throughput vs Delay ms"),
    (r".*_delay(\d+)_mid$",  "Delay (ms)", "Delay Mid:  Throughput vs Delay ms"),
]

def smooth(s, w): return s.rolling(window=w, min_periods=1, center=True).mean()

def load(pattern):
    rx = re.compile(pattern)
    runs = []
    for d in os.listdir(BASE_DIR):
        m = rx.match(d)
        if not m: continue
        p = int(m.group(1))
        fp = os.path.join(BASE_DIR, d, "throughput.csv")
        if not os.path.isfile(fp): continue
        df = pd.read_csv(fp).sort_values("second")
        df["smoothed"] = smooth(df["ops"], SMOOTH_WINDOW)
        runs.append((p, df))
    return sorted(runs, key=lambda x: x[0])

for pat, xlabel, title in SWEEPS:
    sweep = load(pat)
    if not sweep: 
        print(f"[WARN] missing: {pat}")
        continue
    fig, ax = plt.subplots(figsize=(14,6))
    cmap = cm.get_cmap("tab20")
    for i, (param, df) in enumerate(sweep):
        ax.plot(df["second"], df["smoothed"], label=str(param),
                linewidth=2, alpha=0.8, color=cmap(i % cmap.N))
    ax.set_title(title, fontsize=18)
    ax.set_xlabel("Time (seconds)"); ax.set_ylabel("Throughput (ops/sec)")
    ax.grid(linestyle=":")
    ax.legend(title=xlabel, loc="center left", bbox_to_anchor=(1,0.5))
    fig.tight_layout(rect=[0,0,0.85,1])
    plt.show()
```

**Latency:** bucket by 5 s and plot median over time for the same sweeps by reading
`latency.log` (`end_ms,latency_ms`). (You already have a working snippet—reuse it.)

---

## 9) Interpreting Results (what you should see)

- **Baseline**: ~90–105 ops/sec steady (your host may vary).
- **Delay (full)**: lower steady‑state throughput; larger delay ⇒ lower plateau.
- **Delay (mid)**: sharp drop **after 60 s** to a lower plateau that tracks the delay.
- **Loss (full/mid)**: spikier throughput; higher loss ⇒ more frequent dips/stalls.
- **Sticky gRPC**: because clients keep their existing TCP/gRPC channels, **they keep
  hitting the degraded follower**, causing long‑lived throughput impact even though the
  leader is fine — mirroring the paper’s observation.

---

## 10) Debugging & Tips

- **Verify cluster health**:
  ```bash
  docker exec etcd0 etcdctl endpoint health \
    --endpoints="http://etcd0:2379,http://etcd1:2379,http://etcd2:2379"
  ```
- **Check NetEm applied**:
  ```bash
  docker run --rm --privileged --net container:etcd1 nicolaka/netshoot tc qdisc show dev eth0
  ```
- **Clear NetEm manually**:
  ```bash
  docker run --rm --privileged --net container:etcd1 nicolaka/netshoot \
    tc qdisc del dev eth0 root 2>/dev/null || true
  ```
- **Permissions**: ensure your user can run Docker without `sudo` or prefix commands with `sudo`.
- **Slow/long runs**: larger loss (≥30%) or large delays (≥80ms) can make runs take much longer — expected.
- **If compose fails**: `docker compose -f docker-compose-etcd.yml down && docker compose -f docker-compose-etcd.yml up -d`
- **Logs**: `docker logs etcd0` (and 1/2) to check raft elections, timeouts, etc.

---

## 11) One‑Line Recap (Minimal)

```bash
# bring up etcd
docker compose -f docker-compose-etcd.yml up -d

# run a single experiment (e.g., 100ms delay injected at 60s on follower etcd1)
./run_slowfollower.sh 100ms 120 delay100_mid delay 60

# sweep everything (loss 5–50%, delay 10–100ms; full & mid)
./sweep_slowfollower.sh

# copy results to Windows
scp -i "C:\key.pem" -r cc@HOST:~/cassandra-demo/etcd_bench_results C:\Newer-fault
```

---

**That’s it.** Rerun the sweeps, copy results, and use the plotting snippets to reproduce
the figures for your slides.
