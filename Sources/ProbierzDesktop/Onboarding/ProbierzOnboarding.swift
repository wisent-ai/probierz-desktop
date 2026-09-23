import Combine
@preconcurrency import Foundation
import SwiftUI
import WisentOnboarding
import WisentDesignSystem

@MainActor
final class ProbierzOnboarding: ObservableObject {
    enum PrimaryActionResult {
        case advanced
        case adoptExistingProject
        case showEvidenceBundles
        case unavailable
    }

    @Published private(set) var screen: JourneyScreen?
    @Published private(set) var status: JourneyProgressStatus?
    @Published private(set) var isWorking = false

    private static let productID = "probierz-desktop"
    private static let journeyID = "first-use"
    private static let evidenceRevision = "probierz-desktop-evidence-v1"
    private static let installationIDKey = "probierzDesktop.onboarding.installationID"
    private static let resourceName = "probierz-desktop-first-use"
    /// SwiftPM names a resource bundle `<Package>_<Target>.bundle`; this string
    /// is the one `swift build` writes into `.build/debug`, not a guess.
    private static let resourceBundleName = "ProbierzDesktop_ProbierzDesktop.bundle"

    private let client: JourneyClient?
    private var didStart = false
    private var exposedScreenID: String?

    init(defaults: UserDefaults = .standard) {
        let installationID: String
        if let saved = defaults.string(forKey: Self.installationIDKey), UUID(uuidString: saved) != nil {
            installationID = saved
        } else {
            installationID = UUID().uuidString.lowercased()
            defaults.set(installationID, forKey: Self.installationIDKey)
        }

        let subjectHash = JourneySubject.scoped([
            Self.productID,
            JourneyScope.device.rawValue,
            installationID,
        ])
        let transport = ProbierzJourneyTransport()
        let storage = UserDefaultsJourneyStorage(
            namespace: "probierzDesktop.onboarding",
            defaults: defaults
        )

        if let fallback = Self.fallbackBundle() {
            client = try? JourneyClient(
                productId: Self.productID,
                journeyId: Self.journeyID,
                subjectHash: subjectHash,
                scope: .device,
                transport: transport,
                storage: storage,
                fallback: fallback
            )
        } else {
            client = nil
        }
    }

    func start() async {
        guard !didStart, let client else { return }
        didStart = true
        isWorking = true
        defer { isWorking = false }

        do {
            let (bundle, progress) = try await client.start(evidenceRevision: Self.evidenceRevision)
            apply(
                screen: bundle.definition.screens.first { $0.screenId == progress.currentScreenId },
                status: progress.status
            )
            try await exposeCurrentScreenIfNeeded(using: client)
            try await client.flush()
        } catch {
            screen = nil
            status = nil
        }
    }

    func performPrimaryAction() async -> PrimaryActionResult {
        guard let screen else { return .unavailable }
        if screen.screenId == "adopt-existing-project" {
            return .adoptExistingProject
        }
        return await advanceCurrentScreen()
    }

    func completeOptionalProjectStep(imported: Bool) async -> Bool {
        guard screen?.screenId == "adopt-existing-project" else { return false }
        if case .advanced = await advanceCurrentScreen(
            evidence: ["project_definitions_adopted": .boolean(imported)]
        ) {
            return true
        }
        return false
    }

    private func advanceCurrentScreen(
        evidence: [String: JSONValue] = ["evidence_bundle_inspected": .boolean(false)]
    ) async -> PrimaryActionResult {
        guard let client, let screen, status == .inProgress else { return .unavailable }
        if screen.transitions.isEmpty {
            return .showEvidenceBundles
        }

        isWorking = true
        defer { isWorking = false }
        do {
            guard try await client.advance(
                evidence: evidence,
                evidenceRevision: Self.evidenceRevision
            ) != nil else { return .unavailable }
            await synchronize(using: client)
            try await exposeCurrentScreenIfNeeded(using: client)
            return .advanced
        } catch {
            return .unavailable
        }
    }

