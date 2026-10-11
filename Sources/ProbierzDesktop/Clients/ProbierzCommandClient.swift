import Foundation

struct ProbierzCommandClient: Sendable {
    enum CommandError: LocalizedError {
        case missingCLI
        case launch(String)
        case refused(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingCLI:
                "The selected workspace does not contain probierz/agent/cli.mjs."
            case .launch(let detail):
                "Probierz could not start: \(detail)"
            case .refused(let detail):
                detail
            case .invalidResponse(let detail):
                "Probierz returned an invalid repair response: \(detail)"
            }
        }
    }

    func repair(repositoryRoot: URL, appID: String, runID: String, rounds: Int) async throws
        -> String
    {
        let cli = repositoryRoot.appendingPathComponent("agent/cli.mjs", isDirectory: false)
        guard FileManager.default.fileExists(atPath: cli.path) else {
            throw CommandError.missingCLI
        }
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let runID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !runID.isEmpty else {
            throw CommandError.refused("A repair needs both an app id and a run id.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", cli.path, "repair", appID,
            "--run", runID,
            "--rounds", String(rounds),
        ]
        process.currentDirectoryURL = repositoryRoot
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
            throw CommandError.launch(error.localizedDescription)
        }
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let detail =
                String(data: stderrData, encoding: .utf8)?
                .split(separator: "\n")
                .last
                .map(String.init)
                ?? "Probierz repair exited \(process.terminationStatus)."
            throw CommandError.refused(detail)
        }
        // The parser's reason, or what the payload said instead of ok, is the
        // diagnostic; "invalid repair response" alone named neither.
        let payload: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: stdoutData) as? [String: Any]
            else {
                throw CommandError.invalidResponse(
                    "stdout is JSON but not an object: \(String(decoding: stdoutData, as: UTF8.self))")
            }
            payload = object
        } catch let error as CommandError {
            throw error
        } catch {
            throw CommandError.invalidResponse(
                "stdout is not JSON (\(error)): \(String(decoding: stdoutData, as: UTF8.self))")
        }
        guard payload["ok"] as? Bool == true else {
            throw CommandError.invalidResponse(
                "ok is not true: \(String(decoding: stdoutData, as: UTF8.self))")
        }
        if let pullRequest = payload["pullRequest"] as? String, !pullRequest.isEmpty {
            return "Repair published: \(pullRequest)"
        }
        if let branch = payload["branch"] as? String, !branch.isEmpty {
            return "Repair published on \(branch)."
        }
        if let verdict = payload["verdict"] as? String, !verdict.isEmpty {
            return "Repair completed with verdict \(verdict)."
        }
        return "Repair completed."
    }
}
