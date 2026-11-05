import Foundation

/// Deterministic on-disk trees the real scanner reads. Every file is generated here,
/// inside the Testing profile, so destructive flows can never reach user data.
enum FixtureTrees {
    static let all = ["sample-home", "dense-map", "permission-wait"]

    /// Rebuilds `home` for `id`. File contents are seeded so equal seeds produce
    /// identical bytes (duplicate sets) and everything else differs.
    static func build(_ id: String, at home: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: home.path) { try fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        switch id {
        case "sample-home", "permission-wait": try sampleHome(home)
        case "dense-map": try denseMap(home)
        default: throw CocoaError(.fileNoSuchFile)
        }
    }

    private static func sampleHome(_ home: URL) throws {
        let mb = 1 << 20
        // Curated caches (Junk / Caches levels).
        try file(home, "Library/Caches/com.example.editor/Cache.db", 6 * mb, seed: 1)
        try file(home, "Library/Caches/com.example.browser/GPUCache/data_1", 4 * mb, seed: 2)
        try file(home, "Library/Caches/Homebrew/downloads/wget.bottle.tar.gz", 3 * mb, seed: 3)
        // Developer rebuildables.
        try file(home, "Library/Developer/Xcode/DerivedData/App-abc/Build/Products/App.o", 8 * mb, seed: 4)
        try file(home, "Projects/web/package.json", 1024, seed: 5)
        try file(home, "Projects/web/node_modules/left-pad/index.js", 2 * mb, seed: 6)
        try file(home, "Projects/web/node_modules/react/umd/react.js", 3 * mb, seed: 7)
        // Older app versions (Deep clean) — the newest survives.
        try file(home, "Library/Application Support/Blender/4.2/config/userpref.blend", 2 * mb, seed: 8, ageDays: 400)
        try file(home, "Library/Application Support/Blender/5.4/config/userpref.blend", 2 * mb, seed: 9)
        // Installers: one long unused (Deep), one recent (never selected).
        try file(home, "Downloads/OldTool.dmg", 5 * mb, seed: 10, ageDays: 300)
        try file(home, "Downloads/NewTool.dmg", 5 * mb, seed: 11)
        // Duplicate set: three identical copies with different ages and depths.
        try file(home, "Documents/Holiday.mov", 7 * mb, seed: 42, ageDays: 900)
        try file(home, "Downloads/Holiday copy.mov", 7 * mb, seed: 42, ageDays: 30)
        try file(home, "Desktop/Old stuff/Holiday.mov", 7 * mb, seed: 42, ageDays: 200)
        // Same size, different content: never a duplicate.
        try file(home, "Documents/Lookalike.mov", 7 * mb, seed: 43)
        // User documents of various ages.
        try file(home, "Documents/Report.pdf", 1 * mb, seed: 12, ageDays: 20)
        try file(home, "Documents/Archive/2019.zip", 4 * mb, seed: 13, ageDays: 2000)
        try file(home, "Pictures/Screenshot.png", 1 * mb, seed: 14, ageDays: 3)
        for (folder, days) in [("Library/Application Support/Blender/4.2/config", 400), ("Library/Application Support/Blender/4.2", 400),
                               ("Desktop/Old stuff", 200), ("Documents/Archive", 2000)] {
            try age(home, folder, days: days)
        }
    }

    private static func denseMap(_ home: URL) throws {
        for folder in 0..<40 {
            for item in 0..<150 {
                try file(home, "Dense/Folder \(folder)/Sub \(item % 6)/file-\(item).bin", 4096 * (1 + (folder * 7 + item) % 23), seed: UInt64(folder * 1000 + item))
            }
        }
    }

    private static func file(_ home: URL, _ relative: String, _ size: Int, seed: UInt64, ageDays: Int = 0) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var generator = seed &+ 0x9E37_79B9_7F4A_7C15
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for index in words.indices {
                generator ^= generator << 13; generator ^= generator >> 7; generator ^= generator << 17
                words[index] = generator
            }
        }
        try data.write(to: url)
        if ageDays > 0 { try age(home, relative, days: ageDays) }
    }

    /// Folder mtimes count toward "latest content modification", so folders that hold
    /// only old content are aged too (after their files were written).
    private static func age(_ home: URL, _ relative: String, days: Int) throws {
        let date = Date().addingTimeInterval(-Double(days) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: home.appendingPathComponent(relative).path)
    }
}
