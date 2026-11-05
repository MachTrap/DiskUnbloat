import Foundation
import Darwin
import UniformTypeIdentifiers

/// One directory entry as returned by `getattrlistbulk`: everything the scanner needs
/// from `lstat` plus the hidden/bundle/dataless flags, read in one syscall per buffer
/// instead of one `lstat` and one resource-value lookup per item.
struct BulkEntry {
    enum Kind { case file, directory, symlink, other }
    var name: String
    var kind: Kind
    var device: Int32
    var inode: UInt64
    var modified: timespec
    var changed: timespec
    /// `st_mode` equivalent: object-type bits plus the access mask.
    var mode: UInt32
    var flags: UInt32
    var finderFlags: UInt16
    var links: UInt32
    var size: Int64
    var allocated: Int64
    /// Per-entry error reported by the kernel (`ATTR_CMN_ERROR`); the other fields are
    /// unreliable when non-zero.
    var error: Int32

    var identity: String { "\(device):\(inode)" }
    /// Same layout as `FileIdentity.read`, so cleanup validation compares fingerprints
    /// recorded by the bulk reader against a later `lstat` byte for byte.
    var fingerprint: String { "\(changed.tv_sec):\(changed.tv_nsec):\(size):\(mode)" }
    var modificationDate: Date { Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9) }
    /// Hidden the way `FileManager`'s `.skipsHiddenFiles` treats it: dot-prefixed or `UF_HIDDEN`.
    var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 }
    /// iCloud/File Provider placeholder whose contents are not on disk; enumerating a
    /// dataless directory would ask the provider to materialize it.
    var isDataless: Bool { flags & 0x4000_0000 != 0 } // SF_DATALESS
    /// Finder's kHasBundle bit, which marks a folder as a package regardless of extension.
    var hasBundleBit: Bool { finderFlags & 0x2000 != 0 }
}

/// Reads whole directories through `getattrlistbulk(2)`. Not thread-safe: each scan
/// worker owns one reader and its buffer.
final class BulkDirectoryReader {
    private let buffer: UnsafeMutableRawPointer
    private let capacity = 256 * 1024
    // Attribute bits, spelled out so packing order is explicit (see getattrlist(2)).
    private static let common: attrgroup_t = 0x8000_0000 /* RETURNED_ATTRS */ | 0x2000_0000 /* ERROR */
        | 0x1 /* NAME */ | 0x2 /* DEVID */ | 0x8 /* OBJTYPE */ | 0x400 /* MODTIME */ | 0x800 /* CHGTIME */
        | 0x4000 /* FNDRINFO */ | 0x2_0000 /* ACCESSMASK */ | 0x4_0000 /* FLAGS */ | 0x200_0000 /* FILEID */
    private static let directory: attrgroup_t = 0x20 /* DATALENGTH, st_size of a directory */
    private static let file: attrgroup_t = 0x1 /* LINKCOUNT */ | 0x200 /* DATALENGTH */ | 0x400 /* DATAALLOCSIZE */

