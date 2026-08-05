import Foundation

struct MetadataLoader: Sendable {
    let workspaceRoot: URL

    private static let repositoryName = "probierz"
    private static let maximumManifests = 2_000
    private static let maximumVisitedEntries = 100_000
    private static let configurationNames = [
        "ANDROID_HOME",
        "ANDROID_SDK_ROOT",
        "APPIUM_HOME",
        "APP_IOS",
        "BUNDLE_ID",
        "IOS_DEVICE",
        "IOS_VERSION",
        "PLAYWRIGHT_BROWSERS_PATH",
        "PROBIERZ_ARTIFACT_ENCRYPTION_KEY_FILE",
        "PROBIERZ_COLOR_SCHEME",
        "PROBIERZ_LOCALE",
        "PROBIERZ_RELEASE",
        "WISENT_WORKSPACE_ROOT",
    ]

    private enum ContractKind: Sendable {
        case file
        case directory
        case executable
    }

    private struct ContractSpec: Sendable {
        let id: String
        let title: String
        let detail: String
        let relativePath: String
        let kind: ContractKind
    }

    private static let contractSpecs = [
        ContractSpec(id: "manifest", title: "Node package", detail: "Probierz package contract", relativePath: "package.json", kind: .file),
        ContractSpec(id: "mcp", title: "Las MCP surface", detail: "Probierz agent entry point", relativePath: "agent/mcp.mjs", kind: .file),
        ContractSpec(id: "history", title: "History boundary", detail: "Read-only run metadata projection", relativePath: "agent/history.mjs", kind: .file),
        ContractSpec(id: "apps", title: "Application surfaces", detail: "Configured verification products", relativePath: "apps", kind: .directory),
        ContractSpec(id: "results", title: "Result store", detail: "Local run metadata directory", relativePath: "test-results", kind: .directory),
        ContractSpec(id: "config", title: "Workspace configuration", detail: "Shared TypeScript contract", relativePath: "tsconfig.base.json", kind: .file),
    ]

    func load() -> ProbierzSnapshot {
        let repositoryRoot = workspaceRoot
            .appendingPathComponent(Self.repositoryName, isDirectory: true)
            .standardizedFileURL
        let contracts = Self.contractSpecs.map { inspectContract($0, repositoryRoot: repositoryRoot) }
        let environment = ProcessInfo.processInfo.environment
        let configurations = Self.configurationNames.map { name in
            ConfigurationItem(name: name, isPresent: !(environment[name] ?? "").isEmpty)
        }
        let history = loadHistory(repositoryRoot: repositoryRoot)
        let summary = StatusSummary(
            passed: history.runs.filter { $0.status == .passed }.count,
            failed: history.runs.filter { $0.status == .failed }.count,
            blocked: history.runs.filter { $0.status == .blocked }.count,
            canceled: history.runs.filter { $0.status == .canceled }.count,
            incomplete: history.runs.filter { $0.status == .incomplete }.count
        )
        return ProbierzSnapshot(
            repositoryRoot: repositoryRoot,
            contracts: contracts,
            configurations: configurations,
            runs: history.runs,
            artifacts: history.artifacts,
            summary: summary,
            loadedAt: Date(),
            manifestsTruncated: history.truncated
        )
    }

