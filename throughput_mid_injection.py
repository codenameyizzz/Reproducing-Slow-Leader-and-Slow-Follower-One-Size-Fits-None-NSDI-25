import pandas as pd
import matplotlib.pyplot as plt
import glob
import os

# === Konfigurasi ===
log_files = sorted(glob.glob("latency_x*ms.log"))  # Ambil semua file log sesuai pattern
fault_start = 40   # detik (injeksi dimulai)
colors = plt.cm.tab10.colors  # Palet warna otomatis

plt.figure(figsize=(12, 6))

# === Load setiap file dan plot ===
for i, filepath in enumerate(log_files):
    label = os.path.splitext(os.path.basename(filepath))[0].replace("latency_", "")
    timestamps = []
    
    with open(filepath, "r") as f:
        for line in f:
            if "," not in line: 
                continue
            ts = line.strip().split(",")[0]
            if ts.isdigit():
                timestamps.append(int(ts) // 1000)
    
    if not timestamps:
        continue

    # Hitung throughput per detik
    df = pd.Series(timestamps).value_counts().sort_index()
    full_range = pd.Series(0, index=range(df.index.min(), df.index.max() + 1))
    full_range.update(df)
    throughput = full_range.rolling(window=3, center=True).mean()
    
    # Plot garis throughput
    plt.plot(throughput.index - throughput.index.min(),
             throughput.values,
             label=label,
             color=colors[i % len(colors)],
             linewidth=1.5)

# === Garis vertikal Fault Start (sama untuk semua) ===
plt.axvline(fault_start, color="orange", linestyle="--", linewidth=1.5, label="Fault Start")

# === Labeling ===
plt.title("Slow Leader Mid Injection: Throughput vs Time", fontsize=14)
plt.xlabel("Time (seconds)")
plt.ylabel("Throughput (ops/sec)")
plt.legend(title="Delay Config")
plt.grid(True, linestyle="--", alpha=0.5)
plt.tight_layout()

plt.show()
