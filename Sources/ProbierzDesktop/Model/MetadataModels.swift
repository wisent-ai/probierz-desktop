import Foundation

// MARK: - Verdict

enum RunStatus: String, CaseIterable, Identifiable, Sendable {
    case passed
    case failed
    case blocked
    case canceled
    case incomplete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .blocked: "Blocked"
        case .canceled: "Canceled"
        case .incomplete: "Incomplete"
        }
    }

    var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .canceled: "slash.circle.fill"
        case .incomplete: "clock.badge.questionmark.fill"
        }
    }

    /// A verdict the operator has to resolve before evidence counts.
    var needsAttention: Bool {
        switch self {
        case .failed, .blocked, .incomplete: true
        case .passed, .canceled: false
        }
    }
}

/// The evidence strength Probierz assigns to a run.
///
/// The scale is the product's, not this viewer's: `gate.mjs`, `status.mjs`,
/// `receipt.mjs` and `matrix.mjs` all compute it from the same three manifest
/// facts, and all four only ever produce E0, E2 or E3. Nothing here invents a
/// level the backend cannot emit.
enum EvidenceLevel: String, CaseIterable, Identifiable, Sendable {
    case e0
    case e2
    case e3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .e0: "No verified result"
        case .e2: "Verified"
        case .e3: "Recorded"
        }
    }

    var detail: String {
        switch self {
        case .e0: "The run did not pass."
        case .e2: "The run passed and saved a report."
        case .e3: "The run passed and saved a report and recording."
        }
    }

    /// Comparison order used by `probierz status` when a policy names a floor.
    var ordinal: Int {
        switch self {
        case .e0: 0
        case .e2: 2
        case .e3: 3
        }
    }
}

// MARK: - Run provenance

struct SourceIdentityRecord: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let gitSHA: String?
    let isDirty: Bool
}

struct PreflightCheck: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let isSatisfied: Bool
    let hint: String
    /// `true` when `probierz setup <target>` can fix it, `false` when the host owner must.
    let isOwnedByProbierz: Bool
}

struct PreflightRecord: Identifiable, Sendable {
    var id: String { target }
    let target: String
    let isReady: Bool
    let checks: [PreflightCheck]
    let missing: [String]
    let remediation: [String]
    let observedAt: Date?
    let runID: String
}

/// Why a run did not produce evidence, in the manifest's own words.
///
/// Every string here is copied out of `run-manifest.json` without rewording.
/// When the manifest records a verdict but no reason text, `sentence` says so
/// and names the fields that were empty rather than inventing a cause.
struct RunFailure: Sendable {
    let headline: String
    let sentence: String
    let reasons: [String]
    let remediation: [String]
    let command: String?
    let code: String?
    let facts: [String]
    let hasRecordedReason: Bool
}

struct RunRecord: Identifiable, Sendable {
    var id: String { runID }
    let runID: String
    let appID: String
    let target: String
    let kind: String
    let spec: String?
    let status: RunStatus
    let evidenceLevel: EvidenceLevel
    let startedAt: Date?
    let completedAt: Date?
    let durationMilliseconds: Double
    let manifestModifiedAt: Date?
    let artifactCount: Int
    let artifactBytes: Int64
    let journeys: [String]
    let isRecorded: Bool
    let hasReportEvidence: Bool
    let hasAnalysisEvidence: Bool
    let isCapturePresent: Bool
    let exitCode: Int?
    let signalName: String?
    let didTimeOut: Bool
    let hostPlatform: String?
    let hostName: String?
    let deviceName: String?
    let deviceRuntime: String?
    let harnessGitSHA: String?
    let harnessIsDirty: Bool
    let sourceRepositories: [SourceIdentityRecord]
    let failure: RunFailure?
    let preflight: PreflightRecord?
    let hasProtectedBundle: Bool
}

// MARK: - Evidence

enum ArtifactKind: String, CaseIterable, Identifiable, Sendable {
    case image
    case video
    case trace
    case report
    case log
    case protectedBundle
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Screenshot"
        case .video: "Recording"
        case .trace: "Trace"
        case .report: "Report"
        case .log: "Log"
        case .protectedBundle: "Protected bundle"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "video"
        case .trace: "waveform.path.ecg"
        case .report: "doc.text"
        case .log: "text.alignleft"
        case .protectedBundle: "lock.doc"
        case .other: "doc"
        }
    }
}

struct ArtifactMetadata: Identifiable, Sendable {
    let id: String
    let runID: String
    let appID: String
    let target: String
    let kind: ArtifactKind
    let fileExtension: String
    let bytes: Int64
    let sha256: String?
    let keyFingerprintSHA256: String?
    let modifiedAt: Date?
    let isAvailableOnDisk: Bool
    /// Plaintext removed by `probierz protect`; the descriptor survives, the file does not.
    let wasPlaintextRemoved: Bool

    var hasSHA256: Bool { sha256 != nil }
}

// MARK: - Specs

struct SurfaceRecord: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let packagePath: String
    let tool: String
    let scriptLabel: String
    let targetsLabel: String
    let conditionNames: [String]
    let isPackagePresent: Bool
    let specPaths: [String]
    let runCount: Int
    let lastStatus: RunStatus?
    let lastEvidenceLevel: EvidenceLevel?
    let observedTargets: [String]
}

struct ConditionRecord: Identifiable, Sendable {
    var id: String { "\(surface)/\(name)" }
    let surface: String
    let name: String
    /// Presence in this viewer's own process environment. Never the value.
    let isPresentForViewer: Bool
}

struct JourneyRecord: Identifiable, Sendable {
    var id: String { "\(appID)/\(name)" }
    let appID: String
    let name: String
    /// Declared in `probierz.yaml`; absent when the journey is known only from
    /// a run manifest that named it.
    let owner: String?
    let purpose: String?
    let runCount: Int
    let passed: Int
    let failed: Int
    let blocked: Int
    let canceled: Int
    let incomplete: Int
    let latestRunID: String?
    let latestStatus: RunStatus?
    let latestEvidenceLevel: EvidenceLevel?
    let latestStartedAt: Date?
    let bestEvidenceLevel: EvidenceLevel?

    var passRate: Double? {
        let decided = passed + failed
        return decided > 0 ? Double(passed) / Double(decided) : nil
    }
}

// MARK: - Merge decision

/// One journey's merge eligibility, computed from manifests alone.
///
/// `blockingReasons` reproduces the sentences `status.mjs` emits, character for
/// character, for the three reasons a manifest can settle on its own. The
/// fourth reason `status.mjs` can emit — evidence older than HEAD — needs a
/// `git rev-parse`, which this viewer does not run; `headFreshnessUnknown`
/// records that rather than guessing eligibility.
struct VerdictRecord: Identifiable, Sendable {
    var id: String { "\(appID)/\(journey)" }
    let appID: String
    let journey: String
    let minimumEvidence: EvidenceLevel
    let latestRunID: String?
    let latestStatus: RunStatus?
    let latestEvidenceLevel: EvidenceLevel?
    let latestStartedAt: Date?
    let recordedSources: [SourceIdentityRecord]
    let blockingReasons: [String]
    let headFreshnessUnknown: Bool

    var isBlocking: Bool { !blockingReasons.isEmpty }
}

// MARK: - Aggregates
