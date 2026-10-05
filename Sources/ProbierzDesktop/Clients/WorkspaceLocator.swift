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
        if let environment = ProcessInfo.processInfo.environment["WISENT_WORKSPACE_ROOT"], !environment.isEmpty {
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
        let repository = url.appendingPathComponent("probierz", isDirectory: true)
        let package = repository.appendingPathComponent("package.json")
        let historyBoundary = repository.appendingPathComponent("agent/history.mjs")
        let packageValues = try? package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let boundaryValues = try? historyBoundary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return packageValues?.isRegularFile == true
            && packageValues?.isSymbolicLink != true
            && boundaryValues?.isRegularFile == true
            && boundaryValues?.isSymbolicLink != true
    }
}