    init() { buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16) }
    deinit { buffer.deallocate() }

    /// Lists every entry of `path` (not recursive, symlinks are not followed). Throws a
    /// POSIX error when the directory itself cannot be opened or read.
    func read(_ path: String, _ body: (BulkEntry) -> Void) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = Self.common
        list.dirattr = Self.directory
        list.fileattr = Self.file
        while true {
            let count = getattrlistbulk(fd, &list, buffer, capacity, 0)
            if count == 0 { return }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                body(Self.parse(entry))
                entry += length
            }
        }
    }

    /// Lists `path` without ever requesting attributes of entries `skip` names: names come
    /// from `readdir`, every other entry is read with `getattrlist`. For folders that hold
    /// a protected store (Movies with the TV library, Library/Containers…), where touching
    /// the store's metadata alone can raise a consent dialog. Skipped entries carry only
    /// what `readdir` reports (name, inode, type) and a zero size.
    func readCarefully(_ path: String, skip: (_ name: String, _ isDirectory: Bool) -> Bool, _ body: (BulkEntry) -> Void) throws {
        guard let dir = opendir(path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(dir) }
        var parent = stat()
        let device = lstat(path, &parent) == 0 ? Int32(parent.st_dev) : 0
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // ATTR_CMN_ERROR is valid only for getattrlistbulk; per-path failures come from errno.
        list.commonattr = Self.common & ~0x2000_0000
        list.dirattr = Self.directory
        list.fileattr = Self.file
        while let item = readdir(dir) {
            let name = withUnsafePointer(to: item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let isDirectory = item.pointee.d_type == UInt8(DT_DIR)
            if skip(name, isDirectory) {
                body(BulkEntry(name: name, kind: isDirectory ? .directory : .other, device: device, inode: item.pointee.d_ino,
                               modified: timespec(), changed: timespec(), mode: isDirectory ? UInt32(S_IFDIR) : 0, flags: 0,
                               finderFlags: 0, links: 1, size: 0, allocated: 0, error: 0))
                continue
            }
            let full = path == "/" ? "/" + name : path + "/" + name
            if getattrlist(full, &list, buffer, capacity, UInt32(FSOPT_NOFOLLOW)) == 0 {
                var entry = Self.parse(buffer)
                entry.name = name
                body(entry)
            } else {
                body(BulkEntry(name: name, kind: .other, device: device, inode: item.pointee.d_ino, modified: timespec(), changed: timespec(),
                               mode: 0, flags: 0, finderFlags: 0, links: 1, size: 0, allocated: 0, error: errno))
            }
        }
    }

    private static func parse(_ start: UnsafeMutableRawPointer) -> BulkEntry {
        var cursor = start + 4
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size
        var result = BulkEntry(name: "", kind: .other, device: 0, inode: 0, modified: timespec(), changed: timespec(), mode: 0, flags: 0, finderFlags: 0, links: 1, size: 0, allocated: 0, error: 0)
        let c = returned.commonattr
        // ATTR_CMN_ERROR is packed immediately after the returned-attributes set.
        if c & 0x2000_0000 != 0 { result.error = Int32(bitPattern: cursor.loadUnaligned(as: UInt32.self)); cursor += 4 }
        if c & 0x1 != 0 {
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            let namePointer = (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            result.name = String(cString: namePointer)
            cursor += MemoryLayout<attrreference_t>.size
        }
        if c & 0x2 != 0 { result.device = cursor.loadUnaligned(as: Int32.self); cursor += 4 }
        var typeBits: UInt32 = 0
        if c & 0x8 != 0 {
            switch cursor.loadUnaligned(as: UInt32.self) {
            case 1: result.kind = .file; typeBits = UInt32(S_IFREG)
            case 2: result.kind = .directory; typeBits = UInt32(S_IFDIR)
            case 5: result.kind = .symlink; typeBits = UInt32(S_IFLNK)
            case 3: typeBits = UInt32(S_IFBLK)
            case 4: typeBits = UInt32(S_IFCHR)
            case 6: typeBits = UInt32(S_IFSOCK)
            case 7: typeBits = UInt32(S_IFIFO)
            default: break
            }
            cursor += 4
        }
        if c & 0x400 != 0 { result.modified = cursor.loadUnaligned(as: timespec.self); cursor += MemoryLayout<timespec>.size }
        if c & 0x800 != 0 { result.changed = cursor.loadUnaligned(as: timespec.self); cursor += MemoryLayout<timespec>.size }
        if c & 0x4000 != 0 {
            // FileInfo and FolderInfo both keep finderFlags (big-endian) at byte 8.
            result.finderFlags = UInt16(bigEndian: (cursor + 8).loadUnaligned(as: UInt16.self))
            cursor += 32
        }
        if c & 0x2_0000 != 0 { result.mode = typeBits | (cursor.loadUnaligned(as: UInt32.self) & 0o7777); cursor += 4 }
        if c & 0x4_0000 != 0 { result.flags = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }
        if c & 0x200_0000 != 0 { result.inode = cursor.loadUnaligned(as: UInt64.self); cursor += 8 }
        if returned.dirattr & 0x20 != 0 { result.size = cursor.loadUnaligned(as: Int64.self); cursor += 8 }
        let f = returned.fileattr
        if f & 0x1 != 0 { result.links = cursor.loadUnaligned(as: UInt32.self); cursor += 4 }
        if f & 0x200 != 0 { result.size = cursor.loadUnaligned(as: Int64.self); cursor += 8 }
        if f & 0x400 != 0 { result.allocated = cursor.loadUnaligned(as: Int64.self); cursor += 8 }
        return result
    }
}

/// Decides whether a directory is a package the way `URLResourceKey.isPackageKey` does:
/// the Finder bundle bit, or a filename extension declared as a package type. Lookups
/// are cached per extension; each scan worker owns its own detector.
final class PackageDetector {
    private var cache: [String: Bool] = [:]
    func isPackage(name: String, bundleBit: Bool) -> Bool {
        if bundleBit { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty else { return false }
        if let known = cache[ext] { return known }
        let declared = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
            .contains { !$0.isDynamic && $0.conforms(to: .package) }
        cache[ext] = declared
        return declared
    }
}
