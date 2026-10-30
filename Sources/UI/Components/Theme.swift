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
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(CareTheme.border, lineWidth: 1))
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
        HStack(spacing: 14) {
            Image(systemName: systemImage).font(.system(size: 23, weight: .medium))
                .foregroundStyle(tint).iconBadge(tint: tint, size: 50, radius: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-0.7)
                    .foregroundStyle(CareTheme.ink).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(CareTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                heading.fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 16)
                HStack(spacing: 8) { actions }.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 18) { heading; HStack(spacing: 8) { actions; Spacer(minLength: 0) } }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [CareTheme.panel, CareTheme.lilac.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(CareTheme.border, lineWidth: 1))
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 18)
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
    /// Light value chosen for 4.5:1 on the lilac gradient behind headers,
    /// not just on white.
    public static let secondaryInk = adaptive(
        NSColor(red: 0.38, green: 0.35, blue: 0.43, alpha: 1),
        NSColor(red: 0.72, green: 0.69, blue: 0.77, alpha: 1)
    )
    public static let onAccent = adaptive(.white, NSColor(red: 0.14, green: 0.09, blue: 0.25, alpha: 1))
    public static let accent = adaptive(
        NSColor(red: 0.45, green: 0.31, blue: 0.83, alpha: 1),
        NSColor(red: 0.73, green: 0.61, blue: 0.97, alpha: 1)
    )
    public static let teal = adaptive(
        NSColor(red: 0.08, green: 0.46, blue: 0.44, alpha: 1),
        NSColor(red: 0.35, green: 0.82, blue: 0.76, alpha: 1)
    )
    public static let blue = adaptive(
        NSColor(red: 0.20, green: 0.40, blue: 0.74, alpha: 1),
        NSColor(red: 0.53, green: 0.71, blue: 0.98, alpha: 1)
    )
    public static let rose = adaptive(
        NSColor(red: 0.68, green: 0.27, blue: 0.43, alpha: 1),
        NSColor(red: 0.94, green: 0.58, blue: 0.73, alpha: 1)
    )
    public static let gold = adaptive(
        NSColor(red: 0.63, green: 0.40, blue: 0.12, alpha: 1),
        NSColor(red: 0.94, green: 0.73, blue: 0.40, alpha: 1)
    )
    public static let background = adaptive(
        NSColor(red: 0.98, green: 0.97, blue: 0.99, alpha: 1),
        NSColor(red: 0.13, green: 0.12, blue: 0.16, alpha: 1)
    )
    public static let sidebar = adaptive(
        NSColor(red: 0.94, green: 0.93, blue: 0.97, alpha: 1),
        NSColor(red: 0.16, green: 0.15, blue: 0.19, alpha: 1)
    )
    public static let border = adaptive(NSColor.black.withAlphaComponent(0.055), NSColor.white.withAlphaComponent(0.09))
    public static let panel = adaptive(.white, NSColor(red: 0.17, green: 0.16, blue: 0.20, alpha: 1))
    public static let lilac = adaptive(
        NSColor(red: 0.90, green: 0.87, blue: 0.98, alpha: 1),
        NSColor(red: 0.23, green: 0.19, blue: 0.32, alpha: 1)
    )
    public static let pink = adaptive(
        NSColor(red: 0.96, green: 0.86, blue: 0.91, alpha: 1),
        NSColor(red: 0.31, green: 0.19, blue: 0.28, alpha: 1)
    )
}
