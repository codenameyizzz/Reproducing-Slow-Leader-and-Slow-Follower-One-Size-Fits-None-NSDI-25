import os
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns
import glob

# Simulated filenames and delay labels (since user cannot upload)
# You can replace this with actual file reading logic like:
# files = glob.glob("/mnt/data/latency_*ms.log")
# For now, simulate a few files
delay_labels = ["0ms", "1ms", "2ms", "5ms", "10ms", "20ms", "50ms", "100ms"]
latency_data = {}

# Placeholder simulation: replace this block with file reading logic
# Example file content parsing simulation
for label in delay_labels:
    filename = f"./latency_{label}.log"
    try:
        with open(filename, "r") as f:
            lines = f.readlines()
            latencies = [int(line.strip().split(",")[1]) for line in lines if "," in line and line.strip().split(",")[1].isdigit()]
            latency_data[label] = latencies
    except FileNotFoundError:
        continue  # If some files not uploaded, skip

# Plot CDF for each delay config
plt.figure(figsize=(10, 6))
for label, latencies in latency_data.items():
    sorted_lat = np.sort(latencies)
    yvals = np.arange(1, len(sorted_lat) + 1) / float(len(sorted_lat))
    plt.plot(sorted_lat, yvals, label=label)

plt.xlabel("Latency (ms)")
plt.ylabel("CDF")
plt.title("Slow Leader Fault: Latency CDF by Delay Injection")
plt.grid(True, linestyle='--', alpha=0.5)
plt.legend(title="Delay")
plt.tight_layout()

# Show plot to user
# import ace_tools as tools; tools.display_dataframe_to_user("Latency data preview", pd.DataFrame({k: pd.Series(v) for k, v in latency_data.items() if v}))
plt.show()
