import SwiftUI

struct ScanOptionsView: View {
    @Bindable var model: ScanViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan your way").font(.title3.weight(.semibold))
            Toggle("Include hidden files", isOn: $model.options.includeHidden)
            Toggle("Inspect package contents", isOn: $model.options.inspectPackages)
            Toggle("Cross mounted volumes", isOn: $model.options.crossVolumes)
            Text("Exclude folders · one absolute path per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.exclusionText).font(.system(.caption, design: .monospaced)).frame(height: 75).border(.quaternary)
            Text("Packages are counted even when shown as one tile. Symbolic links aren’t followed; cloud files aren’t downloaded.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 340)
    }
}
