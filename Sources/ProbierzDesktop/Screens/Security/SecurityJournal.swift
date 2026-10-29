import Foundation

/// A progress journal is partial execution evidence, never a passing assessment.
struct SecurityJournal {
    let events: [Event]
    let hasPartialRecord: Bool

    struct Event: Decodable {
        let kind: String
        let at: String
        let operation: String
        let check: String?
        let state: State
        let detail: Detail?
    }

    enum State: String, Decodable {
        case started, observed, failed, finished
    }

    struct Detail: Decodable {
        let appId: String?
        let error: String?
        let path: String?
        let status: Int?
        let pass: Bool?
    }

    static func decode(_ data: Data) throws -> SecurityJournal {
        let newline = UInt8(ascii: "\n")
        let rows = data.split(separator: newline, omittingEmptySubsequences: false)
        let partial = !data.isEmpty && data.last != newline
        var events: [Event] = []
        for row in rows.dropLast() {
            let event = try JSONDecoder().decode(Event.self, from: Data(row))
            guard event.kind == "probierz-security-event", !event.operation.isEmpty else {
                throw ProbierzCLI.Failure.refused(
                    "This file contains an invalid security journal event.")
            }
            guard events.last?.state != .finished && events.last?.state != .failed else {
                throw ProbierzCLI.Failure.refused(
                    "The security journal contains events after a terminal record.")
            }
            if event.state == .observed {
                guard event.operation == "check", event.check != nil,
                    event.detail?.path != nil, event.detail?.status != nil,
                    event.detail?.pass != nil
                else {
                    throw ProbierzCLI.Failure.refused(
                        "A security observation lacks its check, path, status or verdict.")
                }
            }
            events.append(event)
        }
        guard let first = events.first, first.operation == "initialize", first.state == .started,
            first.detail?.appId != nil
        else {
            throw ProbierzCLI.Failure.refused(
                "The journal has no complete security run initialization record.")
        }
        return SecurityJournal(events: events, hasPartialRecord: partial)
    }
}
