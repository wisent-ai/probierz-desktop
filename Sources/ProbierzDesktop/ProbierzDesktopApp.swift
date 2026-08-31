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
                ProbierzRootContent(model: model, onboarding: onboarding, auth: auth)
            }
        }
    }
}

/// The one description of Probierz's window contents, rendered by both the
/// `WindowGroup` scene and the delegate's fallback window so the two can never
/// disagree about what the app shows — including whether its text can be
/// selected.
private struct ProbierzRootContent: View {
    @ObservedObject var model: ProbierzModel
    @ObservedObject var onboarding: ProbierzOnboarding
    @ObservedObject var auth: WisentAuthStore

    var body: some View {
        WisentAuthGate(store: auth) {
            ProbierzRootView(model: model, onboarding: onboarding)
        }
        // Every fact Probierz reports is selectable, and therefore copyable.
        // The app exists to state things an operator then quotes somewhere
        // else — a run id, a failure envelope, a verdict, a workspace path —
        // and SwiftUI's `Text` refuses selection on macOS unless a view asks
        // for it, which left all 53 text sites in this window dead to Cmd-C.
        //
        // `.textSelection` travels through the environment, so one call here
        // covers every screen, present and future. It sits outside
        // `WisentAuthGate`'s closure rather than inside it because the sign-in
        // and error branches the gate renders are siblings of the shell, not
        // children of it, and an operator quoting an auth failure needs the
        // same reach. The tables opt out explicitly: there a click already
        // means "select this row".
        .textSelection(.enabled)
    }
}

@main
struct ProbierzDesktopApp: App {
    @NSApplicationDelegateAdaptor(ProbierzAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Probierz") {
            ProbierzRootContent(
                model: delegate.model,
                onboarding: delegate.onboarding,
                auth: delegate.auth
            )
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
