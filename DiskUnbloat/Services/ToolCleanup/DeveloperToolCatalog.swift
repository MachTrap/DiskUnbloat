import Foundation

/// A developer tool's own cleanup command. Running the tool is safer than deleting its
/// files: it knows what it can rebuild (Docker's disk image never shrinks when files
/// inside are deleted; simulators belong to `simctl`). Closed list, exact arguments.
struct DeveloperTool: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    /// Absolute paths checked in order; the tool is offered only when one exists.
    let executables: [String]
    let arguments: [String]
    /// Home-relative locations whose scanned size estimates what the command can free.
    let estimatePaths: [String]
    let explanation: String
    let warning: String?

    var commandLine: String { ([executables.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? id] + arguments).joined(separator: " ") }
}

enum DeveloperToolCatalog {
    static let all: [DeveloperTool] = [
        DeveloperTool(id: "brew", name: "Homebrew", executables: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
                      arguments: ["cleanup"], estimatePaths: ["Library/Caches/Homebrew"],
                      explanation: "Removes old versions of installed formulae and outdated downloads.", warning: nil),
        DeveloperTool(id: "simctl", name: "Xcode simulators", executables: ["/usr/bin/xcrun"],
                      arguments: ["simctl", "delete", "unavailable"], estimatePaths: [],
                      explanation: "Deletes simulators whose runtime is no longer installed.", warning: nil),
        DeveloperTool(id: "npm", name: "npm", executables: ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"],
                      arguments: ["cache", "clean", "--force"], estimatePaths: [".npm/_cacache"],
                      explanation: "Empties npm's download cache; packages download again when needed.", warning: nil),
        DeveloperTool(id: "pnpm", name: "pnpm", executables: ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"],
                      arguments: ["store", "prune"], estimatePaths: ["Library/pnpm/store"],
                      explanation: "Removes packages from pnpm's store that no project references.", warning: nil),
        DeveloperTool(id: "yarn", name: "Yarn", executables: ["/opt/homebrew/bin/yarn", "/usr/local/bin/yarn"],
                      arguments: ["cache", "clean"], estimatePaths: ["Library/Caches/Yarn"],
                      explanation: "Empties Yarn's package cache.", warning: nil),
        DeveloperTool(id: "docker", name: "Docker", executables: ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"],
                      arguments: ["system", "prune", "--force"], estimatePaths: [],
                      explanation: "Removes unused images, build cache and networks inside Docker.",
                      warning: "Also removes every stopped container. Docker must be running."),
    ]

    static func executable(for tool: DeveloperTool, exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        tool.executables.first(where: exists)
    }
}

struct ToolRunResult: Sendable, Equatable {
    let status: Int32
    let output: String
    var succeeded: Bool { status == 0 }
}

/// Runs one catalog command. No shell: a fixed executable and argument list, a minimal
/// environment, a timeout, and bounded output.
protocol ToolCommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: Duration) async -> ToolRunResult
}

struct ProcessToolRunner: ToolCommandRunning {
    func run(executable: String, arguments: [String], timeout: Duration) async -> ToolRunResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "HOMEBREW_NO_AUTO_UPDATE": "1",
            ]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { return ToolRunResult(status: -1, output: error.localizedDescription) }
            let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
            let deadline = ContinuousClock.now + timeout
            while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            let data = await reader.value
            let text = String(decoding: data.suffix(64 * 1024), as: UTF8.self)
            return ToolRunResult(status: process.terminationReason == .uncaughtSignal ? -2 : process.terminationStatus, output: text)
        }.value
    }
}
