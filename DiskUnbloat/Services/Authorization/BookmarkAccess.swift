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

    // The app runs unsandboxed (a disk-measurement utility cannot read other applications'
    // app data through the App Sandbox on macOS 27 — the sandbox denies every read before
    // TCC can ask). Bookmarks therefore do not carry security scope; they only remember the
    // chosen path across launches. Scoped bookmark data saved by earlier sandboxed builds
    // is still resolved through the scope option first, then falls back to a plain resolve
    // so upgrade-migrated locations keep working.

    func makeBookmark(for url: URL) async throws -> Data {
        // ScopedBookmarksAgent can stall; never block the main actor or delay starting a scan.
        try await withCheckedThrowingContinuation { continuation in
            Self.creationQueue.async {
                do {
                    let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
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
                    let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                    continuation.resume(returning: ResolvedBookmark(url: url, isStale: stale))
                } catch {
                    // Legacy sandbox-era bookmark: retry through the scope option, which the
                    // unsandboxed host ignores for the path lookup but the data itself needs.
                    do {
                        var stale = false
                        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                        continuation.resume(returning: ResolvedBookmark(url: url, isStale: stale))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// Start-and-stop pairs are sandbox mechanics; without a sandbox they are no-ops, so
    /// activation always reports success and the real access question belongs to TCC, whose
    /// consents (and Full Disk Access) decide whether enumerations and prompts succeed.
    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
        return true
    }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}
