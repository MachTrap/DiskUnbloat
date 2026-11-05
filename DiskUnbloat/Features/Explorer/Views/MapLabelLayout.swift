import SwiftUI
import DiskCore

/// Fits Canvas text into a leaf or into the reserved header of an expanded folder.
enum MapLabelLayout {
    private static let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    fileprivate struct Policy {
        let detail: MapLabelDetail
        let headerHeight: CGFloat

        var titleLines: Int {
            switch detail {
            case .compact: 1
            case .balanced: 2
            case .detailed: headerHeight > 0 ? 2 : 3
            }
        }

        var fontSize: CGFloat {
            switch detail {
            case .compact: headerHeight > 0 ? 11 : 12
            case .balanced: 11
            case .detailed: headerHeight > 0 ? 9 : 10
            }
        }

        func band(in rect: CGRect) -> CGRect? {
            guard MapMorph.drawable(rect) else { return nil }
            let height = headerHeight > 0 ? min(rect.height, headerHeight) : rect.height
            let side: CGFloat
            let top: CGFloat
            let bottom: CGFloat
            switch detail {
            case .compact:
                guard rect.width > 62, height > 23 else { return nil }
                side = 9
                top = 5
                bottom = 2
            case .balanced:
                guard rect.width >= 48, height >= 20 else { return nil }
                side = headerHeight > 0 ? 6 : 5
                top = headerHeight > 0 ? 2 : 3
                bottom = top
            case .detailed:
                guard rect.width >= 32, height >= 16 else { return nil }
                side = headerHeight > 0 ? 5 : 3
                top = headerHeight > 0 ? 1 : 1.5
                bottom = top
            }
            return CGRect(x: rect.minX + side, y: rect.minY + top,
                          width: rect.width - 2 * side, height: height - top - bottom)
        }
    }

    struct Block {
        let text: GraphicsContext.ResolvedText
        let extent: CGSize
        let offset: CGFloat
    }

    struct Plan {
        fileprivate let policy: Policy
        let width: CGFloat
        let title: Block
        let metadata: Block?

        func fits(in rect: CGRect) -> Bool {
            guard let band = policy.band(in: rect) else { return false }
            return titleFits(in: band)
        }

        private func titleFits(in band: CGRect) -> Bool {
            title.extent.width <= band.width && title.extent.height <= band.height
        }

        func draw(in rect: CGRect, clippedTo tilePath: Path, context base: GraphicsContext) {
            guard let band = policy.band(in: rect), titleFits(in: band) else { return }
            var context = base
            context.clip(to: tilePath)
            context.clip(to: Path(band))
            // Use the measured proposal width to keep line breaks stable during motion.
            // In RTL the proposal starts on the right side of the available band.
            let x = context.environment.layoutDirection == .rightToLeft ? band.maxX - width : band.minX
            context.draw(title.text, in: CGRect(x: x, y: band.minY, width: width, height: title.extent.height))
            if let metadata,
               metadata.extent.width <= band.width,
               metadata.offset + metadata.extent.height <= band.height {
                context.draw(metadata.text, in: CGRect(x: x, y: band.minY + metadata.offset,
                                                        width: width, height: metadata.extent.height))
            }
        }
    }

