import Foundation
import XCTest
@testable import ProbierzDesktop

final class FirstUseJourneyTests: XCTestCase {
    @MainActor
    func testRealProtectedBundleCompletesOnlyItsCurrentAttempt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let workspace = try XCTUnwrap(
            environment["PROBIERZ_TEST_WORKSPACE"],
            "PROBIERZ_TEST_WORKSPACE must name an actual retained Probierz workspace"
        )
        let artifactID = try XCTUnwrap(
            environment["PROBIERZ_TEST_PROTECTED_ARTIFACT_ID"],
            "Select an actual retained protected bundle by its native artifact identity"
        )
        let sourceRevision = try XCTUnwrap(
            environment["PROBIERZ_TEST_SOURCE_REVISION"],
            "Declare the exact source revision of the matching native test bundle"
        )
        let snapshot = MetadataLoader(workspaceRoot: URL(fileURLWithPath: workspace)).load()
        let artifact = try XCTUnwrap(
            snapshot.artifacts.first { $0.id == artifactID },
            "The declared artifact must be loaded from the actual retained run"
        )
        XCTAssertEqual(artifact.kind, .protectedBundle)
        XCTAssertTrue(artifact.isAvailableOnDisk, "The real protected bundle must exist")
        guard artifact.kind == .protectedBundle, artifact.isAvailableOnDisk else { return }

        let suite = "probierz-onboarding-qualification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let onboarding = ProbierzOnboarding(defaults: defaults)
        await onboarding.start()
        try requireStarted(onboarding)
        let entry = try XCTUnwrap(onboarding.screen?.screenId)

        // An actual available bundle is not completion on the optional first step.
        await onboarding.observeEvidenceBundleInspected(artifact)
        XCTAssertEqual(onboarding.status, .inProgress)
        XCTAssertEqual(onboarding.screen?.screenId, entry)
        XCTAssertNil(onboarding.errorMessage)

        let skipped = await onboarding.completeOptionalProjectStep(imported: false)
        XCTAssertTrue(skipped)
        var seen = Set<String>()
        while let screen = onboarding.screen, !screen.transitions.isEmpty {
            guard seen.insert(screen.screenId).inserted else {
                XCTFail("The actual journey returned to \(screen.screenId) without reaching inspection")
                return
            }
            let result = await onboarding.performPrimaryAction()
            guard case .advanced = result else {
                XCTFail("Cannot advance \(screen.screenId): \(String(describing: onboarding.errorMessage))")
                return
            }
        }
        let terminal = try XCTUnwrap(onboarding.screen)
        XCTAssertTrue(terminal.transitions.isEmpty)
        XCTAssertEqual(onboarding.status, .inProgress)
        await onboarding.observeEvidenceBundleInspected(artifact)
        XCTAssertEqual(onboarding.status, .completed)
        XCTAssertNil(onboarding.errorMessage, "Real event delivery must succeed too")
        XCTAssertNil(onboarding.screen)

        let restored = ProbierzOnboarding(defaults: defaults)
        await restored.start()
        XCTAssertEqual(restored.status, .completed, "Completion must survive a new native controller")
        XCTAssertNil(restored.errorMessage)
        let replay = await restored.replay()
        guard case .succeeded = replay else {
            XCTFail("The real persisted attempt could not be replayed: \(replay)")
            return
        }
        XCTAssertEqual(restored.status, .inProgress)
        XCTAssertEqual(restored.screen?.screenId, entry)
        XCTAssertNil(restored.errorMessage)
        await restored.observeEvidenceBundleInspected(artifact)
        XCTAssertEqual(restored.status, .inProgress, "An old inspection cannot complete the new entry step")
        XCTAssertEqual(restored.screen?.screenId, entry)

        let replayed = ProbierzOnboarding(defaults: defaults)
        await replayed.start()
        XCTAssertEqual(replayed.status, .inProgress)
        XCTAssertEqual(replayed.screen?.screenId, entry, "Replay must also survive controller recreation")
        XCTAssertNil(replayed.errorMessage)
        print("first-use source=\(sourceRevision) run=\(artifact.runID) artifact=\(artifact.id) suite=\(suite)")
    }

    @MainActor
    private func requireStarted(_ onboarding: ProbierzOnboarding) throws {
        XCTAssertNil(onboarding.errorMessage, "Use the actual configured journey dependency")
        XCTAssertEqual(onboarding.status, .inProgress)
        _ = try XCTUnwrap(onboarding.screen, "The real first-use entry screen must be available")
    }
}
