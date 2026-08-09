import SwiftUI

/// A horizontal progress bar showing a percentage with color coding.
public struct SizeBar: View {
    public let percent: Double
    public let color: Color

    public init(percent: Double, color: Color = .accentColor) {
        self.percent = min(100, max(0, percent))
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * (percent / 100))
            }
        }
        .frame(height: 8)
    }

    public static func color(for percent: Double) -> Color {
        switch percent {
        case ..<50: .green
        case ..<80: .yellow
        case ..<93: .orange
        default: .red
        }
    }
}