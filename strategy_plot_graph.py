import csv
from collections import defaultdict
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

input_file = "tlsf_strategy_results_4.csv"

# ---------------------------------------------------
# Step 1: Read CSV and group by file + strategy
# ---------------------------------------------------

data = defaultdict(lambda: defaultdict(list))

with open(input_file, newline='') as f:
    reader = csv.DictReader(f)

    for row in reader:
        file = row["file"]
        strategy = row["strategy"]

        state = int(row["current_state"])
        exit_code = row["exit_code"].strip()
        total_states = row["total_states"].strip()
        time_taken = float(row["time_seconds"])

        data[file][strategy].append({
            "state": state,
            "exit_code": exit_code,
            "total_states": total_states,
            "time": time_taken
        })

# ---------------------------------------------------
# Step 2: Extract final time per benchmark
# ---------------------------------------------------

strategy_times = defaultdict(list)

for file, strategies in data.items():

    for strategy in ["linear", "expo", "hybrid"]:

        entries = strategies.get(strategy, [])

        if not entries:
            continue

        # Keep only successful runs
        entries = [
            e for e in entries
            if e["exit_code"] == "0"
        ]

        if not entries:
            continue

        # Remove duplicate consecutive states
        filtered = []

        prev_state = None

        for e in entries:

            if e["state"] != prev_state:
                filtered.append(e)
                prev_state = e["state"]

        if not filtered:
            continue

        # Final time = last printed state's time
        final_time = filtered[-1]["time"]

        strategy_times[strategy].append(final_time)

# ---------------------------------------------------
# Step 3: Create cactus plot
# ---------------------------------------------------

plt.figure(figsize=(8, 5))

for strategy, times in strategy_times.items():

    # Keep first 200
    times = times[:200]

    # X-axis = solved instances
    x = list(range(1, len(times) + 1))

    # Cumulative time
    cumulative = []

    total = 0

    for t in times:
        total += t
        cumulative.append(total)

    plt.plot(
        x,
        cumulative,
        marker='o',
        markersize=3,
        linewidth=1.5,
        label=strategy
    )

# ---------------------------------------------------
# Step 4: Axis formatting
# ---------------------------------------------------

ax = plt.gca()

# Horizontal grid only
ax.grid(True, which='major', axis='y')

# Remove vertical grid lines
ax.grid(False, axis='x')

# X-axis ticks every 10
ax.xaxis.set_major_locator(
    ticker.MultipleLocator(10)
)

# ---------------------------------------------------
# Labels
# ---------------------------------------------------

plt.xlabel("# instances")
plt.ylabel("time (sec)")
plt.title("Strategy Comparison")

plt.legend()

plt.tight_layout()

plt.savefig("strategy_comparison_4.png", dpi=300)

plt.show()