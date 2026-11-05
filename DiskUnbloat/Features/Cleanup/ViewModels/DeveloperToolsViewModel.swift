import Foundation
import Observation
import DiskCore

/// The "Developer tools" sheet: detected tools, their estimated reclaimable size from the
/// scan, and one confirmed run at a time with its output shown afterwards.
@MainActor @Observable final class DeveloperToolsViewModel {
    enum RunState: Equatable { case idle, running, finished(ToolRunResult) }
    struct Row: Identifiable, Equatable {
        let tool: DeveloperTool
        let executable: String
        let estimate: Int64?
        var id: String { tool.id }
    }

    private(set) var rows: [Row] = []
    private(set) var states: [String: RunState] = [:]
    var showSheet = false
    @ObservationIgnored private let runner: any ToolCommandRunning
    @ObservationIgnored private let exists: @Sendable (String) -> Bool
    /// The scanned index and home, for size estimates.
    @ObservationIgnored var context: () -> (index: ScanIndex, home: String)? = { nil }
    /// Called after a successful run with the home-relative estimate paths, so the
    /// affected locations can be rescanned.
    @ObservationIgnored var didRun: ([String]) -> Void = { _ in }

    init(runner: any ToolCommandRunning = ProcessToolRunner(), exists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.runner = runner; self.exists = exists
    }

    var anyRunning: Bool { states.values.contains(.running) }

    func open() async {
        var found: [Row] = []
        let context = context()
        for tool in DeveloperToolCatalog.all {
            guard let executable = DeveloperToolCatalog.executable(for: tool, exists: exists) else { continue }
            var estimate: Int64?
            if let context {
                for relative in tool.estimatePaths {
                    if let node = await context.index.node(path: context.home + "/" + relative) {
                        estimate = (estimate ?? 0) + node.knownSize(for: .allocated)
                    }
                }
            }
            found.append(Row(tool: tool, executable: executable, estimate: estimate))
        }
        rows = found
        showSheet = true
    }

    func run(_ row: Row) {
        guard !anyRunning else { return }
        states[row.id] = .running
        Task {
            let result = await runner.run(executable: row.executable, arguments: row.tool.arguments, timeout: .seconds(300))
            states[row.id] = .finished(result)
            if result.succeeded { didRun(row.tool.estimatePaths) }
        }
    }
}
