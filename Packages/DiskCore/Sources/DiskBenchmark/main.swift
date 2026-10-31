import Foundation
import Darwin
import DiskCore
import CoreGraphics

@main struct DiskBenchmark {
    static func main() async throws {
        let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1_000_000
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiskBenchmark-" + UUID().uuidString + ".sqlite")
        let index = try ScanIndex(url: url)
        let start = ContinuousClock.now
        let root = FileNode(id: 1, parentID: nil, path: "/benchmark", name: "benchmark", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: nil, identity: "root")
        try await index.insert([root])
        for batch in stride(from: 0, to: count, by: 512) {
            let nodes: [FileNode] = (batch..<min(batch + 512, count)).map { i in
                let bytes = Int64((i % 10000 + 1) * 4096)
                return FileNode(id: Int64(i + 2), parentID: 1, path: "/benchmark/file-\(i).bin", name: "file-\(i).bin", isDirectory: false, logicalSize: bytes, allocatedSize: bytes, modified: Date(timeIntervalSince1970: 1700000000), identity: "node-\(i)")
            }
            try await index.insert(nodes)
        }
        let inserted = ContinuousClock.now
        try await index.aggregate()
        let aggregated = ContinuousClock.now
        var query = FileQuery(); query.parentID = 1
        let rows = await index.query(query)
        let queried = ContinuousClock.now
        var analysis = FileQuery(); analysis.leafResults = true; analysis.subtreePath = "/benchmark"; analysis.limit = 250; analysis.knownSizesOnly = true
        let largest = await index.query(analysis)
        let ranked = ContinuousClock.now
        let categories = await index.categorySummaries(analysis)
        let analyzed = ContinuousClock.now
        let scene = await index.mapScene(rootID: 1, query: query, filtered: false)
        let sceneBuilt = ContinuousClock.now
        var tileCount = 0
        for _ in 0..<100 { tileCount = NestedTreemap.layoutSync(scene, in: CGRect(x: 0,y: 0,width: 1200,height: 650)).count }
        let laidOut = ContinuousClock.now
        print("Entries: \(count), browser rows: \(rows.count), scene entries: \(scene.entries.count), rendered tiles: \(tileCount)")
        print("Represented items: \(scene.summary.itemCount); known bytes: \(scene.summary.knownBytes)")
        print("Insert: \(start.duration(to: inserted)); aggregate: \(inserted.duration(to: aggregated)); query: \(aggregated.duration(to: queried)); scene: \(analyzed.duration(to: sceneBuilt)); 100 layouts: \(sceneBuilt.duration(to: laidOut))")
        await index.close()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        print("Largest rows: \(largest.count); ranking: \(queried.duration(to: ranked)); category entries: \(categories.reduce(0) { $0 + $1.count }); category query: \(ranked.duration(to: analyzed))")
        print("Database bytes: \(size)")
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { print("Peak resident bytes: \(usage.ru_maxrss)") }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}
