import Foundation

public enum FileCategory: String, Sendable, CaseIterable, Identifiable, Codable {
    case images = "Images", video = "Video", audio = "Audio", documents = "Documents"
    case archives = "Archives", applications = "Apps", development = "Development", other = "Other"
    public var id: Self { self }
    public static func classify(_ path: String) -> Self {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "svg", "raw": return .images
        case "mov", "mp4", "mkv", "avi", "m4v", "webm": return .video
        case "mp3", "m4a", "wav", "aiff", "flac", "ogg": return .audio
        case "pdf", "txt", "md", "docx", "pages", "xlsx", "numbers", "pptx", "key", "rtf": return .documents
        case "zip", "gz", "tar", "7z", "rar", "dmg", "pkg", "xip", "iso": return .archives
        case "app": return .applications
        case "swift", "js", "ts", "tsx", "py", "rs", "c", "h", "cpp", "json", "o", "a", "framework", "xcodeproj", "build": return .development
        default: return .other
        }
    }
}
public struct SizeSummary: Sendable, Equatable {
    public let knownBytes: Int64
    public let itemCount: Int
    public let unknownCount: Int
    public init(knownBytes: Int64 = 0, itemCount: Int = 0, unknownCount: Int = 0) {
        self.knownBytes = knownBytes; self.itemCount = itemCount; self.unknownCount = unknownCount
    }
}
