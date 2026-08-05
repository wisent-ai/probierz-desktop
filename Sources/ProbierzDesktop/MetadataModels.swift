import Foundation

struct ContractItem: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let relativePath: String
    let isAvailable: Bool
    let modifiedAt: Date?
}

struct ConfigurationItem: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let isPresent: Bool
}

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
        case .failed: "xmark.circle.fill"
        case .blocked: "exclamationmark.octagon.fill"
        case .canceled: "slash.circle.fill"
        case .incomplete: "clock.badge.questionmark.fill"
        }
    }
}

struct RunRecord: Identifiable, Sendable {
    var id: String { runID }
    let runID: String
    let appID: String
    let target: String
    let kind: String
    let status: RunStatus
    let startedAt: Date?
    let completedAt: Date?
    let durationMilliseconds: Double
    let manifestModifiedAt: Date?
    let artifactCount: Int
    let artifactBytes: Int64
}

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
        case .image: "Image"
        case .video: "Video"
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
    let kind: ArtifactKind
    let fileExtension: String
    let bytes: Int64
    let hasSHA256: Bool
    let modifiedAt: Date?
    let isAvailableOnDisk: Bool
}

struct StatusSummary: Sendable {
    let passed: Int
    let failed: Int
    let blocked: Int
    let canceled: Int
    let incomplete: Int

    var total: Int { passed + failed + blocked + canceled + incomplete }
}

struct ProbierzSnapshot: Sendable {
    let repositoryRoot: URL
    let contracts: [ContractItem]
    let configurations: [ConfigurationItem]
    let runs: [RunRecord]
    let artifacts: [ArtifactMetadata]
    let summary: StatusSummary
    let loadedAt: Date
    let manifestsTruncated: Bool

    var availableContractCount: Int { contracts.filter(\.isAvailable).count }
    var configuredCount: Int { configurations.filter(\.isPresent).count }
    var artifactBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
}

enum ProbierzDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case configuration
    case runs
    case artifacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .configuration: "Configuration"
        case .runs: "Runs"
        case .artifacts: "Artifacts"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .configuration: "gearshape.2"
        case .runs: "checklist"
        case .artifacts: "archivebox"
        }
    }
}
