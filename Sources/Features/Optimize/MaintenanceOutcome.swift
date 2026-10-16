import Foundation
#if canImport(SwiftUI)
    import SwiftUI
#endif

/// Canonical outcome for a maintenance task run.
public enum MaintenanceOutcome: Codable, Hashable, Sendable {
    /// Inspection found an eligible change; no change has run.
    case recommended(String? = nil)
    /// A change completed.
    case applied(String? = nil)
    /// Inspection completed and no change was needed.
    case unchanged(String? = nil)
    /// Inspection completed with information that does not require repair.
    case information(String? = nil)
    /// Policy or run context intentionally prevented execution.
    case skipped(String? = nil)
    /// The host does not provide the required capability.
    case unavailable(String? = nil)
    /// Inspection completed and found an issue requiring user action.
    case attention(String? = nil)
    /// An eligible operation could not complete.
    case failed(String? = nil)

    public var needsAction: Bool {
        switch self { case .recommended, .attention: true; default: false }
    }

    public var isClear: Bool {
        switch self { case .unchanged, .applied: true; default: false }
    }

    public var isIncomplete: Bool {
        switch self { case .failed, .unavailable, .skipped: true; default: false }
    }

    /// Human-readable detail message, if any.
    public var detail: String? {
        switch self {
        case let .recommended(d), let .applied(d), let .unchanged(d), let .information(d), let .skipped(d),
             let .unavailable(d), let .attention(d), let .failed(d):
            d
        }
    }

    /// Short label suitable for UI display.
    public var label: String {
        switch self {
        case .recommended: "Recommended"
        case .applied: "Applied"
        case .unchanged: "No Change"
        case .information: "Information"
        case .skipped: "Skipped"
        case .unavailable: "Unavailable"
        case .attention: "Attention"
        case .failed: "Failed"
        }
    }

    /// SF Symbol name for UI rendering.
    public var icon: String {
        switch self {
        case .recommended: "sparkles"
        case .applied: "checkmark.circle.fill"
        case .unchanged: "minus.circle.fill"
        case .information: "info.circle.fill"
        case .skipped: "forward.fill.circle"
        case .unavailable: "questionmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    #if canImport(SwiftUI)
        /// Color for UI rendering.
        public var color: Color {
            switch self {
            case .recommended: .purple
            case .applied: .green
            case .unchanged: .secondary
            case .information: .blue
            case .skipped: .blue
            case .unavailable: .gray
            case .attention: .orange
            case .failed: .red
            }
        }
    #endif
}
