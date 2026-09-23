import Foundation

extension MetadataLoader {
    /// A narrow reader for the one block mapping and one policy this viewer needs.
    ///
    /// `probierz.yaml` is schema-validated at `schemaVersion: 1` by
    /// `agent/apps.mjs`: top-level scalars, `journeys:` keyed at one indent
    /// level, journey bodies at two. Reading those keys needs none of a YAML
    /// engine, and anything unrecognised is skipped rather than guessed.
    static func scanAppManifest(_ text: String) -> AppManifestScan {
        var scan = AppManifestScan()
        enum Block { case other, journeys, policy }
        var block = Block.other
        var currentJourney: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let entry = keyValue(trimmed) else { continue }
            let indent = line.prefix { $0 == " " }.count

            if indent == 0 {
                currentJourney = nil
                block = switch entry.key {
                case "journeys": .journeys
                case "pullRequestPolicy": .policy
                default: .other
                }
                continue
            }

            switch (block, indent) {
            case (.journeys, 2):
                guard entry.value == nil, isIdentifier(entry.key) else { continue }
                currentJourney = entry.key
                if !scan.journeyOrder.contains(entry.key) { scan.journeyOrder.append(entry.key) }
            case (.journeys, 4):
                guard let journey = currentJourney, let value = entry.value else { continue }
                if entry.key == "owner" { scan.journeyOwners[journey] = value }
                if entry.key == "description" { scan.journeyDescriptions[journey] = value }
            case (.policy, 2):
                guard entry.key == "minimumEvidence",
                      let value = entry.value,
                      let level = EvidenceLevel(rawValue: value.lowercased())
                else { continue }
                scan.minimumEvidence = level
            default:
                continue
            }
        }
        return scan
    }
    /// A block key ends with a colon; a scalar splits at its first one. Target
    /// names such as `desktop:mac` and descriptions containing a colon make that
    /// the only rule that separates them correctly.
    static func keyValue(_ trimmed: String) -> (key: String, value: String?)? {
        if trimmed.hasSuffix(":") {
            let key = String(trimmed.dropLast())
            return key.isEmpty ? nil : (key, nil)
        }
        guard let separator = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[trimmed.startIndex..<separator])
        var value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return key.isEmpty || value.isEmpty ? nil : (key, String(value.prefix(maxFrontMatterValue)))
    }
    static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maxIdentifierLength
            && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.:".contains($0) }
    }
    func loadHistory(repositoryRoot: URL) -> (runs: [RunRecord], artifacts: [ArtifactMetadata], truncated: Bool) {
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
        runs.reserveCapacity(manifestURLs.count)
        for manifestURL in manifestURLs {
            guard let attributes = try? manifestURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  (attributes.fileSize ?? 0) <= Self.maximumManifestBytes,
                  let data = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe]),
                  let manifest = try? JSONDecoder().decode(RunManifest.self, from: data),
                  let runID = normalizedIdentifier(manifest.runId) else {
                continue
            }
            let runDirectory = manifestURL.deletingLastPathComponent()
            let appID = normalizedLabel(manifest.appId, fallback: "unspecified-product")
            let target = normalizedLabel(manifest.target, fallback: "unspecified-target")
            let wasPlaintextRemoved = manifest.plaintextArtifactsRemovedAt != nil
            var runArtifacts = (manifest.artifacts ?? []).enumerated().map { index, artifact in
                artifactMetadata(
                    artifact,
                    index: index,
                    runID: runID,
                    appID: appID,
                    target: target,
                    runDirectory: runDirectory,
                    wasPlaintextRemoved: wasPlaintextRemoved
                )
            }
            if let bundle = protectedBundle(
                manifest.protection,
                runID: runID,
                appID: appID,
                target: target,
                resultsRoot: resultsRoot
            ) {
                runArtifacts.append(bundle)
            }

            let startedAt = parseDate(manifest.startedAt)
            let completedAt = parseDate(manifest.completedAt)
            let status = Self.normalizedStatus(manifest.status, completedAt: completedAt)
            let preflight = preflightRecord(manifest.preflight, runID: runID, target: target, observedAt: completedAt ?? startedAt)
            runs.append(RunRecord(
                runID: runID,
                appID: appID,
                target: target,
                kind: normalizedLabel(manifest.kind, fallback: "adhoc"),
                spec: normalizedIdentifier(manifest.spec),
                status: status,
                evidenceLevel: Self.evidenceLevel(manifest, status: status),
                startedAt: startedAt,
                completedAt: completedAt,
                durationMilliseconds: max(0, manifest.durationMs ?? 0),
                manifestModifiedAt: attributes.contentModificationDate,
                artifactCount: runArtifacts.count,
                artifactBytes: runArtifacts.reduce(0) { $0 + $1.bytes },
                journeys: (manifest.appManifest?.journeys ?? []).compactMap(normalizedIdentifier),
                isRecorded: manifest.conditions?.record == true,
                hasReportEvidence: manifest.evidence?.report == true,
                hasAnalysisEvidence: manifest.evidence?.analysis == true,
                isCapturePresent: manifest.evidence?.capturePresent == true,
                exitCode: manifest.exitCode,
                signalName: normalizedIdentifier(manifest.signal),
                didTimeOut: manifest.timedOut == true,
                hostPlatform: normalizedIdentifier(manifest.host?.platform),
                hostName: normalizedIdentifier(manifest.host?.hostname),
                deviceName: normalizedIdentifier(manifest.device?.name),
                deviceRuntime: normalizedIdentifier(manifest.device?.runtime),
                harnessGitSHA: normalizedIdentifier(manifest.harness?.gitSha),
                harnessIsDirty: manifest.harness?.dirty == true,
                sourceRepositories: (manifest.source?.repositories ?? []).compactMap { repository in
                    guard let name = normalizedIdentifier(repository.name) else { return nil }
                    return SourceIdentityRecord(
                        name: name,
                        gitSHA: normalizedIdentifier(repository.gitSha),
                        isDirty: repository.dirty == true
                    )
                },
                failure: Self.failure(manifest, status: status, preflight: preflight),
                preflight: preflight,
                hasProtectedBundle: manifest.protection != nil
            ))
            artifacts.append(contentsOf: runArtifacts)
        }
        runs.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        artifacts.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        return (runs, artifacts, truncated)
    }
    /// Mirrors `normalizedStatus` in `probierz/agent/history.mjs`, including the
    /// fallback: a manifest that names an unknown status is failed once it has a
    /// completion timestamp and incomplete until then.
    static func normalizedStatus(_ value: String?, completedAt: Date?) -> RunStatus {
        switch value?.lowercased() {
        case "passed", "executed": .passed
        case "failed": .failed
        case "blocked": .blocked
        case "canceled", "cancelled": .canceled
        default: completedAt == nil ? .incomplete : .failed
        }
    }
    /// Mirrors `evidenceLevel` in `gate.mjs`, `status.mjs`, `receipt.mjs` and
    /// `matrix.mjs` — the same three manifest facts, the same three outcomes.
    static func evidenceLevel(_ manifest: RunManifest, status: RunStatus) -> EvidenceLevel {
        guard status == .passed else { return .e0 }
        if manifest.conditions?.record == true,
           manifest.evidence?.report == true,
           manifest.evidence?.analysis == true,
           manifest.evidence?.capturePresent == true {
            return .e3
        }
        return .e2
    }
}
