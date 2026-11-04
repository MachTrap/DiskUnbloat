import Foundation
import Darwin

struct WorkerBatch: Sendable {
    var nodes: [FileNode] = []
    var issues: [(String, String)] = []
    var bytes: Int64 = 0
    var currentFolder: String?
    var done = false
}

/// Bytes, newest modification, and unreadable-entry count gathered for one summarized
/// folder. Its subdirectories are summed by whichever worker is free; the last finishing
/// job emits the folder's node.
private final class SummaryTally {
    let template: FileNode
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var latest: Double
    var failures = 0
    /// Directory jobs still to run for this summary (the folder itself counts as one).
    var pending = 1
    init(_ template: FileNode) { self.template = template; latest = template.modified?.timeIntervalSince1970 ?? 0 }
}

/// Pool of dedicated enumeration threads reading directories with `getattrlistbulk`.
///
/// Safety invariant: every mutable field is read and written only while `condition` is
/// held, except each thread's own reader/detector (thread-confined) and the immutable
/// configuration. `SummaryTally` instances are only touched under `condition` too.
/// The coordinator drains batches through `next()`, which blocks a dedicated dispatch
/// queue rather than the cooperative pool. See ARCHITECTURE.md.
final class ParallelEnumeration: @unchecked Sendable {
    private struct Job {
        let path: String
        let id: Int64
        /// Children are inside a package (cleanup treats them as package contents).
        let insidePackage: Bool
        let device: Int32
        /// Set when the job only sums bytes into a summarized folder.
        let summary: SummaryTally?
    }

    private let request: ScanRequest
    private let excludedPaths: [String]
    private let summarizedNames: Set<String>
    private let summarizedPaths: Set<String>
    private let workerCount: Int
    private let drainQueue = DispatchQueue(label: "DiskUnbloat.enumeration.drain", qos: .userInitiated)

    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var running = 0
    private var started = false
    private var cancelled = false
    private var nextID: Int64 = 1
    private var output: [FileNode] = []
    private var issues: [(String, String)] = []
    private var bytes: Int64 = 0
    private var currentFolder: String?
    private var seenHardLinks: Set<String> = []
    /// Upper bound on buffered nodes; workers wait while the index catches up.
    private static let backlogLimit = 60_000

    init(_ request: ScanRequest, workers: Int = ParallelEnumeration.defaultWorkerCount) {
        self.request = request
        excludedPaths = request.options.exclusions.map { canonicalURL(URL(fileURLWithPath: $0)).path }
        var names: Set<String> = []; var paths: Set<String> = []
        for entry in request.options.summarizedFolders.map({ $0.trimmingCharacters(in: .whitespaces) }) where !entry.isEmpty {
            if entry.contains("/") { paths.insert(canonicalURL(URL(fileURLWithPath: entry)).path) } else { names.insert(entry.lowercased()) }
        }
        summarizedNames = names; summarizedPaths = paths
        workerCount = max(1, workers)
    }

