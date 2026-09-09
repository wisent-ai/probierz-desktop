import XCTest
@testable import ProbierzDesktop

/// Uses the real Probierz service without operating a GUI. These assertions
/// defend persisted effects and refusals, not rendering.
final class RegisterTests: XCTestCase {
    private func workspace() throws -> URL {
        let binary = try XCTUnwrap(ProcessInfo.processInfo.environment["PROBIERZ_BIN"], "Set PROBIERZ_BIN to the built product")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary))
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".build/register-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apps"), withIntermediateDirectories: true)
        return root
    }

    private func contents(_ root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("test-results/.incidents/register.jsonl"), encoding: .utf8)
    }

    @MainActor
    func testRecordingAndResolvingUseTheProductAPIAndPreserveRefusals() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RegisterStore()
        let envelope = #"{"service":"probierz","failure_point":"verification.claim","error_code":"invalid","detail":"A result had no retained run","context":{"source":"exact-revision"}}"#
        await store.record(workspaceRoot: root, claim: "The result was verified", envelope: envelope, runID: "original-run")
        XCTAssertNil(store.problem)
        let entry = try XCTUnwrap(store.entries.first)
        let before = try contents(root)
        XCTAssertTrue(before.contains("exact-revision"))
        XCTAssertTrue(before.contains("original-run"))

        store.selectedID = entry.id
        await store.show(workspaceRoot: root, id: entry.id)
        XCTAssertTrue(try XCTUnwrap(store.detail).contains("exact-revision"))
        await store.resolve(workspaceRoot: root, id: entry.id, note: "   ")
        XCTAssertEqual(store.problem, "--note must say what closed it")
        XCTAssertEqual(try contents(root), before)

        await store.resolve(workspaceRoot: root, id: entry.id, note: "Retained the real run", runID: "verified-run")
        XCTAssertNil(store.problem)
        XCTAssertEqual(store.entries.first?.resolution?.runID, "verified-run")
        let after = try contents(root)
        XCTAssertTrue(after.hasPrefix(before), "Resolving preserves the incident bytes")
        XCTAssertEqual(after.split(separator: "\n").count, 2)
        await store.resolve(workspaceRoot: root, id: entry.id, note: "Second resolution")
        XCTAssertTrue(try XCTUnwrap(store.problem).contains("was resolved at"))
        XCTAssertEqual(try contents(root), after)

        store.stateFilter = "open"
        await store.load(workspaceRoot: root)
        XCTAssertNil(store.problem)
        XCTAssertTrue(store.entries.isEmpty)
        store.stateFilter = "resolved"
        await store.load(workspaceRoot: root)
        XCTAssertEqual(store.entries.map(\.id), [entry.id])
    }

    @MainActor
    func testInvalidRecordAndUnreadableRegisterDoNotLookSuccessful() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RegisterStore()
        await store.record(workspaceRoot: root, claim: "A claim", envelope: "{}", runID: "")
        XCTAssertEqual(store.problem, "the envelope is not usable: failure_point must be a non-empty string")
        let file = root.appendingPathComponent("test-results/.incidents/register.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not JSON\n".utf8).write(to: file)
        await store.load(workspaceRoot: root)
        XCTAssertTrue(try XCTUnwrap(store.problem).contains(":1 is not one JSON object"))
        XCTAssertNil(store.loadedAt)
        XCTAssertEqual(try contents(root), "not JSON\n")
    }
}
