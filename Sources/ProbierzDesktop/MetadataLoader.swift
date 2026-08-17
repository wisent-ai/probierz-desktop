import Foundation

struct MetadataLoader: Sendable {
    let workspaceRoot: URL

    private static let repositoryName = "probierz"
    static let maximumManifests = 2_000
    private static let maximumVisitedEntries = 100_000
    private static let maximumManifestBytes = 4 << 20
    private static let maximumAppManifestBytes = 512 << 10

    /// The six surfaces `probierz list` declares, with the packages, tools and
    /// condition names it names. Mirrors `probierz/agent/lib.mjs`.
    private struct SurfaceSpec: Sendable {
        let name: String
        let packagePath: String
        let tool: String
        let scriptLabel: String
        let targetsLabel: String
        let conditionNames: [String]
    }

    private static let surfaceSpecs = [
        SurfaceSpec(
            name: "web",
            packagePath: "packages/web",
            tool: "Playwright",
            scriptLabel: "test:web",
            targetsLabel: "Chromium / Firefox / WebKit + emulated mobile",
            conditionNames: ["BASE_URL"]
        ),
        SurfaceSpec(
            name: "electron",
            packagePath: "packages/electron",
            tool: "Playwright (_electron)",
            scriptLabel: "test:electron",
            targetsLabel: "Electron desktop app",
            conditionNames: ["ELECTRON_APP_MAIN"]
        ),
        SurfaceSpec(
            name: "mobile",
            packagePath: "packages/mobile",
            tool: "WebdriverIO + Appium (XCUITest / UiAutomator2)",
            scriptLabel: "test:mobile:ios | test:mobile:android",
            targetsLabel: "iOS / Android",
            conditionNames: [
                "APP_IOS", "APP_ANDROID", "BUNDLE_ID", "APP_PACKAGE",
                "IOS_DEVICE", "IOS_VERSION", "APPIUM_HOME",
            ]
        ),
        SurfaceSpec(
            name: "desktop-native",
            packagePath: "packages/desktop-native",
            tool: "WebdriverIO + Appium (Mac2 / WinAppDriver)",
            scriptLabel: "test:desktop:mac | test:desktop:win",
            targetsLabel: "native macOS / Windows",
            conditionNames: ["MAC_BUNDLE_ID", "WIN_APP"]
        ),
        SurfaceSpec(
            name: "desktop-cua",
            packagePath: "packages/desktop-cua",
            tool: "cua-driver",
            scriptLabel: "test:desktop:cua",
            targetsLabel: "native desktop accessibility surfaces",
            conditionNames: ["CUA_APP_EXECUTABLE"]
        ),
        SurfaceSpec(
            name: "tui",
            packagePath: "packages/tui",
            tool: "PTY",
            scriptLabel: "test:tui",
            targetsLabel: "terminal applications",
            conditionNames: ["TUI_CMD"]
        ),
    ]

    private static let specDirectories = ["test/specs", "tests", "specs"]
    private static let specSuffixes = [".e2e.ts", ".spec.ts", ".spec.mjs"]

    /// `status.mjs` falls back to E2 when an app manifest names no floor.
    private static let defaultMinimumEvidence = EvidenceLevel.e2

    func load() -> ProbierzSnapshot {
        let repositoryRoot = workspaceRoot
            .appendingPathComponent(Self.repositoryName, isDirectory: true)
            .standardizedFileURL
        let apps = scanAppManifests(repositoryRoot: repositoryRoot)
        let history = loadHistory(repositoryRoot: repositoryRoot)
        let surfaces = Self.surfaceSpecs.map {
            inspectSurface($0, repositoryRoot: repositoryRoot, runs: history.runs)
        }
        let environment = ProcessInfo.processInfo.environment
        let conditions = Self.surfaceSpecs.flatMap { spec in
            spec.conditionNames.map { name in
                ConditionRecord(
                    surface: spec.name,
                    name: name,
                    isPresentForViewer: !(environment[name] ?? "").isEmpty
                )
            }
        }
        let journeys = aggregateJourneys(runs: history.runs, apps: apps)
        let verdicts = computeVerdicts(journeys: journeys, runs: history.runs, apps: apps)
        let productIDs = Set(history.runs.map(\.appID)).union(apps.keys).sorted()
        return ProbierzSnapshot(
            repositoryRoot: repositoryRoot,
            productIDs: productIDs,
            surfaces: surfaces,
            conditions: conditions,
            runs: history.runs,
            artifacts: history.artifacts,
            journeys: journeys,
            verdicts: verdicts,
            preflights: latestPreflights(runs: history.runs),
            summaries: summaries(runs: history.runs, artifacts: history.artifacts),
            loadedAt: Date(),
            manifestsTruncated: history.truncated,
            manifestLimit: Self.maximumManifests
        )
    }

    // MARK: - Surfaces

