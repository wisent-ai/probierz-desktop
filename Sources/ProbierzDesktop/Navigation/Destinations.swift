import Foundation

// MARK: - Navigation

enum ProbierzDestination: String, CaseIterable, Identifiable, Hashable {
    case posture
    case runs
    case failures
    case register
    case artifacts
    case verdicts
    case surfaces
    case journeys
    case preflight
    case workspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posture: "Posture"
        case .runs: "Runs"
        case .failures: "Failures"
        case .register: "Register"
        case .artifacts: "Artifacts"
        case .verdicts: "Verdicts"
        case .surfaces: "Surfaces"
        case .journeys: "Journeys"
        case .preflight: "Preflight"
        case .workspace: "Workspace"
        }
    }

    var symbol: String {
        switch self {
        case .posture: "shield.lefthalf.filled"
        case .runs: "list.bullet.rectangle"
        case .failures: "exclamationmark.triangle"
        case .register: "book.closed"
        case .artifacts: "archivebox"
        case .verdicts: "checkmark.seal"
        case .surfaces: "square.stack.3d.up"
        case .journeys: "point.topleft.down.curvedto.point.bottomright.up"
        case .preflight: "wrench.and.screwdriver"
        case .workspace: "internaldrive"
        }
    }
}

struct DestinationGroup: Identifiable, Sendable {
    var id: String { title }
    let title: String
    let destinations: [ProbierzDestination]

    /// Grouped by the decision the operator makes there, not by the table the
    /// metadata happens to live in.
    static let all: [DestinationGroup] = [
        DestinationGroup(title: "Work", destinations: [.posture, .runs, .failures, .register]),
        DestinationGroup(title: "Evidence", destinations: [.artifacts, .verdicts]),
        DestinationGroup(title: "Specs", destinations: [.surfaces, .journeys]),
        DestinationGroup(title: "System", destinations: [.preflight, .workspace]),
    ]
}
