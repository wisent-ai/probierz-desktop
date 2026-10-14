import Foundation
import SwiftUI
import WisentDesignSystem

/// One wisent-errors envelope as `probierz intake` appended it.
///
/// A class because `cause` recurses — a gateway refusal whose cause is a
/// provider refusal whose cause is a vault refusal is three envelopes — and a
/// Swift value type cannot contain itself. Every property is immutable, so
/// the unchecked Sendable is a formality: instances are decoded once on a
/// background task and never mutated.
final class FailureNode: Decodable, @unchecked Sendable {
    let failurePoint: String
    let errorCode: String
    let service: String
    let impact: String?
    let severity: String
    let retryable: Bool
    let outage: Bool
    let detail: String?
    let cause: FailureNode?
    let context: [String: FailureContextValue]?

    enum CodingKeys: String, CodingKey {
        case failurePoint = "failure_point"
        case errorCode = "error_code"
        case service
        case impact
        case severity
        case retryable
        case outage
        case detail
        case cause
        case context
    }

    var severityTone: WisentTone {
        switch severity {
        case "warning": .warning
        case "error", "critical": .danger
        default: .neutral
        }
    }

    /// The failures underneath this one, outermost first — the flattening the
    /// wisent-errors formatters apply, because that is the order a reader in a
    /// hurry needs.
    var causeChain: [FailureNode] {
        var chain: [FailureNode] = []
        var node = cause
        while let current = node {
            chain.append(current)
            node = current.cause
        }
        return chain
    }
}

/// Context values are scalars by contract, so a log shipper can index them.
enum FailureContextValue: Decodable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case null

    /// A JSON null is `.null`; a string, boolean or number is itself. Any other
    /// value breaks the scalar contract and fails the line's decoding, so the
    /// failure list shows the line as unreadable instead of a null nobody wrote.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        do {
            self = .text(try container.decode(String.self))
            return
        } catch DecodingError.typeMismatch {
            // Not a string: the next scalar type is asked.
        }
        do {
            self = .flag(try container.decode(Bool.self))
            return
        } catch DecodingError.typeMismatch {
            // Not a boolean: only a number is left, and anything else throws.
        }
        self = .number(try container.decode(Double.self))
    }

    var rendered: String {
        switch self {
        case .text(let value): value
        case .number(let value): value.formatted(.number)
        case .flag(let value): value ? "true" : "false"
        case .null: "null"
        }
    }
}

/// One parsed line, with the file position needed to order and select it.
struct FailureEntry: Identifiable, Sendable {
    let id: String
    let envelope: FailureNode
}

// MARK: - Store

/// The intake owns the files; the desktop only reads them.
///
/// `probierz intake` appends one envelope per line to
/// `~/.probierz/failures/<service>.jsonl` (PROBIERZ_FAILURES_DIR overrides —
/// the store lives outside TCC-protected directories so a launchd listener
/// can write it), caps the line at 64 KB
/// and rotates the file at 10 MB, so reading a whole file is bounded by the
/// writer's own rules. A malformed line is skipped, never reported: a failure
/// index must never fail either.
enum FailureIntakeStore {
    static func directory(workspaceRoot: URL) -> URL {
        // workspaceRoot stays in the signature for the caller's sake; the store
        // itself is the operator-home path the intake writes.
        if let override = ProcessInfo.processInfo.environment["PROBIERZ_FAILURES_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".probierz/failures", isDirectory: true)
    }

    /// Every reported failure, newest first, and every intake directory or
    /// file that exists but could not be read, as `path: cause`, so an
    /// unreadable intake is not shown as nothing having reported.
    static func load(workspaceRoot: URL) -> (entries: [FailureEntry], unreadable: [String]) {
        let root = directory(workspaceRoot: workspaceRoot)
        let files: [URL]
        do {
            let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                return (
                    [],
                    [
                        "\(root.path): failure intake must be a non-symbolic directory; isDirectory=\(String(describing: rootValues.isDirectory)), isSymbolicLink=\(String(describing: rootValues.isSymbolicLink))"
                    ]
                )
            }
            files = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                ]
            )
        } catch {
            let missing = (error as? CocoaError)?.code == .fileReadNoSuchFile
            return ([], missing ? [] : ["\(root.path): \(error.localizedDescription)"])
        }
        var unreadable: [String] = []

        let decoder = JSONDecoder()
        var parsed: [(modified: Date, file: String, line: Int, entry: FailureEntry)] = []
        for file in files where file.pathExtension == "jsonl" {
            let values: URLResourceValues
            do {
                values = try file.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
                )
            } catch {
                unreadable.append(
                    "\(file.path): cannot inspect metadata: \(error.localizedDescription)")
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let content: String
            do {
                content = try String(contentsOf: file, encoding: .utf8)
            } catch {
                unreadable.append("\(file.path): \(error.localizedDescription)")
                continue
            }
            let modified = values.contentModificationDate ?? .distantPast
            let name = file.lastPathComponent
            for (index, line) in content.split(separator: "\n").enumerated() {
                // A line that is not a failure envelope is reported with the
                // unreadable files, never left out of the list unseen.
                let envelope: FailureNode
                do {
                    envelope = try decoder.decode(FailureNode.self, from: Data(line.utf8))
                } catch {
                    unreadable.append(
                        "\(file.path) line \(index + 1): \(error.localizedDescription)")
                    continue
                }
                parsed.append(
                    (
                        modified: modified,
                        file: name,
                        line: index,
                        entry: FailureEntry(id: "\(name)#\(index)", envelope: envelope)
                    ))
            }
        }

        // Newest first: within a service file the last appended line is the
        // newest; the envelope carries no timestamp, so across services the
        // file's modification date is the only honest ordering.
        let entries =
            parsed
            .sorted { lhs, rhs in
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                if lhs.file != rhs.file { return lhs.file < rhs.file }
                return lhs.line > rhs.line
            }
            .map(\.entry)
        return (entries, unreadable)
    }
}

// MARK: - Screen
