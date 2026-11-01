import SwiftUI
import DiskCore

/// Per-item outcome report shown after a completed cleanup run. Kept separate from the
/// queue panel because a successful run returns the workspace to the location chooser.
struct CleanupReportView: View {
    let results: [CleanupResult]
    let done: () -> Void

    private var succeededCount: Int { results.filter(\.succeeded).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cleanup report").font(.title2.bold())
                    Text(L10n.count("%lld items processed", results.count)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: succeededCount == results.count ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(succeededCount == results.count ? Color.teal : Color.orange)
            }
            List(results) { result in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: result.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(L10n.text(result.message)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } icon: {
                    Image(systemName: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(result.succeeded ? Color.teal : Color.orange)
                }
            }.listStyle(.inset)
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
        .accessibilityIdentifier("cleanupReport")
    }
}
