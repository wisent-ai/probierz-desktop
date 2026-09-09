import SwiftUI

/// Which screen each destination is. Moved out of `ProbierzRootView` so a new
/// screen lands beside the destination that names it.
extension ProbierzRootView {
    @ViewBuilder
    var destinationView: some View {
        switch model.destination {
        case .posture:
            PostureView(model: model, chooseWorkspace: chooseWorkspace)
        case .runs:
            RunsView(model: model)
        case .failures:
            FailuresView(model: model)
        case .register:
            RegisterView(model: model)
        case .artifacts:
            ArtifactsView(model: model, onboarding: onboarding)
        case .verdicts:
            VerdictsView(model: model)
        case .surfaces:
            SurfacesView(model: model)
        case .journeys:
            JourneysView(model: model)
        case .preflight:
            PreflightView(model: model)
        case .workspace:
            WorkspaceView(model: model, onboarding: onboarding, chooseWorkspace: chooseWorkspace)
        }
    }

    /// The workspace picker the screens above hand back to. It lives beside
    /// them because two of them call it and the root view only forwards it.
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Choose a workspace"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.workspaceRoot
        if panel.runModal() == .OK, let url = panel.url {
            model.selectWorkspace(url)
        }
    }
}
