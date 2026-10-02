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
        public static let card: CGFloat = 10
        public static let panel: CGFloat = 12
    }
}

public extension View {
    /// The standard card surface used for list rows and summary panels.
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        background(.quaternary, in: RoundedRectangle(cornerRadius: radius))
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

    public var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
        }
        .padding()
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
