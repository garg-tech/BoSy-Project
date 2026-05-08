# LLM Solver for BoSy

This document describes the LLM-based synthesis backend added to BoSy.
Instead of calling a traditional SMT solver (Z3, CVC4), it sends the
SMTLIB2 encoding to an LLM (Google Gemini or OpenAI) and asks it to find
a satisfying assignment.

---

## Quick start

```bash
# Gemini (default)
export GEMINI_API_KEY="AI..."
./bosy.sh --llm-solve --bound 4 Samples/simple_arbiter.bosy

# OpenAI
export OPENAI_API_KEY="sk-..."
./bosy.sh --llm-solve --llm-provider openai --bound 4 Samples/simple_arbiter.bosy
```

Output is identical to the standard BoSy output: `REALIZABLE` followed by
the AIGER circuit, or `UNKNOWN` if no solution was found within the bound.

---

## New flags (BoSy executable only)

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--llm-solve` | Bool | — | Enable the LLM backend. When given, the concurrent game-solving search is skipped entirely. |
| `--bound N` | Int | 4 | Upper bound on the number of states. The loop tries bound = 1, 2, …, N. Prints `UNKNOWN` and exits 0 when exhausted. |
| `--llm-provider NAME` | String | `gemini` | Which API to call: `gemini` or `openai`. |
| `--llm-model NAME` | String | *(provider default)* | Model name override. Defaults to `gemini-2.0-flash` for Gemini and `gpt-4o` for OpenAI. |

All existing BoSy flags continue to work unchanged when `--llm-solve` is
**not** given.

---

## Environment variables

| Variable | Required for | Description |
|----------|-------------|-------------|
| `GEMINI_API_KEY` | `--llm-provider gemini` (default) | Google AI Studio / Gemini API key. |
| `OPENAI_API_KEY` | `--llm-provider openai` | OpenAI platform API key. |
| `LLM_MODEL` | optional | Runtime model override; takes precedence over `--llm-model` and the provider default. Useful for quick experiments without rebuilding. |

---

## How it works

### 1 — Automaton construction (unchanged)

```
SynthesisSpecification  →  CoBüchiAutomaton.from(ltl: !spec.ltl)
```

The standard BoSy pipeline builds a Co-Büchi automaton from the negation of
the LTL specification using `spot` (or `ltl3ba`). No change here.

### 2 — Iterative bound search

The outer loop in `BoSy/main.swift` tries bound = 1, 2, …, maxStates,
calling `LLMSmtEncoding.solve(forBound:)` each time. On SAT the loop breaks
and solution extraction runs immediately. On UNSAT the bound is incremented.
If the bound exceeds `--bound N` the tool reports `UNKNOWN`.

There is **no concurrent search** and **no game-reduction** step; the SMT
encoding handles the Co-Büchi → safety reduction internally via the
`lambdaSharp` integer counter variables.

### 3 — SMTLIB2 formula generation

`LLMSmtEncoding` delegates formula construction to
`SmtEncoding.getEncoding(forBound:)` (the existing Z3/CVC4 path). The
formula uses the `UFDTLIA` logic and encodes:

- `S` — a finite datatype with `s0 … s(k-1)` as constructors.
- `lambda_q(s): Bool` — true iff automaton state q is consistent with
  system state s.
- `lambdaSharp_q(s): Int` — ranking function witnessing the absence of
  infinite rejecting cycles.
- `tau(s, i1, …, in): S` — transition function.
- `out_j(s [, i1, …, in]): Bool` — output functions (Moore: state only;
  Mealy: state + inputs).

### 4 — Pre-computing model queries

Before calling the LLM, `LLMSmtEncoding.buildQueryExpressions(forBound:)`
enumerates every expression that `extractSolution()` will need:

- `(tau s<i> b1 … bn)` — one per (state × input combination).
- `(out s<i> [b1 … bn])` — one per (output × state [× input combination]).

All expressions are serialised with `SmtPrinter`, so the strings match
exactly between query generation and solution extraction.

### 5 — Single API call to the LLM

`LLMSolver.query(smtlibFormula:getValueExpressions:)` in
`Sources/Logic/LLMSolver.swift`:

1. Builds a prompt asking for SAT/UNSAT + a JSON map of expression values.
2. Dispatches to the provider-specific HTTP method.
3. Strips optional markdown code fences from the response.
4. Returns `LLMSolverResult(sat:values:)` on success.

The HTTP call is made synchronously via `URLSession.dataTask` +
`DispatchSemaphore`, consistent with how other solvers use
`TSCBasic.Process.popen`.

#### Provider differences

| | OpenAI | Gemini |
|--|--|--|
| Endpoint | `https://api.openai.com/v1/chat/completions` | `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}` |
| Auth | `Authorization: Bearer <key>` header | Key embedded in URL |
| Request schema | `{"messages":[{"role":"system",…},{"role":"user",…}]}` | `{"systemInstruction":{…},"contents":[…],"generationConfig":{…}}` |
| Response path | `choices[0].message.content` | `candidates[0].content.parts[0].text` |

The system and user prompts are **identical** for both providers; only the
HTTP wrapper differs.

### 6 — Solution extraction

`LLMSmtEncoding.extractSolution()` mirrors `SmtEncoding.extractSolution()`
but reads values from the in-memory `cachedValues: [String: String]` map:

- **Transitions**: parses `"s3"` → drops the leading `s` → integer index.
- **Boolean outputs**: compares string `"true"` / `"false"`.

The result is an `ExplicitStateSolution` which conforms to
`AigerRepresentable`. `main.swift` minimises the circuit with `abc` before
writing to stdout.

---

## Files added / modified

### Added

