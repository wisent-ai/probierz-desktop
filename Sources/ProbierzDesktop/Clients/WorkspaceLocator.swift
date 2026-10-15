import Foundation

enum WorkspaceLocator {
    /// Each candidate and every one of its ancestors up to the filesystem root is tried,
    /// the app bundle among the candidates; there is no depth at which the search gives up.
    static func resolve(savedPath: String?) -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []

        if let savedPath, !savedPath.isEmpty {
            candidates.append(URL(fileURLWithPath: savedPath, isDirectory: true))
        }
        if let environment = ProcessInfo.processInfo.environment["WISENT_WORKSPACE_ROOT"],
            !environment.isEmpty
        {
            candidates.append(URL(fileURLWithPath: environment, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true))
        candidates.append(
            manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/CodingProjects/Wisent", isDirectory: true)
        )

        candidates.append(Bundle.main.bundleURL.standardizedFileURL)

        var seen = Set<String>()
        for candidate in candidates {
            var current = candidate.standardizedFileURL
            while true {
                let path = current.path
                if seen.insert(path).inserted, isWorkspace(current) {
                    return current
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return nil
    }

    static func isWorkspace(_ url: URL) -> Bool {
        workspaceProblem(url) == nil
    }

    static func workspaceProblem(_ url: URL) -> String? {
        let repository = url.appendingPathComponent("probierz", isDirectory: true)
        let manifest = repository.appendingPathComponent(".wisent-release.json")
        let cargo = repository.appendingPathComponent("probierz-rs/Cargo.toml")
        for file in [manifest, cargo] {
            let values: URLResourceValues
            do {
                values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                return "Cannot inspect \(file.path): \(error.localizedDescription)"
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return "The Probierz workspace requires a regular, non-symlink file at \(file.path)."
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifest)
        } catch {
            return "Cannot read \(manifest.path): \(error.localizedDescription)"
        }
        let identity: ReleaseIdentity
        do {
            identity = try JSONDecoder().decode(ReleaseIdentity.self, from: data)
        } catch {
            return "Cannot decode \(manifest.path): \(error.localizedDescription)"
        }
        guard identity.product == "probierz" else {
            return "\(manifest.path) identifies \(identity.product), not Probierz."
        }
        return nil
    }

    private struct ReleaseIdentity: Decodable {
        let product: String
    }
}
