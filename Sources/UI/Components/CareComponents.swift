import AppKit
import SwiftUI

/// The installed app icon is the single source for myKikau's visual identity.
public struct AppBrandIcon: View {
    private let size: CGFloat
    public init(size: CGFloat = 36) {
        self.size = size
    }

    public var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable().renderingMode(.original).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

public struct CareWindowHeader<Actions: View>: View {
    private let title: String
    private let subtitle: String
    private let actions: Actions
    public init(_ title: String, subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.subtitle = subtitle; self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 12) {
            AppBrandIcon(size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(.title, design: .rounded).weight(.bold)).foregroundStyle(CareTheme.ink)
                Text(subtitle).font(.caption).foregroundStyle(CareTheme.secondaryInk)
            }
            Spacer(minLength: 12)
            actions
        }.padding(22)
    }
}

public struct CareEmptyState<Actions: View>: View {
    private let title: String
    private let systemImage: String
    private let description: Text
    private let actions: Actions

    public init(_ title: String, systemImage: String, description: Text, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.systemImage = systemImage; self.description = description; self.actions = actions()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: systemImage).font(.system(.largeTitle).weight(.medium))
                    .foregroundStyle(CareTheme.accent).frame(width: 70, height: 70)
                    .background(CareTheme.lilac, in: RoundedRectangle(cornerRadius: 20)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.system(.title, design: .rounded).weight(.bold)).tracking(-0.5)
                        .foregroundStyle(CareTheme.ink).accessibilityAddTraits(.isHeader)
                    description.font(.callout).foregroundStyle(CareTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 470, alignment: .leading)
                }
                HStack(spacing: 10) { actions }
            }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [CareTheme.panel, CareTheme.lilac.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22)
                )
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(CareTheme.border, lineWidth: 1))
                .padding(.horizontal, 22).padding(.vertical, 8)
        }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

public extension CareEmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

public struct CareSummary: View {
    private let values: [(String, String)]
    public init(_ values: [(String, String)]) {
        self.values = values
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(values.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Text(values[index].0).font(.caption).foregroundStyle(CareTheme.secondaryInk)
                    Text(values[index].1).font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(CareTheme.ink).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
            }
        }.padding(18).cardSurface(radius: 16).padding(.horizontal, 22).padding(.bottom, 14)
    }
}

/// Shared visual treatment; native selection, keyboard controls and scrolling
/// remain owned by each screen's List, Table or Form.
public extension View {
    func careScreen() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(CareTheme.ink).background(CareTheme.background).tint(CareTheme.accent)
    }

    func carePrimaryAction() -> some View {
        buttonStyle(CarePrimaryButtonStyle())
    }

    /// The primary button for an action that removes something: same shape
    /// as `carePrimaryAction`, filled rose, so a destructive step never
    /// looks like the ordinary next step.
    func careDestructiveAction() -> some View {
        buttonStyle(CarePrimaryButtonStyle(fill: CareTheme.rose))
    }

    func careToolbar() -> some View {
        padding(12).background(CareTheme.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(CareTheme.border, lineWidth: 1))
            .padding(.horizontal, 22).padding(.bottom, 12)
    }

    func careResults() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(CareTheme.panel, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CareTheme.border, lineWidth: 1))
            .padding(.horizontal, 22).padding(.bottom, 14)
            .layoutPriority(-1)
    }
}

public struct CarePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    private let fill: Color
    public init(fill: Color = CareTheme.accent) {
        self.fill = fill
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .foregroundStyle(enabled ? CareTheme.onAccent : CareTheme.secondaryInk)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(
                enabled ? fill.opacity(configuration.isPressed ? 0.8 : 1) : CareTheme.lilac,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// One line explaining that a control is set by a configuration profile.
public struct ManagedNote: View {
    private let text: LocalizedStringKey
    public init(_ text: LocalizedStringKey = "Set by your organisation") {
        self.text = text
    }

    public var body: some View {
        Label(text, systemImage: "building.2")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(text))
    }
}

public extension View {
    /// Disables the view and, when `managed`, says why beneath it.
    @ViewBuilder
    func managedBy(_ managed: Bool, note: LocalizedStringKey = "Set by your organisation") -> some View {
        if managed {
            VStack(alignment: .leading, spacing: 4) {
                disabled(true)
                ManagedNote(note)
            }
        } else {
            self
        }
    }
}
