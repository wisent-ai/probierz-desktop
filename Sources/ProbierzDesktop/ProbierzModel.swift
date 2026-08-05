import Combine
import Foundation

@MainActor
final class ProbierzModel: ObservableObject {
    @Published private(set) var workspaceRoot: URL?
    @Published private(set) var snapshot: ProbierzSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var inspectedEvidenceBundle: ArtifactMetadata?
    @Published var query = ""
    @Published var statusFilter: RunStatus?

    private let defaults: UserDefaults
    private let workspaceKey = "probierzDesktop.workspaceRoot"
    private var generation = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaceRoot = WorkspaceLocator.resolve(savedPath: defaults.string(forKey: workspaceKey))
        if workspaceRoot == nil {
            errorMessage = "Choose the local Wisent workspace to inspect Probierz metadata."
        }
    }

    var filteredContracts: [ContractItem] {
        guard let snapshot else { return [] }
        guard !query.isEmpty else { return snapshot.contracts }
        return snapshot.contracts.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
                || $0.relativePath.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredConfigurations: [ConfigurationItem] {
        guard let snapshot else { return [] }
        guard !query.isEmpty else { return snapshot.configurations }
        return snapshot.configurations.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var filteredRuns: [RunRecord] {
        guard let snapshot else { return [] }
        return snapshot.runs.filter { run in
            let matchesStatus = statusFilter == nil || run.status == statusFilter
            let matchesQuery = query.isEmpty
                || run.runID.localizedCaseInsensitiveContains(query)
                || run.appID.localizedCaseInsensitiveContains(query)
                || run.target.localizedCaseInsensitiveContains(query)
                || run.kind.localizedCaseInsensitiveContains(query)
                || run.status.title.localizedCaseInsensitiveContains(query)
            return matchesStatus && matchesQuery
        }
    }

    var filteredArtifacts: [ArtifactMetadata] {
        guard let snapshot else { return [] }
        guard !query.isEmpty else { return snapshot.artifacts }
        return snapshot.artifacts.filter {
            $0.runID.localizedCaseInsensitiveContains(query)
                || $0.kind.title.localizedCaseInsensitiveContains(query)
                || $0.fileExtension.localizedCaseInsensitiveContains(query)
        }
    }

    var hasActiveFilter: Bool {
        !query.isEmpty || statusFilter != nil
    }

    func clearFilters() {
        query = ""
        statusFilter = nil
    }

    func inspectEvidenceBundle(id: ArtifactMetadata.ID) {
        guard let artifact = snapshot?.artifacts.first(where: { $0.id == id }),
              artifact.kind == .protectedBundle,
              artifact.isAvailableOnDisk
        else { return }
        inspectedEvidenceBundle = artifact
    }

    func closeEvidenceBundleInspector() {
        inspectedEvidenceBundle = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let workspaceRoot else {
            errorMessage = "A local Wisent workspace has not been selected."
            return
        }
        guard WorkspaceLocator.isWorkspace(workspaceRoot) else {
            snapshot = nil
            inspectedEvidenceBundle = nil
            errorMessage = "The saved workspace no longer contains the Probierz metadata boundary."
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
        if let inspectedEvidenceBundle,
           !loaded.artifacts.contains(where: {
               $0.id == inspectedEvidenceBundle.id
                   && $0.kind == .protectedBundle
                   && $0.isAvailableOnDisk
           }) {
            self.inspectedEvidenceBundle = nil
        }
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
        inspectedEvidenceBundle = nil
        errorMessage = nil
        defaults.set(standardized.path, forKey: workspaceKey)
        Task { await refresh() }
    }
}
