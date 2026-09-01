import Combine
@preconcurrency import Foundation
import SwiftUI
import WisentOnboarding
import WisentDesignSystem

private struct ProbierzJourneyTransport: JourneyTransport {
    private let base: EnvironmentJourneyTransport

    init() {
        base = EnvironmentJourneyTransport(
            tokenEnvironmentKey: "PROBIERZ_DESKTOP_STADO_INTEGRATION_TOKEN"
        )
    }

    func readBundle(productId: String, journeyId: String) async throws -> JourneyBundle {
        let bundle = try await base.readBundle(productId: productId, journeyId: journeyId)
        guard bundle.definition.journeyVersion == "2026-08-04.1",
              bundle.definition.firstSuccessFact == "evidence_bundle_inspected"
        else {
            throw JourneyClientError.invalid("Probierz journey identity")
        }
        return bundle
    }

    func readState(productId: String, attemptId: UUID, subjectHash: String) async throws -> JSONValue? {
        try await base.readState(
            productId: productId,
            attemptId: attemptId,
            subjectHash: subjectHash
        )
    }

    func assignExperiment(request: JourneyAssignmentRequest) async throws -> JourneyAssignmentResponse {
        try await base.assignExperiment(request: request)
    }

    func collect(event: JourneyRuntimeEvent) async throws {
        try await base.collect(event: event)
    }
}

@MainActor
final class ProbierzOnboarding: ObservableObject {
    enum PrimaryActionResult {
        case advanced
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
        guard let client, let screen, status == .inProgress else { return .unavailable }
        if screen.transitions.isEmpty {
            return .showEvidenceBundles
        }

        isWorking = true
        defer { isWorking = false }
        do {
            guard try await client.advance(
                evidence: ["evidence_bundle_inspected": .boolean(false)],
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

    private static func fallbackBundle() -> JourneyBundle? {
        guard let versionID = UUID(uuidString: "A1E81E86-368A-42C0-9BBA-C7E05D42AD24") else {
            return nil
        }
        return try? JourneyRouter.makeBundle(
            canonicalDefinition: fallbackDefinition,
            journeyVersionId: versionID
        )
    }

    private static let fallbackDefinition = #"{"schema_version":1,"product_id":"probierz-desktop","journey_id":"first-use","journey_version":"2026-08-04.1","entry_screen_id":"read-only-semantics","first_success_fact":"evidence_bundle_inspected","published_at":"2026-08-04T00:00:00Z","source_revision":"probierz-desktop-onboarding-2026-08-04.1","screens":[{"screen_id":"read-only-semantics","screen_kind":"explanation","title_key":"probierz.first_use.read_only.title","body_key":"probierz.first_use.read_only.body","required":true,"actions":["continue"],"transitions":[{"next_screen_id":"bundle-provenance","reason_code":"semantics_acknowledged","priority":0}],"presentation":{}},{"screen_id":"bundle-provenance","screen_kind":"explanation","title_key":"probierz.first_use.provenance.title","body_key":"probierz.first_use.provenance.body","required":true,"actions":["continue"],"transitions":[{"next_screen_id":"inspect-evidence-bundle","reason_code":"provenance_explained","priority":0}],"presentation":{}},{"screen_id":"inspect-evidence-bundle","screen_kind":"first_success","title_key":"probierz.first_use.inspect.title","body_key":"probierz.first_use.inspect.body","required":true,"completion_evidence":{"kind":"fact","fact":"evidence_bundle_inspected","operator":"eq","value":true},"actions":["inspect_evidence_bundle"],"transitions":[],"presentation":{}}],"analytics_contract":{"contract_version":"1","surface":"native_viewer","exposure_event":"journey.step_viewed","primary_action_event":"journey.step_completed","completion_event":"journey.completed","first_success_event":"journey.first_success_observed"}}"#
}

struct ProbierzOnboardingCard: View {
    let screen: JourneyScreen
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        WisentPanel {
            HStack(alignment: .top, spacing: WisentDesign.Space.x4) {
                Image(systemName: symbol)
                    .font(.system(size: WisentDesign.Space.x5, weight: .semibold))
                    .foregroundStyle(WisentDesign.brand)
                    .frame(width: WisentDesign.Space.x10, height: WisentDesign.Space.x10)
                    .background(
                        WisentDesign.brandSoft,
                        in: RoundedRectangle(cornerRadius: WisentDesign.Radius.medium)
                    )
                VStack(alignment: .leading, spacing: WisentDesign.Space.x2) {
                    WisentBadge("Getting started", symbol: "sparkles", tone: .brand)
                    Text(title)
                        .font(WisentTypography.heading(18))
                        .foregroundStyle(WisentDesign.ink)
                    Text(bodyText)
                        .font(WisentTypography.body(13))
                        .foregroundStyle(WisentDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: WisentDesign.Space.x4)
                Button(action: action) {
                    // The button keeps its words while the step is in flight;
                    // they are dimmed rather than swapped for a spinning
                    // circle, so the control never changes size and keeps its
                    // accessible name.
                    Text(actionLabel)
                        .opacity(isWorking ? 0.35 : 1)
                }
                .buttonStyle(WisentPrimaryButtonStyle())
                .disabled(isWorking)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Probierz first-use journey")
    }

    private var title: String {
        switch screen.titleKey {
        case "probierz.first_use.read_only.title":
            "Review a run"
        case "probierz.first_use.provenance.title":
            "Check a result"
        case "probierz.first_use.inspect.title":
            "Open a result"
        default:
            screen.transitions.isEmpty ? "Open a result" : "Review results"
        }
    }

    private var bodyText: String {
        switch screen.bodyKey {
        case "probierz.first_use.read_only.body":
            "See what happened and retry a failed run."
        case "probierz.first_use.provenance.body":
            "Each result shows when it ran and what it produced."
        case "probierz.first_use.inspect.body":
            "Open Artifacts and choose a result."
        default:
            screen.transitions.isEmpty
                ? "Choose a result to see its details."
                : "Continue to see how results are presented."
        }
    }

    private var actionLabel: String {
        screen.transitions.isEmpty ? "Show results" : "Continue"
    }

    private var symbol: String {
        switch screen.titleKey {
        case "probierz.first_use.read_only.title": "lock.open.display"
        case "probierz.first_use.provenance.title": "point.3.connected.trianglepath.dotted"
        default: "doc.text.magnifyingglass"
        }
    }
}
