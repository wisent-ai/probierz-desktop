import Foundation
import SwiftUI

// MARK: - Records

/// One line of the register, as `probierz incident record` appended it.
struct RegisterIncident: Decodable, Sendable {
    let incidentID: String
    let recordedAt: String
    let actor: String
    let claim: String
    let runID: String?
    let envelope: RegisterEnvelope

    enum CodingKeys: String, CodingKey {
        case incidentID = "incident_id"
        case recordedAt = "recorded_at"
        case actor
        case claim
        case runID = "run_id"
        case envelope
    }
}

/// The `wisent-errors` envelope the incident carries. The register refuses a
/// missing field, so every one of these is present by the time it is on disk.
struct RegisterEnvelope: Decodable, Sendable {
    let service: String
    let failurePoint: String
    let errorCode: String
    let detail: String

    enum CodingKeys: String, CodingKey {
        case service
        case failurePoint = "failure_point"
        case errorCode = "error_code"
        case detail
    }
}

/// The second line kind: what closed an incident.
struct RegisterResolution: Decodable, Sendable {
    let incidentID: String
    let resolvedAt: String
    let actor: String
    let note: String
    let runID: String?

    enum CodingKeys: String, CodingKey {
        case incidentID = "incident_id"
        case resolvedAt = "resolved_at"
        case actor
        case note
        case runID = "run_id"
    }
}

/// An incident with its resolution folded on, which is how the CLI reports it:
/// state is derived from the two records rather than edited into one.
struct RegisterEntry: Identifiable, Sendable {
    let incident: RegisterIncident
    let resolution: RegisterResolution?

    var id: String { incident.incidentID }
    var isOpen: Bool { resolution == nil }
    var state: String { isOpen ? "open" : "resolved" }
}

/// What one read of the register found: its entries, and the first line it
/// could not read, if there was one.
struct RegisterReading: Sendable {
    let entries: [RegisterEntry]
    let refusal: String?
}

// MARK: - Reading

/// The register the binary owns; the desktop reads the same file.
///
/// `test-results/.incidents/register.jsonl` under the selected workspace is
/// append-only: an incident, then optionally its resolution. Reading folds the
/// second onto the first. A line that is neither is a defect in the file, and
/// this reader reports it the way the CLI does — with the line it sits on —
/// instead of showing a register that quietly lost an entry.
enum RegisterReader {
    static func file(workspaceRoot: URL) -> URL {
        workspaceRoot
            .appendingPathComponent("test-results/.incidents", isDirectory: true)
            .appendingPathComponent("register.jsonl", isDirectory: false)
    }

    static func read(workspaceRoot: URL) -> RegisterReading {
        let file = file(workspaceRoot: workspaceRoot)
        if !FileManager.default.fileExists(atPath: file.path) {
            return RegisterReading(entries: [], refusal: nil)
        }
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            return RegisterReading(
                entries: [],
                refusal: "\(file.path) could not be read: \(error.localizedDescription)"
            )
        }
        return fold(text: text, file: file)
    }

    private static func fold(text: String, file: URL) -> RegisterReading {
        var incidents: [RegisterIncident] = []
        var resolutions: [String: RegisterResolution] = [:]
        var refusals: [String] = []
        let decoder = JSONDecoder()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for (offset, line) in lines.enumerated() {
            let data = Data(line.utf8)
            let position = "\(file.path):\(offset + 1)"
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let schema = object["schema"] as? String
            else {
                refusals.append("\(position) is not one JSON object")
                continue
            }
            if schema == "ai.wisent.probierz.incident.v1" {
                if let incident = try? decoder.decode(RegisterIncident.self, from: data) {
                    incidents.append(incident)
                    continue
                }
                refusals.append("\(position) is an incident this app cannot read")
                continue
            }
            if schema == "ai.wisent.probierz.incident-resolution.v1" {
                if let resolution = try? decoder.decode(RegisterResolution.self, from: data) {
                    resolutions[resolution.incidentID] = resolution
                    continue
                }
                refusals.append("\(position) is a resolution this app cannot read")
                continue
            }
            refusals.append("\(position) carries the unknown schema \(schema)")
        }
        let entries = incidents
            .map { RegisterEntry(incident: $0, resolution: resolutions[$0.incidentID]) }
            .sorted { $0.incident.recordedAt > $1.incident.recordedAt }
        return RegisterReading(entries: entries, refusal: refusals.first)
    }
}