    /// Shows the walkthrough again, now, for an operator who asked for it.
    ///
    /// The shared client owns the semantics. `reset` closes the finished
    /// attempt, opens a fresh one on the entry screen, and emits
    /// `onboarding_reset` followed by `onboarding_started`, so a second viewing
    /// is a second attempt in the funnel rather than a completed journey that
    /// silently reappears. Republishing `screen` is the whole of the
    /// presentation: `ProbierzRootView` stacks the card above whatever
    /// destination is open the moment a screen exists, so the walkthrough
    /// returns to the window already on screen and the operator keeps the
    /// screen they asked from.
    ///
    /// `exposedScreenID` is cleared because the replayed entry screen is a view
    /// of a new attempt: leaving the old id in place would suppress its
    /// `onboarding_step_viewed` and lose the first step of every replay.
    ///
    /// A journey that never loaded its progress — the root task failed, or the
    /// operator reached this control first — is started here rather than
    /// refused, because a dead control is worse than a slow one.
    func replay() async -> WisentMutationOutcome {
        guard let client else {
            return .failed("Onboarding did not load in this session, so there is nothing to show.")
        }

        isWorking = true
        defer { isWorking = false }
        do {
            if await client.progress == nil {
                _ = try await client.start(evidenceRevision: Self.evidenceRevision)
                didStart = true
            }
            try await client.reset(evidenceRevision: Self.evidenceRevision)
            exposedScreenID = nil
            await synchronize(using: client)
            try await exposeCurrentScreenIfNeeded(using: client)
            try await client.flush()
            return .succeeded("Started. The walkthrough is at the top of this screen.")
        } catch {
            return .failed(Self.replayFailure(error))
        }
    }

    /// Why a replay failed, in a sentence an operator can act on.
    ///
    /// `JourneyClientError` carries no localization, so `localizedDescription`
    /// renders it as "error 3" and names nothing. Its cases are spelled out
    /// here; anything else keeps the words its own type gives, exactly as
    /// `ProbierzModel` reports a failed repair.
    private static func replayFailure(_ error: Error) -> String {
        guard let journeyError = error as? JourneyClientError else {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        switch journeyError {
        case .notStarted:
            return "Onboarding did not load in this session, so there is nothing to show."
        case .storage:
            return "Onboarding progress could not be written on this machine."
        case .transport:
            return "The onboarding service could not be reached."
        case let .invalid(reason):
            return reason
        }
    }

    func observeEvidenceBundleInspected(_ artifact: ArtifactMetadata) async {
        guard artifact.kind == .protectedBundle,
              artifact.isAvailableOnDisk,
              let client,
              status == .inProgress
        else { return }

        let revision = "evidence_bundle_inspected:\(artifact.id)"
        do {
            let completed = try await client.complete(
                evidence: ["evidence_bundle_inspected": .boolean(true)],
                evidenceRevision: revision
            )
            guard completed else { return }
            await synchronize(using: client)
            try await client.flush()
        } catch {
            return
        }
    }

    private func synchronize(using client: JourneyClient) async {
        let progress = await client.progress
        let currentScreen = await client.currentScreen
        apply(screen: currentScreen, status: progress?.status)
    }

    private func apply(screen: JourneyScreen?, status: JourneyProgressStatus?) {
        self.status = status
        self.screen = status == .inProgress ? screen : nil
    }

    private func exposeCurrentScreenIfNeeded(using client: JourneyClient) async throws {
        guard let screen, screen.screenId != exposedScreenID else { return }
        try await client.expose(evidenceRevision: Self.evidenceRevision)
        exposedScreenID = screen.screenId
    }

    /// The bundled definition, which is both the offline journey and the
    /// identity a definition published through Echo is checked against.
    ///
    /// `JourneyResource` resolves the packaged resource bundle the way a
    /// shipped app has to — from `Bundle.main.resourceURL` and then
    /// `bundleURL` — instead of SwiftPM's `Bundle.module` accessor, which
    /// resolves an absolute `.build` path that exists only on the machine that
    /// compiled the binary and traps on everyone else's Mac.
    private static func fallbackBundle() -> JourneyBundle? {
        guard let versionID = UUID(uuidString: "C8498F19-AD2A-4E7E-93F2-C173BE84256E"),
              let data = try? JourneyResource.definitionData(
                  resource: resourceName,
                  bundleName: resourceBundleName
              )
        else {
            return nil
        }
        return try? JourneyRouter.makeBundle(
            canonicalDefinition: String(decoding: data, as: UTF8.self),
            journeyVersionId: versionID
        )
    }
}
