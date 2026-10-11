import Darwin
import Foundation
import XCTest
@testable import ProbierzDesktop

final class FailureIntakeJourneyTests: XCTestCase {
    func testConfiguredPathRefusalAndRealEnvelopeRecovery() throws {
        let environment = ProcessInfo.processInfo.environment
        let configured = try XCTUnwrap(environment["PROBIERZ_FAILURES_DIR"])
        let fixture = URL(fileURLWithPath: try XCTUnwrap(environment["PROBIERZ_TEST_FAILURE_ENVELOPE"]))
        let revision = try XCTUnwrap(environment["PROBIERZ_TEST_SOURCE_REVISION"])
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = checkout.appendingPathComponent(".build", isDirectory: true).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: configured).standardizedFileURL
        let manager = FileManager.default
        XCTAssertTrue(root.resolvingSymlinksInPath().path.hasPrefix(build.path + "/"))
        guard root.resolvingSymlinksInPath().path.hasPrefix(build.path + "/") else { return }
        XCTAssertFalse(manager.fileExists(atPath: root.path), "Use a new isolated intake path")
        guard !manager.fileExists(atPath: root.path) else { return }
        let original = try Data(contentsOf: fixture)
        let envelope = try JSONDecoder().decode(FailureNode.self, from: original)
        let object = try JSONSerialization.jsonObject(with: original)
        let compact = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let parent = root.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let missing = FailureIntakeStore.load(workspaceRoot: checkout)
        XCTAssertTrue(missing.entries.isEmpty)
        XCTAssertTrue(missing.unreadable.isEmpty)
        try compact.write(to: root, options: .withoutOverwriting)
        defer {
            do { try manager.removeItem(at: root) }
            catch { XCTFail("Cannot remove isolated intake \(root.path): \(error)") }
        }
        let refused = FailureIntakeStore.load(workspaceRoot: checkout)
        XCTAssertTrue(refused.entries.isEmpty)
        XCTAssertTrue(refused.unreadable.contains { $0.contains(root.path) && $0.contains("isDirectory") })
        XCTAssertEqual(try Data(contentsOf: root), compact, "Refusal must not rewrite the configured file")
        try manager.removeItem(at: root)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        let item = root.appendingPathComponent("reported.jsonl")
        try compact.write(to: item, options: .withoutOverwriting)
        let recovered = FailureIntakeStore.load(workspaceRoot: checkout)
        XCTAssertTrue(recovered.unreadable.isEmpty)
        XCTAssertEqual(recovered.entries.map(\.envelope.failurePoint), [envelope.failurePoint])
        XCTAssertEqual(recovered.entries.map(\.envelope.errorCode), [envelope.errorCode])
        XCTAssertEqual(recovered.entries.map(\.envelope.service), [envelope.service])
        XCTAssertEqual(try Data(contentsOf: item), compact)
        let attributes = try manager.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        let inaccessible = permissions.uint16Value & ~UInt16(S_IRWXU | S_IRWXG | S_IRWXO)
        try manager.setAttributes([.posixPermissions: NSNumber(value: inaccessible)], ofItemAtPath: root.path)
        defer {
            do { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
            catch { XCTFail("Cannot restore isolated intake permissions \(root.path): \(error)") }
        }
        let listingCause: String
        do {
            _ = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                ]
            )
            XCTFail("Qualification requires a process that cannot bypass the isolated directory permissions")
            return
        } catch {
            listingCause = error.localizedDescription
        }
        let inaccessibleIntake = FailureIntakeStore.load(workspaceRoot: checkout)
        XCTAssertTrue(inaccessibleIntake.entries.isEmpty)
        XCTAssertTrue(inaccessibleIntake.unreadable.contains {
            $0.contains(root.path) && $0.contains(listingCause)
        })
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path)
        let readableAgain = FailureIntakeStore.load(workspaceRoot: checkout)
        XCTAssertTrue(readableAgain.unreadable.isEmpty)
        XCTAssertEqual(readableAgain.entries.map(\.envelope.failurePoint), [envelope.failurePoint])
        XCTAssertEqual(try Data(contentsOf: item), compact)
        XCTAssertEqual(try Data(contentsOf: fixture), original, "The real source envelope stays unchanged")
        print("failure-intake source=\(revision) fixture=\(fixture.path) isolated=\(root.path)")
    }
}
