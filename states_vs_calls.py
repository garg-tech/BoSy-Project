import csv
from collections import defaultdict
import matplotlib.pyplot as plt
import numpy as np

input_file = "tlsf_strategy_results_4.csv"

# data[file][strategy] = list of entries
data = defaultdict(lambda: defaultdict(list))

with open(input_file, newline='') as f:
    reader = csv.DictReader(f)
    for row in reader:
        file = row["file"]
        strategy = row["strategy"]
        state = int(row["current_state"])
        total_states = row["total_states"].strip()
        exit_code = row["exit_code"].strip()

        data[file][strategy].append({
            "state": state,
            "total_states": total_states,
            "exit_code": exit_code
        })

# Metrics
total_states_sum = defaultdict(int)
solver_calls_sum = defaultdict(int)

for file, strategies in data.items():

    # ✅ Check: all three strategies must have at least one success
    valid_file = True
    for strat in ["linear", "expo", "hybrid"]:
        entries = strategies.get(strat, [])
        if not any(e["exit_code"] == "0" for e in entries):
            valid_file = False
            break

    if not valid_file:
        continue

    # Process each strategy
    for strat in ["linear", "expo", "hybrid"]:
        entries = strategies.get(strat, [])

        # Keep only successful entries
        entries = [e for e in entries if e["exit_code"] == "0"]

        # Sort by state
        entries.sort(key=lambda x: x["state"])

        # Remove duplicate states
        unique_states = []
        seen = set()
        for e in entries:
            if e["state"] not in seen:
                unique_states.append(e)
                seen.add(e["state"])

        # Solver calls = number of unique successful states
        solver_calls_sum[strat] += len(unique_states)

        # Total states = final successful state's total_states
        final_entry = unique_states[-1]
        if final_entry["total_states"] != "":
            total_states_sum[strat] += int(final_entry["total_states"])

# ------------------ Plot ------------------

strategies = ["linear", "expo", "hybrid"]

states_values = [total_states_sum[s] for s in strategies]
calls_values = [solver_calls_sum[s] for s in strategies]

x = np.arange(len(strategies))
width = 0.35

plt.figure()

plt.bar(x - width/2, states_values, width, label="Total States")
plt.bar(x + width/2, calls_values, width, label="Solver Calls")

plt.xticks(x, strategies)
plt.ylabel("Count")
plt.title("Total States vs Solver Calls")
plt.legend()
plt.grid(axis='y')

plt.savefig("states_vs_solver_calls_2.png")
plt.show()