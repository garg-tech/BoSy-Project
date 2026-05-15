# DQBDD Integration

This document describes the changes made to integrate
[DQBDD](https://github.com/jurajsic/DQBDD) as a DQBF backend in BoSy.

---

## What is DQBDD?

DQBDD is a DQBF (Dependency Quantified Boolean Formula) solver based on
BDD-based variable elimination. It takes input in DQDIMACS format and outputs
SAT or UNSAT. It is an additional solver for BoSy's existing DQBF encodings
(`state-symbolic`, `symbolic`), alongside iDQ, HQS, and Pedant.

---

## Build

DQBDD is built from source as part of the standard tool build:

```bash
make Tools/dqbdd        # build dqbdd only
make                    # build all required tools (includes dqbdd)
```

The Makefile clones the repository, runs cmake, and copies the resulting
binary to `Tools/dqbdd`.

---

## Code Changes

The integration follows the same pattern as [Pedant](PEDANT.md). The changes
are identical in structure:

### `Sources/Logic/Solver.swift`

**1. New case in `SolverInstance` enum:**

```swift
case dqbdd
```

**2. New entry in `SolverInstance.instance` switch:**

```swift
case .dqbdd:
    return DQBDD()
```

**3. New entry in `SolverInstance.allValues`:**

```swift
.dqbdd,
```

**4. New `DQBDD` struct (conforms to `DqbfSolver`):**

```swift
struct DQBDD: DqbfSolver {
    mutating func solve(formula: Logic, preprocessor: QbfPreprocessor?) -> SolverResult? {
        let dqdimacsVisitor = DQDIMACSVisitor(formula: formula)
        let encodedFormula = dqdimacsVisitor.description

        return try? withTemporaryFile(dir: nil, prefix: "", suffix: ".dqdimacs", deleteOnClose: true) {
            (tempFile: TemporaryFile) throws -> SolverResult? in
            tempFile.fileHandle.write(Data(encodedFormula.utf8))
            do {
                let result = try TSCBasic.Process.popen(
                    arguments: ["./Tools/dqbdd", tempFile.path.pathString]
                )
                let stdout = try result.utf8Output()
                if stdout.contains("UNSAT") { return .unsat }
                if stdout.contains("SAT")   { return .sat }
                return nil
            } catch {
                Logger.default().error("execution of dqbdd failed")
                return nil
            }
        }
    }
}
```

### `Makefile`

Added `dqbdd` to the `required-tools` target and the corresponding build rules.

### `bosy.sh`

Added `"dqbdd"` to the required tools check array.

---

## Usage

Use DQBDD with the `--backend` and `--solver` flags:

```bash
./bosy.sh --backend state-symbolic --solver dqbdd Samples/simple_arbiter.bosy
./bosy.sh --backend symbolic       --solver dqbdd Samples/simple_arbiter.bosy
```

DQBDD is only valid with DQBF backends (`state-symbolic`, `symbolic`).

---

## Note on Synthesis

DQBDD does not produce AIGER certificates. `extractSolution()` returns `nil`
for DQBDD — realizability checking works, but `--synthesize` will not produce
a circuit.
