import Foundation
import SwiftUI

struct RegisterIncident: Decodable, Sendable {
    let incidentID: String
    let recordedAt: String
    let actor: String
    let claim: String
    let runID: String?
    let envelope: RegisterEnvelope

    enum CodingKeys: String, CodingKey {
        case incidentID = "incident_id", recordedAt = "recorded_at"
        case actor, claim, envelope
        case runID = "run_id"
    }
}

struct RegisterEnvelope: Decodable, Sendable {
    let service: String
    let failurePoint: String
    let errorCode: String
    let detail: String

    enum CodingKeys: String, CodingKey {
        case service, detail
        case failurePoint = "failure_point", errorCode = "error_code"
    }
}

struct RegisterResolution: Decodable, Sendable {
    let incidentID: String
    let resolvedAt: String
    let actor: String
    let note: String
    let runID: String?

    enum CodingKeys: String, CodingKey {
        case incidentID = "incident_id", resolvedAt = "resolved_at"
        case actor, note
        case runID = "run_id"
    }
}

struct RegisterEntry: Identifiable, Decodable, Sendable {
    let incident: RegisterIncident
    let resolution: RegisterResolution?
    var id: String { incident.incidentID }
    var isOpen: Bool { resolution == nil }
    var state: String { isOpen ? "open" : "resolved" }

    private enum CodingKeys: String, CodingKey { case resolution }
    init(from decoder: Decoder) throws {
        incident = try RegisterIncident(from: decoder)
        resolution = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(RegisterResolution.self, forKey: .resolution)
    }
}

/// `probierz incident` owns validation, file locking and resolution state.
/// Desktop never parses the register file or implements a second write path:
/// each operation is one finite CLI call and reads that command's JSON answer.
@MainActor
final class RegisterStore: ObservableObject {
    @Published private(set) var entries: [RegisterEntry] = []
    @Published private(set) var loadedAt: Date?
    @Published private(set) var problem: String?
    @Published private(set) var isWorking = false
    @Published private(set) var detail: String?
    @Published var stateFilter: String?
    @Published var selectedID: String?
    @Published var limit = 20
    private var generation = 0

    var visible: [RegisterEntry] { entries }
    func clear() {
        generation += 1
        entries = []
        selectedID = nil
        detail = nil
        problem = nil
        loadedAt = nil
    }

    var openCount: Int { entries.filter(\.isOpen).count }
    var resolvedCount: Int { entries.count - openCount }
    var selected: RegisterEntry? { entries.first { $0.id == selectedID } }
    var freshnessLabel: String? {
        loadedAt.map { "Read \($0.formatted(date: .omitted, time: .standard))" }
    }

    func load(workspaceRoot: URL) async {
        generation += 1
        let requested = generation
        do {
            let data = try await request(workspaceRoot, [
                "list", "--state=\(stateFilter ?? "all")", "--limit=\(limit)",
            ])
            struct List: Decodable { let incidents: [RegisterEntry] }
            let response = try JSONDecoder().decode(List.self, from: data)
            guard requested == generation else { return }
            entries = response.incidents
            problem = nil
            loadedAt = Date()
            if !entries.contains(where: { $0.id == selectedID }) {
                selectedID = nil
                detail = nil
            }
        } catch {
            guard requested == generation else { return }
            entries = []
            detail = nil
            problem = error.localizedDescription
        }
    }

    func show(workspaceRoot: URL, id: String) async {
        do {
            let data = try await request(workspaceRoot, ["show"], id: id)
            let value = try JSONSerialization.jsonObject(with: data)
            let formatted = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            guard selectedID == id else { return }
            detail = String(decoding: formatted, as: UTF8.self)
        } catch {
            problem = error.localizedDescription
        }
    }

    func record(workspaceRoot: URL, claim: String, envelope: String, runID: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            var arguments = ["record", "--claim=\(claim)", "--envelope=-"]
            if !runID.isEmpty { arguments.append("--run=\(runID)") }
            let data = try await request(workspaceRoot, arguments, input: Data(envelope.utf8))
            let incident = try JSONDecoder().decode(RegisterIncident.self, from: data)
            stateFilter = nil
            await load(workspaceRoot: workspaceRoot)
            selectedID = incident.incidentID
            await show(workspaceRoot: workspaceRoot, id: incident.incidentID)
        } catch {
            problem = error.localizedDescription
        }
    }

    func resolve(workspaceRoot: URL, id: String, note: String, runID: String = "") async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            var arguments = ["resolve", "--note=\(note)"]
            if !runID.isEmpty { arguments.append("--run=\(runID)") }
            _ = try await request(workspaceRoot, arguments, id: id)
            await load(workspaceRoot: workspaceRoot)
            await show(workspaceRoot: workspaceRoot, id: id)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// One `probierz incident` operation's JSON answer. The incident id goes
    /// after `--`, so no id can be read as an option.
    private func request(_ root: URL, _ arguments: [String], id: String? = nil, input: Data? = nil) async throws -> Data {
        var command = ["incident"] + arguments + ["--json"]
        if let id { command += ["--", id] }
        return try await ProbierzCLI.answer(repositoryRoot: root, arguments: command, input: input)
    }
}