    private func inspectSurface(
        _ spec: SurfaceSpec,
        repositoryRoot: URL,
        runs: [RunRecord]
    ) -> SurfaceRecord {
        let packageURL = safeURL(spec.packagePath, root: repositoryRoot)
        let packageValues = packageURL.flatMap {
            try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        }
        let isPresent = packageValues?.isDirectory == true && packageValues?.isSymbolicLink != true
        var specPaths: [String] = []
        if isPresent {
            for directory in Self.specDirectories {
                let relative = "\(spec.packagePath)/\(directory)"
                guard let url = safeURL(relative, root: repositoryRoot),
                      let entries = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                      )
                else { continue }
                for entry in entries {
                    let name = entry.lastPathComponent
                    guard Self.specSuffixes.contains(where: name.hasSuffix),
                          let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true,
                          values.isSymbolicLink != true
                    else { continue }
                    specPaths.append("\(relative)/\(name)")
                }
            }
            specPaths.sort()
        }
        let surfaceRuns = runs.filter { Self.surfaceName(forTarget: $0.target) == spec.name }
        let latest = surfaceRuns.first
        return SurfaceRecord(
            name: spec.name,
            packagePath: spec.packagePath,
            tool: spec.tool,
            scriptLabel: spec.scriptLabel,
            targetsLabel: spec.targetsLabel,
            conditionNames: spec.conditionNames,
            isPackagePresent: isPresent,
            specPaths: specPaths,
            runCount: surfaceRuns.count,
            lastStatus: latest?.status,
            lastEvidenceLevel: latest?.evidenceLevel,
            observedTargets: Set(surfaceRuns.map(\.target)).sorted()
        )
    }

    /// Run targets are finer-grained than surfaces: `mobile:ios` and
    /// `mobile:android` both belong to the single `mobile` package.
    private static func surfaceName(forTarget target: String) -> String? {
        switch target {
        case "web": "web"
        case "electron": "electron"
        case "tui": "tui"
        case "desktop:cua": "desktop-cua"
        default:
            if target.hasPrefix("mobile:") { "mobile" }
            else if target.hasPrefix("desktop:") { "desktop-native" }
            else { nil }
        }
    }

    // MARK: - App manifests

    /// The declared journey inventory and merge policy for one product.
    ///
    /// A journey declared here but never named by a run manifest is the
    /// `untested` set `probierz status` reports, and the only way this viewer
    /// can show a journey that has no evidence at all.
    private struct AppManifestScan: Sendable {
        var journeyOrder: [String] = []
        var journeyOwners: [String: String] = [:]
        var journeyDescriptions: [String: String] = [:]
        var minimumEvidence: EvidenceLevel = MetadataLoader.defaultMinimumEvidence
    }

    private func scanAppManifests(repositoryRoot: URL) -> [String: AppManifestScan] {
        guard let appsRoot = safeURL("apps", root: repositoryRoot),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: appsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              )
        else { return [:] }

        var scans: [String: AppManifestScan] = [:]
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let manifestURL = safeURL("\(entry.lastPathComponent)/probierz.yaml", root: appsRoot),
                  let attributes = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  attributes.isRegularFile == true,
                  (attributes.fileSize ?? 0) <= Self.maximumAppManifestBytes,
                  let text = try? String(contentsOf: manifestURL, encoding: .utf8)
            else { continue }
            scans[entry.lastPathComponent] = Self.scanAppManifest(text)
        }
        return scans
    }

    /// A narrow reader for the one block mapping and one policy this viewer needs.
    ///
    /// `probierz.yaml` is schema-validated at `schemaVersion: 1` by
    /// `agent/apps.mjs`: top-level scalars, `journeys:` keyed at one indent
    /// level, journey bodies at two. Reading those keys needs none of a YAML
    /// engine, and anything unrecognised is skipped rather than guessed.
    private static func scanAppManifest(_ text: String) -> AppManifestScan {
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
    private static func keyValue(_ trimmed: String) -> (key: String, value: String?)? {
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
        return key.isEmpty || value.isEmpty ? nil : (key, String(value.prefix(400)))
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 120
            && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.:".contains($0) }
    }

    // MARK: - History

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

    // MARK: - Verdict normalization

    /// Mirrors `normalizedStatus` in `probierz/agent/history.mjs`, including the
    /// fallback: a manifest that names an unknown status is failed once it has a
    /// completion timestamp and incomplete until then.
    private static func normalizedStatus(_ value: String?, completedAt: Date?) -> RunStatus {
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
    private static func evidenceLevel(_ manifest: RunManifest, status: RunStatus) -> EvidenceLevel {
        guard status == .passed else { return .e0 }
        if manifest.conditions?.record == true,
           manifest.evidence?.report == true,
           manifest.evidence?.analysis == true,
           manifest.evidence?.capturePresent == true {
            return .e3
        }
        return .e2
    }

    // MARK: - Failure reason

    /// Every sentence a failed or blocked manifest recorded about itself.
    ///
    /// The baseline loader decoded no reason field at all, so a failure could
    /// only ever be a coloured pill. These are the manifest's own strings, in
    /// the order the runner writes them, and nothing is paraphrased.
    private static func failure(
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

    private func preflightRecord(
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
    private func latestPreflights(runs: [RunRecord]) -> [PreflightRecord] {
        var byTarget: [String: PreflightRecord] = [:]
        for run in runs {
            guard let preflight = run.preflight else { continue }
            if byTarget[preflight.target] == nil { byTarget[preflight.target] = preflight }
        }
        return byTarget.values.sorted { $0.target < $1.target }
    }

    // MARK: - Artifacts

    private func artifactMetadata(
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
    private func protectedBundle(
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

    private static func artifactKind(for fileExtension: String) -> ArtifactKind {
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

    // MARK: - Journeys

    private func aggregateJourneys(
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

    // MARK: - Merge verdicts

    private func computeVerdicts(
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

    // MARK: - Counters

    private func summaries(runs: [RunRecord], artifacts: [ArtifactMetadata]) -> [String: ScopeSummary] {
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

    // MARK: - Boundary

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return String(value.prefix(600))
    }

    private static func normalizedDigest(_ value: String?) -> String? {
        guard let value = trimmed(value),
              value.count == 64,
              value.allSatisfy(\.isHexDigit)
        else { return nil }
        return value.lowercased()
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

    /// An absolute path recorded by the backend is accepted only when it stays
    /// inside the result store and crosses no symlink on the way.
    private func containedURL(absolutePath: String, within root: URL) -> URL? {
        guard absolutePath.hasPrefix("/") else { return nil }
        let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: absolutePath).standardizedFileURL
        guard candidate.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(normalizedRoot.path + "/") else { return nil }
        let relative = candidate.path.dropFirst(root.standardizedFileURL.path.count)
        return safeURL(String(relative.drop(while: { $0 == "/" })), root: root)
    }
}

// MARK: - Manifest projection

private struct RunManifest: Decodable {
    let runId: String?
    let appId: String?
    let target: String?
    let kind: String?
    let spec: String?
    let status: String?
    let startedAt: String?
    let completedAt: String?
    let durationMs: Double?
    let timeoutMs: Double?
    let command: String?
    let exitCode: Int?
    let signal: String?
    let timedOut: Bool?
    let setupError: String?
    let cleanupError: String?
    let plaintextArtifactsRemovedAt: String?
    let reportValidation: ManifestReportValidation?
    let spawnFailure: ManifestSpawnFailure?
    let resourceLock: ManifestResourceLock?
    let preflight: ManifestPreflight?
    let evidence: ManifestEvidence?
    let conditions: ManifestConditions?
    let appManifest: ManifestAppManifest?
    let harness: ManifestIdentity?
    let source: ManifestSource?
    let host: ManifestHost?
    let device: ManifestDevice?
    let protection: ManifestProtection?
    let artifacts: [ManifestArtifact]?
}

private struct ManifestReportValidation: Decodable {
    let ok: Bool?
    let error: String?
}

private struct ManifestSpawnFailure: Decodable {
    let failurePoint: String?
    let errorCode: String?
    let message: String?
}

private struct ManifestResourceLock: Decodable {
    let error: String?
    let resource: String?
    let owner: String?
}

struct ManifestPreflight: Decodable {
    let target: String?
    let ready: Bool?
    let checks: [ManifestPreflightCheck]?
    let missing: [String]?
    let remediation: [String]?
}

struct ManifestPreflightCheck: Decodable {
    let name: String?
    let ok: Bool?
    let own: Bool?
    let hint: String?
}

private struct ManifestEvidence: Decodable {
    let report: Bool?
    let analysis: Bool?
    let captureRequired: Bool?
    let capturePresent: Bool?
    let captureErrors: [String]?
    let errors: [String]?
}

private struct ManifestConditions: Decodable {
    let record: Bool?
}

private struct ManifestAppManifest: Decodable {
    let owner: String?
    let journeys: [String]?
}

private struct ManifestIdentity: Decodable {
    let name: String?
    let gitSha: String?
    let dirty: Bool?
    let sha256: String?
}

private struct ManifestSource: Decodable {
    let sha256: String?
    let repositories: [ManifestIdentity]?
}

private struct ManifestHost: Decodable {
    let hostname: String?
    let platform: String?
    let release: String?
    let arch: String?
}

private struct ManifestDevice: Decodable {
    let name: String?
    let runtime: String?
}

private struct ManifestProtection: Decodable {
    let file: String?
    let bytes: Int64?
    let sha256: String?
    let keyFingerprintSha256: String?
}

private struct ManifestArtifact: Decodable {
    let file: String?
    let bytes: Int64?
    let sha256: String?
}
