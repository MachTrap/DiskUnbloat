import DiskCore

extension MapEntry {
    var localizedTitle: String {
        if kind == .unreached { return L10n.text("Not reached by the scan") }
        return node?.name ?? L10n.count("%lld more items", count)
    }
}
