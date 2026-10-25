import Foundation
import Core

/// Lists the launch agents and daemons that start software in the background:
/// the user's own (`~/Library/LaunchAgents`), which can be removed directly,
/// and the system-wide ones in `/Library`, which are owned by root and can be
/// removed only through the administrator helper (with a password each time).
///
/// Apps that register through System Settings → Login Items aren't
/// enumerable by other apps; the screen links to that pane for those.
public enum StartupItems {
    public enum Scope: String, Sendable {
        case user = "For You"
        case systemAgent = "All Users"
        case systemDaemon = "System"
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String {
            url.path
        }

        public let url: URL
        public let label: String
        /// The executable launchd starts, when the plist names one.
        public let program: String?
        public let scope: Scope
        /// The executable is an absolute path that no longer exists.
        public let programMissing: Bool
        public let runsAtLoad: Bool
        /// Apple's own, or a security / device-management agent: never removable.
        public let isProtected: Bool
        /// For a system-wide item: the privileged helper tool its plist runs,
        /// when that tool sits directly in `/Library/PrivilegedHelperTools`
        /// (exact-path evidence, removed together with the plist).
        public let helperTool: URL?
        /// The plist's file permissions let only its owner (usually root)
        /// read it, so its label and program are unknown. The item is still
        /// listed; no privacy permission can change this, so it isn't
        /// reported as a gap in the scan.
        public let contentsUnreadable: Bool

        /// The app the executable lives in, if it lives in one.
        public var owningAppName: String? {
            guard let program, let range = program.range(of: ".app/") else { return nil }
            return URL(fileURLWithPath: String(program[..<range.lowerBound])).lastPathComponent
        }

        /// Removable without an administrator: the user's own agents.
        public var isRemovable: Bool {
            scope == .user && !isProtected
        }

        /// Owned by root: only the administrator helper can remove it.
        public var needsAdministrator: Bool {
            scope != .user
        }

        /// Whether this item can be ticked for removal, given whether the
        /// administrator helper is installed and approved.
        public func canRemove(helperEnabled: Bool) -> Bool {
            !isProtected && (scope == .user || helperEnabled)
        }
    }

    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        library: URL = URL(fileURLWithPath: "/Library"),
        coverage: ScanCoverageRecorder? = nil
    ) -> [Item] {
        let locations: [(URL, Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .user),
            (library.appendingPathComponent("LaunchAgents"), .systemAgent),
            (library.appendingPathComponent("LaunchDaemons"), .systemDaemon),
        ]
        let helperTools = library.appendingPathComponent("PrivilegedHelperTools")
        var items: [Item] = []
        for (directory, scope) in locations {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                coverage?.checked(directory)
            } catch { coverage?.failed(directory, error: error); continue }
            for entry in entries where entry.pathExtension == "plist" {
                items.append(item(at: entry, scope: scope, helperTools: helperTools, coverage: coverage))
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func item(
        at url: URL,
        scope: Scope,
        helperTools: URL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools"),
        coverage: ScanCoverageRecorder? = nil
    ) -> Item {
        var dict: [String: Any] = [:]
        do {
            let data = try Data(contentsOf: url)
            if let parsed = try PropertyListSerialization
                .propertyList(from: data, options: [], format: nil) as? [String: Any]
            {
                dict = parsed
            } else {
                coverage?.record(url, kind: .unavailable, detail: "The startup configuration could not be read.")
            }
        } catch {
            if !isOwnerOnly(url) {
                coverage?.failed(url, error: error)
            }
        }
        let contentsUnreadable = dict.isEmpty && isOwnerOnly(url)
        let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        let missing: Bool = if let program, program.hasPrefix("/"), !program.hasPrefix("/Volumes/") {
            !FileManager.default.fileExists(atPath: program)
        } else {
            false
        }
        let protection = PathProtection.shared
        // Only the exact program a system-wide plist names, directly inside
        // PrivilegedHelperTools and not a symbolic link.
        var helperTool: URL?
        if scope != .user, let program, program.hasPrefix("/") {
            let tool = URL(fileURLWithPath: program)
            let values = try? tool.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if PathProtection.normalise(tool.deletingLastPathComponent().path) == PathProtection.normalise(helperTools.path),
               values?.isRegularFile == true, values?.isSymbolicLink != true
            {
                helperTool = tool
            }
        }
        return Item(
            url: url,
            label: label,
            program: program,
            scope: scope,
            programMissing: missing,
            runsAtLoad: (dict["RunAtLoad"] as? Bool) ?? false,
            isProtected: label.hasPrefix("com.apple.")
                || url.lastPathComponent.hasPrefix("com.apple.")
                || protection.isEndpointSecurityBundle(label)
                || protection.shouldProtect(url),
            helperTool: helperTool,
            contentsUnreadable: contentsUnreadable
        )
    }

    /// Unreadable because of its file permissions (EACCES), not a privacy
    /// setting such as Full Disk Access (EPERM): e.g. a vendor's daemon plist
    /// installed as root with mode 700.
    static func isOwnerOnly(_ url: URL) -> Bool {
        access(url.path, R_OK) != 0 && errno == EACCES
    }

    /// Plan for removing startup items: each plist, plus the helper tool a
    /// system-wide one runs. System-wide items join only when the
    /// administrator helper is enabled; they fail the first pass and go
    /// through the helper, which stops each job before moving it. Anything
    /// that can't be removed is dropped here, whatever the caller passed.
    public static func removalPlan(
        for items: [Item],
        helperEnabled: Bool = false,
        deleter: SafeFileDeleter = .shared
    ) -> SafeFileDeleter.Plan {
        let removable = items.filter { $0.canRemove(helperEnabled: helperEnabled) }
        var urls = removable.map(\.url)
        for tool in removable.compactMap(\.helperTool) where !urls.contains(tool) {
            urls.append(tool)
        }
        return deleter.preview(urls, category: .leftover)
    }

    /// Stops a user agent so removing its plist takes effect now rather than
    /// at the next login.
    public static func stop(_ item: Item) async {
        guard item.isRemovable else { return }
        _ = await ProcessRunner.run("/bin/launchctl", ["bootout", "gui/\(getuid())", item.url.path], timeout: 20)
    }
}