| File | Purpose |
|------|---------|
| `Sources/Logic/LLMSolver.swift` | `LLMProvider` enum, `LLMSolverResult` type, `LLMSolver` struct with OpenAI and Gemini HTTP backends. |
| `Sources/BoundedSynthesis/LLMSmtEncoding.swift` | `LLMSmtEncoding` struct — wraps `SmtEncoding` for formula generation, calls `LLMSolver`, caches model values, implements `extractSolution()`. |
| `LLM_SOLVER.md` | This file. |

### Modified

| File | Change |
|------|--------|
| `Sources/BoSy/main.swift` | `LLMProvider: ArgumentKind` extension; `--llm-solve`, `--bound`, `--llm-provider`, `--llm-model` argument definitions; LLM code path before the concurrent search block. |
| `bosy.sh` | Detects `--llm-solve` and `--llm-provider`; checks the correct API key env var before invoking the binary. |

---

## Adding support for other encodings later

Currently only the SMT encoding (`SmtEncoding`) is supported. To add QBF
via `InputSymbolicEncoding`:

1. Add `LLMQbfEncoding.swift` in `Sources/BoundedSynthesis/` that wraps
   `InputSymbolicEncoding.getEncoding(forBound:)` and serialises the
   `Logic` AST to QDIMACS.
2. Add `--encoding smt|qbf` to `main.swift` and dispatch accordingly
   inside the `if llmSolve` block.

`LLMSolver` in `LLMSolver.swift` is encoding-agnostic — only the prompt
and value-parsing rules differ between encodings.

---

## Observations (simple_arbiter, gpt-4o)

These observations come from running `gpt-4o` on `Samples/simple_arbiter.bosy`
(3-input, 3-output Mealy arbiter). The correct solution requires bound 4.

### Prompt biases the LLM heavily

The LLM has no mechanism to actually solve the SMTLIB2 formula — it
pattern-matches the prompt framing and produces output that fits the expected
shape. The prompt wording alone determines whether it leans SAT or UNSAT:

**Prompt framing: "find a satisfying assignment" (active task)**
The LLM returns `sat` at bound 1 with a structurally well-formed but logically
wrong assignment — all output functions constantly false, single state looping
to itself. This satisfies mutual exclusion trivially (nothing is ever granted)
but violates liveness (requests are never served). The real solver correctly
identifies bound 1 as UNSAT. The LLM hallucinated a SAT answer at a bound
where no solution exists.

**Prompt framing: "wrong SAT is worse than honest UNSAT" (UNSAT-biased)**
The LLM returns `unsat` at every bound — 1, 2, 4, 8, 16, 32 — including bounds
well above the actual solution bound of 4. It never attempts to construct an
assignment regardless of the formula size. This is the opposite failure mode:
the model took the path of least resistance in the direction the prompt nudged.

### Core finding

The LLM does not reason about the formula content. It responds to the
incentive structure of the prompt:
- Incentivise finding an answer → spurious SAT at wrong bounds.
- Incentivise caution → blanket UNSAT across all bounds.

A balanced prompt produces inconsistent behaviour across runs, which is itself
informative: the model has no reliable internal signal to distinguish SAT from
UNSAT for these quantified synthesis formulas.

---

## Observations (simple_arbiter, o4-mini)

These observations come from running `o4-mini` on `Samples/simple_arbiter.bosy`
with `--bound 8` and the active-task prompt framing (same prompt as the gpt-4o
run above). The correct solution requires bound 4.

### Bound 1: correct UNSAT

`o4-mini` returned `unsat` at bound 1, which agrees with the real solver — no
1-state solution exists for this arbiter. This is a marginal improvement over
`gpt-4o`, which hallucinated SAT at bound 1.

### Bound 2: same degenerate pattern

At bound 2 (64 value expressions) `o4-mini` returned `sat` with the following
assignment:

- **Transition function**: a 2-state ping-pong — s0 always goes to s1, s1
  always goes to s0, completely input-blind.
- **All three outputs (g_0, g_1, g_2)**: constantly `false` for every state
  and every input combination.

The real solver says UNSAT at bound 2; the correct solution only exists at
bound 4. `o4-mini` hallucinated a SAT answer one bound earlier than a valid
solution can exist.

### Why this assignment is wrong

The all-false outputs satisfy **mutual exclusion** trivially (nothing is ever
granted, so no two grants can be simultaneously active). They violate
**liveness** (`G(r_i → F g_i)`): every request must eventually be granted, but
no grant is ever issued. The `lambdaSharp` integer ranking constraints in the
SMTLIB2 formula exist precisely to rule out this kind of infinite non-granting
behaviour — but the LLM ignores them.

The assignment is the cheapest syntactically valid JSON the model could produce:
tau returns valid state names, outputs return valid booleans. It pattern-fills
the expected response shape without evaluating a single assertion.

### Comparison with gpt-4o

| Model   | Bound 1 | Bound 2 | Bound 4 (correct) |
|---------|---------|---------|-------------------|
| gpt-4o  | SAT (hallucinated, wrong) | — | — |
| o4-mini | UNSAT (correct) | SAT (hallucinated, wrong) | — |

`o4-mini` shows slightly better structural awareness — it did not claim a
1-state solution is possible — but the failure mode is identical: produce the
minimal all-false-output assignment, ignore liveness constraints, report SAT one
bound before a real solution could exist.

---

## Limitations

- **No correctness guarantee**: the LLM may return a `sat` answer with a
  model that does not actually satisfy the formula. The extracted AIGER
  circuit is not formally verified.
- **API latency**: each bound attempt is one synchronous API round-trip.
  Large formulas may exceed the model's context window.
- **No unrealisability detection**: the LLM path only searches for a system
  strategy. It prints `UNKNOWN` when the bound is exhausted.
- **Cost**: every bound attempt consumes tokens. Start with a small `--bound`
  (2–4) and increase as needed.
