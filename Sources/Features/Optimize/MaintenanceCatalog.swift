import Foundation

/// Catalog of bounded maintenance/optimization tasks.
/// Ported from Mole's `lib/optimize/catalog.sh`.
/// Each task is safe for manual execution and declares its requirements.
public enum MaintenanceCatalog {
    public enum TaskKind: Hashable, Sendable {
        case maintenance
        case guidedDiagnostic
    }

    /// A maintenance task definition.
    public struct Task: Identifiable, Hashable {
        public let id: String        // action slug
        public let name: String      // display name
        public let summary: String   // one-line description
        public let requiresSudo: Bool
        public let safeForAuto: Bool
        public let kind: TaskKind

        public init(
            id: String,
            name: String,
            summary: String,
            requiresSudo: Bool,
            safeForAuto: Bool,
            kind: TaskKind = .maintenance
        ) {
            self.id = id
            self.name = name
            self.summary = summary
            self.requiresSudo = requiresSudo
            self.safeForAuto = safeForAuto
            self.kind = kind
        }
    }

    /// The catalog of maintenance tasks shown in the UI.
    ///
    /// `MaintenanceRunner` has dispatch cases for more task IDs than are listed
    /// here — 7 sudo-gated tasks (dns_spotlight, network_cache, network_stack,
    /// disk_permissions, spotlight_index, periodic, disk_verify) and 4 tasks
    /// deferred for active-database safety (sqlite_vacuum, notifications,
    /// coreduet, login_items) are real dispatch cases that always return
    /// `.skipped`/`.unavailable` — they were never actually implemented, just
    /// stubbed. Listing them here made roughly half the Optimize screen look
    /// broken ("click Run, nothing happens"). Only the 10 tasks that actually
    /// do something are listed; the runner's dispatch cases for the rest are
    /// untouched so they're ready to wire up for real in a future release
    /// (sudo tasks need a proper privilege-escalation UX first; the deferred
    /// four need an active-app-safety check).
    ///
    /// Currently: 11 real maintenance tasks + 1 guided diagnostic
    /// (`network_privacy`).
    public static let tasks: [Task] = [
        Task(id: "finder_cache", name: "Finder Cache Refresh",
             summary: "Refresh QuickLook thumbnails & icon services cache",
             requiresSudo: false, safeForAuto: true),
        Task(id: "saved_state", name: "App State Cleanup",
             summary: "Remove old saved application states (30+ days)",
             requiresSudo: false, safeForAuto: true),
        Task(id: "broken_configs", name: "Broken Config Repair",
             summary: "Fix corrupted preferences files",
             requiresSudo: false, safeForAuto: true),
        Task(id: "launch_services", name: "LaunchServices Repair",
             summary: "Repair \"Open with\" menu & file associations",
             requiresSudo: false, safeForAuto: true),
        Task(id: "prevent_dsstore", name: "Prevent Finder .DS_Store",
             summary: "Set a persistent Finder preference to stop writing .DS_Store on network/USB volumes",
             requiresSudo: false, safeForAuto: true),
        Task(id: "legacy_overrides", name: "Legacy Overrides",
             summary: "Remove hidden App Nap and disk-image verification overrides left by old tweak tools",
             requiresSudo: false, safeForAuto: true),
        Task(id: "spotlight_orphans", name: "Spotlight Orphan Rules",
             summary: "Remove Spotlight search-rule entries for apps that are no longer installed",
             requiresSudo: false, safeForAuto: true),
        Task(id: "shared_file_lists", name: "Shared File Lists",
             summary: "Repair corrupted Finder favourites and recent documents",
             requiresSudo: false, safeForAuto: true),
        Task(id: "quarantine", name: "Quarantine Database Cleanup",
             summary: "Clear Gatekeeper download tracking history",
             requiresSudo: false, safeForAuto: true),
        Task(id: "launch_agents", name: "Launch Agents Cleanup",
             summary: "Remove broken LaunchAgents whose binaries no longer exist",
             requiresSudo: false, safeForAuto: true),
        Task(id: "font_cache", name: "Font Cache Reset",
             summary: "Clear the per-user font registration cache — fixes garbled or missing text in apps",
             requiresSudo: false, safeForAuto: true),
        Task(id: "network_privacy", name: "System Privacy Records",
             summary: "Detect duplicate, conflicting, and orphaned Local Network app permissions",
             requiresSudo: false, safeForAuto: false, kind: .guidedDiagnostic),
    ]
}