import Darwin
import Foundation
import XCTest
@testable import ProbierzDesktop

/// Runs the actual evaluator against a declared owned application and real Brama.
/// Missing dependencies fail; this never substitutes a canned provider answer.
final class SecurityJourneyTests: XCTestCase {
    private func required(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw ProbierzCLI.Failure.refused("The real security journey requires \(name).")
        }
        return value
    }

    func testRealSecurityAssessmentAndImmutableReportRefusal() async throws {
        try await assess(model: required("PROBIERZ_SECURITY_TEST_MODEL"))
    }

    func testRealDeterministicSecurityAssessmentAndImmutableReportRefusal() async throws {
        try await assess(model: nil)
    }

    private func assess(model: String?) async throws {
        let root = URL(fileURLWithPath: try required("PROBIERZ_SECURITY_TEST_HARNESS"))
        let app = try required("PROBIERZ_SECURITY_TEST_APP")
        let revision = try required("PROBIERZ_TEST_SOURCE_REVISION")
        let evidence = root.appendingPathComponent(".build/security-desktop-results")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let report = evidence.appendingPathComponent("assessment.json")
        var args = ["evaluate", "security", "--app", app, "--out", report.path]
        if let model { args += ["--model", model] }
        else { args.append("--deterministic") }
        let outcome = try await ProbierzCLI.run(repositoryRoot: root, arguments: args)
        try outcome.stdout.write(to: evidence.appendingPathComponent("stdout.json"))
        try outcome.stderr.write(to: evidence.appendingPathComponent("stderr.txt"))
        let metadata: [String: Any] = ["sourceRevision": revision, "arguments": args, "exitStatus": outcome.status]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("command.json"))
        let original = try Data(contentsOf: report)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(value["kind"] as? String, "probierz-security-evaluation")
        XCTAssertEqual(value["complete"] as? Bool, true, String(decoding: outcome.stderr, as: UTF8.self))
        let decoded = try SecurityReport.decode(original)
        XCTAssertEqual(decoded.appId, app)
        XCTAssertEqual(decoded.mode, model == nil ? .deterministic : .modelAssisted)
        let expectationsURL = URL(fileURLWithPath: try required("PROBIERZ_SECURITY_TEST_EXPECTATIONS"))
        let expectations = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: expectationsURL))
            as? [String: [String: Any]])
        XCTAssertEqual(expectations.count, decoded.scope.checks.count)
        for observation in decoded.observations {
            let expected = try XCTUnwrap(expectations[observation.id])
            XCTAssertEqual(observation.pass, expected["pass"] as? Bool, observation.id)
            XCTAssertEqual(observation.status, expected["status"] as? Int, observation.id)
        }
        XCTAssertEqual(outcome.status == EXIT_SUCCESS, decoded.pass)
        let journalURL = URL(fileURLWithPath: try XCTUnwrap(decoded.journal))
        let journalData = try Data(contentsOf: journalURL)
        let journal = try SecurityJournal.decode(journalData)
        XCTAssertFalse(journal.hasPartialRecord)
        XCTAssertEqual(journal.events.last?.state, .finished)
        let retained = journal.events.filter { $0.state == .observed }
        XCTAssertEqual(retained.map(\.check), decoded.observations.map { Optional($0.id) })
        for event in retained {
            let expected = try XCTUnwrap(expectations[try XCTUnwrap(event.check)])
            XCTAssertEqual(event.detail?.pass, expected["pass"] as? Bool)
            XCTAssertEqual(event.detail?.status, expected["status"] as? Int)
        }
        let interrupted = try SecurityJournal.decode(Data(journalData.dropLast()))
        XCTAssertTrue(interrupted.hasPartialRecord)
        XCTAssertNotEqual(interrupted.events.last?.state, .finished,
            "an unterminated final record cannot establish finished execution")
        var trailing = journalData
        trailing.append(journalData)
        XCTAssertThrowsError(try SecurityJournal.decode(trailing),
            "events after a finished run must be refused")
        var inconsistent = value
        inconsistent["complete"] = false
        inconsistent["pass"] = true
        let inconsistentBytes = try JSONSerialization.data(withJSONObject: inconsistent)
        XCTAssertThrowsError(try SecurityReport.decode(inconsistentBytes),
            "a retained incomplete report must not be presented as passing")
        var missing = value
        missing["observations"] = []
        let missingBytes = try JSONSerialization.data(withJSONObject: missing)
        XCTAssertThrowsError(try SecurityReport.decode(missingBytes),
            "a completed report must account for every declared check")
        let observations = try XCTUnwrap(value["observations"] as? [[String: Any]])
        let scope = try XCTUnwrap(value["scope"] as? [String: Any])
        let checks = try XCTUnwrap(scope["checks"] as? [[String: Any]])
        XCTAssertEqual(observations.count, checks.count)
        for check in checks {
            let id = try XCTUnwrap(check["id"] as? String)
            let observed = try XCTUnwrap(observations.first { $0["id"] as? String == id })
            XCTAssertEqual(observed["path"] as? String, check["path"] as? String)
            XCTAssertEqual(observed["method"] as? String, "GET")
            let classified: (field: String, subject: String)?
            switch check["kind"] as? String {
            case "policy": classified = ("failedAssertions", "header")
            case "cookies": classified = ("failedCookies", "cookie")
            default: classified = nil
            }
            if let (field, subject) = classified {
                let expected = try XCTUnwrap(expectations[id]?[field] as? [[String: String]], "\(field) of \(id)")
                let findings = try XCTUnwrap(observed[field] as? [[String: Any]], "\(field) of \(id)")
                let actual: [[String: String]] = try findings.map { finding in
                    XCTAssertNil(finding["value"], "findings of \(id) must not carry response values")
                    return [subject: try XCTUnwrap(finding[subject] as? String),
                            "reason": try XCTUnwrap(finding["reason"] as? String)]
                }
                XCTAssertEqual(actual, expected, "\(field) classification for \(id)")
            }
        }
        let refused = try await ProbierzCLI.run(repositoryRoot: root, arguments: args)
        try refused.stderr.write(to: evidence.appendingPathComponent("overwrite-refusal.txt"))
        XCTAssertEqual(try Data(contentsOf: report), original)
        XCTAssertNotEqual(refused.status, EXIT_SUCCESS, "the real CLI must refuse overwriting evidence")
        print("Security desktop evidence: \(evidence.path)")
    }
}
