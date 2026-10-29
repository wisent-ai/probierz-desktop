import Foundation

extension MetadataLoader {
    /// Every run manifest under test-results, read whole: no count, entry or size ceiling.
    /// A manifest that cannot be read or decoded, and a results folder or entry
    /// that cannot be read, is named in `unreadable` with its cause: skipped, a
    /// failed latest run with a damaged manifest vanished from the history and
    /// the gate evidence, and an unreadable folder showed no runs at all.
    func loadHistory(repositoryRoot: URL) -> (
        runs: [RunRecord], artifacts: [ArtifactMetadata], unreadable: [String]
    ) {
        let resultsRoot = repositoryRoot.appendingPathComponent("test-results", isDirectory: true)
        var unreadable: [String] = []
        let rootValues: URLResourceValues
        do {
            rootValues = try resultsRoot.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
        } catch CocoaError.fileReadNoSuchFile {
            return ([], [], [])
        } catch {
            return ([], [], ["\(resultsRoot.path): \(error.localizedDescription)"])
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            return (
                [], [],
                [
                    "\(resultsRoot.path): expected a non-symbolic-link directory; isDirectory=\(String(describing: rootValues.isDirectory)), isSymbolicLink=\(String(describing: rootValues.isSymbolicLink))"
                ]
            )
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: resultsRoot,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    unreadable.append("\(url.path): \(error.localizedDescription)")
                    return true
                }
            )
        else {
            return ([], [], ["\(resultsRoot.path): cannot be walked"])
        }

        var manifestURLs: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                ])
            } catch {
                unreadable.append("\(url.path): \(error.localizedDescription)")
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, url.lastPathComponent == "run-manifest.json" else {
                continue
            }
            manifestURLs.append(url)
        }

        var runs: [RunRecord] = []
        var artifacts: [ArtifactMetadata] = []
        runs.reserveCapacity(manifestURLs.count)
        for manifestURL in manifestURLs {
            let attributes: URLResourceValues
            let manifest: RunManifest
            do {
                attributes = try manifestURL.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey,
                ])
                let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
                manifest = try JSONDecoder().decode(RunManifest.self, from: data)
            } catch {
                unreadable.append("\(manifestURL.path): \(error.localizedDescription)")
                continue
            }
            guard let runID = normalizedIdentifier(manifest.runId) else {
                unreadable.append("\(manifestURL.path): names no run id")
                continue
            }
            let runDirectory = manifestURL.deletingLastPathComponent()
            let appID = normalizedLabel(manifest.appId, fallback: "unspecified-product")
            let target = normalizedLabel(manifest.target, fallback: "unspecified-target")
            let wasPlaintextRemoved = manifest.plaintextArtifactsRemovedAt != nil
            guard let descriptors = manifest.artifacts else {
                unreadable.append("\(manifestURL.path): artifacts is missing; record an array")
                continue
            }
            var runArtifacts = descriptors.enumerated().map { index, artifact in
                artifactMetadata(
                    artifact,
                    index: index,
                    runID: runID,
                    appID: appID,
                    target: target,
                    runDirectory: runDirectory,
                    wasPlaintextRemoved: wasPlaintextRemoved,
                    onFailure: { unreadable.append($0) }
                )
            }
            if let bundle = protectedBundle(
                manifest.protection,
                runID: runID,
                appID: appID,
                target: target,
                resultsRoot: resultsRoot,
                onFailure: { unreadable.append($0) }
            ) {
                runArtifacts.append(bundle)
            }

            let startedAt = parseDate(manifest.startedAt)
            let completedAt = parseDate(manifest.completedAt)
            let status = Self.normalizedStatus(manifest.status, completedAt: completedAt)
            let preflight = preflightRecord(
                manifest.preflight, runID: runID, target: target,
                observedAt: completedAt ?? startedAt)
            let journeyNames: [String] =
                switch manifest.appManifest?.journeys {
                case .some(let names): names.compactMap(normalizedIdentifier)
                case .none: []
                }
            let sources: [SourceIdentityRecord] =
                switch manifest.source?.repositories {
                case .some(let repositories):
                    repositories.compactMap { repository in
                        guard let name = normalizedIdentifier(repository.name) else { return nil }
                        return SourceIdentityRecord(
                            name: name,
                            gitSHA: normalizedIdentifier(repository.gitSha),
                            isDirty: repository.dirty == true
                        )
                    }
                case .none: []
                }
            runs.append(
                RunRecord(
                    runID: runID,
                    appID: appID,
                    target: target,
                    kind: normalizedLabel(manifest.kind, fallback: "adhoc"),
                    spec: normalizedIdentifier(manifest.spec),
                    status: status,
                    evidenceLevel: Self.evidenceLevel(manifest, status: status),
                    startedAt: startedAt,
                    completedAt: completedAt,
                    durationMilliseconds: manifest.durationMs,
                    manifestModifiedAt: attributes.contentModificationDate,
                    artifactCount: runArtifacts.count,
                    artifactBytes: runArtifacts.reduce(.zero) { $0 + $1.bytes },
                    journeys: journeyNames,
                    isRecorded: manifest.conditions?.record == true,
                    hasReportEvidence: manifest.evidence?.report == true,
                    hasAnalysisEvidence: manifest.evidence?.analysis == true,
                    isCapturePresent: manifest.evidence?.capturePresent == true,
                    exitCode: manifest.exitCode,
                    signalName: normalizedIdentifier(manifest.signal),
                    hostPlatform: normalizedIdentifier(manifest.host?.platform),
                    hostName: normalizedIdentifier(manifest.host?.hostname),
                    deviceName: normalizedIdentifier(manifest.device?.name),
                    deviceRuntime: normalizedIdentifier(manifest.device?.runtime),
                    harnessGitSHA: normalizedIdentifier(manifest.harness?.gitSha),
                    harnessIsDirty: manifest.harness?.dirty == true,
                    sourceRepositories: sources,
                    failure: Self.failure(manifest, status: status, preflight: preflight),
                    preflight: preflight,
                    platformDiagnostics: manifest.platformDiagnostics,
                    hasProtectedBundle: manifest.protection != nil
                ))
            artifacts.append(contentsOf: runArtifacts)
        }
        runs.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        artifacts.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        return (runs, artifacts, unreadable)
    }
    /// The statuses a run manifest records, as Probierz writes them.
    private enum ManifestStatus: String {
        case passed, executed, failed, blocked, canceled, cancelled
    }
    /// Mirrors `normalizedStatus` in `probierz/agent/history.mjs`, including the
    /// fallback: a manifest that names an unknown status is failed once it has a
    /// completion timestamp and incomplete until then.
    static func normalizedStatus(_ value: String?, completedAt: Date?) -> RunStatus {
        switch value.flatMap({ ManifestStatus(rawValue: $0.lowercased()) }) {
        case .passed?, .executed?: .passed
        case .failed?: .failed
        case .blocked?: .blocked
        case .canceled?, .cancelled?: .canceled
        case nil: completedAt == nil ? .incomplete : .failed
        }
    }
    /// Mirrors `evidenceLevel` in `gate.mjs`, `status.mjs`, `receipt.mjs` and
    /// `matrix.mjs` — the same three manifest facts, the same three outcomes.
    static func evidenceLevel(_ manifest: RunManifest, status: RunStatus) -> EvidenceLevel {
        guard status == .passed else { return .e0 }
        if manifest.conditions?.record == true,
            manifest.evidence?.report == true,
            manifest.evidence?.analysis == true,
            manifest.evidence?.capturePresent == true
        {
            return .e3
        }
        return .e2
    }
}
