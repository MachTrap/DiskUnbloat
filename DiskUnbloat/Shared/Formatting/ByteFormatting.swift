import Foundation

func sizeText(_ bytes: Int64?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.text("Unknown") }

/// A queue row's size readout: the selection-attributed size alone, or "selected/total"
/// through a slash when selection covers only part of the row's directory
/// (for example `5.2/50 GB`), so the panel shows at a glance how much of the folder the
/// queue would remove against the folder's whole on-disk size. A directory whose selected
/// subtree already equals its known total, and rows without a known total, render the
/// single size without a slash.
func queueRowSizeText(selected: Int64?, total: Int64?) -> String {
    guard let selected, let total, total != selected else { return sizeText(selected) }
    return sizeText(selected) + "/" + sizeText(total)
}
