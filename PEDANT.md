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

Unlike `iDQ` (which only checks SAT/UNSAT), `Pedant` also passes `--aag <tmpfile>`
to request an AIGER certificate on SAT. The certificate is read back via
`aiger_open_and_read_from_file` and stored in `lastCertificate`, which
`extractSolution()` in the DQBF encodings picks up via the
`CertifyingDqbfSolver` protocol.

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

---

## Limitations of the AIGER Certificate

When `--synthesize` is used with pedant, the AIGER circuit produced has two
known limitations that are inherent to how DQDIMACS encoding works. These are
not fixable without significant additional engineering and are accepted as-is.

### 1. No latches — purely combinational circuit

The DQDIMACS encoding represents the synthesis problem as a snapshot formula,
not a sequential circuit. Universal variables encode the current state bits
and inputs; existential variables encode outputs and next-state bits. Pedant's
AIGER certificate is therefore a **purely combinational** circuit: it computes
next-state and output values from current-state and input values, but contains
no latches to close the state feedback loop.

A correct sequential AIGER would require identifying which outputs are
next-state bits, adding latches connecting them back to the corresponding
state-bit inputs, and re-wiring the circuit accordingly. This is not
implemented.

### 2. Signal names are DQDIMACS variable numbers, not spec names

The DQDIMACS encoding maps named signals (`r_0`, `g_1`, etc.) to integer
variable numbers. Pedant only sees these numbers and its AIGER symbol table
labels signals by those numbers (e.g. `i0 3`, `o0 7`), not by the original
names from the `.bosy` spec.

A correct relabeling would require tracking the variable-number → signal-name
mapping during encoding and applying it to the certificate's symbol table.
This is not implemented.

### Summary

| Property | Normal BoSy AIGER | Pedant AIGER certificate |
|----------|------------------|--------------------------|
| Latches | Yes (FSM states) | No (combinational only) |
| Signal names | `r_0`, `g_1`, etc. | Integer variable numbers |
| Correctness | Formally verified | Not verified |
