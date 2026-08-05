import Combine
import Foundation
import SwiftUI
import WisentOnboarding

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
        ProbierzPanel {
            HStack(alignment: .top, spacing: ProbierzTheme.Space.x4) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(ProbierzTheme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: ProbierzTheme.Space.x2) {
                    Text(title)
                        .font(.headline)
                    Text(bodyText)
                        .font(.subheadline)
                        .foregroundStyle(ProbierzTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: ProbierzTheme.Space.x4)
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Probierz first-use journey")
    }

    private var title: String {
        switch screen.titleKey {
        case "probierz.first_use.read_only.title":
            "Evidence stays read-only"
        case "probierz.first_use.provenance.title":
            "Every bundle has provenance"
        case "probierz.first_use.inspect.title":
            "Inspect a real evidence bundle"
        default:
            screen.transitions.isEmpty ? "Inspect Probierz evidence" : "Understand Probierz evidence"
        }
    }

    private var bodyText: String {
        switch screen.bodyKey {
        case "probierz.first_use.read_only.body":
            "Probierz Desktop presents a read-only projection. It never executes a verification, changes a run, or decrypts protected evidence contents."
        case "probierz.first_use.provenance.body":
            "Bundle records come from a real run manifest. The viewer accepts only regular, non-symlink files contained by that run directory, then exposes provenance metadata without revealing a path or payload."
        case "probierz.first_use.inspect.body":
            "Open Artifacts and inspect an available Protected bundle. The journey finishes only when its real metadata inspector is on screen."
        default:
            screen.transitions.isEmpty
                ? "Inspect an available protected evidence bundle to see its read-only provenance record."
                : "Continue through the product-owned explanation before inspecting evidence."
        }
    }

    private var actionLabel: String {
        screen.transitions.isEmpty ? "Show Evidence Bundles" : "Continue"
    }

    private var symbol: String {
        switch screen.titleKey {
        case "probierz.first_use.read_only.title": "lock.open.display"
        case "probierz.first_use.provenance.title": "point.3.connected.trianglepath.dotted"
        default: "doc.text.magnifyingglass"
        }
    }
}
