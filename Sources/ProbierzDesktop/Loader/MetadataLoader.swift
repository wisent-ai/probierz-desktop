import Foundation

struct MetadataLoader: Sendable {
    /// Bounds on what is read from a run's metadata: a front-matter value, an identifier, a trimmed field,
    /// a SHA-256 digest and a display name.
    static let maxFrontMatterValue = 400
    static let maxIdentifierLength = 120
    static let maxFieldLength = 600
    static let sha256HexLength = 64
    static let maxDisplayNameLength = 160
    let workspaceRoot: URL

    static let repositoryName = "probierz"
    static let maximumManifests = 2_000
    static let maximumVisitedEntries = 100_000
    static let maximumManifestBytes = 4 << 20
    static let maximumAppManifestBytes = 512 << 10

    /// The six surfaces `probierz list` declares, with the packages, tools and
    /// condition names it names. Mirrors `probierz/agent/lib.mjs`.
    struct SurfaceSpec: Sendable {
        let name: String
        let packagePath: String
        let tool: String
        let scriptLabel: String
        let targetsLabel: String
        let conditionNames: [String]
    }

    static let surfaceSpecs = [
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

    static let specDirectories = ["test/specs", "tests", "specs"]
    static let specSuffixes = [".e2e.ts", ".spec.ts", ".spec.mjs"]

    /// `status.mjs` falls back to E2 when an app manifest names no floor.
    static let defaultMinimumEvidence = EvidenceLevel.e2

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

    func inspectSurface(
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
    static func surfaceName(forTarget target: String) -> String? {
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
    struct AppManifestScan: Sendable {
        var journeyOrder: [String] = []
        var journeyOwners: [String: String] = [:]
        var journeyDescriptions: [String: String] = [:]
        var minimumEvidence: EvidenceLevel = MetadataLoader.defaultMinimumEvidence
    }

    func scanAppManifests(repositoryRoot: URL) -> [String: AppManifestScan] {
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




    // MARK: - History


    // MARK: - Verdict normalization



    // MARK: - Failure reason




    // MARK: - Artifacts




    // MARK: - Journeys


    // MARK: - Merge verdicts


    // MARK: - Counters


    // MARK: - Boundary







}

// MARK: - Manifest projection
