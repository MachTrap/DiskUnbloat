import Foundation
import Darwin

private struct WorkerBatch: Sendable {
    var nodes: [FileNode] = []
    var issues: [(String, String)] = []
    var bytes: Int64 = 0
    var done = false
}
// Safety invariant: all mutable state, including Foundation's enumerator, is used only
// on `queue`. The only public operation schedules work there. See ARCHITECTURE.md.
private final class EnumerationWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DiskUnbloat.enumeration", qos: .utility)
    private let request: ScanRequest
    private let excludedPaths: [String]
    private var enumerator: FileManager.DirectoryEnumerator?
    private var parents: [(path: String, id: Int64, package: Bool)] = []
    private var nextID: Int64 = 1
    private var rootDevice: Int32 = 0

    private var seenHardLinks: Set<String> = []
    private var pendingBytes: Int64 = 0
    private var pendingIssues: [(String, String)] = []
    private var initialized = false
    private var remainingRoots: [URL] = []
    private var wrapperID: Int64 = 0
    private var rootActive = false
    private let keys: [URLResourceKey] = [.isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    init(_ request: ScanRequest) { self.request = request; self.excludedPaths = request.options.exclusions.map { canonicalURL(URL(fileURLWithPath: $0)).path } }
    func next() async -> WorkerBatch {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readBatch()) }
        }
    }
    private func makeNode(_ url: URL, parent: Int64?, insidePackage: Bool) throws -> FileNode {
        let identity = try FileIdentity.read(url)
        let values = try url.resourceValues(forKeys: Set(keys))
        let node = FileNode(id: nextID, parentID: parent, path: url.path, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, isDirectory: identity.directory, isPackage: values.isPackage ?? false, isSymbolicLink: identity.link, logicalSize: identity.directory ? 0 : (identity.link ? identity.size : values.fileSize.map(Int64.init)), allocatedSize: identity.directory ? 0 : (identity.link ? identity.allocated : values.totalFileAllocatedSize.map(Int64.init)), modified: identity.modified, identity: identity.identity, fingerprint: identity.fingerprint, packageAncestor: insidePackage)
        if !identity.directory && (identity.links <= 1 || seenHardLinks.insert(identity.identity).inserted) { pendingBytes += node.displaySize }
        nextID += 1; return node
    }
    /// Opens one scan root: a fresh parent stack, enumerator, and per-root cross-volume check.
    private func openRoot(_ url: URL, parentID: Int64?) throws -> FileNode {
        let requestedIdentity = try FileIdentity.read(url)
        guard !requestedIdentity.link else { throw CocoaError(.fileReadUnsupportedScheme) }
        let rootURL = canonicalURL(url)
        rootDevice = try FileIdentity.read(rootURL).device
        let root = try makeNode(rootURL, parent: parentID, insidePackage: false)
        guard root.isDirectory && !root.isSymbolicLink else { throw CocoaError(.fileReadUnsupportedScheme) }
        parents = [(root.path, root.id, root.isPackage)]
        let options: FileManager.DirectoryEnumerationOptions = request.options.includeHidden ? [] : [.skipsHiddenFiles]
        enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: options, errorHandler: { [weak self] url, error in
            self?.pendingIssues.append((url.path, error.localizedDescription)); return true
        })
        if enumerator == nil { pendingIssues.append((url.path, "Unable to enumerate this location.")) }
        return root
    }
    private func beginRoot(_ url: URL, parentID: Int64?, into batch: inout WorkerBatch) {
        do { batch.nodes.append(try openRoot(url, parentID: parentID)); rootActive = true }
        catch {
            batch.issues.append((url.path, error.localizedDescription))
            rootActive = false
            startNextRoot(into: &batch)
        }
    }
    /// Grouped scans continue with the next listed location; a single-root scan ends instead.
    private func startNextRoot(into batch: inout WorkerBatch) {
        while !remainingRoots.isEmpty {
            let next = remainingRoots.removeFirst()
            do { batch.nodes.append(try openRoot(next, parentID: wrapperID)); rootActive = true; return }
            catch { batch.issues.append((next.path, error.localizedDescription)) }
        }
        batch.done = true
    }
    private func readBatch() -> WorkerBatch {
        var batch = WorkerBatch()
        if !initialized {
            initialized = true
            if !request.extraRoots.isEmpty {
                let wrapper = FileNode(id: nextID, parentID: nil, path: ScanGroup.path, name: request.groupTitle, isDirectory: true, isPackage: false, isSymbolicLink: false, logicalSize: nil, allocatedSize: nil, modified: nil, identity: ScanGroup.path, packageAncestor: false)
                batch.nodes.append(wrapper)
                wrapperID = nextID; nextID += 1
                remainingRoots = request.extraRoots
            }
            beginRoot(request.root, parentID: wrapperID == 0 ? nil : wrapperID, into: &batch)
        }
        let start = Date()
        while batch.nodes.count < 512 && Date().timeIntervalSince(start) < 0.1 {
            guard let url = enumerator?.nextObject() as? URL else { batch.done = true; break }
            if excludedPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) { enumerator?.skipDescendants(); continue }
            while parents.count > 1 && url.deletingLastPathComponent().path != parents.last?.path { parents.removeLast() }
            do {
                let identity = try FileIdentity.read(url)
                if !request.options.crossVolumes && identity.device != rootDevice { enumerator?.skipDescendants(); continue }
                let node = try makeNode(url, parent: parents.last?.id, insidePackage: parents.last?.package ?? false)
                batch.nodes.append(node)
                if node.isSymbolicLink { enumerator?.skipDescendants() }
                else if node.isDirectory {
                    let cloud = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                    if cloud?.isUbiquitousItem == true && cloud?.ubiquitousItemDownloadingStatus == .notDownloaded {
                        enumerator?.skipDescendants(); pendingIssues.append((node.path, "Cloud directory is not downloaded; contents were not requested."))
                    } else { parents.append((node.path, node.id, node.isPackage || node.packageAncestor)) }
                }
            } catch { enumerator?.skipDescendants(); pendingIssues.append((url.path, error.localizedDescription)) }
        }
        // A finished grouped root hands the turn to the next listed location; the scan
        // completes only when no root remains active and none can be opened.
        if batch.done {
            rootActive = false
            if wrapperID != 0 { startNextRoot(into: &batch) }
            batch.done = batch.done && !rootActive
        }
        batch.bytes = pendingBytes; pendingBytes = 0
        batch.issues += pendingIssues; pendingIssues.removeAll(keepingCapacity: true)
        return batch
    }
}
public protocol ScanServing: Sendable {
    func scan(_ request: ScanRequest, into index: ScanIndex) async -> AsyncStream<ScanEvent>
    func cancel() async
}
public actor ScanCoordinator: ScanServing {
    private var runningTask: Task<Void, Never>?
    public init() {}
    public func cancel() { runningTask?.cancel() }
    public func scan(_ request: ScanRequest, into index: ScanIndex) -> AsyncStream<ScanEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task {
                let worker = EnumerationWorker(request)
                let start = Date(); var lastUpdate = Date.distantPast
                var count = 0; var bytes: Int64 = 0; var errors = 0; var folders = 0; var currentFolder = request.root.path
                continuation.yield(.stage(.reading))
                do {
                    while !Task.isCancelled {
                        let batch = await worker.next()
                        try await index.insert(batch.nodes)
                        count += batch.nodes.count
                        folders += batch.nodes.filter(\.isDirectory).count
                        if let last = batch.nodes.last { currentFolder = last.isDirectory ? last.path : last.url.deletingLastPathComponent().path }
                        bytes += batch.bytes
                        errors += batch.issues.count
                        for issue in batch.issues { await index.issue(path: issue.0, message: issue.1) }
                        if Date().timeIntervalSince(lastUpdate) >= 0.2 {
                            continuation.yield(.progress(ScanSnapshot(items: count, bytes: bytes, elapsed: Date().timeIntervalSince(start), errors: errors, cancelled: false, complete: false, folders: folders, currentFolder: currentFolder)))
                            lastUpdate = Date()
                        }
                        if batch.done { break }
                    }
                    continuation.yield(.stage(.aggregating))
                    try await index.aggregate()
                    continuation.yield(.finished(ScanSnapshot(items: count, bytes: bytes, elapsed: Date().timeIntervalSince(start), errors: errors, cancelled: Task.isCancelled, complete: !Task.isCancelled && errors == 0, folders: folders, currentFolder: currentFolder)))
                } catch { continuation.yield(.failed(error.localizedDescription)) }
                continuation.finish()
            }
            runningTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
