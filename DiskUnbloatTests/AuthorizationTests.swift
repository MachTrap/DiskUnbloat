import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct AuthorizationTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiskUnbloatAuthorization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func bookmarkFailureDoesNotRejectPickerSelection() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "DiskUnbloatAuthorizationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = StubBookmarkAccess(url: url)
        bookmarks.creationError = CocoaError(.fileReadUnknown)
        let store = AuthorizationStore(defaults: defaults, bookmarks: bookmarks)
        let selected = try store.acceptSelection(url)
        #expect(selected == url)
        let request = ScanRequest(root: selected)
        store.retainOnly(request.roots)
        #expect(bookmarks.stopped.isEmpty)
        // Scopes unrelated to the scan can be released mid-session.
        store.retainOnly([URL(fileURLWithPath: "/elsewhere")])
        #expect(bookmarks.stopped.contains(selected))
        await store.waitForPendingBookmark()
        #expect(store.bookmarkWarning != nil)
        #expect(store.locations.isEmpty)
        store.release()
        #expect(bookmarks.started.count == 1 && bookmarks.stopped.count == 1)
    }

    @Test func savedSelectionRestoresAndRefreshFailureRemainsUsable() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "DiskUnbloatAuthorizationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = StubBookmarkAccess(url: url)
        let first = AuthorizationStore(defaults: defaults, bookmarks: bookmarks)
        _ = try first.acceptSelection(url)
        await first.waitForPendingBookmark()
        #expect(first.locations.count == 1)
        first.release()
        let restored = AuthorizationStore(defaults: defaults, bookmarks: bookmarks)
        let saved = try #require(restored.locations.first)
        bookmarks.isStale = true
        bookmarks.creationError = CocoaError(.fileReadUnknown)
        #expect(try await restored.restore(saved) == url)
        await restored.waitForPendingBookmark()
        #expect(restored.bookmarkWarning != nil)
        restored.release()
        #expect(bookmarks.started.count == bookmarks.stopped.count)
    }

    @Test func revokedSavedScopeIsNotAccepted() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmarks = StubBookmarkAccess(url: url)
        bookmarks.canStart = false
        let store = AuthorizationStore(bookmarks: bookmarks)
        let location = SavedLocation(id: UUID(), name: url.path, bookmark: Data([1]))
        await #expect(throws: (any Error).self) { try await store.restore(location) }
        #expect(bookmarks.stopped.isEmpty)
    }
}
