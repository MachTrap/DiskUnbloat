import Foundation

enum SampleData {
    static func create() throws -> URL {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Sample Library", isDirectory: true)
        // Samples contain only generated data. Existing samples are reused, never overwrite user-selected locations.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries: [(String, Int)] = [("Creative/Film edit.mov", 8_000_000), ("Creative/Design assets.zip", 4_000_000), ("Creative/Podcast.wav", 2_000_000), ("Downloads/Old installer.dmg", 5_000_000), ("Downloads/Archive.zip", 3_000_000), ("Documents/Project notes.txt", 300_000), ("Documents/Research.pdf", 1_000_000), ("Pictures/Travel.heic", 2_000_000), (".hidden-example", 200_000)]
        for (name, bytes) in entries {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Deterministic nonzero content exercises actual allocated sizing.
            let data = Data((0..<min(bytes, 65536)).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 19) })
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            do { var remaining = bytes; while remaining > 0 { let chunk = data.prefix(min(remaining, data.count)); try handle.write(contentsOf: chunk); remaining -= chunk.count }; try handle.close() }
            catch { try? handle.close(); throw error }
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-220 * 86400)], ofItemAtPath: url.path)
        }
        return root
    }
}
