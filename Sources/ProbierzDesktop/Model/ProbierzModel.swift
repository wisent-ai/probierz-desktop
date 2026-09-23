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
            case .recorded: "Recorded"
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

    @Published var workspaceRoot: URL?
    @Published var snapshot: ProbierzSnapshot?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var repairOutcome: WisentMutationOutcome = .idle
    @Published var adoptionOutcome: WisentMutationOutcome = .idle
    @Published var projectAdoption: ProjectAdoptionResult?
    @Published var projectAdoptions: ProjectAdoptionIndex?
    @Published var isAdopting = false

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
    /// Envelopes desktop apps reported to the Probierz intake, read straight
    /// from probierz/test-results/failures — a local file read, no backend.
    @Published var failures: [FailureEntry] = []
    @Published var failuresLoadedAt: Date?
    @Published var failureServiceFilter: String?
    @Published var failureCodeFilter: String?
    @Published var selectedFailureID: FailureEntry.ID?

    /// Scoped projections, recomputed once per load or scope change rather than
    /// on every render of a table that asks for them.
    @Published var runs: [RunRecord] = []
    @Published var artifacts: [ArtifactMetadata] = []
    @Published var journeys: [JourneyRecord] = []
    @Published var verdicts: [VerdictRecord] = []
    @Published var summary = ScopeSummary()
    @Published var artifactKindCounts: [ArtifactKind: Int] = [:]

    let defaults: UserDefaults
    let workspaceKey = "probierzDesktop.workspaceRoot"
    let scopeKey = "probierzDesktop.productScope"
    var generation = 0
    let commandClient = ProbierzCommandClient()
    let adoptionClient = ProjectAdoptionClient()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaceRoot = WorkspaceLocator.resolve(savedPath: defaults.string(forKey: workspaceKey))
        productScope = defaults.string(forKey: scopeKey)
        if workspaceRoot == nil {
            errorMessage = "Choose your Wisent workspace."
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
    var failuresFreshnessLabel: String? {
        guard let failuresLoadedAt else { return nil }
        return "Read \(failuresLoadedAt.formatted(.dateTime.hour().minute().second()))"
    }

    // MARK: - Reported failures

    var visibleFailures: [FailureEntry] {
        failures.filter { entry in
            guard failureServiceFilter == nil || entry.envelope.service == failureServiceFilter else {
                return false
            }
            guard failureCodeFilter == nil || entry.envelope.errorCode == failureCodeFilter else { return false }
            return true
        }
    }

    var hasFailureFilter: Bool {
        failureServiceFilter != nil || failureCodeFilter != nil
    }

    func clearFailureFilters() {
        failureServiceFilter = nil
        failureCodeFilter = nil
    }

    /// (value, count) pairs, most reported first — the facet rail's labels.
    var failureServiceCounts: [(service: String, count: Int)] {
        failureCounts(\.envelope.service).map { (service: $0.value, count: $0.count) }
    }

    var failureCodeCounts: [(code: String, count: Int)] {
        failureCounts(\.envelope.errorCode).map { (code: $0.value, count: $0.count) }
    }

    func failureCounts(_ keyPath: KeyPath<FailureEntry, String>) -> [(value: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in failures { counts[entry[keyPath: keyPath], default: 0] += 1 }
        return counts
            .map { (value: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
    }

    var selectedFailure: FailureEntry? {
        guard let selectedFailureID else { return nil }
        return failures.first { $0.id == selectedFailureID }
    }

    func refreshFailures() async {
        guard let workspaceRoot else {
            failures = []
            failuresLoadedAt = nil
            selectedFailureID = nil
            return
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            FailureIntakeStore.load(workspaceRoot: workspaceRoot)
        }.value
        guard !Task.isCancelled else { return }
        failures = loaded
        failuresLoadedAt = Date()
        if let selectedFailureID, !loaded.contains(where: { $0.id == selectedFailureID }) {
            self.selectedFailureID = nil
        }
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






    // MARK: - Artifacts







    // MARK: - Journeys and verdicts







    // MARK: - Loading



}
