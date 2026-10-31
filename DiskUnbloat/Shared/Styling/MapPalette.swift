import SwiftUI
import DiskCore

extension FileCategory {
    var color: Color {
        switch self {
        case .images: .teal
        case .video: .indigo
        case .audio: .pink
        case .documents: .blue
        case .archives: .orange
        case .applications: .purple
        case .development: .mint
        case .other: .gray
        }
    }
}
