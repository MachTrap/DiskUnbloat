import Foundation

/// Path-relationship helpers shared by scanning, cleanup, and authorization. All comparisons
/// operate on canonical absolute paths and treat `/` as an ancestor of every absolute path.
extension String {
    /// The immediate parent of an already canonical absolute path.
    var canonicalParentPath: String? {
        guard self != "/", let separator = lastIndex(of: "/") else { return nil }
        return separator == startIndex ? "/" : String(self[..<separator])
    }

    /// Whether this path is `other` or a descendant of it (whole-segment match, so
    /// `/Users/a` does not match `/Users/ab`). `/` matches every absolute path.
    public func isWithin(_ other: String) -> Bool {
        if other == "/" { return hasPrefix("/") }
        return self == other || hasPrefix(other + "/")
    }

    /// Whether either path is the other or a descendant of it.
    public func overlaps(_ other: String) -> Bool {
        isWithin(other) || other.isWithin(self)
    }

    /// BINARY sort-range bounds that select this path and every descendant: `[self/, self0)`.
    /// `/` maps to `["/", "0")` so the whole tree is covered.
    public var pathRange: (lower: String, upper: String) {
        self == "/" ? ("/", "0") : (self + "/", self + "0")
    }
}