    /// Parallel reads pay off on SSDs and APFS; beyond eight threads the kernel's
    /// directory locks and the single index writer dominate.
    static var defaultWorkerCount: Int { min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)) }

    func preflightTargets() async -> [ScanPermissionPreflight.Target] {
        await withCheckedContinuation { continuation in
            drainQueue.async { continuation.resume(returning: ScanPermissionPreflight.targets(for: self.request)) }
        }
    }
    func probe(_ target: ScanPermissionPreflight.Target) async -> ScanPermissionPreflight.ProbeOutcome {
        await withCheckedContinuation { continuation in
            drainQueue.async { continuation.resume(returning: ScanPermissionPreflight.probe(target, excludedPaths: self.excludedPaths)) }
        }
    }

    /// Next batch of discovered nodes: returns once 2048 nodes are buffered, 0.1 s passed,
    /// or enumeration finished. The first call opens the roots and starts the workers.
    func next() async -> WorkerBatch {
        await withCheckedContinuation { continuation in
            drainQueue.async { continuation.resume(returning: self.drain()) }
        }
    }

    /// Stops every worker; buffered results are discarded by the caller.
    func cancel() {
        condition.lock(); cancelled = true; condition.broadcast(); condition.unlock()
    }

    // MARK: - Draining

    private func drain() -> WorkerBatch {
        condition.lock(); defer { condition.unlock() }
        if !started { started = true; openRoots() }
        let deadline = Date().addingTimeInterval(0.1)
        while output.count < 2048 && !isFinished && !cancelled {
            if !condition.wait(until: deadline) { break }
        }
        var batch = WorkerBatch()
        swap(&batch.nodes, &output)
        swap(&batch.issues, &issues)
        batch.bytes = bytes; bytes = 0
        batch.currentFolder = currentFolder
        batch.done = isFinished || cancelled
        condition.broadcast() // wake workers held back by the backlog limit
        return batch
    }

    private var isFinished: Bool { jobs.isEmpty && running == 0 }

    /// Called with `condition` held: emits the root nodes (and the group wrapper), seeds
    /// one job per readable root, and launches the worker threads.
    private func openRoots() {
        var wrapperID: Int64?
        if !request.extraRoots.isEmpty {
            output.append(FileNode(id: nextID, parentID: nil, path: ScanGroup.path, name: request.groupTitle, isDirectory: true, isPackage: false, isSymbolicLink: false, logicalSize: nil, allocatedSize: nil, modified: nil, identity: ScanGroup.path, packageAncestor: false))
            wrapperID = nextID; nextID += 1
        }
        for url in request.roots {
            do {
                let requested = try FileIdentity.read(url)
                guard !requested.link else { throw CocoaError(.fileReadUnsupportedScheme) }
                let rootURL = canonicalURL(url)
                let identity = try FileIdentity.read(rootURL)
                guard identity.directory else { throw CocoaError(.fileReadUnsupportedScheme) }
                let isPackage = (try? rootURL.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
                let root = FileNode(id: nextID, parentID: wrapperID, path: rootURL.path, name: rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent, isDirectory: true, isPackage: isPackage, isSymbolicLink: false, logicalSize: 0, allocatedSize: 0, modified: identity.modified, identity: identity.identity, fingerprint: identity.fingerprint, packageAncestor: false)
                nextID += 1
                output.append(root)
                jobs.append(Job(path: root.path, id: root.id, insidePackage: isPackage, device: identity.device, summary: nil))
            } catch {
                issues.append((url.path, error.localizedDescription))
            }
        }
        // LIFO pops keep the frontier depth-first; reverse so the first root starts first.
        jobs.reverse()
        for _ in 0..<workerCount {
            let thread = Thread { [self] in work() }
            thread.qualityOfService = .userInitiated
            thread.name = "DiskUnbloat.enumeration"
            thread.start()
        }
    }

    // MARK: - Workers

    private func work() {
        // Never ask File Provider to download placeholders while measuring them.
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let reader = BulkDirectoryReader()
        let packages = PackageDetector()
        while true {
            condition.lock()
            while jobs.isEmpty && running > 0 && !cancelled { condition.wait() }
            if cancelled || jobs.isEmpty { condition.broadcast(); condition.unlock(); return }
            let job = jobs.removeLast()
            running += 1
            condition.unlock()

            if let summary = job.summary { sum(job, into: summary, reader: reader) }
            else { index(job, reader: reader, packages: packages) }
        }
    }

    private func skipped(_ path: String) -> Bool {
        !excludedPaths.isEmpty && excludedPaths.contains { path.isWithin($0) }
    }

    private func join(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }

    /// Reads one indexed directory: every entry becomes a node; subfolders become jobs
    /// (summarized folders become summing jobs whose node is emitted when they finish).
    private func index(_ job: Job, reader: BulkDirectoryReader, packages: PackageDetector) {
        var entries: [BulkEntry] = []
        var failure: (String, String)?
        do { try reader.read(job.path) { entries.append($0) } }
        catch { failure = (job.path, error.localizedDescription) }

        var nodes: [FileNode] = []; nodes.reserveCapacity(entries.count)
        var newJobs: [Job] = []
        var newIssues: [(String, String)] = failure.map { [$0] } ?? []
        var discovered: Int64 = 0
        var hardLinks: [(String, Int64)] = []

        condition.lock()
        var id = nextID; nextID += Int64(entries.count)
        condition.unlock()

        for entry in entries {
            let path = join(job.path, entry.name)
            if entry.error != 0 { newIssues.append((path, POSIXError(POSIXErrorCode(rawValue: entry.error) ?? .EIO).localizedDescription)); continue }
            if !request.options.includeHidden && entry.isHidden { continue }
            if skipped(path) { continue }
            if !request.options.crossVolumes && entry.device != job.device { continue }
            let directory = entry.kind == .directory
            let package = directory && packages.isPackage(name: entry.name, bundleBit: entry.hasBundleBit)
            let summarize = directory && !entry.isDataless
                && ((package && !request.options.inspectPackages) || summarizedNames.contains(entry.name.lowercased()) || summarizedPaths.contains(path))
            let size: Int64? = directory ? 0 : entry.size
            let allocated: Int64? = directory ? 0 : entry.allocated
            let node = FileNode(id: id, parentID: job.id, path: path, name: entry.name, isDirectory: directory, isPackage: package, isSymbolicLink: entry.kind == .symlink, logicalSize: size, allocatedSize: allocated, modified: entry.modificationDate, identity: entry.identity, fingerprint: entry.fingerprint, packageAncestor: job.insidePackage)
            id += 1
            if !directory {
                if entry.links <= 1 { discovered += entry.allocated } else { hardLinks.append((entry.identity, entry.allocated)) }
                nodes.append(node)
            } else if entry.isDataless {
                nodes.append(node)
                newIssues.append((path, "Cloud directory is not downloaded; contents were not requested."))
            } else if summarize {
                let tally = SummaryTally(node)
                newJobs.append(Job(path: path, id: node.id, insidePackage: true, device: job.device, summary: tally))
            } else {
                nodes.append(node)
                newJobs.append(Job(path: path, id: node.id, insidePackage: job.insidePackage || package, device: job.device, summary: nil))
            }
        }

        condition.lock()
        for (identity, allocated) in hardLinks where seenHardLinks.insert(identity).inserted { discovered += allocated }
        output += nodes
        issues += newIssues
        bytes += discovered
        currentFolder = job.path
        jobs += newJobs
        running -= 1
        condition.broadcast()
        while output.count > Self.backlogLimit && !cancelled { condition.wait() }
        condition.unlock()
    }

    /// Sums one directory of a summarized folder without creating nodes; nested folders
    /// are summed by further jobs so one huge package spreads across workers.
    private func sum(_ job: Job, into tally: SummaryTally, reader: BulkDirectoryReader) {
        var logical: Int64 = 0, allocated: Int64 = 0, latest: Double = 0, failures = 0
        var newJobs: [Job] = []
        var hardLinks: [(String, Int64, Int64)] = []
        do {
            try reader.read(job.path) { entry in
                if entry.error != 0 { failures += 1; return }
                if !request.options.includeHidden && entry.isHidden { return }
                let path = join(job.path, entry.name)
                if skipped(path) { return }
                if !request.options.crossVolumes && entry.device != job.device { return }
                latest = max(latest, entry.modificationDate.timeIntervalSince1970)
                switch entry.kind {
                case .directory:
                    if entry.isDataless { failures += 1 }
                    else { newJobs.append(Job(path: path, id: job.id, insidePackage: true, device: job.device, summary: tally)) }
                default:
                    if entry.links > 1 { hardLinks.append((entry.identity, entry.size, entry.allocated)) }
                    else { logical += entry.size; allocated += entry.allocated }
                }
            }
        } catch { failures += 1 }

        condition.lock()
        for (identity, size, alloc) in hardLinks where seenHardLinks.insert(identity).inserted { logical += size; allocated += alloc }
        tally.logical += logical; tally.allocated += allocated
        tally.latest = max(tally.latest, latest); tally.failures += failures
        tally.pending += newJobs.count - 1
        bytes += allocated
        currentFolder = tally.template.path
        jobs += newJobs
        if tally.pending == 0 { finish(tally) }
        running -= 1
        condition.broadcast()
        while output.count > Self.backlogLimit && !cancelled { condition.wait() }
        condition.unlock()
    }

    /// Called with `condition` held once every directory of a summary was summed.
    private func finish(_ tally: SummaryTally) {
        let t = tally.template
        output.append(FileNode(id: t.id, parentID: t.parentID, path: t.path, name: t.name, isDirectory: true, isPackage: t.isPackage, isSymbolicLink: false, logicalSize: tally.logical, allocatedSize: tally.allocated, modified: t.modified, identity: t.identity, fingerprint: t.fingerprint, packageAncestor: t.packageAncestor, latestContentModification: Date(timeIntervalSince1970: tally.latest), isSummarized: true))
        // Reported on the folder itself so the index marks it incomplete (sizes stay "known").
        if tally.failures > 0 { issues.append((t.path, "Some items inside could not be read; the size shown is a lower bound.")) }
    }
}
