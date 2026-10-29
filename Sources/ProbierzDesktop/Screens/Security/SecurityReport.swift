import Foundation

struct SecurityReport: Decodable {
    let kind: String
    let appId: String
    let complete: Bool
    let pass: Bool
    let error: String?
    let scope: Scope
    let mode: Mode
    let journal: String?
    let failedOperation: String?
    let failedCheck: String?

    enum Mode: String, Decodable {
        case deterministic
        case modelAssisted = "model-assisted"
    }

    struct Scope: Decodable {
        let checks: [DeclaredCheck]
    }

    struct DeclaredCheck: Decodable {
        let id: String
        let path: String
    }
    let observations: [Observation]

    struct Observation: Decodable, Identifiable {
        let id: String
        let method: String
        let path: String
        let status: Int
        let pass: Bool
        let missingHeaders: [String]
        let failedAssertions: [Assertion]
        let failedCookies: [CookieFinding]
    }

    struct Assertion: Decodable {
        let header: String
        let cause: String
    }

    /// A declared cookie the response did not set as required; its value is never reported.
    struct CookieFinding: Decodable {
        let cookie: String
        let reason: String
        let cause: String
    }

    static func decode(_ data: Data) throws -> SecurityReport {
        let report = try JSONDecoder().decode(SecurityReport.self, from: data)
        guard report.kind == "probierz-security-evaluation" else {
            throw ProbierzCLI.Failure.refused("This file is not a Probierz security assessment.")
        }
        guard Set(report.observations.map(\.id)).count == report.observations.count else {
            throw ProbierzCLI.Failure.refused(
                "The security report contains duplicate check identities.")
        }
        let declared = Set(report.scope.checks.map(\.id))
        guard !declared.isEmpty, declared.count == report.scope.checks.count,
            report.observations.allSatisfy({ observation in
                report.scope.checks.contains {
                    $0.id == observation.id && $0.path == observation.path
                }
                    && observation.method == "GET"
            }),
            !report.complete || Set(report.observations.map(\.id)) == declared,
            report.complete == (report.error == nil)
        else {
            throw ProbierzCLI.Failure.refused(
                "The security report does not account consistently for its declared scope and completion."
            )
        }
        guard
            !report.pass
                || (report.complete && report.error == nil
                    && !report.observations.isEmpty && report.observations.allSatisfy(\.pass))
        else {
            throw ProbierzCLI.Failure.refused(
                "The security report claims a pass despite incomplete or failed evidence.")
        }
        return report
    }
}
