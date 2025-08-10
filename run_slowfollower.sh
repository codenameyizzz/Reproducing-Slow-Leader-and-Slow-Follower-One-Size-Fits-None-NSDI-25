#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 5 ]; then
  cat <<EOF
Usage: $0 <fault_value> <duration_seconds> <label> <fault_type> <inject_at>
Example: $0 100ms 120 slowfollower_mid delay 60
EOF
  exit 1
fi

FAULT_VAL="$1"         # e.g. "100ms" or "10%"
DURATION="$2"          # total seconds to run
LABEL="$3"             # descriptive label
MODE="$4"              # "delay" or "loss"
INJECT_AT="$5"         # seconds into run to start the fault

FOLLOWER="etcd1"       # slow this follower
BENCH_NODE="etcd1"     # send puts from etcd1 (sticky gRPC)
ENDPOINTS="http://etcd0:2379,http://etcd1:2379,http://etcd2:2379"

OUTDIR="etcd_bench_results/$(date +%Y%m%d_%H%M%S)_${LABEL}"
mkdir -p "$OUTDIR"

LATLOG="$OUTDIR/latency.log"         # end_ms,latency_ms
ANOMLOG="$OUTDIR/anomaly.log"        # end_ms,PUT_FAILED
THRUPUT_CSV="$OUTDIR/throughput.csv" # second,ops/sec

echo "[INFO] Label           : $LABEL"
echo "[INFO] Fault Mode/Value : $MODE $FAULT_VAL"
echo "[INFO] Duration         : ${DURATION}s"
echo "[INFO] Inject at        : ${INJECT_AT}s"
echo "[INFO] Target follower  : $FOLLOWER"
echo "[INFO] Output dir       : $OUTDIR"

TOTAL=10000
PAR=10

# clear logs
: > "$LATLOG"
: > "$ANOMLOG"
echo "second,ops" > "$THRUPUT_CSV"

# ------------------------------------------------------------------------------
# 1) Launch the benchmark in the background, logging timestamp & latency
START_MS=$(date +%s%3N)
echo "[INFO] Launching $TOTAL puts ($PAR parallel) via $BENCH_NODE ..."
seq 1 "$TOTAL" | xargs -P"$PAR" -n1 bash -c '
  S=$(date +%s%3N)
  if ! docker exec -e ETCDCTL_API=3 '"$BENCH_NODE"' \
       etcdctl --endpoints="'"$ENDPOINTS"'" put key{} value{} >/dev/null 2>&1
  then
    E=$(date +%s%3N)
    echo "$E,PUT_FAILED" >> '"$ANOMLOG"'
  else
    E=$(date +%s%3N)
    echo "$E,$((E-S))" >> '"$LATLOG"'
  fi
' _ {} &
BENCH_PID=$!

# ------------------------------------------------------------------------------
# 2) Wait 1s then spawn a 1 s throughput monitor
sleep 1
echo "[INFO] Starting throughput monitor..."
(
  elapsed=0
  prev_count=0
  while kill -0 "$BENCH_PID" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed+1))
    total_lines=$(wc -l < "$LATLOG")
    ops=$(( total_lines - prev_count ))
    echo "$elapsed,$ops" >> "$THRUPUT_CSV"
    prev_count=$total_lines
  done
) &
MON_PID=$!

# ------------------------------------------------------------------------------
# 3) Wait for injection time, then apply NetEm on follower
sleep "$INJECT_AT"
echo "[INFO] Injecting $MODE $FAULT_VAL on $FOLLOWER at ${INJECT_AT}s..."
docker run --rm --privileged --net container:"$FOLLOWER" nicolaka/netshoot \
  sh -c "tc qdisc del dev eth0 root 2>/dev/null; tc qdisc add dev eth0 root netem $MODE $FAULT_VAL"

# ------------------------------------------------------------------------------
# 4) Wait for the benchmark to finish
wait "$BENCH_PID"
END_MS=$(date +%s%3N)

# stop the monitor
kill "$MON_PID" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5) Clean up NetEm
echo "[INFO] Cleaning up NetEm on $FOLLOWER..."
docker run --rm --privileged --net container:"$FOLLOWER" nicolaka/netshoot \
  sh -c "tc qdisc del dev eth0 root 2>/dev/null"

# ------------------------------------------------------------------------------
# 6) Post‑run summary
ELAPSED_MS=$((END_MS - START_MS))
SORTED=$(mktemp)
cut -d',' -f2 "$LATLOG" | grep -E '^[0-9]+' | sort -n > "$SORTED"
CNT=$(wc -l < "$SORTED")
p50=$(awk -v c=$CNT 'NR==int(c*0.50+0.5)' "$SORTED")
p95=$(awk -v c=$CNT 'NR==int(c*0.95+0.5)' "$SORTED")
p99=$(awk -v c=$CNT 'NR==int(c*0.99+0.5)' "$SORTED")
pmax=$(tail -n1 "$SORTED")
rm -f "$SORTED"

THROUGHPUT=$(( TOTAL * 1000 / ELAPSED_MS ))
{
  echo "Latency median (p50)       : $p50 ms"
  echo "Latency 95th percentile    : $p95 ms"
  echo "Latency 99th percentile    : $p99 ms"
  echo "Latency max                : $pmax ms"
  echo "Total puts                 : $TOTAL"
  echo "Elapsed (ms)               : $ELAPSED_MS"
  echo "Avg throughput (ops/sec)   : $THROUGHPUT"
} | tee "$OUTDIR/summary.txt"

# metadata
cat > "$OUTDIR/metadata.txt" <<EOF
timestamp=$(date --iso-8601=seconds)
label=$LABEL
mode=$MODE
fault_value=$FAULT_VAL
duration_s=$DURATION
inject_at_s=$INJECT_AT
follower=$FOLLOWER
bench_node=$BENCH_NODE
endpoints=$ENDPOINTS
total_ops=$TOTAL
elapsed_ms=$ELAPSED_MS
throughput_ops_per_sec=$THROUGHPUT
p50_ms=$p50
p95_ms=$p95
p99_ms=$p99
pmax_ms=$pmax
EOF

echo "[SUCCESS] Results in $OUTDIR"
