import Foundation
// On Linux, URLSession/URLRequest live in a separate module.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Utils

// MARK: - Provider enum

/// Supported LLM API providers.
public enum LLMProvider: String {
    case openai = "openai"
    case gemini = "gemini"

    /// Default model name for each provider.
    public var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.0-flash"
        }
    }

    /// Environment variable that holds the API key for this provider.
    public var apiKeyEnvVar: String {
        switch self {
        case .openai: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        }
    }

    public static let allValues: [LLMProvider] = [.openai, .gemini]
}

// MARK: - Result type

/// Result returned by LLMSolver for a single bound query.
public struct LLMSolverResult {
    public let sat: Bool
    /// Maps each SMTLIB2 expression string to its value in the model.
    /// Only populated when sat == true.
    public let values: [String: String]

    public init(sat: Bool, values: [String: String]) {
        self.sat = sat
        self.values = values
    }
}

// MARK: - Solver

/// Unified LLM solver that supports both OpenAI and Google Gemini.
///
/// Auth for Gemini (in priority order):
///   1. GEMINI_ACCESS_TOKEN — short-lived OAuth token, e.g. from
///      `gcloud auth print-access-token` after activating a service account.
///      Sent as `Authorization: Bearer <token>`.
///   2. GEMINI_API_KEY — API key appended to the URL as `?key=<key>`.
///
/// Auth for OpenAI:
///   OPENAI_API_KEY — sent as `Authorization: Bearer <key>`.
public struct LLMSolver {
    public let provider: LLMProvider
    public let model: String
    private let credential: String
    // true → Bearer header (OAuth); false → ?key= URL param (API key)
    private let useOAuth: Bool

