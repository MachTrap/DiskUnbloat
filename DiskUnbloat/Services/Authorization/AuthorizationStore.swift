import Foundation
import AppKit
import Observation
import OSLog
import DiskCore

struct SavedLocation: Identifiable, Codable {
    var id: UUID
    var name: String
    var bookmark: Data
}

@MainActor @Observable final class AuthorizationStore {
    private(set) var locations: [SavedLocation] = []
    private(set) var bookmarkWarning: String?
    @ObservationIgnored private var rememberingTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bookmarks: any BookmarkAccessing
    @ObservationIgnored private let logger = Logger(subsystem: "com.diskunbloat.app", category: "Authorization")
    private var active: [URL] = []

    init(defaults: UserDefaults = .standard, bookmarks: any BookmarkAccessing = SystemBookmarkAccess()) {
        self.defaults = defaults
        self.bookmarks = bookmarks
        if let data = defaults.data(forKey: "locations"), let saved = try? JSONDecoder().decode([SavedLocation].self, from: data) {
            locations = saved
        }
    }

    /// Presents the folder picker for authorization. Replaceable so authorization flows can be
    /// verified without presenting UI; the default opens a system open panel.
    @ObservationIgnored var panelProvider: @MainActor (URL?, String?) throws -> URL? = AuthorizationStore.openPanel

    func choose(suggestedLocation: URL? = nil, message: (String)? = nil) throws -> URL? {
        guard let url = try panelProvider(suggestedLocation, message) else { return nil }
        return try acceptSelection(url)
    }

    private static func openPanel(suggestedLocation: URL?, message: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = L10n.text("Choose location")
        panel.directoryURL = suggestedLocation
        if let suggestedLocation { panel.message = message ?? L10n.format("Authorize %@, or choose another folder if it isn’t available.", suggestedLocation.path) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// The picker grants access for this session. Persisting it for a later launch is optional.
    /// Keep this exact URL, including its security-scope association, through scan setup.
    func acceptSelection(_ url: URL) throws -> URL {
        bookmarkWarning = nil
        try activateAndValidate(url, requiresExplicitScope: false)
        remember(url)
        return url
    }

    func restore(_ location: SavedLocation) async throws -> URL {
        bookmarkWarning = nil
        let resolved = try await bookmarks.resolve(location.bookmark)
        try Task.checkCancellation()
        try activateAndValidate(resolved.url, requiresExplicitScope: true)
        if resolved.isStale { remember(resolved.url) }
        return resolved.url
    }

    private func remember(_ url: URL) {
        rememberingTask?.cancel()
        rememberingTask = Task {
            do {
                let data = try await bookmarks.makeBookmark(for: url)
                guard !Task.isCancelled else { return }
                let id = locations.first { $0.name == url.path }?.id ?? UUID()
                locations.removeAll { $0.name == url.path }
                locations.insert(SavedLocation(id: id, name: url.path, bookmark: data), at: 0)
                locations = Array(locations.prefix(10))
                persist()
            } catch {
                guard !Task.isCancelled else { return }
                reportBookmarkFailure(error)
            }
        }
    }

    func waitForPendingBookmark() async { await rememberingTask?.value }

    private func activateAndValidate(_ url: URL, requiresExplicitScope: Bool) throws {
        let alreadyActive = active.contains(url)
        let started = !alreadyActive && bookmarks.startAccessing(url)
        if requiresExplicitScope && !alreadyActive && !started {
            throw CocoaError(.fileReadNoPermission)
        }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if started { active.append(url) }
        } catch {
            if started { bookmarks.stopAccessing(url) }
            throw error
        }
    }

    private func reportBookmarkFailure(_ error: Error) {
        bookmarkWarning = L10n.text("This folder can be scanned now, but macOS couldn’t remember access for next time. Choose it again after restarting the app.")
        logger.error("Unable to save security-scoped bookmark: \(error.diagnosticDescription, privacy: .public)")
    }

    /// Derive a child URL from a live grant without replacing the granted root's token.
    func authorizedURL(for target: URL) -> URL? {
        for grant in active where target.path.isWithin(grant.path) {
            if target.path == grant.path { return grant }
            return grant.appendingPathComponent(String(target.path.dropFirst(grant.path.count + 1)))
        }
        return nil
    }

    /// The most specific stored grant that reaches every URL, preferring narrow covering
    /// bookmarks over broad ones (the home grant restores reliably; a volume-root grant
    /// such as `/` may resolve but does not extend the sandbox into protected home data).
    func coveringLocation(for urls: [URL]) -> SavedLocation? {
        let paths = urls.map { canonicalURL($0).path }
        return locations
            .filter { saved in paths.allSatisfy { $0.isWithin(saved.name) } && FileManager.default.fileExists(atPath: saved.name) }
            .max { $0.name.count < $1.name.count }
    }

    /// Keep every grant the scan scope depends on: grants of the scanned locations themselves
    /// and any ancestor grant (e.g. home) that reaches grouped scan locations. Grouped quick
    /// actions derive child scan roots through `authorizedURL(for:)`, so the live grant is an
    /// ancestor of every requested URL — stopping it here would strip the scan's only access.
    func retainOnly(_ urls: [URL]) {
        let kept = urls.map(canonicalURL)
        func covers(_ item: URL) -> Bool {
            // Both sides go through realpath, so /var aliases of /private/var paths still
            // cover their grants.
            let path = canonicalURL(item).path
            return kept.contains { $0.path.overlaps(path) }
        }
        for item in active where !covers(item) { bookmarks.stopAccessing(item) }
        active.removeAll { !covers($0) }
    }

    func release() {
        rememberingTask?.cancel()
        active.forEach { bookmarks.stopAccessing($0) }
        active = []
    }

    private func persist() { defaults.set(try? JSONEncoder().encode(locations), forKey: "locations") }
}

extension Error {
    /// Includes the failing API's error identity instead of hiding it behind a generic Cocoa message.
    var diagnosticDescription: String {
        let error = self as NSError
        var description = "\(error.localizedDescription) (\(error.domain), code \(error.code))"
        if let reason = error.localizedFailureReason { description += " \(reason)" }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            description += " Underlying: \(underlying.localizedDescription) (\(underlying.domain), code \(underlying.code))."
        }
        return description
    }
}
