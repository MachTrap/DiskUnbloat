enum MapLabelDetail: String, CaseIterable, Decodable {
    case compact, balanced, detailed

    var title: String {
        switch self {
        case .compact: L10n.text("Compact")
        case .balanced: L10n.text("Balanced")
        case .detailed: L10n.text("Detailed")
        }
    }
}
