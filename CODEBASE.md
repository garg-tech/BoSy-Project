# BoSy Codebase Guide

This document explains the structure and flow of the BoSy codebase: what each module does, which types and functions matter, and how everything connects.

---

## The Big Picture

Given a specification like `simple_arbiter.bosy`, BoSy:

1. Parses the spec into an LTL formula
2. Builds a Co-Büchi automaton from the negated LTL
3. Searches for the smallest FSM (bounded by number of states) that wins a game against the automaton
4. Outputs the solution as an AIGER circuit

---

## Pipeline Flow (`BoSy/main.swift`)

1. Parse CLI args (via `TSCUtility` argument parser)
2. Load spec → `SynthesisSpecification`
3. **If `--llm-solve`**: run `LLMSmtEncoding` loop, extract solution, print AIGER, exit
4. **Otherwise**: launch two `DispatchQueue` threads concurrently:
   - Thread 1: search for *system* winning strategy (`Player.system`)
   - Thread 2: search for *environment* winning strategy (dualized spec, `Player.environment`)
5. `TerminationCondition` coordinates: whichever thread finds a solution first broadcasts, the main thread wakes
6. `winner` is set to `.system` (REALIZABLE) or `.environment` (UNREALIZABLE)
7. If synthesizing: call `synthesizeSolution()` → `InputSymbolicEncoding` for QBF-based extraction
8. If optimizing: binary search on AND gate count via `optimizeSolution()`
9. Print `REALIZABLE`/`UNREALIZABLE` + write AIGER to stdout

---

## Module Reference

### `LTL` — Formula Representation and Parsing
**Files:** `Sources/LTL/`

The core type is the `LTL` enum in `LTL.swift` — a recursive AST:

```
enum LTL {
    .atomicProposition(LTLAtomicProposition)    // leaf: "r_0", "g_1"
    .application(LTLFunction, parameters:[LTL]) // operator node: G, F, U, ¬, ∧, ...
    .pathQuantifier(...)                        // HyperLTL only
}
```

`LTLFunction` holds the operator (temporal: `G`, `F`, `X`, `U`; boolean: `¬`, `∧`, `∨`).

**Parsing:** `LTLLexer` tokenizes the string → `LTLParser` builds the AST. The spec's `guarantees` and `assumptions` arrays become `LTL` values; `SynthesisSpecification.ltl` combines them into one formula (`assumptions → guarantees`).

**Key files:**

| File | Purpose |
|------|---------|
| `LTL.swift` | Core enum AST, `parse()`, `nnf`, `normalized` |
| `Parser.swift` | Recursive descent parser |
| `Lexer.swift` | Tokenizer |
| `LTL+Operators.swift` | Operator overloads (`&&`, `||`, `!`, `=>`) |
| `HyperLTL.swift` | HyperLTL extensions (`prenex`, `pathVariables`) |
| `LTL+spot.swift` / `LTL+ltl3ba.swift` | Export to external tool formats |

---

### `Specification` — The Problem Definition
**Files:** `Sources/Specification/Specifications.swift`

`SynthesisSpecification` is the central data structure passed everywhere:

| Property | Type | Meaning |
|----------|------|---------|
| `inputs` | `[String]` | Environment-controlled signals (`r_0`, `r_1`, `r_2`) |
| `outputs` | `[String]` | System-controlled signals (`g_0`, `g_1`, `g_2`) |
| `assumptions` | `[LTL]` | Environment assumptions |
| `guarantees` | `[LTL]` | System guarantees |
| `semantics` | `TransitionSystemType` | `.mealy` (outputs on state+input) or `.moore` (state only) |
| `ltl` | `LTL` (computed) | `(∧assumptions) → (∧guarantees)` |
| `dualized` | `SynthesisSpecification` (computed) | Swaps inputs/outputs for unrealizability check |

Loaded via `SynthesisSpecification.from(fileName:)` which reads JSON (`.bosy`) or TLSF format.

---

### `Automata` — LTL to Co-Büchi Automaton
**Files:** `Sources/Automata/`

`CoBüchiAutomaton` is built from the *negation* of the spec's LTL:

```swift
let automaton = try CoBüchiAutomaton.from(ltl: !specification.ltl)
```

This calls an external tool (`spot` or `ltl3ba`) as a subprocess, parses its HOA/SPIN output, and builds:

| Property | Meaning |
|----------|---------|
| `states: Set<String>` | Automaton states (named by the tool) |
| `transitions: [State: [State: Logic]]` | `transitions[q1][q2]` = Logic formula labelling edge q1→q2 |
| `rejectingStates: Set<String>` | States that must be visited finitely often (Co-Büchi) |
| `initialStates: Set<String>` | Starting states |

**`reduceToSafety(bound:)`** converts the Co-Büchi automaton to a `SafetyAutomaton<CounterState>` by adding integer counters (`lambdaSharp`) bounding how many times each rejecting state can be visited. This safety automaton is what all the encodings operate on.

