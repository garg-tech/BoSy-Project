#!/usr/bin/env bash
set -u
set -o pipefail

cd "$(dirname "$0")" || exit 1

benchdir="../LTL-Synth/"
input_csv="tlsf_strategy_results_2.csv"
output_csv="tlsf_strategy_results_4.csv"
strategies=(linear expo hybrid)

printf '%s\n' "file,strategy,current_state,exit_code,total_states,time_seconds" > "$output_csv"

# ✅ Get ALL unique files (no filtering)
valid_files=$(awk -F',' '
NR > 1 {
    print $1
}' "$input_csv" | sort -u)

echo "Files selected for execution:"
echo "$valid_files"
echo "-----------------------------------"

echo "$valid_files" | while IFS= read -r tlsf; do
  [ -z "$tlsf" ] && continue

  for strategy in "${strategies[@]}"; do
    echo "Running strategy=$strategy on file=$tlsf"

    tmpfile=$(mktemp)
    set +e

    python3 -u - <<PY >"$tmpfile" 2>&1
import subprocess, sys, time
cmd = ["./bosy.sh", "--synthesize", "$tlsf", "--strategy", "$strategy"]
p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

start_time = time.time()
timeout = 1800.0

while True:
    import select
    ready, _, _ = select.select([p.stdout], [], [], timeout)
    if not ready:
        p.kill()
        ret = -1
        break

    line = p.stdout.readline()
    if not line:
        ret = p.wait()
        break

    sys.stdout.write(f"{time.time():.6f} {line}")
    sys.stdout.flush()

    elapsed = time.time() - start_time
    timeout = 1800.0 - elapsed
    if timeout <= 0:
        p.kill()
        ret = -1
        break

sys.exit(ret)
PY

    exit_code=$?
    set +e

    states=$(grep -oE 'NumberOfStates\(value: [0-9]+\)|found solution with [0-9]+' "$tmpfile" | tail -n1 | grep -oE '[0-9]+' | tail -n1 || true)

    # ✅ Start from first timestamp (true start)
    start_ts=$(head -n1 "$tmpfile" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/' || true)

    # Extract all bounds
    while read -r line; do
      ts=$(echo "$line" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
      bound=$(echo "$line" | grep -oE 'bound [0-9]+' | grep -oE '[0-9]+')

      if [ -n "$start_ts" ] && [ -n "$ts" ]; then
        time_taken=$(python3 - <<PY
print(float('$ts') - float('$start_ts'))
PY
)
      else
        time_taken=""
      fi

      printf '%s,%s,%s,%s,%s,%s\n' \
        "${tlsf//,/\,}" \
        "$strategy" \
        "$bound" \
        "$exit_code" \
        "$states" \
        "$time_taken" >> "$output_csv"

    done < <(grep 'build encoding for bound' "$tmpfile")

    rm -f "$tmpfile"
  done
done

echo "Finished. Results written to $output_csv"