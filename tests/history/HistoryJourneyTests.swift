import Foundation
import XCTest
@testable import ProbierzDesktop

final class HistoryJourneyTests: XCTestCase {
    func testHistoryRootRefusalMalformedManifestAndRecovery() throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try XCTUnwrap(environment["PROBIERZ_TEST_RUN_MANIFEST"]))
        let revision = try XCTUnwrap(environment["PROBIERZ_TEST_SOURCE_REVISION"])
        let original = try Data(contentsOf: fixture)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let identity = try XCTUnwrap(document["runId"] as? String)
        XCTAssertFalse(identity.isEmpty)
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = checkout.appendingPathComponent(".build/history-journeys", isDirectory: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try manager.removeItem(at: root) }
            catch { XCTFail("Cannot remove isolated history \(root.path): \(error)") }
        }
        let loader = MetadataLoader(workspaceRoot: root)
        let missing = loader.loadHistory(repositoryRoot: root)
        XCTAssertTrue(missing.runs.isEmpty)
        XCTAssertTrue(missing.unreadable.isEmpty)
        let results = root.appendingPathComponent("test-results")
        try original.write(to: results, options: .withoutOverwriting)
        let refused = loader.loadHistory(repositoryRoot: root)
        XCTAssertTrue(refused.runs.isEmpty)
        XCTAssertTrue(refused.unreadable.contains { $0.contains(results.path) && $0.contains("isDirectory") })
        XCTAssertEqual(try Data(contentsOf: results), original)
        try manager.removeItem(at: results)
        let run = results.appendingPathComponent("retained-run", isDirectory: true)
        try manager.createDirectory(at: run, withIntermediateDirectories: true)
        let manifest = run.appendingPathComponent("run-manifest.json")
        try original.write(to: manifest, options: .withoutOverwriting)
        let readable = loader.loadHistory(repositoryRoot: root)
        XCTAssertTrue(readable.unreadable.isEmpty, readable.unreadable.joined(separator: "\n"))
        XCTAssertEqual(readable.runs.map(\.id), [identity])
        var malformed = try XCTUnwrap(String(data: original, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(malformed.popLast(), "}")
        let damaged = Data(malformed.utf8)
        try damaged.write(to: manifest)
        let decodingCause: String
        do {
            _ = try JSONDecoder().decode(RunManifest.self, from: damaged)
            XCTFail("The damaged real manifest must fail decoding")
            return
        } catch {
            decodingCause = error.localizedDescription
        }
        let invalid = loader.loadHistory(repositoryRoot: root)
        XCTAssertTrue(invalid.runs.isEmpty)
        XCTAssertTrue(invalid.unreadable.contains {
            $0.contains(manifest.path) && $0.contains(decodingCause)
        })
        XCTAssertEqual(try Data(contentsOf: manifest), damaged)
        try original.write(to: manifest)
        let recovered = loader.loadHistory(repositoryRoot: root)
        XCTAssertTrue(recovered.unreadable.isEmpty, recovered.unreadable.joined(separator: "\n"))
        XCTAssertEqual(recovered.runs.map(\.id), [identity])
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        XCTAssertEqual(try Data(contentsOf: fixture), original)
        print("history source=\(revision) fixture=\(fixture.path) rootRefusal=\(refused.unreadable) malformed=\(invalid.unreadable)")
    }
}
