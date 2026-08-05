import SwiftUI
import WisentAuth
import WisentDesktopUpdate

@main
struct ProbierzDesktopApp: App {
    @StateObject private var model = ProbierzModel()
    @StateObject private var onboarding = ProbierzOnboarding()
    @StateObject private var auth = WisentAuthStore(productName: "Probierz")
    @StateObject private var updater = WisentUpdater()

    var body: some Scene {
        WindowGroup("Probierz") {
            WisentAuthGate(store: auth) {
                ProbierzRootView(model: model, onboarding: onboarding)
            }
        }
        .defaultSize(width: ProbierzTheme.minimumWidth, height: ProbierzTheme.minimumHeight)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                WisentCheckForUpdatesCommand(updater: updater)
            }
        }
    }
}
