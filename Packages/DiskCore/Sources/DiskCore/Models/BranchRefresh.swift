import Foundation

public struct BranchRefreshRequest: Sendable {
    public let nodeID: Int64
    public let identity: String
    public init(nodeID: Int64, identity: String) { self.nodeID = nodeID; self.identity = identity }
}
public struct BranchRefreshResult: Sendable {
    public let rootID: Int64
    public let revision: UInt64
}
public enum RefreshError: LocalizedError {
    case changedFolder
    public var errorDescription: String? { "The folder or its ancestry changed. Scan the location again before refreshing." }
}
public struct CategorySummary: Identifiable, Sendable, Equatable {
    public var id: FileCategory { category }
    public let category: FileCategory
    public let bytes: Int64
    public let count: Int
    public let unknown: Int
    public init(category: FileCategory, bytes: Int64, count: Int, unknown: Int) { self.category = category; self.bytes = bytes; self.count = count; self.unknown = unknown }
}
