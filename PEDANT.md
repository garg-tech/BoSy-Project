# Pedant DQBF Solver Integration

This document describes the changes made to integrate
[pedant-solver](https://github.com/fslivovsky/pedant-solver) as a required
DQBF backend in BoSy.

---

## What is Pedant?

Pedant is a DQBF (Dependency Quantified Boolean Formula) solver. It takes
input in DQDIMACS format and outputs SAT or UNSAT. BoSy already uses DQBF
encodings (`symbolic`, `state-symbolic`) via iDQ and HQS; pedant is an
additional solver for the same encodings.

---

## Build

Pedant is built from source as part of the standard tool build:

```bash
make Tools/pedant        # build pedant only
make                     # build all required tools (includes pedant)
```

The Makefile clones the repo recursively (pedant has submodules), runs cmake,
and copies the resulting binary to `Tools/pedant`.

---

## Files Modified

### `Makefile`

Added pedant to the `required-tools` target and added three build rules:

```makefile
# in required-tools target
Tools/pedant \

# build rules
Tools/pedant: Tools/pedant-src/build/pedant
    cp Tools/pedant-src/build/pedant Tools/pedant

Tools/pedant-src/build/pedant: Tools/pedant-src
    mkdir -p Tools/pedant-src/build
    cd Tools/pedant-src/build ; cmake ..
    make -C Tools/pedant-src/build

Tools/pedant-src: Tools/.f
    cd Tools ; git clone --recursive https://github.com/fslivovsky/pedant-solver pedant-src
```

### `bosy.sh`

Added `"pedant"` to the required tools check array in `check_tools()`:

```bash
tools=("abc" ... "idq" "pedant" "quabs" ...)
```

This means `./bosy.sh` will report an error and refuse to run if `Tools/pedant`
is missing or not executable, consistent with how all other required tools are
handled.

### `Sources/Logic/Solver.swift`

**1. New case in `SolverInstance` enum:**

```swift
// DQBF solver
case idq
case hqs
case dcaqe
case pedant      // added
```

**2. New entry in `SolverInstance.instance` switch:**

```swift
case .pedant:
    return Pedant()
```

**3. New entry in `SolverInstance.allValues`:**

```swift
.pedant,
```

**4. New `Pedant` struct (after `DCAQE`, before `Eprover`):**

```swift
struct Pedant: DqbfSolver {
    func solve(formula: Logic, preprocessor: QbfPreprocessor?) -> SolverResult? {
        let dqdimacsVisitor = DQDIMACSVisitor(formula: formula)
        let encodedFormula = dqdimacsVisitor.description

        return try? withTemporaryFile(dir: nil, prefix: "", suffix: ".dqdimacs", deleteOnClose: true) {
            (tempFile: TemporaryFile) throws -> SolverResult? in
            tempFile.fileHandle.write(Data(encodedFormula.utf8))

            do {
                let result = try TSCBasic.Process.popen(
                    arguments: ["./Tools/pedant", tempFile.path.pathString]
                )
                let stdout = try result.utf8Output()

                if stdout.contains("UNSAT") { return .unsat }
                if stdout.contains("SAT")   { return .sat }
                return nil
            } catch {
                Logger.default().error("execution of pedant failed")
                return nil
            }
        }
    }
}
```

The struct follows the same pattern as `iDQ`: encode the `Logic` formula to
DQDIMACS via `DQDIMACSVisitor`, write it to a temp file, invoke the binary,
and scan stdout for `"SAT"` / `"UNSAT"`.

Note: pedant does not support a preprocessor argument. The `preprocessor`
parameter from the `DqbfSolver` protocol is accepted but ignored.

---

## Usage

Use pedant with the `--backend` and `--solver` flags (see `SPECIFIC_SOLVER.md`):

```bash
./bosy.sh --backend state-symbolic --solver pedant --synthesize Samples/simple_arbiter.bosy
./bosy.sh --backend symbolic       --solver pedant --synthesize Samples/simple_arbiter.bosy
```

Pedant is only valid with DQBF backends (`state-symbolic`, `symbolic`).
Passing it with an SMT or QBF backend will cause BoSy to exit with an error
at the encoding layer.

---

## Output Format Assumption

The `Pedant` struct checks for the strings `"SAT"` and `"UNSAT"` in stdout.
If a future version of pedant changes its output format, update the
`stdout.contains(...)` checks in `Sources/Logic/Solver.swift`.
