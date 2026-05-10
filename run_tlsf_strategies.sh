#!/usr/bin/env bash
set -u
set -o pipefail

# Run all TLSF benchmarks under ../benchmarks/tlsf with each strategy.
# Outputs a CSV with strategy results, exit code, states, and total state-search time.

cd "$(dirname "$0")" || exit 1
benchdir="../LTL-Synth/"
output_csv="tlsf_strategy_results.csv"
strategies=(linear expo hybrid)

printf '%s\n' "file,strategy,exit_code,states,time_seconds" > "$output_csv"

find "$benchdir" -type f -name '*.tlsf' | sort | while IFS= read -r tlsf; do
  for strategy in "${strategies[@]}"; do
    echo "Running strategy=$strategy on file=$tlsf"
    tmpfile=$(mktemp)
    set +e
    python3 -u - <<PY >"$tmpfile" 2>&1
import subprocess, sys, time
cmd = ["./bosy.sh", "--synthesize", "$tlsf", "--strategy", "$strategy"]
p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
for line in p.stdout:
    sys.stdout.write(f"{time.time():.6f} {line}")
    sys.stdout.flush()
ret = p.wait()
sys.exit(ret)
PY
    exit_code=$?
    set -e

    states=$(grep -oE 'NumberOfStates\(value: [0-9]+\)|found solution with [0-9]+' "$tmpfile" | tail -n1 | grep -oE '[0-9]+' | tail -n1)

    start_ts=$(grep -m1 'build encoding for bound' "$tmpfile" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
    end_ts=$(grep 'found solution with NumberOfStates' "$tmpfile" | tail -n1 | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
    if [ -n "$start_ts" ] && [ -n "$end_ts" ]; then
      time_taken=$(python3 - <<PY
print(float('$end_ts') - float('$start_ts'))
PY
)
    else
      time_taken=""
    fi

    if [ -z "$states" ]; then
      states=""
    fi

    printf '%s,%s,%s,%s,%s\n' "${tlsf//,/\,}" "$strategy" "$exit_code" "$states" "$time_taken" >> "$output_csv"
    rm -f "$tmpfile"
  done
done

echo "Finished. Results written to $output_csv"
