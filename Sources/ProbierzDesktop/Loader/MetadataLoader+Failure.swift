import Foundation

extension MetadataLoader {
    /// Every sentence a failed or blocked manifest recorded about itself.
    ///
    /// The baseline loader decoded no reason field at all, so a failure could
    /// only ever be a coloured pill. These are the manifest's own strings, in
    /// the order the runner writes them, and nothing is paraphrased.
    static func failure(
        _ manifest: RunManifest,
        status: RunStatus,
        preflight: PreflightRecord?
    ) -> RunFailure? {
        guard status == .failed || status == .blocked else { return nil }

        var reasons: [String] = []
        var code: String?
        var facts: [String] = []

        if let spawn = manifest.spawnFailure {
            if let message = trimmed(spawn.message) { reasons.append(message) }
            code = trimmed(spawn.errorCode) ?? trimmed(spawn.failurePoint)
            if let point = trimmed(spawn.failurePoint) { facts.append("failure point \(point)") }
        }
        if let setupError = trimmed(manifest.setupError) { reasons.append(setupError) }
        if let lock = manifest.resourceLock {
            if let message = trimmed(lock.error) { reasons.append(message) }
            if let resource = trimmed(lock.resource) { facts.append("resource \(resource)") }
            if let owner = trimmed(lock.owner) { facts.append("resource owner \(owner)") }
        }
        reasons.append(contentsOf: (manifest.evidence?.errors ?? []).compactMap(trimmed))
        reasons.append(contentsOf: (manifest.evidence?.captureErrors ?? []).compactMap(trimmed))
        if manifest.reportValidation?.ok != true, let error = trimmed(manifest.reportValidation?.error) {
            reasons.append(error)
        }
        if let cleanupError = trimmed(manifest.cleanupError) { reasons.append(cleanupError) }

        var remediation: [String] = []
        if let preflight, !preflight.isReady {
            remediation = preflight.remediation
            // `stado.mjs` phrases a blocked preflight exactly this way.
            if !preflight.missing.isEmpty {
                let missing = preflight.missing.joined(separator: ", ")
                let hint = preflight.remediation.joined(separator: "; ")
                reasons.append(hint.isEmpty ? "missing: \(missing)" : "missing: \(missing); remediation: \(hint)")
            }
        }

        var seen = Set<String>()
        reasons = reasons.filter { seen.insert($0).inserted }

        if let exitCode = manifest.exitCode { facts.append("exit code \(exitCode)") }
        if let signal = trimmed(manifest.signal) { facts.append("terminated by \(signal)") }
        if manifest.timedOut == true {
            let budget = manifest.timeoutMs.map { " after \(Int($0)) ms" } ?? ""
            facts.append("timed out\(budget)")
        }
        if manifest.evidence?.captureRequired == true, manifest.evidence?.capturePresent != true {
            facts.append("recording requested without a capture")
        }
        if manifest.reportValidation?.ok == true { facts.append("report validation recorded ok") }
        if manifest.evidence?.analysis == true { facts.append("analysis recorded valid") }

        let headline = status == .blocked
            ? "Run blocked before the suite started"
            : "Run failed"
        let sentence = reasons.first ?? [
            "The run manifest records status \"\(manifest.status ?? "unknown")\" without a reason sentence:",
            "evidence.errors, reportValidation.error, setupError, spawnFailure, resourceLock and preflight are all absent or empty.",
        ].joined(separator: " ")

        return RunFailure(
            headline: headline,
            sentence: sentence,
            reasons: reasons,
            remediation: remediation,
            command: trimmed(manifest.command),
            code: code,
            facts: facts,
            hasRecordedReason: !reasons.isEmpty
        )
    }
    func preflightRecord(
        _ preflight: ManifestPreflight?,
        runID: String,
        target: String,
        observedAt: Date?
    ) -> PreflightRecord? {
        guard let preflight else { return nil }
        return PreflightRecord(
            target: normalizedLabel(preflight.target, fallback: target),
            isReady: preflight.ready == true,
            checks: (preflight.checks ?? []).compactMap { check in
                guard let name = normalizedIdentifier(check.name) else { return nil }
                return PreflightCheck(
                    name: name,
                    isSatisfied: check.ok == true,
                    hint: Self.trimmed(check.hint) ?? "",
                    isOwnedByProbierz: check.own == true
                )
            },
            missing: (preflight.missing ?? []).compactMap(Self.trimmed),
            remediation: (preflight.remediation ?? []).compactMap(Self.trimmed),
            observedAt: observedAt,
            runID: runID
        )
    }
    /// The freshest recorded preflight per target. A preflight is a fact about
    /// the host that ran it, so the newest recording wins and older ones are not
    /// averaged into it.
    func latestPreflights(runs: [RunRecord]) -> [PreflightRecord] {
        var byTarget: [String: PreflightRecord] = [:]
        for run in runs {
            guard let preflight = run.preflight else { continue }
            if byTarget[preflight.target] == nil { byTarget[preflight.target] = preflight }
        }
        return byTarget.values.sorted { $0.target < $1.target }
    }
    func artifactMetadata(
        _ artifact: ManifestArtifact,
        index: Int,
        runID: String,
        appID: String,
        target: String,
        runDirectory: URL,
        wasPlaintextRemoved: Bool
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
            appID: appID,
            target: target,
            kind: Self.artifactKind(for: fileExtension),
            fileExtension: fileExtension.isEmpty ? "—" : fileExtension.uppercased(),
            bytes: max(0, artifact.bytes ?? diskBytes),
            sha256: Self.normalizedDigest(artifact.sha256),
            keyFingerprintSHA256: nil,
            modifiedAt: isSafeFile ? values?.contentModificationDate : nil,
            isAvailableOnDisk: isSafeFile,
            wasPlaintextRemoved: wasPlaintextRemoved && !isSafeFile
        )
    }
    /// `probierz protect` writes the encrypted bundle outside the run directory,
    /// under `test-results/.protected`, and records it in `protection`. The
    /// descriptor is metadata; the absolute path it carries is never surfaced.
    func protectedBundle(
        _ protection: ManifestProtection?,
        runID: String,
        appID: String,
        target: String,
        resultsRoot: URL
    ) -> ArtifactMetadata? {
        guard let protection, let file = Self.trimmed(protection.file) else { return nil }
        let url = containedURL(absolutePath: file, within: resultsRoot)
        let values = url.flatMap {
            try? $0.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        }
        let isSafeFile = values?.isRegularFile == true && values?.isSymbolicLink != true
        return ArtifactMetadata(
            id: "\(runID)-protection",
            runID: runID,
            appID: appID,
            target: target,
            kind: .protectedBundle,
            fileExtension: URL(fileURLWithPath: file).pathExtension.uppercased(),
            bytes: max(0, protection.bytes ?? Int64(values?.fileSize ?? 0)),
            sha256: Self.normalizedDigest(protection.sha256),
            keyFingerprintSHA256: Self.normalizedDigest(protection.keyFingerprintSha256),
            modifiedAt: isSafeFile ? values?.contentModificationDate : nil,
            isAvailableOnDisk: isSafeFile,
            wasPlaintextRemoved: false
        )
    }
    static func artifactKind(for fileExtension: String) -> ArtifactKind {
        switch fileExtension {
        case "png", "jpg", "jpeg", "heic", "webp", "svg": .image
        case "mp4", "mov", "webm": .video
        case "zip", "trace": .trace
        case "json", "xml", "html", "md": .report
        case "log", "txt", "jsonl": .log
        case "pev": .protectedBundle
        default: .other
        }
    }
    func aggregateJourneys(
        runs: [RunRecord],
        apps: [String: AppManifestScan]
    ) -> [JourneyRecord] {
        struct Accumulator {
            var summary = StatusSummary()
            var latest: RunRecord?
            var best: EvidenceLevel?
        }

        var accumulators: [String: Accumulator] = [:]
        var order: [String] = []
        func key(_ appID: String, _ journey: String) -> String { "\(appID)\u{1}\(journey)" }

        // Declared first, so a journey with no run at all still gets a row.
        for (appID, scan) in apps {
            for journey in scan.journeyOrder {
                let identifier = key(appID, journey)
                if accumulators[identifier] == nil {
                    accumulators[identifier] = Accumulator()
                    order.append(identifier)
                }
            }
        }
        // Runs are sorted newest first, so the first sighting is the latest run.
        for run in runs {
            for journey in run.journeys {
                let identifier = key(run.appID, journey)
                var accumulator = accumulators[identifier] ?? Accumulator()
                if accumulators[identifier] == nil { order.append(identifier) }
                accumulator.summary.add(run.status)
                if accumulator.latest == nil { accumulator.latest = run }
                if run.status == .passed,
                   run.evidenceLevel.ordinal > (accumulator.best?.ordinal ?? -1) {
                    accumulator.best = run.evidenceLevel
                }
                accumulators[identifier] = accumulator
            }
        }

        return order.compactMap { identifier -> JourneyRecord? in
            guard let accumulator = accumulators[identifier] else { return nil }
            let parts = identifier.split(separator: "\u{1}", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let appID = String(parts[0])
            let name = String(parts[1])
            return JourneyRecord(
                appID: appID,
                name: name,
                owner: apps[appID]?.journeyOwners[name],
                purpose: apps[appID]?.journeyDescriptions[name],
                runCount: accumulator.summary.total,
                passed: accumulator.summary.passed,
                failed: accumulator.summary.failed,
                blocked: accumulator.summary.blocked,
                canceled: accumulator.summary.canceled,
                incomplete: accumulator.summary.incomplete,
                latestRunID: accumulator.latest?.runID,
                latestStatus: accumulator.latest?.status,
                latestEvidenceLevel: accumulator.latest?.evidenceLevel,
                latestStartedAt: accumulator.latest?.startedAt,
                bestEvidenceLevel: accumulator.best
            )
        }
        .sorted {
            $0.appID == $1.appID ? $0.name < $1.name : $0.appID < $1.appID
        }
    }
}
