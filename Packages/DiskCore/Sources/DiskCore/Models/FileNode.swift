import Foundation

public enum SizeMetric: String, Sendable, CaseIterable, Identifiable {
    case allocated = "On disk", logical = "Logical"
    public var id: Self { self }
}
public struct FileNode: Identifiable, Sendable, Codable, Hashable {
    public let id: Int64
    public let parentID: Int64?
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let logicalSize: Int64?
    public let allocatedSize: Int64?
    public let modified: Date?
    public let latestContentModification: Date?
    public let unknownModificationCount: Int
    public let identity: String
    public let fingerprint: String?
    public let knownLogicalSize: Int64
    public let knownAllocatedSize: Int64
    public let unknownLogicalCount: Int
    public let unknownAllocatedCount: Int
    public var category: FileCategory { .classify(path) }
    public func knownSize(for metric: SizeMetric) -> Int64 { metric == .allocated ? knownAllocatedSize : knownLogicalSize }
    public func unknownCount(for metric: SizeMetric) -> Int { metric == .allocated ? unknownAllocatedCount : unknownLogicalCount }
    public let packageAncestor: Bool
    public var url: URL { URL(fileURLWithPath: path) }
    public var displaySize: Int64 { allocatedSize ?? 0 }
    public func size(for metric: SizeMetric) -> Int64? { metric == .allocated ? allocatedSize : logicalSize }
    public init(id: Int64, parentID: Int64?, path: String, name: String, isDirectory: Bool, isPackage: Bool = false, isSymbolicLink: Bool = false, logicalSize: Int64?, allocatedSize: Int64?, modified: Date?, identity: String, fingerprint: String? = nil, packageAncestor: Bool = false, knownLogicalSize: Int64? = nil, knownAllocatedSize: Int64? = nil, unknownLogicalCount: Int? = nil, unknownAllocatedCount: Int? = nil, latestContentModification: Date? = nil, unknownModificationCount: Int? = nil) {
        self.latestContentModification = latestContentModification ?? modified
        self.unknownModificationCount = unknownModificationCount ?? (modified == nil ? 1 : 0)
        self.knownLogicalSize = knownLogicalSize ?? logicalSize ?? 0
        self.knownAllocatedSize = knownAllocatedSize ?? allocatedSize ?? 0
        self.unknownLogicalCount = unknownLogicalCount ?? (logicalSize == nil ? 1 : 0)
        self.unknownAllocatedCount = unknownAllocatedCount ?? (allocatedSize == nil ? 1 : 0)
        self.id = id; self.parentID = parentID; self.path = path; self.name = name; self.isDirectory = isDirectory; self.isPackage = isPackage; self.isSymbolicLink = isSymbolicLink; self.logicalSize = logicalSize; self.allocatedSize = allocatedSize; self.modified = modified; self.identity = identity; self.fingerprint = fingerprint; self.packageAncestor = packageAncestor
    }
}
