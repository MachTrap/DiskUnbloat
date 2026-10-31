import Foundation

/// Stable domain identifiers; presentation owns their localized names and explanations.
public enum CleanupRule: String, CaseIterable, Identifiable, Sendable {
    case large, downloads, archives, userCaches, derivedData, swiftPM, npm, pip
    public var id: Self { self }
    public var isCache: Bool { [.userCaches, .derivedData, .swiftPM, .npm, .pip].contains(self) }
    public func root(relativeTo home: String) -> String? {
        switch self {
        case .userCaches: home + "/Library/Caches"
        case .derivedData: home + "/Library/Developer/Xcode/DerivedData"
        case .swiftPM: home + "/Library/Caches/org.swift.swiftpm"
        case .npm: home + "/.npm/_cacache"
        case .pip: home + "/Library/Caches/pip"
        case .downloads: home + "/Downloads"
        default: nil
        }
    }
}
