import SwiftUI
import WisentDesignSystem

extension RunsView {
    /// The reason, verbatim, then the reproducing command the manifest recorded.
    @ViewBuilder
    func failureSection(run: RunRecord, failure: RunFailure) -> some View {
        WisentAlertPanel(
            tone: run.status == .blocked ? .warning : .danger,
            title: failure.headline,
            detail: failure.sentence
        )
        if let command = failure.command {
            RecordedCommandRow(command: command)
        }
        if run.status == .failed {
            WisentAction(
                "Repair Run",
                symbol: "wrench.and.screwdriver",
                kind: .primary,
                isBusy: model.repairOutcome.isWorking
            ) {
                model.repair(run)
            }
            .asButton()
        }
        if failure.reasons.count > 1 {
            WisentField(
                label: "Every recorded reason",
                value: failure.reasons.joined(separator: "\n")
            )
        }
        if !failure.remediation.isEmpty {
            WisentField(
                label: "Suggested fix",
                value: failure.remediation.joined(separator: "\n"),
                tone: .warning
            )
        }
        if let code = failure.code {
            WisentField(label: "Reason code", value: code, tone: .danger)
        }
        if !failure.facts.isEmpty {
            WisentField(label: "Recorded facts", value: failure.facts.joined(separator: "\n"))
        }
    }
    @ViewBuilder
    func hostSection(run: RunRecord) -> some View {
        if run.hostName != nil || run.hostPlatform != nil || run.deviceName != nil {
            WisentField(
                label: "Host",
                value: [run.hostName, run.hostPlatform].compactMap { $0 }.joined(separator: " · ")
            )
        }
        if let device = run.deviceName {
            WisentField(
                label: "Device",
                value: [device, run.deviceRuntime].compactMap { $0 }.joined(separator: " · ")
            )
        }
    }
    @ViewBuilder
    func sourceSection(run: RunRecord) -> some View {
        if let harness = run.harnessGitSHA {
            WisentField(
                label: "Probierz source",
                value: run.harnessIsDirty ? "\(harness) (uncommitted changes)" : harness,
                tone: run.harnessIsDirty ? .warning : .neutral
            )
        }
        ForEach(run.sourceRepositories) { repository in
            WisentField(
                label: "Source \(repository.name)",
                value: repository.isDirty
                    ? "\(repository.gitSHA ?? "Not recorded") (uncommitted changes)"
                    : (repository.gitSHA ?? "Not recorded"),
                tone: repository.isDirty ? .warning : .neutral
            )
        }
    }
}
