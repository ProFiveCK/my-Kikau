import SwiftUI

/// Shared spacing, radius and surface values, so screens stop hard-coding
/// their own and drifting apart.
public enum Theme {
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    public enum Radius {
        public static let control: CGFloat = 8
        public static let card: CGFloat = 15
        public static let panel: CGFloat = 12
    }
}

public extension View {
    /// The standard card surface used for list rows and summary panels.
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        background(CareTheme.panel, in: RoundedRectangle(cornerRadius: radius))
    }

    /// A tinted icon badge: the rounded square behind a feature's symbol.
    func iconBadge(tint: Color, size: CGFloat = 36, radius: CGFloat = Theme.Radius.control) -> some View {
        frame(width: size, height: size)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: radius))
    }
}

/// The title row every screen opens with: icon, title, optional subtitle,
/// and the screen's actions on the trailing edge.
public struct ScreenHeader<Actions: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let tint: Color
    private let actions: Actions

    public init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.actions = actions()
    }

    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint).iconBadge(tint: tint, size: 40, radius: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { heading; Spacer(minLength: 12); actions }
            VStack(alignment: .leading, spacing: 14) { heading; HStack { actions; Spacer(minLength: 0) } }
        }
        .padding(22)
    }
}

/// Progress for a running scan: a bar (determinate when a fraction is
/// known), what's being looked at, and a way to stop.
public struct ScanProgressBar: View {
    private let title: String
    private let detail: String?
    private let fraction: Double?
    private let onCancel: (() -> Void)?

    public init(_ title: String, detail: String? = nil, fraction: Double? = nil, onCancel: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(.subheadline)
                if let fraction {
                    ProgressView(value: min(1, max(0, fraction)))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                // Reserve the line so the bar doesn't jump as paths come and go.
                Text(detail ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.md)
        .cardSurface()
    }
}

/// Native surfaces shared by Care hub and the feature screens.
public enum CareTheme {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    public static let ink = adaptive(
        NSColor(red: 0.15, green: 0.13, blue: 0.21, alpha: 1),
        NSColor(red: 0.97, green: 0.95, blue: 1.0, alpha: 1)
    )
    public static let secondaryInk = adaptive(
        NSColor(red: 0.46, green: 0.43, blue: 0.50, alpha: 1),
        NSColor(red: 0.72, green: 0.69, blue: 0.77, alpha: 1)
    )
    public static let onAccent = adaptive(.white, NSColor(red: 0.14, green: 0.09, blue: 0.25, alpha: 1))
    public static let accent = adaptive(
        NSColor(red: 0.45, green: 0.31, blue: 0.83, alpha: 1),
        NSColor(red: 0.73, green: 0.61, blue: 0.97, alpha: 1)
    )
    public static let background = adaptive(
        NSColor(red: 0.98, green: 0.97, blue: 0.99, alpha: 1),
        NSColor(red: 0.13, green: 0.12, blue: 0.16, alpha: 1)
    )
    public static let sidebar = adaptive(
        NSColor(red: 0.94, green: 0.93, blue: 0.97, alpha: 1),
        NSColor(red: 0.16, green: 0.15, blue: 0.19, alpha: 1)
    )
    public static let panel = Color(nsColor: .controlBackgroundColor)
    public static let lilac = adaptive(
        NSColor(red: 0.90, green: 0.87, blue: 0.98, alpha: 1),
        NSColor(red: 0.23, green: 0.19, blue: 0.32, alpha: 1)
    )
    public static let pink = adaptive(
        NSColor(red: 0.96, green: 0.86, blue: 0.91, alpha: 1),
        NSColor(red: 0.31, green: 0.19, blue: 0.28, alpha: 1)
    )
}
