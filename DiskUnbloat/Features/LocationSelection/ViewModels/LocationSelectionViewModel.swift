import Foundation
import Observation

@MainActor @Observable final class LocationSelectionViewModel {
    let catalog: LocationCatalog
    var showOptions = false
    var dropTargeted = false
    init(catalog: LocationCatalog = LocationCatalog()) { self.catalog = catalog }
    func directory(from urls: [URL]) throws -> URL {
        guard urls.count == 1, let url = urls.first, url.isFileURL else { throw SelectionError.singleFolder }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SelectionError.singleFolder }
        return url
    }
    enum SelectionError: LocalizedError {
        case singleFolder
        var errorDescription: String? { L10n.text("Drop one folder or mounted disk to scan. Files and multiple locations aren’t supported.") }
    }
}
