import SwiftUI

/// Renders `items` as a squarified treemap — each cell's area proportional to
/// `value(item)`. Cells too small to hold a label still render (so total area
/// reads correctly at a glance) but skip the text.
public struct TreemapView<Item: Identifiable>: View {
    public let items: [Item]
    public let value: (Item) -> Double
    public let color: (Item, Int) -> Color   // (item, rank in `items`) -> fill color
    public let label: (Item) -> String
    public let sublabel: (Item) -> String
    public let onSelect: (Item) -> Void

    public init(
        items: [Item],
        value: @escaping (Item) -> Double,
        color: @escaping (Item, Int) -> Color,
        label: @escaping (Item) -> String,
        sublabel: @escaping (Item) -> String,
        onSelect: @escaping (Item) -> Void
    ) {
        self.items = items
        self.value = value
        self.color = color
        self.label = label
        self.sublabel = sublabel
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { geo in
            let rects = SquarifiedTreemap.layout(
                values: items.map(value),
                in: CGRect(origin: .zero, size: geo.size)
            )
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let rect = rects[index]
                    if rect.width > 0.5, rect.height > 0.5 {
                        TreemapCell(title: label(item), subtitle: sublabel(item), color: color(item, index), size: rect.size)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .onTapGesture { onSelect(item) }
                    }
                }
            }
        }
    }
}

private struct TreemapCell: View {
    let title: String
    let subtitle: String
    let color: Color
    let size: CGSize

    // Most cells in a typical folder scan are well under the old 54x32
    // threshold, so they rendered as bare colored rectangles with no way to
    // tell what they were short of hovering every single one. Two tiers
    // instead: title-only down to a much smaller size, full title+subtitle
    // only where there's real room.
    private var showSubtitle: Bool { size.width > 60 && size.height > 34 }
    private var showTitleOnly: Bool { size.width > 24 && size.height > 14 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.black.opacity(0.18), lineWidth: 1)
            if showSubtitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption2.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(4)
            } else if showTitleOnly {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
        .help("\(title) — \(subtitle)")
        .contentShape(Rectangle())
    }
}
