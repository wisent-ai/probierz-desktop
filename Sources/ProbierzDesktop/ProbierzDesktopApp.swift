import AppKit
import SwiftUI
import WisentAuth
import WisentDesignSystem
import WisentDesktopUpdate

/// Guarantees Probierz has a window at launch: when SwiftUI finds persistent state
/// naming a root view tree that no longer exists (`hasPersistentStateToRestore=1`
/// followed by `window=0x0`, as observed after the interface redesign), restoration
/// fails and no fresh window is ever opened. This delegate owns the app's observable
/// state so the fallback window renders exactly what the `WindowGroup` renders.
@MainActor
final class ProbierzAppDelegate: NSObject, NSApplicationDelegate {
    let model = ProbierzModel()
    let onboarding = ProbierzOnboarding()
    let auth = WisentAuthStore(productName: "Probierz")
    let updater = WisentUpdater()
    private var fallbackWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            fallbackWindow = wisentEnsureWindow(title: "Probierz") {
                WisentAuthGate(store: self.auth) {
                    ProbierzRootView(model: self.model, onboarding: self.onboarding)
                }
            }
        }
    }
}

@main
struct ProbierzDesktopApp: App {
    @NSApplicationDelegateAdaptor(ProbierzAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Probierz") {
            WisentAuthGate(store: delegate.auth) {
                ProbierzRootView(model: delegate.model, onboarding: delegate.onboarding)
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
                WisentCheckForUpdatesCommand(updater: delegate.updater)
            }
        }
    }
}
