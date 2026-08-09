import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Canonical outcome for a maintenance task run.
/// Mirrors Mole's `lib/optimize/outcomes.sh` six outcomes.
public enum MaintenanceOutcome: Codable, Hashable, Sendable {
    /// A change completed, or would complete in dry-run mode.
    case applied(String? = nil)
    /// Inspection completed and no change was needed.
    case unchanged(String? = nil)
    /// Policy or run context intentionally prevented execution.
    case skipped(String? = nil)
    /// The host does not provide the required capability.
    case unavailable(String? = nil)
    /// Inspection completed and found an issue requiring user action.
    case attention(String? = nil)
    /// An eligible operation could not complete.
    case failed(String? = nil)

    /// Human-readable detail message, if any.
    public var detail: String? {
        switch self {
        case .applied(let d), .unchanged(let d), .skipped(let d),
             .unavailable(let d), .attention(let d), .failed(let d):
            return d
        }
    }

    /// Short label suitable for UI display.
    public var label: String {
        switch self {
        case .applied: "Applied"
        case .unchanged: "No Change"
        case .skipped: "Skipped"
        case .unavailable: "Unavailable"
        case .attention: "Attention"
        case .failed: "Failed"
        }
    }

    /// SF Symbol name for UI rendering.
    public var icon: String {
        switch self {
        case .applied: "checkmark.circle.fill"
        case .unchanged: "minus.circle.fill"
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
        case .applied: .green
        case .unchanged: .secondary
        case .skipped: .blue
        case .unavailable: .gray
        case .attention: .orange
        case .failed: .red
        }
    }
    #endif
}