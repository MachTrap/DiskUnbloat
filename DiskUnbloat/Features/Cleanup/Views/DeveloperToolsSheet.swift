import SwiftUI
import DiskCore

/// Developer tools that clean up after themselves. Each row shows the exact command;
/// running it needs a confirmation that repeats the command and any warning.
struct DeveloperToolsSheet: View {
    @Bindable var model: DeveloperToolsViewModel
    @State private var pending: DeveloperToolsViewModel.Row?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Developer tools").font(.title2.bold())
                Text("These tools clean their own caches. Running the tool is safer than deleting its files.")
                    .foregroundStyle(.secondary)
            }
            if model.rows.isEmpty {
                ContentUnavailableView("No supported tools found", systemImage: "hammer",
                                       description: Text("Homebrew, Xcode simulators, npm, pnpm, Yarn and Docker are detected in their standard install locations."))
            } else {
                List(model.rows) { row in rowView(row) }.listStyle(.inset)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 600, height: 520)
        .alert(pending.map { L10n.format("Run “%@”?", $0.tool.commandLine) } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(L10n.text("Run")) { if let pending { model.run(pending) }; pending = nil }
            Button(L10n.text("Cancel"), role: .cancel) { pending = nil }
        } message: {
            if let pending { Text(L10n.text(pending.tool.explanation) + (pending.tool.warning.map { "\n\n" + L10n.text($0) } ?? "")) }
        }
        .accessibilityIdentifier("developerTools")
    }

    private func rowView(_ row: DeveloperToolsViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.tool.name).font(.headline)
                if let estimate = row.estimate, estimate > 0 {
                    Text(L10n.format("%@ in its cache", sizeText(estimate))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch model.states[row.id] ?? .idle {
                case .running: ProgressView().controlSize(.small)
                default:
                    Button(L10n.text("Run…")) { pending = row }.disabled(model.anyRunning)
                        .accessibilityIdentifier("runTool." + row.id)
                }
            }
            Text(L10n.text(row.tool.explanation)).font(.caption).foregroundStyle(.secondary)
            if let warning = row.tool.warning { Label(L10n.text(warning), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Text(row.tool.commandLine).font(.caption.monospaced()).textSelection(.enabled)
                .padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 4))
            if case .finished(let result) = model.states[row.id] {
                DisclosureGroup {
                    ScrollView { Text(result.output.isEmpty ? L10n.text("No output.") : result.output).font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 120)
                } label: {
                    Label(result.succeeded ? L10n.text("Finished") : L10n.format("Failed (exit %lld)", Int(result.status)),
                          systemImage: result.succeeded ? "checkmark.circle" : "xmark.octagon")
                        .font(.caption).foregroundStyle(result.succeeded ? Color.teal : .orange)
                }
            }
        }.padding(.vertical, 4)
    }
}
