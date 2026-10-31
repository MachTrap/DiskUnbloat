import DiskCore

extension MapEntry {
    var localizedTitle: String { node?.name ?? L10n.count("%lld more items", count) }
}
