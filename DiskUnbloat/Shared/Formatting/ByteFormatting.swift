import Foundation

func sizeText(_ bytes: Int64?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.text("Unknown") }
