import Foundation
import SwiftUI
import WisentDesignSystem

// MARK: - Tones

extension RunStatus {
    /// Red is reserved for a run that actually failed. A canceled or in-flight
    /// run is a fact about scheduling, not a fault, so it stays neutral.
    var tone: WisentTone {
        switch self {
        case .passed: .success
        case .failed: .danger
        case .blocked: .warning
        case .canceled, .incomplete: .neutral
        }
    }
}

extension EvidenceLevel {
    var tone: WisentTone {
        switch self {
        case .e0: .warning
        case .e2: .success
        case .e3: .brand
        }
    }
}

// MARK: - Formatting

enum ProbierzFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ milliseconds: Double) -> String {
        guard milliseconds > 0 else { return "—" }
        let seconds = milliseconds / 1_000
        if seconds < 60 { return seconds.formatted(.number.precision(.fractionLength(1))) + " s" }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }

    static func shortTimestamp(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "Not recorded" }
        return date.formatted(.dateTime.year().month().day().hour().minute().second())
    }

    static func digest(_ value: String?) -> String {
        guard let value else { return "Not recorded" }
        return value
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }
}

// MARK: - Chips

/// A pill marks a row the operator still has to resolve.
///
/// The baseline put a 96 pt badge in every single row of both tables, including
/// the dominant healthy state, which is how 36 passes and 75 failures ended up
/// wearing the same amount of ink. The dominant state's count belongs in the
/// facet rail; only an unresolved verdict earns a pill in the table.
struct RunVerdictCell: View {
    let status: RunStatus

    var body: some View {
        if status.needsAttention {
            WisentStatusChip(text: status.title, tone: status.tone)
        } else {
            Text(status.title)
                .font(WisentTypeScale.body())
                .foregroundStyle(WisentDesign.secondary)
        }
    }
}

struct EvidenceLevelCell: View {
    let level: EvidenceLevel

    var body: some View {
        Text(level.title)
            .font(WisentTypeScale.identifierSmall())
            .monospacedDigit()
            .foregroundStyle(level == .e0 ? WisentDesign.warning : WisentDesign.secondary)
            .accessibilityLabel("evidence level \(level.title)")
    }
}

// MARK: - Shared panels

/// The failure panel: the manifest's own sentence, its reason code, and the
/// command the manifest recorded for the run that produced it.
struct RunFailurePanel: View {
    let run: RunRecord
    let failure: RunFailure
    var action: WisentAction?

    var body: some View {
        WisentAlertPanel(
            tone: run.status == .blocked ? .warning : .danger,
            title: "\(failure.headline) — \(run.target)",
            detail: detail,
            command: failure.command,
            actions: action.map { [$0] } ?? []
        )
    }

    private var detail: String {
        var lines = [failure.sentence]
        if failure.reasons.count > 1 {
            lines.append(contentsOf: failure.reasons.dropFirst().prefix(4))
        }
        if let code = failure.code { lines.append("reason: \(code)") }
        if !failure.facts.isEmpty { lines.append(failure.facts.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
}

/// Presence without a value. Absent is neutral and says "Not configured";
/// red is kept for a real failure.
struct ConditionPresenceCell: View {
    let isPresent: Bool

    var body: some View {
        if isPresent {
            Text("Present")
                .font(WisentTypeScale.body())
                .foregroundStyle(WisentDesign.secondary)
        } else {
            WisentStatusChip(text: "Not configured", tone: .neutral)
        }
    }
}

extension View {
    /// One row height for every table on every screen.
    func denseRow() -> some View {
        frame(height: WisentAppLayout.tableRowHeight, alignment: .leading)
    }
}

/// Loading, no-workspace and ready are three different states, and the loading
/// one names the directory it is reading instead of showing a bare spinner.
struct ProbierzSnapshotGate<Content: View>: View {
    @ObservedObject var model: ProbierzModel
    let readingTitle: String
    let readingDetail: String
    var chooseWorkspace: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if model.snapshot != nil {
            content()
        } else if model.isRefreshing {
            WisentLoadingPanel(title: readingTitle, detail: readingDetail)
            Spacer(minLength: 0)
        } else {
            WisentEmptyPanel(
                title: "Probierz metadata unavailable",
                detail: model.errorMessage
                    ?? "Choose the Wisent workspace containing probierz/package.json and agent/history.mjs.",
                symbol: "questionmark.folder",
                action: chooseWorkspace.map { choose in
                    WisentAction("Choose Workspace", symbol: "folder", kind: .primary, perform: choose)
                }
            )
            Spacer(minLength: 0)
        }
    }
}
