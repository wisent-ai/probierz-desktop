import Combine
@preconcurrency import Foundation
import SwiftUI
import WisentOnboarding
import WisentDesignSystem

struct ProbierzJourneyTransport: JourneyTransport {
    private let base: EnvironmentJourneyTransport

    init() {
        base = EnvironmentJourneyTransport(
            tokenEnvironmentKey: "PROBIERZ_DESKTOP_STADO_INTEGRATION_TOKEN"
        )
    }

    func readBundle(productId: String, journeyId: String) async throws -> JourneyBundle {
        let bundle = try await base.readBundle(productId: productId, journeyId: journeyId)
        guard bundle.definition.journeyVersion == "2026-09-03.2",
              bundle.definition.firstSuccessFact == "evidence_bundle_inspected"
        else {
            throw JourneyClientError.invalid("Probierz journey identity")
        }
        return bundle
    }

    func readState(productId: String, attemptId: UUID, subjectHash: String) async throws -> JSONValue? {
        try await base.readState(
            productId: productId,
            attemptId: attemptId,
            subjectHash: subjectHash
        )
    }

    func assignExperiment(request: JourneyAssignmentRequest) async throws -> JourneyAssignmentResponse {
        try await base.assignExperiment(request: request)
    }

    func collect(event: JourneyRuntimeEvent) async throws {
        try await base.collect(event: event)
    }
}
