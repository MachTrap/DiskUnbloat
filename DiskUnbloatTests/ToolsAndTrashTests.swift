import Foundation
import Synchronization
import Testing
import DiskCore
@testable import DiskUnbloat

/// Developer tools run only their catalog command, only when installed; the cleanup
/// report says how much went to the Trash and never claims the space is free yet.
@MainActor struct ToolsAndTrashTests {
    final class RecordingRunner: ToolCommandRunning, @unchecked Sendable {
        let calls = Mutex<[[String]]>([])
        func run(executable: String, arguments: [String], timeout: Duration) async -> ToolRunResult {
            calls.withLock { $0.append([executable] + arguments) }
            return ToolRunResult(status: 0, output: "ok")
        }
    }

    @Test func onlyInstalledToolsAreOfferedAndTheirExactCommandRuns() async throws {
        let runner = RecordingRunner()
        let model = DeveloperToolsViewModel(runner: runner, exists: { $0 == "/opt/homebrew/bin/brew" || $0 == "/usr/bin/xcrun" })
        var rerun: [String] = []
        model.didRun = { rerun = $0 }
        await model.open()
        #expect(model.rows.map(\.id) == ["brew", "simctl"])
        model.run(try #require(model.rows.first))
        for _ in 0..<100 where model.anyRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(runner.calls.withLock { $0 } == [["/opt/homebrew/bin/brew", "cleanup"]])
        #expect(model.states["brew"] == .finished(ToolRunResult(status: 0, output: "ok")))
        #expect(rerun == ["Library/Caches/Homebrew"])
    }

    @Test func catalogCommandsAreFixedAndDockerWarns() {
        let docker = try! #require(DeveloperToolCatalog.all.first { $0.id == "docker" })
        #expect(docker.arguments == ["system", "prune", "--force"] && docker.warning != nil)
        #expect(DeveloperToolCatalog.all.allSatisfy { $0.executables.allSatisfy { $0.hasPrefix("/") } })
    }

    @Test func reportCountsBytesMovedToTrash() async throws {
        let cleanup = CleanupViewModel(service: SucceedingCleanupService(), homePath: "/Users/trash", activity: FixedActivity(paths: []))
        let index = try ScanIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite"))
        let a = FileNode(id: 2, parentID: 1, path: "/Users/trash/a.bin", name: "a.bin", isDirectory: false, logicalSize: 3000, allocatedSize: 4096, modified: Date(), identity: "a", knownLogicalSize: 3000, knownAllocatedSize: 4096)
        let entries = [CleanupEntry(node: a, operation: .remove)]
        _ = await cleanup.execute(entries, roots: [URL(fileURLWithPath: "/Users/trash")], index: index, mode: .trash)
        #expect(cleanup.lastRunMode == .trash && cleanup.lastRunBytes == 4096)
        await index.close()
    }
}