**Key files:**

| File | Purpose |
|------|---------|
| `CoBüchi.swift` | `CoBüchiAutomaton`, `CounterState`, SCC analysis, safety reduction |
| `Safety.swift` | `SafetyAutomaton<S>` generic safety automaton |
| `Conversion.swift` | `LTL2AutomatonConverter`, HOA/SPIN parsers |
| `Automaton.swift` | `Automaton` protocol, `CoBüchiAcceptance`, `SafetyAcceptance` |

---

### `Logic` — Boolean Formulas
**Files:** `Sources/Logic/`

`Logic` is a protocol implemented by several concrete types:

| Type | Meaning |
|------|---------|
| `Literal` | `true` / `false` constants |
| `Proposition` | Named variable, e.g. `Proposition("r_0")` |
| `UnaryOperator` | Negation |
| `BinaryOperator` | And, Or, Xor |
| `FunctionApplication` | SMT function call, e.g. `(tau s0 true false false)` |
| `Quantifier` | Existential / universal, used in QBF encodings |

All Logic types support the **visitor pattern** via `accept(visitor:)`. Key visitors:

| Visitor | Output |
|---------|--------|
| `SmtPrinter` | SMTLIB2 string (used in `LLMSmtEncoding` for query expressions) |
| `SmvPrinter` | NuSMV format |
| `NegationNormalFormVisitor` | Converts formula to NNF |
| `RenamingBooleanVisitor` | Renames propositions via closure |

**Key utilities:**
- `allBooleanAssignments(variables:)` — enumerates all 2^n assignments for a list of `Proposition`s; used heavily in encoding and in `LLMSmtEncoding.buildQueryExpressions()`
- `numBitsNeeded(_:)` — ceiling of log2; computes how many latches are needed for N states

**Solver interfaces** (`Solver.swift`):

| Protocol | Implementations |
|----------|----------------|
| `SatSolver` | PicoSAT, CryptoMiniSat |
| `QbfSolver` | RAReQS, DepQBF, CADET, CAQE, QuAbS |
| `SmtSolver` | Z3, CVC4 (`GenericSmtSolver`) |
| `DqbfSolver` | iDQ, HQS, DCAQE |

---

### `BoundedSynthesis` — Encodings and Search
**Files:** `Sources/BoundedSynthesis/`

The central abstraction:

```swift
protocol BoSyEncoding {
    mutating func solve(forBound bound: Int) throws -> Bool
    func extractSolution() -> TransitionSystem?
}
```

Every encoding implements these two methods. `searchMinimalLinear` / `searchMinimalExponential` on `SingleParamaterSearch` call `solve(forBound:)` in a loop, incrementing the bound.

**Available encodings:**

| Type | Backend | Generates |
|------|---------|-----------|
| `SmtEncoding` | Z3 / CVC4 | SMTLIB2 (UFDTLIA logic) |
| `ExplicitEncoding` | SAT (picosat/cryptominisat) | DIMACS CNF |
| `InputSymbolicEncoding` | QBF (rareqs/cadet) | QDIMACS |
| `StateSymbolicEncoding` | DQBF | Dependency-QBF |
| `SafetyGameReduction` | BDD game solving (CUDD) | BDD fixpoint |
| `LLMSmtEncoding` *(added)* | LLM API | SMTLIB2 → HTTP → JSON |

**`SmtEncoding.getEncoding(forBound:)`** builds the SMTLIB2 formula. It declares:
- A finite datatype `S` with constructors `s0, s1, …, s(k-1)`
- `tau(s, i1…in): S` — transition function
- `lambda_q(s): Bool` — whether automaton state `q` is consistent with system state `s`
- `lambdaSharp_q(s): Int` — ranking function to prevent infinite rejecting cycles
- `out_j(s [, i1…in]): Bool` — output functions (Mealy: state+inputs; Moore: state only)

This string is what gets sent to the LLM.

**`SafetyGameReduction`** is the default path in `main.swift`. It uses CUDD BDDs to solve a 2-player safety game. `UCWGame` builds the game arena; `solve(forBound:)` runs BDD fixpoint computation.

**`SolutionSearch`** orchestrates the overall search:
- `SearchStrategy` — `.linear` (1,2,3,…) or `.exponential` (1,2,4,8,…) bound increments
- `Player` — `.system` or `.environment`
- `Backends` — `.explicit`, `.inputSymbolic`, `.stateSymbolic`, `.symbolic`, `.smt`, `.gameSolving`

---

### `TransitionSystem` — The Solution Representation
**Files:** `Sources/TransitionSystem/`

The core protocols:

```swift
protocol TransitionSystem { }
protocol AigerRepresentable { var aiger: UnsafeMutablePointer<aiger>? { get } }
protocol DotRepresentable   { var dot: String { get } }
protocol SmvRepresentable   { var smv: String { get } }
```

