import CryptoKit
import Foundation

struct MetadataLoader: Sendable {
    /// The length of a SHA-256 digest in hexadecimal, measured from one
    /// CryptoKit digest written as records write it, one hex pair a byte.
    static let sha256HexLength = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }
        .joined().count
    let workspaceRoot: URL

    static let repositoryName = "probierz"

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

    /// `status.mjs` falls back to E2 when an app manifest names no floor; a
    /// manifest that cannot be read is not one that names no floor.
    static let defaultMinimumEvidence = EvidenceLevel.e2

    func load() -> ProbierzSnapshot {
        let repositoryRoot =
            workspaceRoot
            .appendingPathComponent(Self.repositoryName, isDirectory: true)
            .standardizedFileURL
        let manifests = scanAppManifests(repositoryRoot: repositoryRoot)
        let apps = manifests.scans
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
                    isPresentForViewer: environment[name]?.isEmpty == false
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
            unreadableRuns: history.unreadable,
            unreadableManifests: manifests.unreadable,
            artifacts: history.artifacts,
            journeys: journeys,
            verdicts: verdicts,
            preflights: latestPreflights(runs: history.runs),
            summaries: summaries(runs: history.runs, artifacts: history.artifacts),
            loadedAt: Date()
        )
    }

    // MARK: - Surfaces

    func inspectSurface(
        _ spec: SurfaceSpec,
        repositoryRoot: URL,
        runs: [RunRecord]
    ) -> SurfaceRecord {
        var specPaths: [String] = []
        var listingFailures: [String] = []
        // A package folder that does not exist is absent; a path outside the
        // repository or attributes that cannot be read are listed with the cause.
        var isPresent = false
        if let url = safeURL(spec.packagePath, root: repositoryRoot) {
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                isPresent = values.isDirectory == true && values.isSymbolicLink != true
            } catch CocoaError.fileReadNoSuchFile {
                isPresent = false
            } catch {
                listingFailures.append("\(spec.packagePath): \(error.localizedDescription)")
            }
        } else {
            listingFailures.append("\(spec.packagePath): the path leaves the repository")
        }
        if isPresent {
            for directory in Self.specDirectories {
                let relative = "\(spec.packagePath)/\(directory)"
                guard let url = safeURL(relative, root: repositoryRoot) else { continue }
                let entries: [URL]
                do {
                    entries = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    continue
                } catch {
                    listingFailures.append("\(relative): \(error.localizedDescription)")
                    continue
                }
                for entry in entries {
                    let name = entry.lastPathComponent
                    guard Self.specSuffixes.contains(where: name.hasSuffix) else { continue }
                    let values: URLResourceValues
                    do {
                        values = try entry.resourceValues(forKeys: [
                            .isRegularFileKey, .isSymbolicLinkKey,
                        ])
                    } catch {
                        listingFailures.append(
                            "\(relative)/\(name): \(error.localizedDescription)")
                        continue
                    }
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        continue
                    }
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
            specListingFailures: listingFailures,
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
            if target.hasPrefix("mobile:") {
                "mobile"
            } else if target.hasPrefix("desktop:") {
                "desktop-native"
            } else {
                nil
            }
        }
    }

    // MARK: - App manifests

    /// The journeys and merge policy one product declares; a journey declared here but
    /// never named by a run manifest is the `untested` set `probierz status` reports.
    struct AppManifestScan: Sendable {
        var journeyOrder: [String] = []
        var journeyOwners: [String: String] = [:]
        var journeyDescriptions: [String: String] = [:]
        var minimumEvidence: EvidenceLevel = MetadataLoader.defaultMinimumEvidence
    }

    /// Each app's manifest scan, and the manifests (or the apps folder) that
    /// exist but could not be read, each with its cause: such an app is not
    /// one whose manifest names no floor, so it is reported, not defaulted.
    func scanAppManifests(repositoryRoot: URL) -> (
        scans: [String: AppManifestScan], unreadable: [String]
    ) {
        guard let appsRoot = safeURL("apps", root: repositoryRoot) else { return ([:], []) }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: appsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return ([:], [])
        } catch {
            return ([:], ["\(appsRoot.path): \(error.localizedDescription)"])
        }

        var scans: [String: AppManifestScan] = [:]
        var unreadable: [String] = []
        for entry in entries {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                unreadable.append("\(entry.path): \(error.localizedDescription)")
                continue
            }
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            guard
                let manifestURL = safeURL(
                    "\(entry.lastPathComponent)/probierz.yaml", root: appsRoot)
            else {
                unreadable.append("\(entry.path): its manifest path leaves the apps folder")
                continue
            }
            // An app folder without a manifest has none to read; anything else
            // that stops the manifest from being read is reported.
            let attributes: URLResourceValues
            do {
                attributes = try manifestURL.resourceValues(forKeys: [.isRegularFileKey])
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch {
                unreadable.append("\(manifestURL.path): \(error.localizedDescription)")
                continue
            }
            guard attributes.isRegularFile == true else {
                unreadable.append("\(manifestURL.path): exists but is not a regular file")
                continue
            }
            do {
                let text = try String(contentsOf: manifestURL, encoding: .utf8)
                scans[entry.lastPathComponent] = Self.scanAppManifest(text)
            } catch {
                unreadable.append("\(manifestURL.path): \(error.localizedDescription)")
            }
        }
        return (scans, unreadable)
    }
}
