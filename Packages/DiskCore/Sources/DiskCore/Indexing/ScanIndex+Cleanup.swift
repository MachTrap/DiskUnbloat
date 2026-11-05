import Foundation

extension ScanIndex {
    /// Takes both ends of each reviewed pair and their ancestry from one actor turn.
    func cleanupEvidence(for entries: [CleanupEntry]) -> (nodes: [String: FileNode], ancestors: [String: String]) {
        let paths = Set(entries.flatMap { [$0.node.path, $0.survivor?.path].compactMap { $0 } }).sorted()
        var nodes: [String: FileNode] = [:]
        for start in stride(from: 0, to: paths.count, by: 500) {
            let batch = Array(paths[start..<min(start + 500, paths.count)])
            let parameters = Array(repeating: "?", count: batch.count).joined(separator: ",")
            for node in read("SELECT * FROM nodes WHERE path IN (\(parameters))", strings: batch) {
                nodes[node.path] = node
            }
        }
        return (nodes, ancestorIdentities(for: nodes.values.map(\.id)))
    }

    public func cleanupAncestorIdentities(for entries: [CleanupEntry]) -> [String: String] {
        guard entries.contains(where: { $0.survivor != nil }) else {
            return ancestorIdentities(for: entries.map(\.node.id))
        }
        return cleanupEvidence(for: entries).ancestors
    }
}
