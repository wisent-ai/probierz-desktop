import Foundation
import Yams

extension MetadataLoader {
    /// YAML structure, not indentation, decides which keys belong to the policy.
    static func scanAppManifest(_ text: String, file: URL) throws -> AppManifestScan {
        guard let document = try Yams.compose(yaml: text) else {
            throw ManifestPolicy.Invalid(message: "\(file.path): manifest is empty")
        }
        let root = try manifestMapping(document, location: file.path)
        var scan = AppManifestScan()
        if let journeys = root["journeys"] {
            for (key, value) in try manifestMapping(journeys, location: "\(file.path) journeys") {
                guard key.tag == Tag(.str), let name = key.string, !name.isEmpty else {
                    throw ManifestPolicy.Invalid(message: "\(file.path) journeys contains a key that is not a name: \(key)")
                }
                let fields = try manifestMapping(value, location: "\(file.path) journeys.\(name)")
                scan.journeyOrder.append(name)
                let reader = ManifestPolicy(node: .mapping(fields), location: "\(file.path) journeys.\(name)")
                scan.journeyOwners[name] = try reader.text("owner")
                scan.journeyDescriptions[name] = try reader.text("description")
            }
        }
        let location = "\(file.path) pullRequestPolicy"
        if let policy = root["pullRequestPolicy"] {
            do {
                _ = try manifestMapping(policy, location: location)
                scan.minimumEvidence = try ManifestPolicy(node: policy, location: location).minimum()
            } catch {
                scan.minimumEvidence = .unavailable(error.localizedDescription)
            }
        } else {
            scan.minimumEvidence = .unavailable("\(location) is missing; declare the policy before evaluating this mode")
        }
        return scan
    }

    private static func manifestMapping(_ node: Node, location: String) throws -> Node.Mapping {
        guard let mapping = node.mapping else {
            throw ManifestPolicy.Invalid(message: "\(location) must be a mapping, found \(node)")
        }
        var keys = Set<String>()
        for (key, _) in mapping {
            guard key.tag == Tag(.str), let name = key.string else {
                throw ManifestPolicy.Invalid(message: "\(location) contains a key that is not text: \(key)")
            }
            guard keys.insert(name).inserted else {
                throw ManifestPolicy.Invalid(message: "\(location) repeats key \(name)")
            }
        }
        return mapping
    }
}
