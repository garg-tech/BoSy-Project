#!/bin/bash

TIMEOUT=10800
PER_FILE_TIMEOUT=600

format_duration() {
    local total_seconds="$1"
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
}

for MODE in "rareqs" "cryptominisat" "z3" "pedant" "dqbdd" "idq"; do

    case "$MODE" in
        rareqs)
            BACKEND="input-symbolic"
            ;;
        cryptominisat)
            BACKEND="explicit"
            ;;
        z3)
            BACKEND="smt"
            ;;
        pedant|dqbdd|idq)
            BACKEND="state-symbolic"
            ;;
        *)
            echo "Unknown solver MODE: $MODE" >&2
            exit 2
            ;;
    esac

    OUTPUT="./benchmarking_3hr/benchmark_results_${MODE}.txt"

    echo "Benchmarking with solver: $MODE (backend: $BACKEND)" > "$OUTPUT"

    start_time=$(date +%s)

    count=0

    for file in /home/tarun/Downloads/TLSF_2019/LTL-Synth/*; do

        ((count++))

        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        if [ $elapsed -gt $TIMEOUT ]; then
            echo "3HR timeout reached. Stopping benchmark." >> "$OUTPUT"
            break
        fi

        echo "[$count] Running $file"

        echo "==== FILE #$count : $file ====" >> "$OUTPUT"

        file_start_time=$(date +%s)
        file_start_human=$(date -Is)
        echo "Start: $file_start_human" >> "$OUTPUT"

        timeout ${PER_FILE_TIMEOUT}s \
            ./bosy.sh --backend "$BACKEND" --strategy linear --solver "$MODE" "$file" \
            >> "$OUTPUT" 2>&1

        exit_code=$?

        file_end_time=$(date +%s)
        file_end_human=$(date -Is)
        file_elapsed=$((file_end_time - file_start_time))
        echo "End:   $file_end_human" >> "$OUTPUT"
        echo "Time:  $(format_duration "$file_elapsed") (${file_elapsed}s)" >> "$OUTPUT"

        if [ $exit_code -eq 124 ]; then
            echo "10 minute timeout for $file" >> "$OUTPUT"

        elif [ $exit_code -ne 0 ]; then
            echo "Error processing $file with exit code $exit_code" >> "$OUTPUT"
        fi

        echo "" >> "$OUTPUT"

    done

done