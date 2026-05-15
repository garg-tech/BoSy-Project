import csv
from collections import defaultdict

input_file = "tlsf_strategy_results_2.csv"

# Structure:
# data[file][strategy] = list of entries
data = defaultdict(lambda: defaultdict(list))

with open(input_file, newline='') as f:
    reader = csv.DictReader(f)
    for row in reader:
        file = row["file"]
        strategy = row["strategy"]
        exit_code = row["exit_code"].strip()
        time = row["time_seconds"].strip()

        data[file][strategy].append({
            "exit_code": exit_code,
            "time": time
        })

# Metrics
total_files = len(data)
all_success = 0
none_success = 0

for file, strategies in data.items():

    strategy_success = {}

    for strat in ["linear", "expo", "hybrid"]:
        entries = strategies.get(strat, [])

        # A strategy is successful if ANY row has exit_code=0 and valid time
        success = any(
            e["exit_code"] == "0" and e["time"] != ""
            for e in entries
        )

        strategy_success[strat] = success

    # Check conditions
    if all(strategy_success.values()):
        all_success += 1

    if not any(strategy_success.values()):
        none_success += 1

# Print results
print("Total number of files:", total_files)
print("Files where ALL 3 strategies succeeded:", all_success)
print("Files where NONE of the strategies succeeded:", none_success)