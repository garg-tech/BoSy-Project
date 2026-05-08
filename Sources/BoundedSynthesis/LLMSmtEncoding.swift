import Automata
import Logic
import Specification
import TransitionSystem
import Utils

/// Bounded synthesis encoding that delegates satisfiability checking to an
/// LLM (OpenAI or Gemini) instead of a traditional SMT solver (Z3 / CVC4).
///
/// For each bound k the encoding works as follows:
///   1. Build the standard SMTLIB2 formula via SmtEncoding.getEncoding(forBound:).
///   2. Pre-compute all (get-value ...) queries that extractSolution() will need.
///   3. Send both to the configured LLM in a single API call, asking for
///      SAT/UNSAT plus the full model as a JSON map { expression → value }.
///   4. Cache the values map; extractSolution() reads from it directly.
///
/// The outer loop in BoSy/main.swift increments the bound on UNSAT up to
/// the user-supplied --bound upper limit.
public struct LLMSmtEncoding: BoSyEncoding {
    let options: BoSyOptions
    let automaton: CoBüchiAutomaton
    let specification: SynthesisSpecification
    public let llmProvider: LLMProvider
    /// nil → use provider.defaultModel (resolved inside LLMSolver.init).
    public let llmModel: String?

    // State populated after a successful solve call.
    private var cachedValues: [String: String] = [:]
    private var solutionBound: Int = 0

    public init(
        options: BoSyOptions,
        automaton: CoBüchiAutomaton,
        specification: SynthesisSpecification,
        llmProvider: LLMProvider = .gemini,
        llmModel: String? = nil
    ) {
        self.options = options
        self.automaton = automaton
        self.specification = specification
        self.llmProvider = llmProvider
        self.llmModel = llmModel
    }

    // MARK: - BoSyEncoding

    public mutating func solve(forBound bound: Int) throws -> Bool {
        Logger.default().info("LLMSmtEncoding: building SMT encoding for bound \(bound)")

        // Reuse the existing SmtEncoding formula builder — no need to duplicate it.
        let inner = SmtEncoding(options: options, automaton: automaton, specification: specification)
        guard let formula = inner.getEncoding(forBound: bound) else {
            throw BoSyEncodingError.EncodingFailed("SmtEncoding.getEncoding failed for bound \(bound)")
        }

        let queries = buildQueryExpressions(forBound: bound)
        let resolvedModel = llmModel ?? llmProvider.defaultModel
        Logger.default().info("LLMSmtEncoding: querying \(llmProvider.rawValue)/\(resolvedModel) (bound=\(bound), \(queries.count) value expressions)")

        let solver = LLMSolver(provider: llmProvider, model: llmModel)
        guard let result = solver.query(smtlibFormula: formula, getValueExpressions: queries) else {
            throw BoSyEncodingError.SolvingFailed("LLM API call failed for bound \(bound)")
        }

        if result.sat {
            solutionBound = bound
            cachedValues  = result.values
            Logger.default().info("LLMSmtEncoding: SAT at bound \(bound)")
            return true
        }

        Logger.default().info("LLMSmtEncoding: UNSAT at bound \(bound), will try larger bound")
        return false
    }

