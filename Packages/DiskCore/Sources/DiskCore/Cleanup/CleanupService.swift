import Foundation

public protocol CleanupServing: Sendable {
    func execute(_ plan: CleanupPlan) async -> [CleanupResult]
}
public actor CleanupService: CleanupServing {
    public init() {}
    public func execute(_ plan: CleanupPlan) async -> [CleanupResult] {
        let queue = DispatchQueue(label: "DiskUnbloat.cleanup", qos: .userInitiated)
        var results: [CleanupResult] = []
        func emit(_ event: CleanupEvent) { plan.diagnostics?(event) }
        if !plan.duplicateRefusals.isEmpty {
            return plan.items.map { entry in
                let path = entry.node.path
                let reason = plan.duplicateRefusals[path] ?? .conflictingSelection
                emit(.itemQueued(path: path, operation: String(describing: entry.operation)))
                emit(.itemFailed(path: path, message: reason.message))
                return CleanupResult(id: entry.id, path: path, succeeded: false, message: reason.message)
            }
        }
        for entry in plan.items {
            emit(.itemQueued(path: entry.node.path, operation: String(describing: entry.operation)))
            if let reason = await plan.preflight?(entry.node.path) {
                let refused = CleanupResult(id: entry.node.id,path: entry.node.path,succeeded: false,message: reason)
                emit(.itemFailed(path: refused.path, message: refused.message))
                results.append(refused)
                continue
            }
            switch entry.operation {
            case .remove:
                let result: CleanupResult = await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: Self.remove(entry.node, survivor: entry.survivor, plan: plan)) }
                }
                emit(result.succeeded ? .itemSucceeded(path: result.path, message: result.message)
                                      : .itemFailed(path: result.path, message: result.message))
                results.append(result)
            case .emptyContents:
                let emptied = await emptyContents(entry.node, plan: plan, queue: queue)
                for result in emptied {
                    emit(result.succeeded ? .itemSucceeded(path: result.path, message: result.message)
                                          : .itemFailed(path: result.path, message: result.message))
                }
                results += emptied
            }
        }
        return results
    }

    /// Read-only commit check. Execution repeats the filesystem checks before mutation.
    public nonisolated static func validateReviewedDuplicates(
        _ entries: [CleanupEntry], roots: [URL], index: ScanIndex
    ) async -> [String: DuplicateCleanupRefusal] {
        let evidence = await index.cleanupEvidence(for: entries)
        let rootPaths = roots.map { canonicalURL($0).path }
        let queue = DispatchQueue(label: "DiskUnbloat.duplicate-review", qos: .userInitiated)
        return await withCheckedContinuation { continuation in
            queue.async {
                var refusals: [String: DuplicateCleanupRefusal] = [:]
                for entry in entries {
                    let path = entry.node.path
                    guard let keeper = entry.survivor,
                          let copy = evidence.nodes[path], copy.id == entry.id,
                          copy.identity == entry.node.identity, copy.fingerprint == entry.node.fingerprint,
                          let kept = evidence.nodes[keeper.path], kept.identity == keeper.identity,
                          kept.fingerprint == keeper.fingerprint else {
                        refusals[path] = .invalidPair
                        continue
                    }
                    refusals[path] = validatePair(copy, keeper: keeper, scope: rootPaths, ancestors: evidence.ancestors)
                }
                continuation.resume(returning: refusals)
            }
        }
    }

    private nonisolated static func validatePair(
        _ node: FileNode, keeper: CleanupEntry.Survivor, scope: [String], ancestors: [String: String]
    ) -> DuplicateCleanupRefusal? {
        guard scope.contains(where: { keeper.path.isWithin($0) }),
              keeper.identity != node.identity, keeper.path != node.path else { return .invalidPair }
        let keptURL = URL(fileURLWithPath: keeper.path)
        do {
            try validateAncestry(node.url, identities: ancestors)
            try validateAncestry(keptURL, identities: ancestors)
        } catch { return .ancestryChanged }
        guard let copy = try? FileIdentity.read(node.url), copy.regular, !copy.dataless,
              copy.identity == node.identity, copy.fingerprint == node.fingerprint else { return .copyChanged }
        guard let kept = try? FileIdentity.read(keptURL), kept.regular, !kept.dataless,
              kept.identity == keeper.identity, kept.fingerprint == keeper.fingerprint else { return .keeperChanged }
        let parent = node.url.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path) ? nil : .writeUnavailable
    }

    private nonisolated static func validateAncestry(_ url: URL, identities: [String: String]) throws {
        let parent = url.deletingLastPathComponent()
        guard canonicalURL(parent).path == parent.path else {
            throw CleanupError.refused("An ancestor changed or is a symbolic link. Scan again.")
        }
        var path = url.path.canonicalParentPath
        while let candidate = path {
            if let expected = identities[candidate] {
                let current = try FileIdentity.read(URL(fileURLWithPath: candidate))
                guard current.identity == expected, current.directory, !current.link else {
                    throw CleanupError.refused("An ancestor changed since scanning. Scan again.")
                }
            }
            path = candidate.canonicalParentPath
        }
    }

    private nonisolated static func remove(_ node: FileNode, survivor: CleanupEntry.Survivor? = nil, plan: CleanupPlan) -> CleanupResult {
        do {
            if let reason = CleanupSafety.blockedReason(node, roots: plan.roots, exemptingCacheRoots: plan.knownCacheRoots) {
                throw CleanupError.refused(reason)
            }
            if let survivor {
                if let refusal = validatePair(node, keeper: survivor, scope: plan.roots.map(\.path), ancestors: plan.ancestorIdentities) {
                    throw CleanupError.refused(refusal.message)
                }
            } else {
                try validateAncestry(node.url, identities: plan.ancestorIdentities)
                let current = try FileIdentity.read(node.url)
                guard current.identity == node.identity,
                      (node.fingerprint.map { $0 == current.fingerprint } ?? (current.modified == node.modified)),
                      current.link == node.isSymbolicLink, current.directory == node.isDirectory else {
                    throw CleanupError.refused("This item changed since scanning. Scan again before removing it.")
                }
                guard FileManager.default.isWritableFile(atPath: node.url.deletingLastPathComponent().path) else {
                    throw CleanupError.refused("Write authorization is unavailable.")
                }
            }
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
                if let reason = await plan.preflight?(child.path) {
                    failures += 1
                    plan.diagnostics?(.childFailed(parent: node.path, path: child.path, message: reason))
                    continue
                }
                // Per-child semantics: a child that cannot be removed stays in place and
                // the run continues with the remaining contents — the failing child and
                // its reason are emitted for the diagnostics log, never swallowed.
                let outcome: Result<Void, CleanupError> = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, CleanupError>, Never>) in
                    queue.async { continuation.resume(returning: Self.removeChild(child, plan: plan)) }
                }
                if case .failure(let error) = outcome {
                    failures += 1
                    plan.diagnostics?(.childFailed(parent: node.path, path: child.path, message: error.errorDescription ?? "Failed"))
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
            try validateAncestry(node.url, identities: plan.ancestorIdentities)
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
