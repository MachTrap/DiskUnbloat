import Foundation

public protocol CleanupServing: Sendable {
    func execute(_ plan: CleanupPlan) async -> [CleanupResult]
}
public actor CleanupService: CleanupServing {
    public init() {}
    public func execute(_ plan: CleanupPlan) async -> [CleanupResult] {
        let queue = DispatchQueue(label: "DiskUnbloat.cleanup", qos: .userInitiated)
        var results: [CleanupResult] = []
        for node in plan.items {
            if let reason = await plan.preflight?(node) {
                results.append(CleanupResult(id: node.id,path: node.path,succeeded: false,message: reason))
                continue
            }
            let result: CleanupResult = await withCheckedContinuation { continuation in
                queue.async {
                    let result: CleanupResult = Self.remove(node, plan: plan)
                    continuation.resume(returning: result)
                }
            }
            results.append(result)
        }
        return results
    }

    private nonisolated static func remove(_ node: FileNode, plan: CleanupPlan) -> CleanupResult {
                    do {
                        if let reason = CleanupSafety.blockedReason(node, root: plan.root) { throw CleanupError.refused(reason) }
                        let parent = node.url.deletingLastPathComponent()
                        // Resolving parent ancestry detects replaced directory components, without following the leaf link.
                        guard canonicalURL(parent).path == parent.path else { throw CleanupError.refused("An ancestor changed or is a symbolic link. Scan again.") }
                        for (path, expected) in plan.ancestorIdentities where node.path.hasPrefix(path + "/") {
                            guard try FileIdentity.read(URL(fileURLWithPath: path)).identity == expected else { throw CleanupError.refused("An ancestor changed since scanning. Scan again.") }
                        }
                        let current = try FileIdentity.read(node.url)
                        guard current.identity == node.identity, (node.fingerprint.map { $0 == current.fingerprint } ?? (current.modified == node.modified)), current.link == node.isSymbolicLink, current.directory == node.isDirectory else { throw CleanupError.refused("This item changed since scanning. Scan again before removing it.") }
                        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw CleanupError.refused("Write authorization is unavailable.") }
                        switch plan.mode {
                        case .trash: try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                        case .permanent: try FileManager.default.removeItem(at: node.url)
                        }
                        return CleanupResult(id: node.id, path: node.path, succeeded: true, message: plan.mode == .trash ? "Moved to Trash" : "Permanently deleted")
                    } catch { return CleanupResult(id: node.id, path: node.path, succeeded: false, message: error.localizedDescription) }
    }
    private enum CleanupError: LocalizedError {
        case refused(String)
        var errorDescription: String? { if case .refused(let reason) = self { reason } else { nil } }
    }
}
