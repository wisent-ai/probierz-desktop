import Combine
import Foundation
import WisentDesignSystem

@MainActor
final class ProbierzModel: ObservableObject {
    enum JourneyFilter: String, CaseIterable, Identifiable {
        case all
        case noEvidence
        case needsAttention
        case recorded

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All journeys"
            case .noEvidence: "No evidence"
            case .needsAttention: "Needs attention"
            case .recorded: "Recorded (E3)"
            }
        }
    }

    enum VerdictFilter: String, CaseIterable, Identifiable {
        case all
        case blocking
        case eligible

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All journeys"
            case .blocking: "Blocking"
            case .eligible: "Eligible"
            }
        }
    }

    @Published private(set) var workspaceRoot: URL?
    @Published private(set) var snapshot: ProbierzSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var repairOutcome: WisentMutationOutcome = .idle

    @Published var destination: ProbierzDestination = .posture
    @Published var query = ""

    @Published var runStatusFilter: RunStatus?
    @Published var runEvidenceFilter: EvidenceLevel?
    @Published var selectedRunID: RunRecord.ID?

    @Published var artifactKindFilter: ArtifactKind?
    @Published var artifactIntegrityFilter: Bool?
    @Published var artifactAvailabilityFilter: Bool?
    @Published var selectedArtifactID: ArtifactMetadata.ID?

    @Published var journeyFilter = JourneyFilter.all
    @Published var verdictFilter = VerdictFilter.all
    @Published var selectedJourneyID: JourneyRecord.ID?
    @Published var selectedVerdictID: VerdictRecord.ID?
    @Published var selectedSurfaceID: SurfaceRecord.ID?
    @Published var selectedPreflightID: PreflightRecord.ID?

    /// Scoped projections, recomputed once per load or scope change rather than
    /// on every render of a table that asks for them.
    @Published private(set) var runs: [RunRecord] = []
    @Published private(set) var artifacts: [ArtifactMetadata] = []
    @Published private(set) var journeys: [JourneyRecord] = []
    @Published private(set) var verdicts: [VerdictRecord] = []
    @Published private(set) var summary = ScopeSummary()
    @Published private(set) var artifactKindCounts: [ArtifactKind: Int] = [:]

    private let defaults: UserDefaults
    private let workspaceKey = "probierzDesktop.workspaceRoot"
    private let scopeKey = "probierzDesktop.productScope"
    private var generation = 0
    private let commandClient = ProbierzCommandClient()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaceRoot = WorkspaceLocator.resolve(savedPath: defaults.string(forKey: workspaceKey))
        productScope = defaults.string(forKey: scopeKey)
        if workspaceRoot == nil {
            errorMessage = "Choose the local Wisent workspace to inspect Probierz metadata."
        }
    }

    /// The product every screen is scoped to. `nil` means every product at once.
    @Published var productScope: String? {
        didSet {
            guard oldValue != productScope else { return }
            if let productScope {
                defaults.set(productScope, forKey: scopeKey)
            } else {
                defaults.removeObject(forKey: scopeKey)
            }
            applyScope()
        }
    }

    var scopeLabel: String { productScope ?? "All products" }

    var freshnessLabel: String? {
        guard let snapshot else { return nil }
        return "Read \(snapshot.loadedAt.formatted(.dateTime.hour().minute().second()))"
    }

    // MARK: - Runs

    var visibleRuns: [RunRecord] {
        runs.filter { run in
            guard runStatusFilter == nil || run.status == runStatusFilter else { return false }
            guard runEvidenceFilter == nil || run.evidenceLevel == runEvidenceFilter else { return false }
            guard !query.isEmpty else { return true }
            return run.runID.localizedCaseInsensitiveContains(query)
                || run.target.localizedCaseInsensitiveContains(query)
                || run.appID.localizedCaseInsensitiveContains(query)
                || run.kind.localizedCaseInsensitiveContains(query)
                || (run.spec ?? "").localizedCaseInsensitiveContains(query)
                || run.journeys.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var hasRunFilter: Bool {
        runStatusFilter != nil || runEvidenceFilter != nil || !query.isEmpty
    }

    func clearRunFilters() {
        runStatusFilter = nil
        runEvidenceFilter = nil
        query = ""
    }

    var selectedRun: RunRecord? {
        guard let selectedRunID else { return nil }
        return runs.first { $0.id == selectedRunID }
    }

    func repair(_ run: RunRecord) {
        guard !repairOutcome.isWorking else { return }
        guard run.status == .failed else {
            repairOutcome = .failed("Only a failed run can be repaired.")
            return
        }
        guard let repositoryRoot = snapshot?.repositoryRoot else {
            repairOutcome = .failed("Select a Probierz workspace before repairing a run.")
            return
        }
        repairOutcome = .working("Dispatching a repair through Brama…")
        let commandClient = commandClient
        Task {
            do {
                let message = try await Task.detached(priority: .userInitiated) {
                    try await commandClient.repair(
                        repositoryRoot: repositoryRoot,
                        appID: run.appID,
                        runID: run.runID
                    )
                }.value
                repairOutcome = .succeeded(message)
                await refresh()
            } catch {
                repairOutcome = .failed(
                    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }
        }
    }

    func clearRepairOutcome() {
        repairOutcome = .idle
    }

    /// The failures the operator has not resolved, newest first. Drives the
    /// alert panels on Posture, which quote each manifest's own sentence.
    var unresolvedFailures: [RunRecord] {
        runs.filter { $0.failure != nil }
    }

    var artifactsForSelectedRun: [ArtifactMetadata] {
        guard let selectedRunID else { return [] }
        return artifacts.filter { $0.runID == selectedRunID }
    }

    // MARK: - Artifacts

    var visibleArtifacts: [ArtifactMetadata] {
        artifacts.filter { artifact in
            guard artifactKindFilter == nil || artifact.kind == artifactKindFilter else { return false }
            guard artifactIntegrityFilter == nil || artifact.hasSHA256 == artifactIntegrityFilter else { return false }
            guard artifactAvailabilityFilter == nil || artifact.isAvailableOnDisk == artifactAvailabilityFilter else {
                return false
            }
            guard !query.isEmpty else { return true }
            return artifact.runID.localizedCaseInsensitiveContains(query)
                || artifact.kind.title.localizedCaseInsensitiveContains(query)
                || artifact.fileExtension.localizedCaseInsensitiveContains(query)
                || (artifact.sha256 ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var hasArtifactFilter: Bool {
        artifactKindFilter != nil
            || artifactIntegrityFilter != nil
            || artifactAvailabilityFilter != nil
            || !query.isEmpty
    }

    func clearArtifactFilters() {
        artifactKindFilter = nil
        artifactIntegrityFilter = nil
        artifactAvailabilityFilter = nil
        query = ""
    }

    var selectedArtifact: ArtifactMetadata? {
        guard let selectedArtifactID else { return nil }
        return artifacts.first { $0.id == selectedArtifactID }
    }

    var runForSelectedArtifact: RunRecord? {
        guard let runID = selectedArtifact?.runID else { return nil }
        return runs.first { $0.runID == runID }
    }

    /// Reveals the first protected bundle whose provenance can be inspected, so
    /// the first-use journey has a real row to land on.
    func selectFirstProtectedBundle() {
        // The product scope can hide every protected bundle in the workspace,
        // and the first-use journey only closes once one of their inspectors is
        // on screen. Widening beats leaving the journey unfinishable.
        let inScope = artifacts.contains { $0.kind == .protectedBundle && $0.isAvailableOnDisk }
        let anywhere = snapshot?.artifacts.contains { $0.kind == .protectedBundle && $0.isAvailableOnDisk } ?? false
        if !inScope, anywhere { productScope = nil }
        artifactKindFilter = .protectedBundle
        artifactIntegrityFilter = nil
        artifactAvailabilityFilter = nil
        query = ""
        selectedArtifactID = artifacts.first {
            $0.kind == .protectedBundle && $0.isAvailableOnDisk
        }?.id ?? artifacts.first { $0.kind == .protectedBundle }?.id
    }

    // MARK: - Journeys and verdicts

    var visibleJourneys: [JourneyRecord] {
        journeys.filter { journey in
            switch journeyFilter {
            case .all: true
            case .noEvidence: journey.runCount == 0 || journey.bestEvidenceLevel == nil
            case .needsAttention: journey.latestStatus?.needsAttention ?? true
            case .recorded: journey.bestEvidenceLevel == .e3
            }
        }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.appID.localizedCaseInsensitiveContains(query) }
    }

    var selectedJourney: JourneyRecord? {
        guard let selectedJourneyID else { return nil }
        return journeys.first { $0.id == selectedJourneyID }
    }

    var visibleVerdicts: [VerdictRecord] {
        verdicts.filter { verdict in
            switch verdictFilter {
            case .all: true
            case .blocking: verdict.isBlocking
            case .eligible: !verdict.isBlocking
            }
        }
        .filter { query.isEmpty || $0.journey.localizedCaseInsensitiveContains(query) || $0.appID.localizedCaseInsensitiveContains(query) }
    }

    var selectedVerdict: VerdictRecord? {
        guard let selectedVerdictID else { return nil }
        return verdicts.first { $0.id == selectedVerdictID }
    }

    var blockingVerdicts: [VerdictRecord] { verdicts.filter(\.isBlocking) }

    var runsForSelectedJourney: [RunRecord] {
        guard let selectedJourney else { return [] }
        return runs.filter { $0.appID == selectedJourney.appID && $0.journeys.contains(selectedJourney.name) }
    }

    // MARK: - Loading

    func refresh() async {
        guard !isRefreshing else { return }
        guard let workspaceRoot else {
            errorMessage = "A local Wisent workspace has not been selected."
            return
        }
        guard WorkspaceLocator.isWorkspace(workspaceRoot) else {
            snapshot = nil
            applyScope()
            errorMessage = "The saved workspace no longer contains the Probierz repository."
            return
        }

        let currentGeneration = generation
        isRefreshing = true
        defer {
            if currentGeneration == generation { isRefreshing = false }
        }
        let loader = MetadataLoader(workspaceRoot: workspaceRoot)
        let loaded = await Task.detached(priority: .userInitiated) {
            loader.load()
        }.value
        guard generation == currentGeneration, !Task.isCancelled else { return }
        snapshot = loaded
        if let productScope, !loaded.productIDs.contains(productScope) {
            self.productScope = nil
        }
        applyScope()
        errorMessage = nil
    }

    func selectWorkspace(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard WorkspaceLocator.isWorkspace(standardized) else {
            errorMessage = "The selected folder does not contain probierz/package.json and agent/history.mjs."
            return
        }
        generation &+= 1
        workspaceRoot = standardized
        snapshot = nil
        applyScope()
        errorMessage = nil
        defaults.set(standardized.path, forKey: workspaceKey)
        Task { await refresh() }
    }

    private func applyScope() {
        guard let snapshot else {
            runs = []
            artifacts = []
            journeys = []
            verdicts = []
            summary = ScopeSummary()
            artifactKindCounts = [:]
            selectedRunID = nil
            selectedArtifactID = nil
            selectedJourneyID = nil
            selectedVerdictID = nil
            return
        }
        let scope = productScope
        runs = scope.map { product in snapshot.runs.filter { $0.appID == product } } ?? snapshot.runs
        artifacts = scope.map { product in snapshot.artifacts.filter { $0.appID == product } } ?? snapshot.artifacts
        journeys = scope.map { product in snapshot.journeys.filter { $0.appID == product } } ?? snapshot.journeys
        verdicts = scope.map { product in snapshot.verdicts.filter { $0.appID == product } } ?? snapshot.verdicts
        summary = snapshot.summary(for: scope)

        var kinds: [ArtifactKind: Int] = [:]
        for artifact in artifacts { kinds[artifact.kind, default: 0] += 1 }
        artifactKindCounts = kinds

        if let selectedRunID, !runs.contains(where: { $0.id == selectedRunID }) { self.selectedRunID = nil }
        if let selectedArtifactID, !artifacts.contains(where: { $0.id == selectedArtifactID }) {
            self.selectedArtifactID = nil
        }
        if let selectedJourneyID, !journeys.contains(where: { $0.id == selectedJourneyID }) {
            self.selectedJourneyID = nil
        }
        if let selectedVerdictID, !verdicts.contains(where: { $0.id == selectedVerdictID }) {
            self.selectedVerdictID = nil
        }
    }
}
