import Foundation
import Darwin

public enum FileIdentity {
    public static func read(_ url: URL) throws -> (identity: String, modified: Date, directory: Bool, link: Bool, links: UInt16, device: Int32, size: Int64, allocated: Int64, fingerprint: String, regular: Bool, dataless: Bool) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadNoPermission) }
        let kind = info.st_mode & S_IFMT
        return (identity(info),
                Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
                kind == S_IFDIR, kind == S_IFLNK, info.st_nlink, info.st_dev, info.st_size, Int64(info.st_blocks) * 512,
                fingerprint(info), kind == S_IFREG, isDataless(info))
    }

    static func identity(_ info: stat) -> String { "\(info.st_dev):\(info.st_ino)" }
    static func fingerprint(_ info: stat) -> String {
        "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_size):\(info.st_mode)"
    }
    static func isDataless(_ info: stat) -> Bool { info.st_flags & UInt32(SF_DATALESS) != 0 }
}