    /// - Parameters:
    ///   - provider: Which API to call.
    ///   - model: Model name override. When nil, uses provider.defaultModel.
    ///            The LLM_MODEL env var takes precedence over both.
    public init(provider: LLMProvider, model: String? = nil) {
        self.provider = provider
        let envModel = ProcessInfo.processInfo.environment["LLM_MODEL"]
        self.model = envModel ?? model ?? provider.defaultModel

        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .gemini:
            // Prefer an OAuth access token (service account workflow).
            if let token = env["GEMINI_ACCESS_TOKEN"], !token.isEmpty {
                credential = token
                useOAuth   = true
            } else if let key = env["GEMINI_API_KEY"], !key.isEmpty {
                credential = key
                useOAuth   = false
            } else {
                fatalError("Set either GEMINI_ACCESS_TOKEN (service account) or GEMINI_API_KEY for Gemini")
            }
        case .openai:
            guard let key = env["OPENAI_API_KEY"], !key.isEmpty else {
                fatalError("OPENAI_API_KEY environment variable is not set")
            }
            credential = key
            useOAuth   = false
        }
    }

    /// Send the SMTLIB2 formula to the configured LLM and request model values
    /// for every expression in getValueExpressions.
    ///
    /// Returns nil only on hard failures (network error, unparseable envelope).
    /// An UNSAT verdict is returned as LLMSolverResult(sat: false, values: [:]).
    public func query(
        smtlibFormula: String,
        getValueExpressions: [String]
    ) -> LLMSolverResult? {
        switch provider {
        case .openai: return queryOpenAI(formula: smtlibFormula, expressions: getValueExpressions)
        case .gemini: return queryGemini(formula: smtlibFormula, expressions: getValueExpressions)
        }
    }

    // MARK: - Shared prompt construction

    private func buildSystemPrompt() -> String {
        """
        You are an SMT solver. Given an SMTLIB2 formula, your job is to find \
        concrete values for all declared functions that make every (assert ...) \
        true simultaneously. Work through the constraints and construct a \
        satisfying assignment. Only return UNSAT if you have tried and confirmed \
        that no valid assignment exists. \
        Respond with valid JSON and nothing else.
        """
    }

    private func buildUserPrompt(formula: String, expressions: [String]) -> String {
        let numbered = expressions
            .enumerated()
            .map { idx, expr in "  \(idx + 1). \(expr)" }
            .joined(separator: "\n")

        return """
        Find a satisfying assignment for the following SMTLIB2 formula. \
        The formula declares functions tau (transition), lambda/lambdaSharp \
        (automaton tracking), and output functions. \
        Your goal is to assign concrete values to these functions so that \
        every (assert ...) in the formula holds at the same time.

        --- FORMULA BEGIN ---
        \(formula)(check-sat)
        --- FORMULA END ---

        Steps:
        1. Read the (declare-fun ...) statements to understand what functions \
           need values.
        2. Work through each (assert ...) and find values for tau, the output \
           functions, lambda, and lambdaSharp that satisfy all of them together.
        3. Once you have a candidate assignment, verify it against every assert.
        4. If a valid assignment exists, return it. Only return UNSAT if you \
           have confirmed no assignment can satisfy all assertions at once.

        Provide the values of these expressions under your satisfying assignment:
        \(numbered)

        Respond with ONLY a JSON object — no markdown, no explanation.

        Format when a satisfying assignment is found:
        {"result":"sat","values":{"<expr1>":"<val1>","<expr2>":"<val2>",...}}

        Format when no satisfying assignment exists:
        {"result":"unsat"}

        Value rules:
        - System states must be formatted as "s0", "s1", "s2", etc.
        - Boolean values must be exactly "true" or "false" (lowercase).
        - Every expression listed above must have an entry in "values".
        """
    }

    // MARK: - OpenAI

    private func queryOpenAI(formula: String, expressions: [String]) -> LLMSolverResult? {
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": buildSystemPrompt()],
                ["role": "user",   "content": buildUserPrompt(formula: formula, expressions: expressions)],
            ],
        ]

        guard let requestJSON = try? JSONSerialization.data(withJSONObject: requestBody) else {
            Logger.default().error("LLMSolver/OpenAI: failed to serialize request body")
            return nil
        }

        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = requestJSON
        urlRequest.timeoutInterval = 600

        guard let data = performRequest(urlRequest, label: "OpenAI") else { return nil }

        guard
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices  = envelope["choices"] as? [[String: Any]],
            let message  = choices.first?["message"] as? [String: Any],
            let content  = message["content"] as? String
        else {
            Logger.default().error("LLMSolver/OpenAI: unexpected response envelope")
            logRaw(data)
            return nil
        }

        Logger.default().info("LLMSolver/OpenAI: received response (length=\(content.count))")
        Logger.default().info("LLMSolver/OpenAI: raw LLM response:\n\(content)")
        return parseLLMResponse(content)
    }

    // MARK: - Gemini

    private func queryGemini(formula: String, expressions: [String]) -> LLMSolverResult? {
        // Auth mode A: OAuth bearer token (service account via gcloud)
        //   Uses the Vertex AI endpoint — the only endpoint that accepts
        //   cloud-platform-scoped service account tokens for Gemini.
        //   Requires GOOGLE_CLOUD_PROJECT env var.
        //   Region defaults to us-central1 or GOOGLE_CLOUD_REGION env var.
        //
        // Auth mode B: API key — uses the generativelanguage.googleapis.com
        //   endpoint with the key embedded in the URL query string.
        let urlString: String
        if useOAuth {
            let env     = ProcessInfo.processInfo.environment
            guard let project = env["GOOGLE_CLOUD_PROJECT"], !project.isEmpty else {
                Logger.default().error("LLMSolver/Gemini: GOOGLE_CLOUD_PROJECT env var must be set when using GEMINI_ACCESS_TOKEN")
                return nil
            }
            let region = env["GOOGLE_CLOUD_REGION"] ?? "us-central1"
            urlString = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(model):generateContent"
        } else {
            urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(credential)"
        }

        guard let url = URL(string: urlString) else {
            Logger.default().error("LLMSolver/Gemini: could not construct URL")
            return nil
        }

        let requestBody: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": buildSystemPrompt()]],
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": buildUserPrompt(formula: formula, expressions: expressions)]],
                ],
            ],
            "generationConfig": ["temperature": 0],
        ]

        guard let requestJSON = try? JSONSerialization.data(withJSONObject: requestBody) else {
            Logger.default().error("LLMSolver/Gemini: failed to serialize request body")
            return nil
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if useOAuth {
            urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = requestJSON
        urlRequest.timeoutInterval = 600

        guard let data = performRequest(urlRequest, label: "Gemini") else { return nil }

        guard
            let envelope   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = envelope["candidates"] as? [[String: Any]],
            let content    = candidates.first?["content"] as? [String: Any],
            let parts      = content["parts"] as? [[String: Any]],
            let text       = parts.first?["text"] as? String
        else {
            Logger.default().error("LLMSolver/Gemini: unexpected response envelope")
            logRaw(data)
            return nil
        }

        Logger.default().info("LLMSolver/Gemini: received response (length=\(text.count))")
        Logger.default().info("LLMSolver/Gemini: raw LLM response:\n\(text)")
        return parseLLMResponse(text)
    }

    // MARK: - Shared HTTP + parsing helpers

    /// Perform a synchronous URL request and return the raw response body.
    private func performRequest(_ request: URLRequest, label: String) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        URLSession.shared.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let error = responseError {
            Logger.default().error("LLMSolver/\(label): HTTP request failed: \(error)")
            return nil
        }
        guard let data = responseData else {
            Logger.default().error("LLMSolver/\(label): received empty response body")
            return nil
        }
        return data
    }

    /// Parse the JSON blob that the LLM returned into an LLMSolverResult,
    /// stripping markdown code fences if the model added them despite instructions.
    private func parseLLMResponse(_ content: String) -> LLMSolverResult? {
        var jsonString = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            jsonString = lines.dropFirst().dropLast()
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let parsed   = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let result   = parsed["result"] as? String
        else {
            Logger.default().error("LLMSolver: could not parse JSON from content: \(content)")
            return nil
        }

        if result == "unsat" {
            return LLMSolverResult(sat: false, values: [:])
        }

        guard result == "sat", let values = parsed["values"] as? [String: String] else {
            Logger.default().error("LLMSolver: unexpected result value or missing 'values': \(content)")
            return nil
        }

        return LLMSolverResult(sat: true, values: values)
    }

    private func logRaw(_ data: Data) {
        if let raw = String(data: data, encoding: .utf8) {
            Logger.default().error("LLMSolver: raw response: \(raw)")
        }
    }
}
