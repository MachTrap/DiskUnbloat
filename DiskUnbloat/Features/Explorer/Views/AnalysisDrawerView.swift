import SwiftUI
import DiskCore

struct AnalysisDrawerView: View {
    @Bindable var model: ExplorerViewModel
    let canClean: Bool
    let preview: (FileNode) -> Void
    let reveal: (FileNode) -> Void
    let addToBasket: (FileNode) -> Void
    let refreshFolder: (FileNode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.drawerTab != .files {
                HStack {
                    Picker("Scope", selection: $model.scope) {
                        ForEach(ExplorerScope.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 310)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 5)
            }
            if model.drawerTab == .types {
                CategoryStatisticsView(categories: model.categories, highlighted: $model.highlightedCategory)
            } else {
                if model.drawerTab == .candidates { candidateControls }
                if model.drawerTab == .largest {
                    Text("Unknown sizes are excluded from this ranking.").font(.caption2).foregroundStyle(.secondary).padding(.top, 5)
                }
                FileTable(model: model, canClean: canClean, preview: preview, reveal: reveal, addToBasket: addToBasket, refreshFolder: refreshFolder)
                pagination
            }
        }
    }

    private var pagination: some View {
        HStack {
            Text("\(model.totalRows.formatted()) items · page \(model.page + 1) of \(model.pageCount)").foregroundStyle(.secondary)
            Spacer()
            Button { model.changePage(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(model.page == 0).help("Previous page")
            Button { model.changePage(1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.page + 1 >= model.pageCount).help("Next page")
        }.font(.caption).padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var candidateControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Picker("Rule", selection: $model.candidateRule) {
                    ForEach(CleanupRule.allCases) { Text($0.title).tag($0) }
                }.frame(maxWidth: 260)
                Spacer()
                Text(model.candidateRule == .large
                     ? L10n.format("Threshold: %@ GB on disk", model.largeThresholdGB.formatted())
                     : L10n.count("Older than %lld days", model.candidateAgeDays)).font(.caption)
            }
            Text(model.candidateRule.explanation).font(.caption).foregroundStyle(.secondary)
            if let selected = model.selected, let date = selected.latestContentModification {
                HStack {
                    Text(selected.path).lineLimit(1).truncationMode(.middle)
                    Text("Latest content modification")
                    Text(date, format: .dateTime.year().month(.abbreviated).day())
                    Text(sizeText(selected.size(for: model.metric)))
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Text("Protected locations, incomplete metadata, and caches of identified running applications are excluded. Other application/tool activity may be unverified. Nothing is selected for removal.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 7)
    }
}