    public func extractSolution() -> TransitionSystem? {
        guard solutionBound > 0 else {
            Logger.default().error("LLMSmtEncoding: extractSolution called before a successful solve")
            return nil
        }

        let printer = SmtPrinter()
        let inputProps: [Proposition] = specification.inputs.map { Proposition($0) }
        var solution = ExplicitStateSolution(bound: solutionBound, specification: specification)

        Logger.default().info("LLMSmtEncoding: extracting solution from \(cachedValues.count) cached values")
        for (expr, val) in cachedValues.sorted(by: { $0.key < $1.key }) {
            Logger.default().info("  \(expr)  →  \(val)")
        }

        // --- Transition relation ---
        for source in 0 ..< solutionBound {
            for assignment in allBooleanAssignments(variables: inputProps) {
                let parameters = inputProps.map { assignment[$0]! }
                let expr = tauExpression(source: source, parameters: parameters, printer: printer)

                guard let stateValue = cachedValues[expr] else {
                    Logger.default().error("LLMSmtEncoding: missing value for tau expression '\(expr)'")
                    return nil
                }
                // stateValue == "s3" → drop the leading 's' and parse the index.
                guard let target = Int(stateValue.dropFirst()) else {
                    Logger.default().error("LLMSmtEncoding: cannot parse state '\(stateValue)' for expression '\(expr)'")
                    return nil
                }
                let guard_ = assignment
                    .map { prop, val in val == Literal.True ? prop : (!prop as Logic) }
                    .reduce(Literal.True as Logic, { $0 & $1 })
                solution.addTransition(from: source, to: target, withGuard: guard_)
            }
        }

        // --- Output functions ---
        for output in specification.outputs {
            for source in 0 ..< solutionBound {
                let enabled: Logic
                switch specification.semantics {
                case .mealy:
                    // Build the enabling condition as a conjunction of
                    // "¬<input_assignment>" for every input combination where
                    // the output evaluates to false — matching SmtEncoding's logic.
                    var disablingClauses: [Logic] = []
                    for assignment in allBooleanAssignments(variables: inputProps) {
                        let parameters: [Logic] = inputProps.map { assignment[$0]! }
                        let expr = outputExpression(
                            output: output, source: source,
                            parameters: parameters, printer: printer
                        )
                        guard let boolValue = cachedValues[expr] else {
                            Logger.default().error("LLMSmtEncoding: missing value for output expression '\(expr)'")
                            return nil
                        }
                        if boolValue == "false" {
                            let blockingClause = assignment
                                .map { prop, val in val == Literal.True ? (!prop as Logic) : prop }
                                .reduce(Literal.False as Logic, { $0 | $1 })
                            disablingClauses.append(blockingClause)
                        }
                    }
                    enabled = disablingClauses.reduce(Literal.True as Logic, { $0 & $1 })

                case .moore:
                    let expr = outputExpression(
                        output: output, source: source,
                        parameters: [], printer: printer
                    )
                    guard let boolValue = cachedValues[expr] else {
                        Logger.default().error("LLMSmtEncoding: missing value for Moore output expression '\(expr)'")
                        return nil
                    }
                    enabled = boolValue == "true" ? Literal.True : Literal.False
                }
                solution.add(output: output, inState: source, withGuard: enabled)
            }
        }

        return solution
    }

    // MARK: - Helpers

    /// Build the complete list of SMTLIB2 expression strings that
    /// extractSolution() will need, so they can be sent to the LLM in one shot.
    private func buildQueryExpressions(forBound bound: Int) -> [String] {
        let printer = SmtPrinter()
        let inputProps: [Proposition] = specification.inputs.map { Proposition($0) }
        var queries: [String] = []

        // tau queries — one per (source state × input combination)
        for source in 0 ..< bound {
            for assignment in allBooleanAssignments(variables: inputProps) {
                let parameters = inputProps.map { assignment[$0]! }
                queries.append(tauExpression(source: source, parameters: parameters, printer: printer))
            }
        }

        // output queries — one per (output × source state [× input combination for Mealy])
        for output in specification.outputs {
            for source in 0 ..< bound {
                switch specification.semantics {
                case .mealy:
                    for assignment in allBooleanAssignments(variables: inputProps) {
                        let parameters: [Logic] = inputProps.map { assignment[$0]! }
                        queries.append(outputExpression(
                            output: output, source: source,
                            parameters: parameters, printer: printer
                        ))
                    }
                case .moore:
                    queries.append(outputExpression(
                        output: output, source: source,
                        parameters: [], printer: printer
                    ))
                }
            }
        }

        return queries
    }

    /// Returns the SmtPrinter-formatted string for  (tau s<source> p1 p2 ...).
    private func tauExpression(source: Int, parameters: [Logic], printer: SmtPrinter) -> String {
        let app = FunctionApplication(
            function: Proposition("tau"),
            application: ([Proposition("s\(source)")] as [Logic]) + parameters
        )
        return app.accept(visitor: printer)
    }

    /// Returns the SmtPrinter-formatted string for  (output s<source> [p1 p2 ...]).
    /// parameters is empty for Moore semantics.
    private func outputExpression(output: String, source: Int, parameters: [Logic], printer: SmtPrinter) -> String {
        let app = FunctionApplication(
            function: Proposition(output),
            application: ([Proposition("s\(source)")] as [Logic]) + parameters
        )
        return app.accept(visitor: printer)
    }
}
