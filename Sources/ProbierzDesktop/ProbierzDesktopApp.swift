import SwiftUI
import WisentAuth
import WisentDesignSystem
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
        // The sidebar, facet rail and inspector claim 236 + 168 + 320 pt, which
        // leaves the table 276 pt at the 1000 pt minimum. The default opens wide
        // enough for the five run columns to fit without compressing.
        .defaultSize(width: 1_320, height: 860)
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
