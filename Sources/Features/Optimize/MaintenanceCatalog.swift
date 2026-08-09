import Foundation

/// Catalog of bounded maintenance/optimization tasks.
/// Ported from Mole's `lib/optimize/catalog.sh`.
/// Each task is safe for manual execution and declares its requirements.
public enum MaintenanceCatalog {
    /// A maintenance task definition.
    public struct Task: Identifiable, Hashable {
        public let id: String        // action slug
        public let name: String      // display name
        public let summary: String   // one-line description
        public let requiresSudo: Bool
        public let safeForAuto: Bool

        public init(id: String, name: String, summary: String, requiresSudo: Bool, safeForAuto: Bool) {
            self.id = id
            self.name = name
            self.summary = summary
            self.requiresSudo = requiresSudo
            self.safeForAuto = safeForAuto
        }
    }

    /// The full catalog of maintenance tasks.
    public static let tasks: [Task] = [
        Task(id: "dns_spotlight", name: "DNS & Spotlight Check",
             summary: "Refresh DNS cache & verify Spotlight status",
             requiresSudo: true, safeForAuto: true),
        Task(id: "finder_cache", name: "Finder Cache Refresh",
             summary: "Refresh QuickLook thumbnails & icon services cache",
             requiresSudo: false, safeForAuto: true),
        Task(id: "saved_state", name: "App State Cleanup",
             summary: "Remove old saved application states (30+ days)",
             requiresSudo: false, safeForAuto: true),
        Task(id: "broken_configs", name: "Broken Config Repair",
             summary: "Fix corrupted preferences files",
             requiresSudo: false, safeForAuto: true),
        Task(id: "network_cache", name: "Network Cache Refresh",
             summary: "Optimize DNS cache & restart mDNSResponder",
             requiresSudo: true, safeForAuto: true),
        Task(id: "sqlite_vacuum", name: "Database Optimization",
             summary: "Compress SQLite databases for Mail, Safari & Messages (skips if apps are running)",
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
        Task(id: "network_stack", name: "Network Stack Refresh",
             summary: "Flush routing table and ARP cache to resolve network issues",
             requiresSudo: true, safeForAuto: true),
        Task(id: "disk_permissions", name: "Permission Repair",
             summary: "Fix user directory permission issues",
             requiresSudo: true, safeForAuto: true),
        Task(id: "spotlight_index", name: "Spotlight Optimization",
             summary: "Rebuild index if search is slow (smart detection)",
             requiresSudo: true, safeForAuto: true),
        Task(id: "spotlight_orphans", name: "Spotlight Orphan Rules",
             summary: "Remove Spotlight search-rule entries for apps that are no longer installed",
             requiresSudo: false, safeForAuto: true),
        Task(id: "periodic", name: "Periodic Maintenance",
             summary: "Run macOS daily/weekly/monthly maintenance scripts if stale",
             requiresSudo: true, safeForAuto: true),
        Task(id: "shared_file_lists", name: "Shared File Lists",
             summary: "Repair corrupted Finder favorites and recent documents",
             requiresSudo: false, safeForAuto: true),
        Task(id: "disk_verify", name: "Disk Health",
             summary: "Verify filesystem integrity",
             requiresSudo: true, safeForAuto: true),
        Task(id: "login_items", name: "Login Items Audit",
             summary: "Audit login items for broken entries",
             requiresSudo: false, safeForAuto: true),
        Task(id: "quarantine", name: "Quarantine Database Cleanup",
             summary: "Clear Gatekeeper download tracking history",
             requiresSudo: false, safeForAuto: true),
        Task(id: "launch_agents", name: "Launch Agents Cleanup",
             summary: "Remove broken LaunchAgents whose binaries no longer exist",
             requiresSudo: false, safeForAuto: true),
        Task(id: "notifications", name: "Notifications",
             summary: "Clean old delivered notifications to reduce database bloat",
             requiresSudo: false, safeForAuto: true),
        Task(id: "coreduet", name: "Usage Data",
             summary: "Clean old usage tracking data",
             requiresSudo: false, safeForAuto: true),
    ]
}