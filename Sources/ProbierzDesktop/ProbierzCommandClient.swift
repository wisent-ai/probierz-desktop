import Foundation

struct ProbierzCommandClient: Sendable {
    enum CommandError: LocalizedError {
        case missingCLI
        case launch(String)
        case refused(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingCLI:
                "The selected workspace does not contain probierz/agent/cli.mjs."
            case .launch(let detail):
                "Probierz could not start: \(detail)"
            case .refused(let detail):
                detail
            case .invalidResponse:
                "Probierz returned an invalid repair response."
            }
        }
    }

    func repair(repositoryRoot: URL, appID: String, runID: String) async throws -> String {
        let cli = repositoryRoot.appendingPathComponent("agent/cli.mjs", isDirectory: false)
        guard FileManager.default.fileExists(atPath: cli.path) else {
            throw CommandError.missingCLI
        }
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let runID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, appID.count <= 128,
              !runID.isEmpty, runID.count <= 256 else {
            throw CommandError.invalidResponse
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", cli.path, "repair", appID,
            "--run", runID,
            "--rounds", "1",
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
        guard stdoutData.count <= 256_000, stderrData.count <= 256_000 else {
            throw CommandError.invalidResponse
        }
        if process.terminationStatus != 0 {
            let detail = String(data: stderrData, encoding: .utf8)?
                .split(separator: "\n")
                .last
                .map(String.init)
                ?? "Probierz repair exited \(process.terminationStatus)."
            throw CommandError.refused(detail)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any],
              payload["ok"] as? Bool == true else {
            throw CommandError.invalidResponse
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
