import Foundation

struct StatusSummary: Sendable {
    var passed = 0
    var failed = 0
    var blocked = 0
    var canceled = 0
    var incomplete = 0

    var total: Int { passed + failed + blocked + canceled + incomplete }
    var needsAttention: Int { failed + blocked + incomplete }

    func count(of status: RunStatus) -> Int {
        switch status {
        case .passed: passed
        case .failed: failed
        case .blocked: blocked
        case .canceled: canceled
        case .incomplete: incomplete
        }
    }

    mutating func add(_ status: RunStatus) {
        switch status {
        case .passed: passed += 1
        case .failed: failed += 1
        case .blocked: blocked += 1
        case .canceled: canceled += 1
        case .incomplete: incomplete += 1
        }
    }
}

struct EvidenceSummary: Sendable {
    var e0 = 0
    var e2 = 0
    var e3 = 0

    var total: Int { e0 + e2 + e3 }

    func count(of level: EvidenceLevel) -> Int {
        switch level {
        case .e0: e0
        case .e2: e2
        case .e3: e3
        }
    }

    mutating func add(_ level: EvidenceLevel) {
        switch level {
        case .e0: e0 += 1
        case .e2: e2 += 1
        case .e3: e3 += 1
        }
    }
}

/// Counters aggregated once at load, so a facet rail never recounts a table.
struct ScopeSummary: Sendable {
    var status = StatusSummary()
    var evidence = EvidenceSummary()
    var artifactCount = 0
    var artifactBytes: Int64 = 0
    var protectedBundleCount = 0
    var missingIntegrityCount = 0
    var lastRunID: String?
    var lastStatus: RunStatus?
    var lastStartedAt: Date?
    var lastGreenRunID: String?
    var lastGreenStartedAt: Date?
}

struct ProbierzSnapshot: Sendable {
    /// Key used by `summaries` for every product at once.
    static let allProducts = ""

    let repositoryRoot: URL
    let productIDs: [String]
    let surfaces: [SurfaceRecord]
    let conditions: [ConditionRecord]
    let runs: [RunRecord]
    let artifacts: [ArtifactMetadata]
    let journeys: [JourneyRecord]
    let verdicts: [VerdictRecord]
    let preflights: [PreflightRecord]
    let summaries: [String: ScopeSummary]
    let loadedAt: Date
    let manifestsTruncated: Bool
    let manifestLimit: Int

    func summary(for product: String?) -> ScopeSummary {
        summaries[product ?? Self.allProducts] ?? ScopeSummary()
    }
}
