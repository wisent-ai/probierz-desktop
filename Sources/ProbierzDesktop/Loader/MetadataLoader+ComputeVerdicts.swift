import Foundation

extension MetadataLoader {
    func computeVerdicts(
        journeys: [JourneyRecord],
        runs: [RunRecord],
        apps: [String: AppManifestScan]
    ) -> [VerdictRecord] {
        let runsByID = Dictionary(runs.map { ($0.runID, $0) }, uniquingKeysWith: { first, _ in first })
        return journeys.map { journey in
            let minimum = apps[journey.appID]?.minimumEvidence ?? Self.defaultMinimumEvidence
            let latest = journey.latestRunID.flatMap { runsByID[$0] }
            var reasons: [String] = []
            if let latest {
                if latest.status != .passed {
                    reasons.append("\(journey.name): last run is \(latest.status.rawValue)")
                }
                if latest.evidenceLevel.ordinal < minimum.ordinal {
                    reasons.append("\(journey.name): \(latest.evidenceLevel.title) is below \(minimum.title)")
                }
            } else {
                reasons.append("\(journey.name): no runs recorded")
            }
            return VerdictRecord(
                appID: journey.appID,
                journey: journey.name,
                minimumEvidence: minimum,
                latestRunID: latest?.runID,
                latestStatus: latest?.status,
                latestEvidenceLevel: latest?.evidenceLevel,
                latestStartedAt: latest?.startedAt,
                recordedSources: latest?.sourceRepositories ?? [],
                blockingReasons: reasons,
                headFreshnessUnknown: latest != nil
            )
        }
    }
    func summaries(runs: [RunRecord], artifacts: [ArtifactMetadata]) -> [String: ScopeSummary] {
        var summaries: [String: ScopeSummary] = [:]
        func update(_ key: String, _ body: (inout ScopeSummary) -> Void) {
            var summary = summaries[key] ?? ScopeSummary()
            body(&summary)
            summaries[key] = summary
        }
        for run in runs {
            for key in [ProbierzSnapshot.allProducts, run.appID] {
                update(key) { summary in
                    summary.status.add(run.status)
                    summary.evidence.add(run.evidenceLevel)
                    if summary.lastStartedAt == nil || (run.startedAt ?? .distantPast) > (summary.lastStartedAt ?? .distantPast) {
                        summary.lastRunID = run.runID
                        summary.lastStatus = run.status
                        summary.lastStartedAt = run.startedAt
                    }
                    if run.status == .passed,
                       summary.lastGreenStartedAt == nil
                           || (run.startedAt ?? .distantPast) > (summary.lastGreenStartedAt ?? .distantPast) {
                        summary.lastGreenRunID = run.runID
                        summary.lastGreenStartedAt = run.startedAt
                    }
                }
            }
        }
        for artifact in artifacts {
            for key in [ProbierzSnapshot.allProducts, artifact.appID] {
                update(key) { summary in
                    summary.artifactCount += 1
                    summary.artifactBytes += artifact.bytes
                    if artifact.kind == .protectedBundle { summary.protectedBundleCount += 1 }
                    if !artifact.hasSHA256 { summary.missingIntegrityCount += 1 }
                }
            }
        }
        return summaries
    }
    static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return String(value.prefix(maxFieldLength))
    }
    static func normalizedDigest(_ value: String?) -> String? {
        guard let value = trimmed(value),
              value.count == sha256HexLength,
              value.allSatisfy(\.isHexDigit)
        else { return nil }
        return value.lowercased()
    }
    func normalizedIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= Self.maxDisplayNameLength,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }
    func normalizedLabel(_ value: String?, fallback: String) -> String {
        normalizedIdentifier(value) ?? fallback
    }
    func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
    func safeURL(_ relativePath: String, root: URL) -> URL? {
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
    /// An absolute path recorded by the backend is accepted only when it stays
    /// inside the result store and crosses no symlink on the way.
    func containedURL(absolutePath: String, within root: URL) -> URL? {
        guard absolutePath.hasPrefix("/") else { return nil }
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: absolutePath).standardizedFileURL
        guard candidate.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(normalizedRoot.path + "/") else { return nil }
        let relative = candidate.path.dropFirst(root.standardizedFileURL.path.count)
        return safeURL(String(relative.drop(while: { $0 == "/" })), root: root)
    }
}
