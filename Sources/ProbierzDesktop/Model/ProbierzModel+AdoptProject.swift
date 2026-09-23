import Combine
import Foundation
import WisentDesignSystem

extension ProbierzModel {
    @discardableResult
    func adoptProject(from sourceRoot: URL, replace: Bool = false) async -> Bool {
        guard !isAdopting else { return false }
        guard let repositoryRoot = snapshot?.repositoryRoot else {
            adoptionOutcome = .failed("Select a Probierz workspace before adopting definitions.")
            return false
        }
        isAdopting = true
        projectAdoption = nil
        adoptionOutcome = .working("Validating the complete Probierz project before writing…")
        defer { isAdopting = false }
        do {
            let result = try await adoptionClient.adopt(
                repositoryRoot: repositoryRoot,
                sourceRoot: sourceRoot,
                replace: replace
            )
            projectAdoption = result
            if result.accepted {
                adoptionOutcome = .succeeded(result.summary)
                projectAdoptions = try await adoptionClient.list(repositoryRoot: repositoryRoot)
                await refresh()
                return true
            }
            adoptionOutcome = .failed(result.summary)
            return false
        } catch {
            adoptionOutcome = .failed(
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
            return false
        }
    }
    func clearAdoptionOutcome() {
        adoptionOutcome = .idle
    }
    func reloadProjectAdoptions() async {
        guard let repositoryRoot = snapshot?.repositoryRoot else {
            projectAdoptions = nil
            return
        }
        projectAdoptions = try? await adoptionClient.list(repositoryRoot: repositoryRoot)
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
        await reloadProjectAdoptions()
        errorMessage = nil
    }
    func selectWorkspace(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard WorkspaceLocator.isWorkspace(standardized) else {
            errorMessage = "Choose the folder that contains your Wisent projects."
            return
        }
        generation &+= 1
        workspaceRoot = standardized
        snapshot = nil
        applyScope()
        projectAdoption = nil
        projectAdoptions = nil
        adoptionOutcome = .idle
        failures = []
        failuresLoadedAt = nil
        selectedFailureID = nil
        failureServiceFilter = nil
        failureCodeFilter = nil
        errorMessage = nil
        defaults.set(standardized.path, forKey: workspaceKey)
        Task { await refresh() }
    }
    func applyScope() {
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
