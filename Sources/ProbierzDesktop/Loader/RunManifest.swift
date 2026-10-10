import Foundation

struct RunManifest: Decodable {
    let runId: String?
    let appId: String?
    let target: String?
    let kind: String?
    let spec: String?
    let status: String?
    let startedAt: String?
    let completedAt: String?
    let durationMs: Double?
    let timeoutMs: Double?
    let command: String?
    let exitCode: Int?
    let signal: String?
    let timedOut: Bool?
    let setupError: String?
    let cleanupError: String?
    let plaintextArtifactsRemovedAt: String?
    let reportValidation: ManifestReportValidation?
    let platformDiagnostics: ManifestPlatformDiagnostics?
    let spawnFailure: ManifestSpawnFailure?
    let resourceLock: ManifestResourceLock?
    let preflight: ManifestPreflight?
    let evidence: ManifestEvidence?
    let conditions: ManifestConditions?
    let appManifest: ManifestAppManifest?
    let harness: ManifestIdentity?
    let source: ManifestSource?
    let host: ManifestHost?
    let device: ManifestDevice?
    let protection: ManifestProtection?
    let artifacts: [ManifestArtifact]?
}

struct ManifestReportValidation: Decodable {
    let ok: Bool?
    let error: String?
}

struct ManifestPlatformDiagnostics: Decodable, Sendable {
    struct Collector: Decodable, Sendable {
        let command: String?
        let args: [String]?
        let exitCode: Int?
        let error: String?
        let stderr: String?
    }

    let supported: Bool?
    let file: String?
    let attemptedFile: String?
    let ok: Bool?
    let exitCode: Int?
    let error: String?
    let collector: Collector?

    var failureDetail: String {
        var lines: [String] = []
        if let error, !error.isEmpty { lines.append(error) }
        if let attemptedFile { lines.append("Attempted file: \(attemptedFile)") }
        if let file { lines.append("Recorded file: \(file)") }
        if let exitCode { lines.append("Collector exit: \(exitCode)") }
        if let collector {
            if let command = collector.command { lines.append("Collector: \(command)") }
            if let args = collector.args { lines.append("Arguments: \(args)") }
            if let exitCode = collector.exitCode { lines.append("Collector exit: \(exitCode)") }
            if let error = collector.error, !error.isEmpty { lines.append(error) }
            if let stderr = collector.stderr, !stderr.isEmpty { lines.append(stderr) }
        }
        if lines.isEmpty {
            return "The run recorded platformDiagnostics.ok=false without a diagnostic reason."
        }
        return lines.joined(separator: "\n")
    }
}

struct ManifestSpawnFailure: Decodable {
    let failurePoint: String?
    let errorCode: String?
    let message: String?
}

struct ManifestResourceLock: Decodable {
    let error: String?
    let resource: String?
    let owner: String?
}

struct ManifestPreflight: Decodable {
    let target: String?
    let ready: Bool?
    let checks: [ManifestPreflightCheck]?
    let missing: [String]?
    let remediation: [String]?
}

struct ManifestPreflightCheck: Decodable {
    let name: String?
    let ok: Bool?
    let own: Bool?
    let hint: String?
}

struct ManifestEvidence: Decodable {
    let report: Bool?
    let analysis: Bool?
    let captureRequired: Bool?
    let capturePresent: Bool?
    let captureErrors: [String]?
    let errors: [String]?
}

struct ManifestConditions: Decodable {
    let record: Bool?
}

struct ManifestAppManifest: Decodable {
    let owner: String?
    let journeys: [String]?
}

struct ManifestIdentity: Decodable {
    let name: String?
    let gitSha: String?
    let dirty: Bool?
    let sha256: String?
}

struct ManifestSource: Decodable {
    let sha256: String?
    let repositories: [ManifestIdentity]?
}

struct ManifestHost: Decodable {
    let hostname: String?
    let platform: String?
    let release: String?
    let arch: String?
}

struct ManifestDevice: Decodable {
    let name: String?
    let runtime: String?
}

struct ManifestProtection: Decodable {
    let file: String?
    let bytes: Int64?
    let sha256: String?
    let keyFingerprintSha256: String?
}

struct ManifestArtifact: Decodable {
    let file: String?
    let bytes: Int64?
    let sha256: String?
}
