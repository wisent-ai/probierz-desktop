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

/// Project adoption through `probierz project adopt` and
/// `probierz project adoptions`: the same core transaction an operator runs,
/// one finite call per operation.
struct ProjectAdoptionClient: Sendable {
    func adopt(repositoryRoot: URL, sourceRoot: URL, replace: Bool) async throws -> ProjectAdoptionResult {
        var arguments = ["project", "adopt", "--source=\(sourceRoot.standardizedFileURL.path)"]
        if replace { arguments.append("--replace") }
        let outcome = try await ProbierzCLI.run(repositoryRoot: repositoryRoot, arguments: arguments)
        // A conflict is an answer: the command prints the result, names every
        // conflicting definition, and exits 1 without writing.
        if let result = try? JSONDecoder().decode(ProjectAdoptionResult.self, from: outcome.stdout) {
            return result
        }
        guard outcome.status == 0 else { throw ProbierzCLI.refusal(outcome) }
        throw ProbierzCLI.Failure.invalidResponse
    }

    func list(repositoryRoot: URL) async throws -> ProjectAdoptionIndex {
        let data = try await ProbierzCLI.answer(repositoryRoot: repositoryRoot, arguments: ["project", "adoptions"])
        guard let index = try? JSONDecoder().decode(ProjectAdoptionIndex.self, from: data) else {
            throw ProbierzCLI.Failure.invalidResponse
        }
        return index
    }
}
