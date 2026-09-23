import Foundation

/// Runs one Probierz command to completion and returns its answer.
///
/// Probierz Desktop keeps no Probierz process of its own. It used to start
/// `probierz serve` and hold it for as long as the window was open, a second
/// resident Probierz process beside any the host runs; every adoption and
/// register operation is now one finite CLI call, and its JSON answer is the
/// document the same command prints for an operator. A refusal is read from
/// the `probierz-failure` line the CLI writes to stderr, so the window quotes
/// the product's own sentence.
enum ProbierzCLI {
    /// A register or adoption answer is a bounded JSON document; a larger
    /// stdout is not a Probierz answer.
    private static let maxOutputBytes = 16 * 1024 * 1024
    private static let failurePrefix = "probierz-failure "

    enum Failure: LocalizedError, Equatable {
        case missingCLI
        case launch(String)
        case refused(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingCLI:
                "The selected workspace does not contain an executable Probierz CLI."
            case .launch(let detail):
                "Probierz could not start: \(detail)"
            case .refused(let detail):
                detail
            case .invalidResponse:
                "Probierz returned an invalid response."
            }
        }
    }

    struct Outcome: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Run `arguments` against the Probierz project at `repositoryRoot` and
    /// wait for the command to exit. `input`, when given, is the command's
    /// stdin; otherwise stdin is empty.
    static func run(repositoryRoot: URL, arguments: [String], input: Data? = nil) async throws -> Outcome {
        let root = repositoryRoot.standardizedFileURL
        let executable = try binary(repositoryRoot: root)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try execute(executable, root: root, arguments: arguments, input: input)
                })
            }
        }
    }

    /// The JSON answer of a command that must succeed, or its refusal.
    static func answer(repositoryRoot: URL, arguments: [String], input: Data? = nil) async throws -> Data {
        let outcome = try await run(repositoryRoot: repositoryRoot, arguments: arguments, input: input)
        guard outcome.status == 0 else { throw refusal(outcome) }
        return outcome.stdout
    }

    /// The product's sentence for a failed command: the `detail` of its
    /// `probierz-failure` line, else the last line it wrote to stderr (clap
    /// usage errors), else its exit status.
    static func refusal(_ outcome: Outcome) -> Failure {
        let lines = String(decoding: outcome.stderr, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines where line.hasPrefix(failurePrefix) {
            let payload = Data(line.dropFirst(failurePrefix.count).utf8)
            if let failure = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let detail = failure["detail"] as? String, !detail.isEmpty {
                return .refused(detail)
            }
        }
        return .refused(lines.last ?? "Probierz exited with status \(outcome.status).")
    }

    static func binary(repositoryRoot: URL) throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["PROBIERZ_BIN"], !explicit.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: explicit) else {
                throw Failure.launch("PROBIERZ_BIN is not executable: \(explicit)")
            }
            return URL(fileURLWithPath: explicit)
        }
        let candidates = [
            repositoryRoot.appendingPathComponent("probierz-rs/target/release/probierz"),
            repositoryRoot.appendingPathComponent("probierz-rs/target/debug/probierz"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/probierz"),
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw Failure.missingCLI
        }
        return binary
    }

    private static func execute(_ executable: URL, root: URL, arguments: [String], input: Data?) throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--harness", root.path] + arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        // A command that refuses before reading stdin closes it; the write then
        // fails with EPIPE instead of ending this application with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            throw Failure.launch(error.localizedDescription)
        }
        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
        }
        try? stdin.fileHandleForWriting.close()
        // stderr drains beside stdout, so neither pipe fills while the other
        // is read.
        let errors = DataBox()
        let errorHandle = stderr.fileHandleForReading
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errors.data = errorHandle.readDataToEndOfFile()
            drained.leave()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        guard output.count <= maxOutputBytes else { throw Failure.invalidResponse }
        return Outcome(status: process.terminationStatus, stdout: output, stderr: errors.data)
    }
}

/// stderr collected on another thread; the dispatch group orders the write
/// before the read.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
