# Bound Search Strategy: Exponential + Binary Search

This document describes the hybrid bound search strategy added to BoSy,
selectable via `--strategy expo+bs`.

---

## Background

Bounded synthesis works by asking: *does a correct system with at most k states
exist?* The tool iterates over values of k (the bound) until it finds one where
the answer is yes.

BoSy originally provided two strategies:

| Strategy | How it works |
|---|---|
| `linear` | Try k = 1, 2, 3, 4, … one at a time |
| `expo` | Try k = 1, 2, 4, 8, … doubling each time |

Linear search finds the **minimum** bound but wastes time on small bounds when
the solution is large. Exponential search reaches large bounds quickly but
overshoots and may solve a bound much larger than necessary.

---

## The Hybrid Strategy (`expo+bs`)

The hybrid strategy combines both in two phases:

**Phase 1 — Exponential search to bracket the solution**

Try k = 1, 2, 4, 8, … until the first SAT bound is found. This gives an
upper bound `high` and a lower bound `low = high/2 + 1`.

**Phase 2 — Binary search to find the minimum**

Binary search the interval `[low, high]` to find the smallest k that is SAT.
Each step halves the remaining search space, so the total number of additional
solver calls is O(log k).

**Example** (solution at k = 6):
```
Phase 1:  k=1 UNSAT, k=2 UNSAT, k=4 UNSAT, k=8 SAT  → interval [5, 8]
Phase 2:  k=6 SAT → [5,5]; k=5 UNSAT → done. Minimum = 6
```

Without the binary search phase, exponential alone would report k = 8.

---

## Implementation

The strategy is implemented in
`Sources/BoundedSynthesis/Encoding.swift` as `searchMinimalHybrid()` on the
`SingleParameterSearch` protocol extension. It is used by
`InputSymbolicEncoding` during the synthesis phase.

The `--strategy` flag in `main.swift` selects among `linear`, `expo`, and
`hybrid` (the internal name for `expo+bs`):

```bash
./bosy.sh --strategy expo+bs Samples/simple_arbiter.bosy
```

---

## When to Use Each Strategy

| Strategy | Best when |
|---|---|
| `linear` | Solution is at a very small bound (k ≤ 3) |
| `expo` | You only need realizability, not the minimal bound |
| `expo+bs` (hybrid) | You want the minimal bound and expect it to be moderate or large |

The default strategy is `hybrid`.
