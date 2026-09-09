import Foundation

struct ProjectAdoptionConflict: Decodable, Identifiable, Sendable {
    let path: String
    let reason: String
    let existingSha256: String?
    let incomingSha256: String?

    var id: String { path }
}

struct ProjectAdoptionResult: Decodable, Sendable {
    let status: String
    let sourceRoot: String
    let sourceDigest: String
    let applications: [String]
    let imported: Int
    let unchanged: Int
    let removed: Int
    let conflicting: Int
    let rejected: Int
    let conflicts: [ProjectAdoptionConflict]
    let skippedLocalState: [String]
    let executedJourneys: Bool

    var accepted: Bool { status != "conflict" }

    var summary: String {
        switch status {
        case "unchanged":
            "Already current: \(unchanged) definitions unchanged. No journey ran."
        case "replaced":
            "Updated: \(imported) imported, \(unchanged) unchanged, \(removed) removed. No journey ran."
        case "imported":
            "Adopted: \(imported) imported and \(unchanged) already matched. No journey ran."
        default:
            "Not adopted: \(conflicting) conflicts and \(rejected) rejected definitions. No files changed."
        }
    }
}

struct ProjectAdoptionSource: Decodable, Identifiable, Sendable {
    let sourceKey: String
    let sourceRoot: String
    let sourceDigest: String
    let adoptedAt: String
    let applications: [String]
    let fileCount: Int

    var id: String { sourceKey }
}

struct ProjectAdoptionIndex: Decodable, Sendable {
    let sources: [ProjectAdoptionSource]
}

actor ProjectAdoptionClient {
    enum ClientError: LocalizedError {
        case missingCLI
        case launch(String)
        case invalidReadyLine
        case service(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingCLI:
                "The selected workspace does not contain an executable Probierz service."
            case .launch(let detail):
                "Probierz could not start its local service: \(detail)"
            case .invalidReadyLine:
                "Probierz did not publish a valid local service address."
            case .service(let detail):
                detail
            case .invalidResponse:
                "Probierz returned an invalid service response."
            }
        }
    }

    private struct Ready: Decodable {
        let ready: Bool
        let host: String
        let port: Int
    }

    private struct ServiceError: Decodable {
        let error: String
    }

    private struct AdoptionRequest: Encodable {
        let sourceRoot: String
        let replace: Bool
    }

    private var process: Process?
    private var repositoryRoot: URL?
    private var baseURL: URL?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    deinit {
        process?.terminate()
    }

    func adopt(repositoryRoot: URL, sourceRoot: URL, replace: Bool) async throws -> ProjectAdoptionResult {
        let request = try await makeRequest(
            repositoryRoot: repositoryRoot,
            path: "/v1/project-adoptions",
            method: "POST",
            body: AdoptionRequest(sourceRoot: sourceRoot.standardizedFileURL.path, replace: replace)
        )
        return try JSONDecoder().decode(ProjectAdoptionResult.self, from: request)
    }

    func list(repositoryRoot: URL) async throws -> ProjectAdoptionIndex {
        let data = try await makeRequest(
            repositoryRoot: repositoryRoot,
            path: "/v1/project-adoptions",
            method: "GET",
            body: Optional<AdoptionRequest>.none
        )
        return try JSONDecoder().decode(ProjectAdoptionIndex.self, from: data)
    }

    private func makeRequest<Body: Encodable>(
        repositoryRoot: URL,
        path: String,
        method: String,
        body: Body?
    ) async throws -> Data {
        try await request(
            repositoryRoot: repositoryRoot, path: path, method: method,
            body: try body.map { try JSONEncoder().encode($0) }
        )
    }

    func request(
        repositoryRoot: URL, path: String, method: String, body: Data?
    ) async throws -> Data {
        let baseURL = try startIfNeeded(repositoryRoot: repositoryRoot)
        guard let url = URL(string: path, relativeTo: baseURL) else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let serviceError = try? JSONDecoder().decode(ServiceError.self, from: data) {
                throw ClientError.service(serviceError.error)
            }
            throw ClientError.invalidResponse
        }
        return data
    }

    private func startIfNeeded(repositoryRoot: URL) throws -> URL {
        let normalizedRoot = repositoryRoot.standardizedFileURL
        if self.repositoryRoot == normalizedRoot,
           let process,
           process.isRunning,
           let baseURL {
            return baseURL
        }
        process?.terminate()
        process = nil
        baseURL = nil

        let binary = try Self.binary(repositoryRoot: normalizedRoot)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--harness", normalizedRoot.path, "serve", "--port", "0"]
        process.currentDirectoryURL = normalizedRoot
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ClientError.launch(error.localizedDescription)
        }

        let readyData = stdout.fileHandleForReading.availableData
        guard readyData.count <= 16_384,
              let line = String(data: readyData, encoding: .utf8)?.split(separator: "\n").first,
              let data = String(line).data(using: .utf8),
              let ready = try? JSONDecoder().decode(Ready.self, from: data),
              ready.ready,
              ready.host == "127.0.0.1",
              (1...65_535).contains(ready.port),
              let url = URL(string: "http://127.0.0.1:\(ready.port)") else {
            process.terminate()
            throw ClientError.invalidReadyLine
        }

        self.process = process
        self.repositoryRoot = normalizedRoot
        self.baseURL = url
        stdoutPipe = stdout
        stderrPipe = stderr
        return url
    }

    nonisolated static func binary(repositoryRoot: URL) throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["PROBIERZ_BIN"], !explicit.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: explicit) else {
                throw ClientError.launch("PROBIERZ_BIN is not executable: \(explicit)")
            }
            return URL(fileURLWithPath: explicit)
        }
        let candidates = [
            repositoryRoot.appendingPathComponent("probierz-rs/target/release/probierz"),
            repositoryRoot.appendingPathComponent("probierz-rs/target/debug/probierz"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/probierz"),
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ClientError.missingCLI
        }
        return binary
    }
}
