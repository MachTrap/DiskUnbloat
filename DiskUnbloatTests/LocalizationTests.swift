import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct LocalizationTests {
    @Test func catalogsContainRussianPluralFormsAndStablePaths() throws {
        let path = try #require(Bundle.main.path(forResource: "Localizable",ofType: "stringsdict",inDirectory: "ru.lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: data,format: nil) as? [String: Any])
        #expect(dictionary["%lld items"] != nil)
        let home = URL(fileURLWithPath: "/Users/localization")
        let catalog = LocationCatalog(home: home)
        #expect(catalog.targets.first { $0.id == "downloads" }?.url.lastPathComponent == "Downloads")
        #expect(catalog.additional.map(\.id) == ["Documents","Pictures"])
    }
}
