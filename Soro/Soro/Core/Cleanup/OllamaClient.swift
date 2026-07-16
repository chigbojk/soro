import Foundation

/// One curated Ollama cleanup model surfaced in Settings.
///
/// Extend the catalogue by appending to `OllamaClient.curatedModels`; the picker
/// and pull affordance both read from that single list.
struct OllamaModelOption: Identifiable, Equatable, Sendable {
    /// The Ollama tag, e.g. `llama3.2:3b`. Doubles as the stable id.
    let id: String
    /// Short human label, e.g. "Fast (3B)".
    let label: String
    /// One-line quality/speed trade-off.
    let hint: String

    var modelName: String { id }
}

/// Thin `URLSession` client for the local Ollama HTTP API (brief §8).
///
/// ONLY talks to `http://127.0.0.1:11434` — no other host, ever. No telemetry.
/// All calls degrade gracefully: availability probes and generation return
/// `nil`/`false` on any error rather than throwing to the caller.
struct OllamaClient {
    /// Production endpoint — the ONLY host this app ever contacts (brief §8).
    static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    /// Curated "recommended" cleanup models surfaced in Settings (fast → high quality).
    /// Any live-installed model from `/api/tags` is merged in on top of these.
    static let curatedModels: [OllamaModelOption] = [
        OllamaModelOption(id: "llama3.2:3b", label: "Fast (3B)",
                          hint: "Fastest, lower quality — great default"),
        OllamaModelOption(id: "qwen2.5:7b", label: "Balanced (7B)",
                          hint: "Better cleanup, still quick on Apple Silicon"),
        OllamaModelOption(id: "llama3.1:8b", label: "High quality (8B)",
                          hint: "Best cleanup, slower and heavier"),
    ]

    /// Look up a curated option by its Ollama tag, if present.
    static func curatedModel(id: String) -> OllamaModelOption? {
        curatedModels.first { $0.id == id }
    }

    /// Ollama treats `name` and `name:latest` as the same model. Normalise so
    /// install-state detection matches regardless of how the tag was written.
    static func normalizeTag(_ tag: String) -> String {
        tag.contains(":") ? tag : "\(tag):latest"
    }

    /// Whether `model` appears in `installed` (accounting for the implicit
    /// `:latest` tag). Pure — unit-testable without a live daemon.
    static func isInstalled(_ model: String, in installed: [String]) -> Bool {
        let target = normalizeTag(model)
        return installed.contains { normalizeTag($0) == target }
    }

    /// Parse the model names out of a raw `/api/tags` JSON body. Returns `[]` on
    /// malformed input. Pure — the network path in `installedModels()` delegates here.
    static func parseTagNames(from data: Data) -> [String] {
        guard let decoded = try? JSONDecoder().decode(TagsResponse.self, from: data) else {
            return []
        }
        return decoded.models.map(\.name)
    }

    /// Parse a single streamed `/api/pull` progress line into a 0…1 fraction and
    /// status text. Returns `nil` for lines we can't interpret. Pure — testable.
    static func parsePullProgress(from line: Data) -> (fraction: Double?, status: String)? {
        guard let p = try? JSONDecoder().decode(PullProgress.self, from: line) else { return nil }
        var fraction: Double? = nil
        if let total = p.total, total > 0, let completed = p.completed {
            fraction = min(1.0, max(0.0, Double(completed) / Double(total)))
        }
        return (fraction, p.status ?? "")
    }

    /// The base URL actually used. Always on `127.0.0.1` — the port is
    /// overridable only so tests can target a dead loopback port; production
    /// callers never change it.
    let baseURL: URL

    /// Model used for cleanup generation. Default fast model per brief (§1/§8).
    var model: String = "llama3.2:3b"

    /// Timeout for the `/api/tags` availability probe (brief: 1.5s).
    var availabilityTimeout: TimeInterval = 1.5

    /// Hard request timeout for a generation call (brief: 4s).
    var generateTimeout: TimeInterval = 4.0

    /// Sampling temperature — low for deterministic cleanup (brief: ~0.2).
    var temperature: Double = 0.2

    private let session: URLSession

    /// - Parameter session: injectable for tests; defaults to an ephemeral,
    ///   non-caching session that never uses cookies or credentials.
    init(model: String = "llama3.2:3b",
         availabilityTimeout: TimeInterval = 1.5,
         generateTimeout: TimeInterval = 4.0,
         temperature: Double = 0.2,
         baseURL: URL = OllamaClient.defaultBaseURL,
         session: URLSession? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.availabilityTimeout = availabilityTimeout
        self.generateTimeout = generateTimeout
        self.temperature = temperature
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    /// Whether the local Ollama daemon answers `GET /api/tags` within the probe
    /// timeout. Any failure (refused connection, DNS, timeout, non-2xx) → false.
    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = availabilityTimeout
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// The list of installed model names from `/api/tags`, or `[]` on failure.
    func installedModels() async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = availabilityTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }
            return Self.parseTagNames(from: data)
        } catch {
            return []
        }
    }

    /// Streams `POST /api/pull` to download `model`, reporting progress as a 0…1
    /// fraction (nil when Ollama hasn't reported byte totals yet). Returns `true`
    /// once the daemon reports success, `false` on any failure. Degrades
    /// gracefully — never throws to the caller.
    ///
    /// Note: a pull can be large/slow, so this deliberately uses NO generation
    /// timeout; the caller owns cancellation by dropping the task.
    func pullModel(_ model: String, progress: @escaping (Double?, String) -> Void) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = PullRequest(model: model, stream: true)
        guard let encoded = try? JSONEncoder().encode(body) else { return false }
        request.httpBody = encoded

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return false }
            var sawSuccess = false
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let parsed = Self.parsePullProgress(from: data) else { continue }
                progress(parsed.fraction, parsed.status)
                if parsed.status.lowercased() == "success" { sawSuccess = true }
            }
            return sawSuccess
        } catch {
            return false
        }
    }

    /// Runs a non-streaming chat completion. Returns the assistant message
    /// content, or `nil` on any failure/timeout. Enforces a hard 4s timeout.
    func generate(system: String, user: String) async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = generateTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatRequest(
            model: model,
            stream: false,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            options: .init(temperature: temperature))
        guard let encoded = try? JSONEncoder().encode(body) else { return nil }
        request.httpBody = encoded

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            let content = decoded.message.content
            return content.isEmpty ? nil : content
        } catch {
            return nil
        }
    }
}

// MARK: - Wire types

private struct TagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

private struct ChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    struct Options: Encodable { let temperature: Double }
    let model: String
    let stream: Bool
    let messages: [Message]
    let options: Options
}

private struct ChatResponse: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message
}

private struct PullRequest: Encodable {
    let model: String
    let stream: Bool
}

private struct PullProgress: Decodable {
    let status: String?
    let total: Int64?
    let completed: Int64?
}
