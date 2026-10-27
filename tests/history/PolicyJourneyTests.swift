import Foundation
import XCTest
import Yams
@testable import ProbierzDesktop

final class PolicyJourneyTests: XCTestCase {
    func testDeclaredPolicyFailureAndRecoveryAcrossSnapshot() throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try XCTUnwrap(environment["PROBIERZ_TEST_APP_MANIFEST"]))
        let runSource = URL(fileURLWithPath: try XCTUnwrap(environment["PROBIERZ_TEST_RUN_MANIFEST"]))
        let revision = try XCTUnwrap(environment["PROBIERZ_TEST_SOURCE_REVISION"])
        let original = try Data(contentsOf: source)
        let originalRun = try Data(contentsOf: runSource)
        let run = try XCTUnwrap(JSONSerialization.jsonObject(with: originalRun) as? [String: Any])
        let appID = try XCTUnwrap(run["appId"] as? String)
        let document = try XCTUnwrap(Yams.load(yaml: XCTUnwrap(String(data: original, encoding: .utf8))) as? [String: Any])
        XCTAssertEqual(document["appId"] as? String, appID)
        let policy = try XCTUnwrap(document["pullRequestPolicy"] as? [String: Any])
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let parent = checkout.appendingPathComponent(".build/policy-journeys", isDirectory: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try manager.removeItem(at: root) }
            catch { XCTFail("Cannot remove isolated policy workspace \(root.path): \(error)") }
        }
        let repository = root.appendingPathComponent("probierz", isDirectory: true)
        let apps = repository.appendingPathComponent("apps", isDirectory: true)
        let app = apps.appendingPathComponent(appID, isDirectory: true).standardizedFileURL
        guard !appID.isEmpty, app.lastPathComponent == appID,
              app.deletingLastPathComponent() == apps.standardizedFileURL else {
            XCTFail("Run appId must name one app directory, not a path: \(appID)")
            return
        }
        let results = repository.appendingPathComponent("test-results/\(appID)/retained", isDirectory: true)
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        try manager.createDirectory(at: results, withIntermediateDirectories: true)
        let manifest = app.appendingPathComponent("probierz.yaml")
        try original.write(to: manifest, options: .withoutOverwriting)
        try originalRun.write(to: results.appendingPathComponent("run-manifest.json"), options: .withoutOverwriting)
        let loader = MetadataLoader(workspaceRoot: root)
        var observations: [[String: Any]] = []
        let evidence = parent.appendingPathComponent("\(UUID().uuidString).json")
        func retain(_ label: String, unreadable: [String], verdicts: [VerdictRecord]) throws {
            observations.append(["case": label, "causes": unreadable,
                                 "blocking": verdicts.map(\.isBlocking),
                                 "minimumEvidence": verdicts.map { $0.minimumEvidence.title },
                                 "blockingReasons": verdicts.map(\.blockingReasons)])
            let report = ["sourceRevision": revision, "appID": appID, "observations": observations] as [String: Any]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence, options: .atomic)
        }
        let baseline = loader.load()
        let verdicts = baseline.verdicts.filter { $0.appID == appID }
        try retain("genuine-policy", unreadable: baseline.unreadableManifests, verdicts: verdicts)
        XCTAssertTrue(baseline.unreadableManifests.isEmpty, baseline.unreadableManifests.joined(separator: "\n"))
        XCTAssertTrue(verdicts.contains { !$0.isBlocking }, "Supply a genuine passing run for its declared journey and minimum")
        func assertRefused(_ label: String, document: [String: Any], cause: String) throws {
            let written = try Data(Yams.dump(object: document).utf8)
            try written.write(to: manifest)
            let snapshot = loader.load()
            let affected = snapshot.verdicts.filter { $0.appID == appID }
            try retain(label, unreadable: snapshot.unreadableManifests, verdicts: affected)
            XCTAssertFalse(affected.isEmpty)
            XCTAssertTrue(affected.allSatisfy(\.isBlocking))
            XCTAssertTrue(affected.allSatisfy { $0.minimumEvidence.title == "Unknown" })
            XCTAssertTrue(snapshot.unreadableManifests.contains { $0.contains(manifest.path) && $0.contains(cause) }, snapshot.unreadableManifests.joined(separator: "\n"))
            XCTAssertTrue(affected.allSatisfy { verdict in verdict.blockingReasons.contains { $0.contains(cause) } })
            XCTAssertEqual(try Data(contentsOf: manifest), written, "The viewer must not repair or overwrite input declarations")
        }
        var missing = document
        missing.removeValue(forKey: "pullRequestPolicy")
        try assertRefused("missing-policy", document: missing, cause: "pullRequestPolicy is missing")
        func malformed(_ field: String, value: Any?, cause: String) throws {
            var changed = document
            var requirements = policy
            requirements[field] = value
            changed["pullRequestPolicy"] = requirements
            try assertRefused(field, document: changed, cause: cause)
        }
        try malformed("minimumEvidence", value: nil, cause: "minimumEvidence is missing")
        try malformed("minimumEvidence", value: "E+3", cause: "minimumEvidence is not an E<n> evidence level")
        try malformed("requireSecretScan", value: "true", cause: "requireSecretScan must be a boolean")
        try malformed("requireProtectedArtifacts", value: "false", cause: "requireProtectedArtifacts must be a boolean")
        try malformed("requiredTargets", value: "web", cause: "requiredTargets must be a list")
        try malformed("requiredJourneys", value: [true], cause: "requiredJourneys must be a list")
        try malformed("requiredMatrixProfile", value: "", cause: "requiredMatrixProfile must be non-empty text")
        try original.write(to: manifest)
        let recovered = loader.load()
        try retain("recovered-policy", unreadable: recovered.unreadableManifests,
                   verdicts: recovered.verdicts.filter { $0.appID == appID })
        XCTAssertTrue(recovered.unreadableManifests.isEmpty, recovered.unreadableManifests.joined(separator: "\n"))
        XCTAssertEqual(recovered.verdicts.filter { $0.appID == appID }.map(\.blockingReasons), verdicts.map(\.blockingReasons))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: runSource), originalRun)
        print("policy source=\(revision) retained=\(evidence.path)")
    }
}
