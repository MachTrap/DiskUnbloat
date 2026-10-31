import SwiftUI
import DiskCore

struct CategoryStatisticsView: View {
    let categories: [CategorySummary]
    @Binding var highlighted: FileCategory?
    private var total: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                ForEach(categories) { row in
                    Button { highlighted = highlighted == row.category ? nil : row.category } label: {
                        HStack(spacing: 12) {
                            Text(L10n.text(row.category.rawValue)).frame(width: 100, alignment: .leading)
                            GeometryReader { geometry in
                                Capsule().fill(row.category.color.opacity(0.15))
                                Capsule().fill(row.category.color).frame(width: geometry.size.width * (total > 0 ? Double(row.bytes) / Double(total) : 0))
                            }.frame(height: 7)
                            Text(total > 0 ? (Double(row.bytes)/Double(total)).formatted(.percent.precision(.fractionLength(1))) : "—").frame(width: 60, alignment: .trailing)
                            Text(sizeText(row.bytes)).monospacedDigit().frame(width: 85, alignment: .trailing)
                            Text("\(row.count) items").frame(width: 85, alignment: .trailing)
                            if row.unknown > 0 { Text("\(row.unknown) unknown").foregroundStyle(.orange) }
                        }.font(.caption).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(highlighted == row.category ? .isSelected : [])
                }
                Text("Percentages use known bytes only. Hard-link storage is counted once within the scan.").font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
        }.accessibilityIdentifier("categoryStatistics")
    }
}
