import AppKit
import SwiftUI
import WisentDesignSystem

extension ProbierzRootView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing || model.workspaceRoot == nil)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh runs, journeys, artifacts, and system state")
            // The resting word stays while the refresh runs: a name that turns
            // into "Refreshing Probierz" is gone at the one moment a screen
            // reader is asked what this control is.
            .accessibilityLabel("Refresh Probierz")
        }
    }
    func performOnboardingAction() {
        Task {
            switch await onboarding.performPrimaryAction() {
            case .adoptExistingProject:
                if model.projectAdoption?.accepted == true {
                    _ = await onboarding.completeOptionalProjectStep(imported: true)
                } else {
                    chooseAdoptionSource()
                }
            case .showEvidenceBundles:
                model.destination = .artifacts
                model.selectFirstProtectedBundle()
            case .advanced, .unavailable:
                break
            }
        }
    }
    func skipProjectAdoption() {
        model.clearAdoptionOutcome()
        Task { _ = await onboarding.completeOptionalProjectStep(imported: false) }
    }
    func replaceProjectAdoption() {
        guard let path = model.projectAdoption?.sourceRoot else { return }
        Task {
            _ = await model.adoptProject(
                from: URL(fileURLWithPath: path, isDirectory: true),
                replace: true
            )
        }
    }
}
