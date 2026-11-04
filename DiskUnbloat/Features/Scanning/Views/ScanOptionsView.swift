import SwiftUI

struct ScanOptionsView: View {
    @Bindable var model: ScanViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan your way").font(.title3.weight(.semibold))
            Toggle("Include hidden files", isOn: $model.options.includeHidden)
            Toggle("Inspect package contents", isOn: $model.options.inspectPackages)
            Toggle("Cross mounted volumes", isOn: $model.options.crossVolumes)
            Stepper(value: $model.options.longUnusedDays, in: 1...3650) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Long-unused threshold")
                    Text(L10n.count("Not modified in %lld days", model.options.longUnusedDays))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("Defines which old simulators and local AI models the quick selection calls long-unused. No rescan is needed.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Exclude folders · one absolute path per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.exclusionText).font(.system(.caption, design: .monospaced)).frame(height: 75).border(.quaternary)
                .accessibilityIdentifier("excludedFolders")
            Text("Measure as one item · folder names or paths, one per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.summarizedText).font(.system(.caption, design: .monospaced)).frame(height: 60).border(.quaternary)
                .accessibilityIdentifier("summarizedFolders")
            Text("These folders, and packages unless their contents are inspected, are sized in one fast pass and shown as one tile; their files aren’t listed. Symbolic links aren’t followed; cloud files aren’t downloaded. Changes apply to the next scan.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 340)
    }
}
