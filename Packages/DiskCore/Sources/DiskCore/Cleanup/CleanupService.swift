import Foundation

public protocol CleanupServing: Sendable {
    func execute(_ plan: CleanupPlan) async -> [CleanupResult]
}
public actor CleanupService: CleanupServing {
    public init() {}
    public func execute(_ plan: CleanupPlan) async -> [CleanupResult] {
        let queue = DispatchQueue(label: "DiskUnbloat.cleanup", qos: .userInitiated)
        var results: [CleanupResult] = []
        for entry in plan.items {
            if let reason = await plan.preflight?(entry.node.path) {
                results.append(CleanupResult(id: entry.node.id,path: entry.node.path,succeeded: false,message: reason))
                continue
            }
            switch entry.operation {
            case .remove:
                let result: CleanupResult = await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: Self.remove(entry.node, plan: plan)) }
                }
                results.append(result)
            case .emptyContents:
                results += await emptyContents(entry.node, plan: plan, queue: queue)
            }
        }
        return results
    }

    private nonisolated static func remove(_ node: FileNode, plan: CleanupPlan) -> CleanupResult {
                    do {
                        if let reason = CleanupSafety.blockedReason(node, roots: plan.roots, exemptingCacheRoots: plan.knownCacheRoots) { throw CleanupError.refused(reason) }
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

    /// Empties a scan-root folder in place: validates the folder itself, then removes each of
    /// its current direct children with the plan's mode. The folder is never deleted, and a
    /// child that cannot be removed stays in place — Trash is never upgraded to permanent.
    private func emptyContents(_ node: FileNode, plan: CleanupPlan, queue: DispatchQueue) async -> [CleanupResult] {
        do {
            let contents = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(children: [URL], blockedVolumes: Int), Error>) in
                queue.async { continuation.resume(with: Self.prepareEmptying(node, plan: plan)) }
            }
            var failures = contents.blockedVolumes
            for child in contents.children {
                // Recheck the per-mutation guard before every child: running-application
                // caches among the contents stay protected even while the folder is emptied.
                if await plan.preflight?(child.path) != nil { failures += 1; continue }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async { continuation.resume(with: Self.removeChild(child, plan: plan)) }
                }
            }
            guard failures == 0 else { return [CleanupResult(id: node.id, path: node.path, succeeded: false, message: "The folder was kept, but some contents could not be removed.")] }
            return [CleanupResult(id: node.id, path: node.path, succeeded: true, message: plan.mode == .trash ? "Emptied. Contents moved to Trash." : "Emptied. Contents permanently deleted.")]
        } catch { return [CleanupResult(id: node.id, path: node.path, succeeded: false, message: error.localizedDescription)] }
    }

    /// Queue-confined validation and child enumeration for an in-place emptying.
    private nonisolated static func prepareEmptying(_ node: FileNode, plan: CleanupPlan) -> Result<(children: [URL], blockedVolumes: Int), CleanupError> {
        do {
            if let reason = CleanupSafety.emptyContentsBlockedReasonCode(node, roots: plan.roots, exemptingCacheRoots: plan.knownCacheRoots) { throw CleanupError.refused(reason.message) }
            for (path, expected) in plan.ancestorIdentities where node.path.hasPrefix(path + "/") {
                guard try FileIdentity.read(URL(fileURLWithPath: path)).identity == expected else { throw CleanupError.refused("An ancestor changed since scanning. Scan again.") }
            }
            let current = try FileIdentity.read(node.url)
            guard current.identity == node.identity, (node.fingerprint.map { $0 == current.fingerprint } ?? (current.modified == node.modified)), current.directory, !current.link else { throw CleanupError.refused("This item changed since scanning. Scan again before removing it.") }
            guard FileManager.default.isWritableFile(atPath: node.path) else { throw CleanupError.refused("Write authorization is unavailable.") }
            // Contents inherit the folder's scope and protections; a mounted volume appearing
            // inside the folder is the only child that must never be swept away.
            let children = try FileManager.default.contentsOfDirectory(at: node.url, includingPropertiesForKeys: [.isVolumeKey], options: [])
            var volumes = 0
            let removable = children.filter { child in
                if let values = try? child.resourceValues(forKeys: [.isVolumeKey]), values.isVolume == true { volumes += 1; return false }
                return true
            }
            return .success((removable, volumes))
        } catch { return .failure(.refused(error.localizedDescription)) }
    }

    /// Queue-confined removal of one child of an emptied folder; failures leave it in place.
    private nonisolated static func removeChild(_ child: URL, plan: CleanupPlan) -> Result<Void, CleanupError> {
        do {
            let values = try child.resourceValues(forKeys: [.isVolumeKey])
            if values.isVolume == true { throw CleanupError.refused(CleanupReason.volumeRoot.message) }
            switch plan.mode {
            case .trash: try FileManager.default.trashItem(at: child, resultingItemURL: nil)
            case .permanent: try FileManager.default.removeItem(at: child)
            }
            return .success(())
        } catch { return .failure(.refused(error.localizedDescription)) }
    }
    private enum CleanupError: LocalizedError {
        case refused(String)
        var errorDescription: String? { if case .refused(let reason) = self { reason } else { nil } }
    }
}
