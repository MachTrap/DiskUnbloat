import Foundation

/// One explicit cache location and how its deletion candidates are derived from it.
public struct CleanupRoot: Sendable, Equatable {
    public enum Candidate: Sendable {
        /// The cache location folder itself is the candidate.
        case rootItself
        /// Direct children of the location are candidates (default).
        case children
        /// Direct children are candidates, except the most recently used one.
        case childrenKeepingNewest
    }
    public let path: String
    public let candidate: Candidate
    public init(path: String, candidate: Candidate = .children) { self.path = path; self.candidate = candidate }
}

/// Stable domain identifiers; presentation owns their localized names and explanations.
public enum CleanupRule: String, CaseIterable, Identifiable, Sendable {
    case large, downloads, archives, userCaches, derivedData, swiftPM, npm, pip, regenerable
    public var id: Self { self }
    public var isCache: Bool { [.userCaches, .derivedData, .swiftPM, .npm, .pip].contains(self) }
    public func root(relativeTo home: String) -> String? { roots(relativeTo: home).first?.path }
    /// Curated exact locations, home-relative. Multiple roots are combined with OR.
    public func roots(relativeTo home: String) -> [CleanupRoot] {
        switch self {
        case .userCaches: [
            .init(path: home + "/Library/Caches"),
            .init(path: home + "/Library/Application Support/Unreal Tournament/Cache", candidate: .rootItself),
            .init(path: home + "/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", candidate: .rootItself),
            .init(path: home + "/Library/Application Support/Code - Insiders/WebStorage", candidate: .rootItself),
            .init(path: home + "/Library/Application Support/Code - Insiders/agent-host/sdk-cache", candidate: .rootItself),
            .init(path: home + "/Library/Application Support/Code - Insiders/CachedExtensionVSIXs", candidate: .rootItself),
            .init(path: home + "/Library/Developer/Xcode/DerivedData"),
            .init(path: home + "/Library/Developer/Xcode/iOS DeviceSupport", candidate: .childrenKeepingNewest),
            .init(path: home + "/Library/Developer/CoreSimulator/Devices", candidate: .childrenKeepingNewest),
            .init(path: home + "/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", candidate: .rootItself),
            .init(path: home + "/.cache/uv", candidate: .rootItself),
            .init(path: home + "/.gradle/caches", candidate: .rootItself),
            .init(path: home + "/.npm/_cacache")
        ]
        case .derivedData: [.init(path: home + "/Library/Developer/Xcode/DerivedData")]
        case .swiftPM: [.init(path: home + "/Library/Caches/org.swift.swiftpm")]
        case .npm: [.init(path: home + "/.npm/_cacache")]
        case .pip: [.init(path: home + "/Library/Caches/pip")]
        case .downloads: [.init(path: home + "/Downloads")]
        default: []
        }
    }
    /// Directory names whose contents tools can usually rebuild or download again.
    public static let regenerableNames: [String] = ["node_modules", "Pods", "DerivedData", ".cache", ".artifacts", ".build", ".build-cache"]
    /// Prefixes matching regenerable directories such as `.derivedData-mapcheck`.
    public static let regenerableNamePrefixes: [String] = [".derivedData"]
    public static func isRegenerableName(_ name: String) -> Bool {
        regenerableNames.contains(name) || regenerableNamePrefixes.contains { name.hasPrefix($0) }
    }
}