// MARK: - Store

@MainActor
final class RegisterStore: ObservableObject {
    @Published private(set) var entries: [RegisterEntry] = []
    @Published private(set) var loadedAt: Date?
    @Published private(set) var problem: String?
    @Published private(set) var isWorking = false
    @Published var stateFilter: String?
    @Published var selectedID: String?

    var visible: [RegisterEntry] {
        guard let stateFilter else { return entries }
        return entries.filter { $0.state == stateFilter }
    }

    var openCount: Int { entries.filter(\.isOpen).count }
    var resolvedCount: Int { entries.count - openCount }

    var selected: RegisterEntry? {
        entries.first { $0.id == selectedID }
    }

    var freshnessLabel: String? {
        loadedAt.map { "Read \($0.formatted(date: .omitted, time: .standard))" }
    }

    func load(workspaceRoot: URL) {
        let reading = RegisterReader.read(workspaceRoot: workspaceRoot)
        entries = reading.entries
        problem = reading.refusal
        loadedAt = Date()
    }

    /// Closing an incident is a write, so it goes through the product binary
    /// rather than through this app's own idea of the file format. The binary's
    /// refusal is what the operator sees.
    func resolve(workspaceRoot: URL, id: String, note: String) async {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty {
            problem = "--note needs what repaired it"
            return
        }
        isWorking = true
        defer { isWorking = false }
        switch RegisterBinary.locate(workspaceRoot: workspaceRoot) {
        case .failure(let refusal):
            problem = refusal.sentence
        case .success(let binary):
            let outcome = await RegisterBinary.run(
                binary,
                workspaceRoot: workspaceRoot,
                arguments: ["incident", "resolve", id, "--note", note]
            )
            switch outcome {
            case .success:
                problem = nil
                load(workspaceRoot: workspaceRoot)
            case .failure(let refusal):
                problem = refusal.sentence
            }
        }
    }
}

// MARK: - Binary

/// Where the register's own command lives, and what it said when it refused.
/// The refusal is a sentence the product printed, so it travels as one.
struct RegisterRefusal: Error {
    let sentence: String
}

enum RegisterBinary {
    static func locate(workspaceRoot: URL) -> Result<URL, RegisterRefusal> {
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["PROBIERZ_BIN"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        candidates.append(workspaceRoot.appendingPathComponent("probierz-rs/target/release/probierz"))
        candidates.append(workspaceRoot.appendingPathComponent("probierz-rs/target/debug/probierz"))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/probierz"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/probierz"))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return .success(candidate)
        }
        return .failure(
            RegisterRefusal(
                sentence: "No probierz binary here: looked at "
                    + candidates.map(\.path).joined(separator: ", ")
            )
        )
    }

    static func run(
        _ binary: URL,
        workspaceRoot: URL,
        arguments: [String]
    ) async -> Result<String, RegisterRefusal> {
        await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--harness", workspaceRoot.path] + arguments
            process.currentDirectoryURL = workspaceRoot
            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return .failure(
                    RegisterRefusal(sentence: "probierz could not start: \(error.localizedDescription)")
                )
            }
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let refusal = String(data: stderr, encoding: .utf8)?
                    .split(separator: "\n")
                    .map(String.init)
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return .failure(
                    RegisterRefusal(
                        sentence: refusal ?? "probierz exited \(process.terminationStatus)"
                    )
                )
            }
            return .success(String(data: stdout, encoding: .utf8) ?? "")
        }.value
    }
}
