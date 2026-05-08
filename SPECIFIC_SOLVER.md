# Single-Solver / Single-Backend CLI Feature

This document describes the `--backend` and `--solver` flags added to BoSy
for benchmarking and comparison of individual solvers.

---

## Motivation

By default BoSy runs two concurrent threads (system + environment) using BDD
game-solving for realizability and QBF (rareqs) for synthesis. There is no
CLI way to select a different encoding or solver without modifying source code.

The `--backend` and `--solver` flags bypass the concurrent game-solving path
entirely and run a single specified encoding with a single specified solver.
This makes it straightforward to benchmark and compare solvers:

```bash
./bosy.sh --backend smt --solver z3   --synthesize spec.bosy
./bosy.sh --backend smt --solver cvc4 --synthesize spec.bosy

./bosy.sh --backend state-symbolic --solver idq    --synthesize spec.bosy
./bosy.sh --backend state-symbolic --solver pedant --synthesize spec.bosy
```

---

## New Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--backend NAME` | String | — | Encoding backend to use. When omitted, the default concurrent game-solving path runs unchanged. |
| `--solver NAME` | String | *(backend default)* | Solver to use with the chosen backend. When omitted, the backend's default solver is used. |

### Backend names

| Name | Encoding | Default solver |
|------|----------|---------------|
| `explicit` | SAT / DIMACS | `cryptominisat` |
| `input-symbolic` | QBF / QDIMACS | `rareqs` |
| `state-symbolic` | DQBF / DQDIMACS | `idq` |
| `symbolic` | DQBF / DQDIMACS | `idq` |
| `smt` | SMT-LIB2 / UFDTLIA | `z3` |
| `game-solving` | BDD safety game | *(none)* |

### Valid solver names per backend

| Backend | Valid solvers |
|---------|--------------|
| `explicit` | `cryptominisat`, `picosat` |
| `input-symbolic` | `rareqs`, `depqbf`, `cadet`, `caqe`, `quabs` |
| `state-symbolic` / `symbolic` | `idq`, `hqs`, `dcaqe`, `pedant` |
| `smt` | `z3`, `cvc4` |

---

## Behaviour

- If `--backend` is **not** given: BoSy runs identically to before — concurrent
  BDD game-solving for realizability, QBF for synthesis.
- If `--backend` is given: the concurrent path is skipped entirely. A single
  `SolutionSearch` instance runs with the chosen encoding, searching with an
  exponential bound strategy (1, 2, 4, 8, …).
- If `--solver` is given without `--backend`: the solver is stored in
  `options.solver` and used by whichever encoding runs (including the default
  concurrent path if `--backend` is absent).
- `--synthesize` works as normal: omit it to check realizability only (no
  AIGER output); include it to also extract and print the circuit.

---

## Files Modified

### `Sources/Logic/Solver.swift`

No changes needed here for the flag feature itself. The existing
`SolverInstance` enum and `DqbfSolver` / `SmtSolver` / `QbfSolver` protocols
are already the correct abstraction — the flag just selects which instance
to put in `options.solver`.

### `Sources/BoundedSynthesis/SolutionSearch.swift`

`defaultSolver` on `Backends` was changed from `internal` to `public` so that
`main.swift` (a separate module) can read it:

```swift
// before
var defaultSolver: SolverInstance? { ... }

// after
public var defaultSolver: SolverInstance? { ... }
```

### `Sources/BoSy/main.swift`

**1. `Backends: ArgumentKind` extension** (mirrors the existing
`SolverInstance: ArgumentKind` and `LLMProvider: ArgumentKind` extensions):

```swift
extension Backends: ArgumentKind {
    public init(argument: String) throws {
        switch Backends(rawValue: argument) {
        case let .some(b): self = b
        default: throw ArgumentConversionError.unknown(value: argument)
        }
    }
    public static var completion: ShellCompletion = .unspecified
}
```

**2. Two new argument definitions** (in the argument parsing block):

```swift
let backendOption = parser.add(option: "--backend", kind: Backends.self,
    usage: "encoding backend: explicit, input-symbolic, state-symbolic, symbolic, smt, game-solving")
let solverOption  = parser.add(option: "--solver",  kind: SolverInstance.self,
    usage: "solver to use with the chosen backend (e.g. z3, cvc4, idq, pedant, rareqs)")
```

**3. Parsing and applying the solver override:**

```swift
let backend        = parsed.get(backendOption)
let solverOverride = parsed.get(solverOption)

options.solver = solverOverride ?? backend?.defaultSolver ?? .rareqs
```

`solverOverride` takes the highest priority, then the backend's built-in
default, then the original fallback (`.rareqs`).

**4. Single-backend execution block** (inserted between the LLM path and the
concurrent game-solving path):

```swift
// MARK: - single backend path (--backend flag given)
if let chosenBackend = backend {
    let automaton = try CoBüchiAutomaton.from(ltl: !specification.ltl)

    var search = SolutionSearch(
        options: options,
        specification: specification,
        automaton: automaton,
        searchStrategy: .exponential,
        player: .system,
        backend: chosenBackend,
        synthesize: synthesize
    )

    guard search.hasSolution() else {
        print("UNREALIZABLE")
        exit(0)
    }

    guard synthesize else {
        print("REALIZABLE")
        exit(0)
    }

    guard
        let solution = search.getSolution(),
        let aigerSolution = (solution as? AigerRepresentable)?.aiger
    else {
        Logger.default().error("could not extract AIGER solution")
        exit(1)
    }

    print("REALIZABLE")
    let minimized = aigerSolution.minimized ?? aigerSolution
    aiger_write_to_file(minimized, aiger_ascii_mode, stdout)
    exit(0)
}
```

`SolutionSearch` and its `hasSolution()` / `getSolution()` methods already
existed in `BoundedSynthesis` — this block just wires them to the CLI.

---

## Example Benchmark Script

```bash
#!/usr/bin/env bash
SPEC=Samples/simple_arbiter.bosy

for backend in smt input-symbolic state-symbolic; do
    case $backend in
        smt)            solvers="z3 cvc4" ;;
        input-symbolic) solvers="rareqs cadet" ;;
        state-symbolic) solvers="idq pedant" ;;
    esac
    for solver in $solvers; do
        echo "=== $backend / $solver ==="
        time ./bosy.sh --backend $backend --solver $solver --synthesize $SPEC
    done
done
```