    static func plan(for tile: SceneTile, in rect: CGRect, detail: MapLabelDetail,
                     dimmed: Bool, context base: GraphicsContext) -> Plan? {
        let policy = Policy(detail: detail, headerHeight: tile.headerHeight)
        guard let band = policy.band(in: rect) else { return nil }

        var context = base
        context.environment.truncationMode = .tail
        context.environment.multilineTextAlignment = .leading
        let foreground: Color = dimmed ? .secondary.opacity(0.4) : .primary
        let proposal = CGSize(width: band.width, height: .greatestFiniteMagnitude)
        let titleHeight = detail == .compact ? min(16, band.height) : band.height
        let entry = tile.entry
        let name = singleParagraph(entry.localizedTitle)
        let title: Block?
        if entry.kind == .unreached {
            // A truncated synthetic label could look like an ordinary file name.
            title = completeTitle(name, policy: policy, proposal: proposal, height: titleHeight,
                                  color: foreground, context: context)
                ?? completeTitle(L10n.text("Unreached space"), policy: policy, proposal: proposal,
                                 height: titleHeight, color: foreground, context: context)
        } else {
            title = fittedTitle(name, policy: policy, proposal: proposal, height: titleHeight,
                                color: foreground, context: context)
        }
        guard let title else { return nil }

        let metadataOffset = detail == .compact ? 22 : title.extent.height + 2
        let canShowMetadata = !tile.isContainer && band.height - metadataOffset >= 12
            && (detail != .compact || (rect.width > 85 && rect.height > 54))
        let metadata = canShowMetadata
            ? metadataBlock(for: entry, band: band, offset: metadataOffset, color: foreground, context: context)
            : nil
        return Plan(policy: policy, width: band.width, title: title, metadata: metadata)
    }

    private static func fittedTitle(_ title: String, policy: Policy, proposal: CGSize, height: CGFloat,
                                    color: Color, context base: GraphicsContext) -> Block? {
        var context = base
        let text = Text(verbatim: title).font(.system(size: policy.fontSize, weight: .medium)).foregroundStyle(color)
        for cap in stride(from: policy.titleLines, through: 1, by: -1) {
            context.environment.lineLimit = cap
            let resolved = context.resolve(text)
            let extent = resolved.measure(in: proposal)
            guard extent.width > 0, extent.width <= proposal.width, extent.height <= height else { continue }
            if extent.width <= policy.fontSize + 1 {
                let ellipsis = context.resolve(Text(verbatim: "…").font(.system(size: policy.fontSize, weight: .medium)))
                guard extent.width > ellipsis.measure(in: unbounded).width
                        || resolved.measure(in: unbounded).width <= proposal.width else { return nil }
            }
            return Block(text: resolved, extent: extent, offset: 0)
        }
        return nil
    }

    private static func completeTitle(_ title: String, policy: Policy, proposal: CGSize, height: CGFloat,
                                      color: Color, context base: GraphicsContext) -> Block? {
        var context = base
        let text = Text(verbatim: title).font(.system(size: policy.fontSize, weight: .medium)).foregroundStyle(color)
        context.environment.lineLimit = nil
        let full = context.resolve(text)
        let extent = full.measure(in: proposal)
        guard extent.width > 0, extent.width <= proposal.width, extent.height <= height else { return nil }
        context.environment.lineLimit = policy.titleLines
        let limited = context.resolve(text)
        guard limited.lastBaseline(in: proposal) == full.lastBaseline(in: proposal) else { return nil }
        return Block(text: limited, extent: extent, offset: 0)
    }

    private static func metadataBlock(for entry: MapEntry, band: CGRect, offset: CGFloat,
                                      color: Color, context base: GraphicsContext) -> Block? {
        var context = base
        context.environment.lineLimit = 1
        let text: Text
        if entry.unknownCount > 0 {
            text = Text("Partial size").font(.system(size: 10)).foregroundStyle(.orange)
        } else {
            let bytes = sizeText(entry.bytes)
            let title = entry.kind == .unreached ? L10n.format("Unreached ≈ %@", bytes) : bytes
            text = Text(verbatim: title).font(.system(size: 11)).foregroundStyle(color.opacity(0.65))
        }
        let resolved = context.resolve(text)
        let extent = resolved.measure(in: unbounded)
        guard extent.width <= band.width, offset + extent.height <= band.height else { return nil }
        return Block(text: resolved, extent: extent, offset: offset)
    }

    private static func singleParagraph(_ name: String) -> String {
        guard name.contains(where: { $0.isNewline || $0 == "\t" }) else { return name }
        return String(name.map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }
}
