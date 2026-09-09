import XCTest

@testable import ProbierzDesktop

/// The register screen, driven through the real product binary.
///
/// SwiftUI layout is not what can break here; what can break is the app
/// reading a register the binary wrote, and closing an entry through a command
/// whose refusals it must show verbatim. Every case runs the installed
/// `probierz` against a temporary workspace of its own, so the operator's real
/// `test-results/` is never read or written.
final class RegisterTests: XCTestCase {
    /// The product this screen is a surface of. `PROBIERZ_BIN` overrides it;
    /// otherwise the sibling checkout beside this one, which is where the
    /// binary is built.
    private func productBinary() throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["PROBIERZ_BIN"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let sibling = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("probierz/probierz-rs/target/release/probierz")
        guard FileManager.default.isExecutableFile(atPath: sibling.path) else {
            throw XCTSkip(
                "No probierz binary at \(sibling.path); build it or set PROBIERZ_BIN"
            )
        }
        return sibling
    }

    private func workspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("register-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("apps", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    @discardableResult
    private func record(binary: URL, workspace: URL, claim: String, detail: String) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--harness", workspace.path,
            "incident", "record",
            "--claim", claim,
            "--service", "probierz",
            "--failure-point", "verification.claim",
            "--code", "unknown",
            "--detail", detail,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PROBIERZ_ACTOR"] = "desktop-test"
        environment.removeValue(forKey: "GITHUB_ACTOR")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "recording an incident succeeds")
        let printed = String(data: data, encoding: .utf8) ?? ""
        let identity = printed
            .split(separator: " ")
            .dropFirst()
            .first
            .map(String.init)
        return try XCTUnwrap(identity, "record prints the identity it wrote: \(printed)")
    }

    /// What the screen shows: the claim the product recorded, still open, with
    /// the envelope it carried.
    func testTheScreenReadsWhatTheProductRecorded() throws {
        let binary = try productBinary()
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let identity = try record(
            binary: binary,
            workspace: root,
            claim: "the areas were verified before merge",
            detail: "the runs happened in worktrees a hook deleted"
        )

        let reading = RegisterReader.read(workspaceRoot: root)
        XCTAssertNil(reading.refusal, "a register the product wrote reads cleanly")
        XCTAssertEqual(reading.entries.count, 1)
        let entry = try XCTUnwrap(reading.entries.first)
        XCTAssertEqual(entry.id, identity)
        XCTAssertEqual(entry.incident.claim, "the areas were verified before merge")
        XCTAssertEqual(entry.incident.actor, "desktop-test")
        XCTAssertEqual(entry.incident.envelope.failurePoint, "verification.claim")
        XCTAssertEqual(entry.incident.envelope.detail, "the runs happened in worktrees a hook deleted")
        XCTAssertTrue(entry.isOpen, "nothing has closed it")
        XCTAssertEqual(entry.state, "open")
    }

    /// Closing one from the screen writes through the product, and the second
    /// attempt shows the sentence the product refused with.
    @MainActor
    func testResolvingFromTheScreenWritesThroughTheProduct() async throws {
        let binary = try productBinary()
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("PROBIERZ_BIN", binary.path, 1)
        setenv("PROBIERZ_ACTOR", "desktop-test", 1)
        defer {
            unsetenv("PROBIERZ_BIN")
            unsetenv("PROBIERZ_ACTOR")
        }

        let identity = try record(
            binary: binary,
            workspace: root,
            claim: "the register has a screen",
            detail: "there was no screen, so nothing could be read or closed"
        )

        let store = RegisterStore()
        store.load(workspaceRoot: root)
        XCTAssertEqual(store.openCount, 1)
        XCTAssertEqual(store.resolvedCount, 0)

        await store.resolve(
            workspaceRoot: root,
            id: identity,
            note: "the screen reads the register and closes an entry through the binary"
        )
        XCTAssertNil(store.problem, "the product accepted the resolution")
        XCTAssertEqual(store.openCount, 0)
        XCTAssertEqual(store.resolvedCount, 1)
        let resolved = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(resolved.state, "resolved")
        XCTAssertEqual(resolved.resolution?.actor, "desktop-test")
        XCTAssertEqual(
            resolved.resolution?.note,
            "the screen reads the register and closes an entry through the binary"
        )

        let file = RegisterReader.file(workspaceRoot: root)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(
            contents.split(separator: "\n").filter { !$0.isEmpty }.count,
            2,
            "the register is append-only: the incident and its resolution"
        )

        await store.resolve(workspaceRoot: root, id: identity, note: "closed twice")
        let refusal = try XCTUnwrap(store.problem, "the second attempt is refused")
        XCTAssertTrue(
            refusal.contains(identity) && refusal.contains("was resolved at"),
            "the screen shows the product's own sentence: \(refusal)"
        )
        XCTAssertEqual(store.resolvedCount, 1, "the refused attempt wrote nothing")
    }

    /// An empty note never reaches the product, and a missing binary says
    /// where it looked. Both are what the operator sees instead of a screen
    /// that silently does nothing.
    @MainActor
    func testTheScreenRefusesBeforeItRunsAnything() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RegisterStore()
        store.load(workspaceRoot: root)
        XCTAssertTrue(store.entries.isEmpty, "an unwritten register is empty, not an error")
        XCTAssertNil(store.problem)

        await store.resolve(workspaceRoot: root, id: "0000000000000000", note: "   ")
        XCTAssertEqual(store.problem, "--note needs what repaired it")

        setenv("PROBIERZ_BIN", root.appendingPathComponent("absent").path, 1)
        defer { unsetenv("PROBIERZ_BIN") }
        await store.resolve(workspaceRoot: root, id: "0000000000000000", note: "a real note")
        let refusal = try XCTUnwrap(store.problem)
        XCTAssertTrue(
            refusal.hasPrefix("No probierz binary here: looked at "),
            "the refusal names every path it tried: \(refusal)"
        )
    }
}
