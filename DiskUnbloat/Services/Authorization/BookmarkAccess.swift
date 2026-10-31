import Foundation

struct ResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

/// Separates macOS bookmark/scoping APIs from the location-selection policy.
@MainActor protocol BookmarkAccessing {
    func makeBookmark(for url: URL) async throws -> Data
    func resolve(_ data: Data) async throws -> ResolvedBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

@MainActor struct SystemBookmarkAccess: BookmarkAccessing {
    private static let creationQueue = DispatchQueue(label: "DiskUnbloat.bookmarks", qos: .utility)

    func makeBookmark(for url: URL) async throws -> Data {
        // ScopedBookmarksAgent can stall; never block the main actor or delay starting a scan.
        try await withCheckedThrowingContinuation { continuation in
            Self.creationQueue.async {
                do {
                    let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func resolve(_ data: Data) async throws -> ResolvedBookmark {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                    continuation.resume(returning: ResolvedBookmark(url: url, isStale: stale))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}