**`ExplicitStateSolution`** is what `extractSolution()` builds in most encodings:

| Property | Meaning |
|----------|---------|
| `states: [Int]` | e.g. `[0, 1, 2, 3]` for 4 states |
| `transitions[source][target]` | Guard Logic: when to take this transition |
| `outputGuards[state][outputName]` | Guard Logic: when this output is true |

Its `aiger` property converts to AIGER by:
1. Encoding states as binary (e.g. 2 latches for 4 states via `stateToBits()`)
2. Building next-state and output logic functions
3. Assembling via `CAiger` (C AIGER library wrapper)

`.minimized` calls `abc` (circuit optimizer) on the result.

**`SymbolicStateSolution`** — BDD-based representation used by game-solving path.

---

### `Utils` — Shared Utilities
**Files:** `Sources/Utils/`

| Utility | Usage |
|---------|-------|
| `Logger.default().info/error/debug()` | Logging throughout; verbosity set by `--verbose` |
| `numBitsNeeded(_:)` | Compute latches needed for N states (⌈log2 N⌉) |
| `allBooleanAssignments(variables:)` | Enumerate all 2^n input combinations |
| `trajan(graph:)` | Tarjan's SCC algorithm (used by `CoBüchiAutomaton.calculateSCC()`) |
| `StreamHelper.readAllAvailableData(from:)` | Read stdin for `--read-from-stdin` |

---

## The LLM Addition

Three files implement the LLM backend:

### `Sources/Logic/LLMSolver.swift`
Sits in the Logic module. Knows about HTTP and JSON; nothing about synthesis.

- `LLMProvider` enum — `.openai` or `.gemini`, with `defaultModel` and `apiKeyEnvVar`
- `LLMSolverResult` — `sat: Bool`, `values: [String: String]` (expression → value map)
- `LLMSolver.query(smtlibFormula:getValueExpressions:)` — builds prompts, dispatches to provider HTTP method, parses JSON response
- Auth: Gemini supports `GEMINI_ACCESS_TOKEN` (OAuth → Vertex AI) or `GEMINI_API_KEY`; OpenAI uses `OPENAI_API_KEY`
- Requests are synchronous via `URLSession.dataTask` + `DispatchSemaphore`; timeout is 600 seconds

### `Sources/BoundedSynthesis/LLMSmtEncoding.swift`
A `BoSyEncoding`. Bridges formula generation and the LLM HTTP client.

- `solve(forBound:)` — calls `SmtEncoding.getEncoding()` for the formula, calls `buildQueryExpressions()` for the value queries, sends both to `LLMSolver`, caches the result
- `buildQueryExpressions(forBound:)` — pre-computes all `(tau sN b1 b2…)` and `(output sN [b1…])` strings using `SmtPrinter` + `FunctionApplication`
- `extractSolution()` — reads `cachedValues[expr]`, parses `"s3"` → `Int(stateValue.dropFirst())`, `"true"`/`"false"` → `Literal`, builds `ExplicitStateSolution`

### `Sources/BoSy/main.swift` (LLM block)
Runs *before* the concurrent game-solving block. If `--llm-solve` is set, the normal search never starts.

```
--llm-solve      Bool     enable LLM backend
--bound N        Int      upper bound on states (default: 4; search doubles: 1,2,4,…)
--llm-provider   String   openai | gemini (default: gemini)
--llm-model      String   model name override
```

`LLMProvider: ArgumentKind` extension makes it parseable by `TSCUtility`'s argument parser.

---

## Quick Cross-Reference

| Question | Where to look |
|----------|--------------|
| How is the spec loaded? | `Specification/Specifications.swift` → `from(fileName:)` |
| How is the LTL formula built? | `SynthesisSpecification.ltl` computed property |
| How is the automaton built? | `Automata/CoBüchi.swift` → `CoBüchiAutomaton.from(ltl:)` |
| How is the SMTLIB2 formula built? | `BoundedSynthesis/SmtEncoding.swift` → `getEncoding(forBound:)` |
| How does the normal (non-LLM) solver work? | `BoundedSynthesis/GameSolver.swift` → `SafetyGameReduction` |
| How is the solution extracted to AIGER? | `TransitionSystem/ExplicitStateSolution.swift` → `aiger` property |
| How does the LLM get called? | `Logic/LLMSolver.swift` → `LLMSolver.query()` |
| How are LLM values turned into a solution? | `BoundedSynthesis/LLMSmtEncoding.swift` → `extractSolution()` |
| How are all input combinations enumerated? | `Logic/Logic.swift` → `allBooleanAssignments(variables:)` |
| How is a Logic AST printed as SMTLIB2? | `Logic/BooleanPrinter.swift` → `SmtPrinter` |