    private func inspectContract(_ spec: ContractSpec, repositoryRoot: URL) -> ContractItem {
        guard let url = safeURL(spec.relativePath, root: repositoryRoot),
              let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
              ]),
              values.isSymbolicLink != true else {
            return ContractItem(
                id: spec.id,
                title: spec.title,
                detail: spec.detail,
                relativePath: spec.relativePath,
                isAvailable: false,
                modifiedAt: nil
            )
        }

        let available: Bool
        switch spec.kind {
        case .file:
            available = values.isRegularFile == true
        case .directory:
            available = values.isDirectory == true
        case .executable:
            available = values.isRegularFile == true && FileManager.default.isExecutableFile(atPath: url.path)
        }
        return ContractItem(
            id: spec.id,
            title: spec.title,
            detail: spec.detail,
            relativePath: spec.relativePath,
            isAvailable: available,
            modifiedAt: values.contentModificationDate
        )
    }

    private func loadHistory(repositoryRoot: URL) -> (runs: [RunRecord], artifacts: [ArtifactMetadata], truncated: Bool) {
        let resultsRoot = repositoryRoot.appendingPathComponent("test-results", isDirectory: true)
        guard let rootValues = try? resultsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              let enumerator = FileManager.default.enumerator(
                at: resultsRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return ([], [], false)
        }

        var manifestURLs: [URL] = []
        var visitedEntries = 0
        var truncated = false
        while let url = enumerator.nextObject() as? URL {
            visitedEntries += 1
            if visitedEntries >= Self.maximumVisitedEntries {
                truncated = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, url.lastPathComponent == "run-manifest.json" else { continue }
            manifestURLs.append(url)
            if manifestURLs.count >= Self.maximumManifests {
                truncated = true
                break
            }
        }

        var runs: [RunRecord] = []
        var artifacts: [ArtifactMetadata] = []
        for manifestURL in manifestURLs {
            guard let data = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe]),
                  let manifest = try? JSONDecoder().decode(RunManifest.self, from: data),
                  let runID = normalizedIdentifier(manifest.runId) else {
                continue
            }
            let runDirectory = manifestURL.deletingLastPathComponent()
            let manifestModifiedAt = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let artifactRecords = (manifest.artifacts ?? []).enumerated().map { index, artifact in
                artifactMetadata(artifact, index: index, runID: runID, runDirectory: runDirectory)
            }
            let startedAt = parseDate(manifest.startedAt)
            let completedAt = parseDate(manifest.completedAt)
            runs.append(RunRecord(
                runID: runID,
                appID: normalizedLabel(manifest.appId, fallback: "Unspecified product"),
                target: normalizedLabel(manifest.target, fallback: "Unspecified target"),
                kind: normalizedLabel(manifest.kind, fallback: "adhoc"),
                status: normalizedStatus(manifest.status, completedAt: completedAt),
                startedAt: startedAt,
                completedAt: completedAt,
                durationMilliseconds: max(0, manifest.durationMs ?? 0),
                manifestModifiedAt: manifestModifiedAt,
                artifactCount: artifactRecords.count,
                artifactBytes: artifactRecords.reduce(0) { $0 + $1.bytes }
            ))
            artifacts.append(contentsOf: artifactRecords)
        }
        runs.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        artifacts.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        return (runs, artifacts, truncated)
    }

    private func artifactMetadata(
        _ artifact: ManifestArtifact,
        index: Int,
        runID: String,
        runDirectory: URL
    ) -> ArtifactMetadata {
        let fileExtension = URL(fileURLWithPath: artifact.file ?? "").pathExtension.lowercased()
        let artifactURL = artifact.file.flatMap { safeURL($0, root: runDirectory) }
        let values = try? artifactURL?.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let isSafeFile = values?.isRegularFile == true && values?.isSymbolicLink != true
        let diskBytes = isSafeFile ? Int64(values?.fileSize ?? 0) : 0
        return ArtifactMetadata(
            id: "\(runID)-\(index)",
            runID: runID,
            kind: artifactKind(for: fileExtension),
            fileExtension: fileExtension.isEmpty ? "—" : fileExtension.uppercased(),
            bytes: max(0, artifact.bytes ?? diskBytes),
            hasSHA256: !(artifact.sha256 ?? "").isEmpty,
            modifiedAt: isSafeFile ? values?.contentModificationDate : nil,
            isAvailableOnDisk: isSafeFile
        )
    }

    private func artifactKind(for fileExtension: String) -> ArtifactKind {
        switch fileExtension {
        case "png", "jpg", "jpeg", "heic", "webp": .image
        case "mp4", "mov", "webm": .video
        case "zip", "trace": .trace
        case "json", "xml", "html": .report
        case "log", "txt": .log
        case "pev": .protectedBundle
        default: .other
        }
    }

    private func normalizedStatus(_ value: String?, completedAt: Date?) -> RunStatus {
        switch value?.lowercased() {
        case "passed", "executed": .passed
        case "failed": .failed
        case "blocked": .blocked
        case "canceled", "cancelled": .canceled
        default: completedAt == nil ? .incomplete : .failed
        }
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 160,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    private func normalizedLabel(_ value: String?, fallback: String) -> String {
        normalizedIdentifier(value) ?? fallback
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private func safeURL(_ relativePath: String, root: URL) -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(".."),
              !components.contains("")
        else {
            return nil
        }

        var candidate = root
        for component in components {
            candidate.appendPathComponent(String(component))
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return nil
            }
        }

        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let normalizedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let prefix = normalizedRoot.path + "/"
        guard normalizedCandidate.path.hasPrefix(prefix) else { return nil }
        return candidate.standardizedFileURL
    }
}

private struct RunManifest: Decodable {
    let runId: String?
    let appId: String?
    let target: String?
    let kind: String?
    let status: String?
    let startedAt: String?
    let completedAt: String?
    let durationMs: Double?
    let artifacts: [ManifestArtifact]?
}

private struct ManifestArtifact: Decodable {
    let file: String?
    let bytes: Int64?
    let sha256: String?
}
