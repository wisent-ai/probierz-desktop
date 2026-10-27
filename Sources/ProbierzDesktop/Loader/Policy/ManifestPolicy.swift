import Foundation
import Yams

/// A policy requirement is either declared or unavailable, never an inferred floor.
enum EvidenceMinimum: Sendable {
    case declared(name: String, rank: UInt8)
    case unavailable(String)

    var title: String {
        switch self {
        case .declared(let name, _): name
        case .unavailable: "Unknown"
        }
    }

    var detail: String {
        switch self {
        case .declared(let name, _): "The manifest requires \(name) or stronger evidence."
        case .unavailable(let reason): reason
        }
    }

    var failure: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

struct ManifestPolicy {
    let node: Node
    let location: String

    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func text(_ key: String, required: Bool = false) throws -> String? {
        guard let value = node[key] else {
            if required { throw Invalid(message: "\(location).\(key) is missing; declare the required E<n> evidence level") }
            return nil
        }
        guard value.tag == Tag(.str), let text = value.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Invalid(message: "\(location).\(key) must be non-empty text, found \(value)")
        }
        return text
    }

    func validateTexts(_ key: String) throws {
        guard let value = node[key] else { return }
        guard let list = value.sequence else {
            throw Invalid(message: "\(location).\(key) must be a list of non-empty text values, found \(value)")
        }
        for item in list {
            guard item.tag == Tag(.str), let text = item.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Invalid(message: "\(location).\(key) must be a list of non-empty text values, found \(item)")
            }
        }
    }

    func validateFlag(_ key: String) throws {
        guard let value = node[key] else { return }
        guard value.tag == Tag(.bool), value.bool != nil else {
            throw Invalid(message: "\(location).\(key) must be a boolean, found \(value)")
        }
    }

    func minimum() throws -> EvidenceMinimum {
        guard node.mapping != nil else {
            throw Invalid(message: "\(location) must be a mapping, found \(node)")
        }
        guard let level = try text("minimumEvidence", required: true) else {
            throw Invalid(message: "\(location).minimumEvidence is missing")
        }
        let digits = level.dropFirst()
        guard level.first == "E", !digits.isEmpty,
              digits.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.decimalDigits.contains($0) }),
              let rank = UInt8(digits) else {
            throw Invalid(message: "\(location).minimumEvidence is not an E<n> evidence level: \(level)")
        }
        try validateTexts("requiredTargets")
        try validateTexts("requiredJourneys")
        try validateFlag("requireProtectedArtifacts")
        try validateFlag("requireSecretScan")
        _ = try text("requiredMatrixProfile")
        return .declared(name: level, rank: rank)
    }
}
