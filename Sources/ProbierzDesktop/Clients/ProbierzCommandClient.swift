import Foundation

struct ProbierzCommandClient: Sendable {
    func repair(repositoryRoot: URL, appID: String, runID: String, rounds: Int) async throws
        -> String
    {
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let runID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !runID.isEmpty else {
            throw ProbierzCLI.Failure.refused("A repair needs both an app id and a run id.")
        }
        let stdout = try await ProbierzCLI.answer(
            repositoryRoot: repositoryRoot,
            arguments: ["repair", appID, "--run", runID, "--rounds", String(rounds)])
        let payload: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: stdout) as? [String: Any]
            else {
                throw ProbierzCLI.Failure.invalidResponse(
                    operation: "repair",
                    cause: "stdout is JSON but not an object: \(String(decoding: stdout, as: UTF8.self))")
            }
            payload = object
        } catch let error as ProbierzCLI.Failure {
            throw error
        } catch {
            throw ProbierzCLI.Failure.invalidResponse(
                operation: "repair",
                cause: "stdout is not JSON (\(error)): \(String(decoding: stdout, as: UTF8.self))")
        }
        guard payload["ok"] as? Bool == true else {
            throw ProbierzCLI.Failure.invalidResponse(
                operation: "repair",
                cause: "ok is not true: \(String(decoding: stdout, as: UTF8.self))")
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
        throw ProbierzCLI.Failure.invalidResponse(
            operation: "repair",
            cause: "ok is true but no repair verdict or publication was recorded: \(payload)")
    }
}
