import Foundation

public enum Suggestion: String, CaseIterable, Sendable, Identifiable {
    case large = "Large files", downloads = "Old downloads", archives = "Old archives & installers", caches = "User cache candidates"
    public var rule: CleanupRule {
        switch self { case .large: .large; case .downloads: .downloads; case .archives: .archives; case .caches: .userCaches }
    }
    public var id: String { rawValue }
    public var explanation: String {
        switch self {
        case .large: "Large does not mean unused. Review the file before removing it."
        case .downloads: "Downloads not modified recently may still be important."
        case .archives: "Older archives and installers may be replaceable. Verify you have another copy."
        case .caches: "Deleting application caches can disrupt applications. Close the related app first."
        }
    }
}
