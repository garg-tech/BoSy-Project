# BoSy — Extended

This repository extends the original [BoSy](https://github.com/reactive-systems/bosy) reactive synthesis
tool with three additional components, developed as part of a study on synthesis
backends and LLM-based solving.

---

## Extensions

### 1. Hybrid Bound Search Strategy (`expo+bs`)

An alternative bound search strategy that combines exponential doubling
(to quickly bracket the solution) with binary search refinement (to find the
minimum bound). This reduces unnecessary solver calls compared to pure
exponential search when the minimal bound matters.

See [BOUND_SEARCH.md](BOUND_SEARCH.md) for a description of the algorithm and
when to prefer each strategy.

```bash
./bosy.sh --strategy expo+bs Samples/simple_arbiter.bosy
```

---

### 2. DQBF Solver Integrations

Two new solvers were added for BoSy's DQBF encodings (`state-symbolic`,
`symbolic`), following the same integration pattern:

#### Pedant

[Pedant](https://github.com/fslivovsky/pedant-solver) is a DQBF solver based
on interpolation/CEGIS. It is the only added solver that also produces an
**AIGER certificate** on SAT (via `--aag`), enabling circuit extraction through
`--synthesize`. Known limitations of the certificate are documented in the
linked readme.

See [PEDANT.md](PEDANT.md) for build instructions, code changes, and
limitations of the AIGER output.

```bash
./bosy.sh --backend state-symbolic --solver pedant --synthesize Samples/simple_arbiter.bosy
```

#### DQBDD

[DQBDD](https://github.com/jurajsic/DQBDD) is a BDD-based DQBF solver. It
supports realizability checking only (no certificate output).

See [DQBDD.md](DQBDD.md) for build instructions and code changes.

```bash
./bosy.sh --backend state-symbolic --solver dqbdd Samples/simple_arbiter.bosy
```

Both solvers are selected via the `--backend` and `--solver` flags described
in [SPECIFIC_SOLVER.md](SPECIFIC_SOLVER.md).

---

### 3. LLM Solver

An experimental backend that sends BoSy's SMTLIB2 encoding directly to an
OpenAI language model (gpt-4o, o4-mini) and asks it to find a satisfying
assignment, bypassing the traditional SMT solver entirely.

**Key finding:** LLMs respond to prompt framing rather than formula content —
they hallucinate SAT at incorrect bounds and ignore quantified constraints such
as the `lambdaSharp` liveness witnesses.

See [LLM_SOLVER.md](LLM_SOLVER.md) for full details, usage, and observations.

```bash
export OPENAI_API_KEY="sk-..."
./bosy.sh --llm-solve --bound 4 Samples/simple_arbiter.bosy
```

---

## Original BoSy

For the original tool documentation — installation, flags, encoding backends,
and the SYNTCOMP results — see [BOSY_README.md](BOSY_README.md).

For a full walkthrough of the codebase, module structure, and pipeline, see
[CODEBASE.md](CODEBASE.md).

## Contributors

Course project (Software Verification, IIT Hyderabad, Jan–May 2026) by
[Devansh Garg](https://github.com/garg-tech), [Tarun](https://github.com/Tarun-pvc),
and [Meet](https://github.com/meet1744), under the guidance of Dr. Ashish Mishra.

## License

This repository is a modified version of BoSy and remains licensed under the
GNU Affero General Public License v3.0 (AGPL-3.0). See [LICENSE](LICENSE).

Original BoSy © Peter Faymonville, Bernd Finkbeiner, and Leander Tentrup —
<https://github.com/reactive-systems/bosy>
