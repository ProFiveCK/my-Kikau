import Foundation
import Core

/// Lists the launch agents and daemons that start software in the background:
/// the user's own (`~/Library/LaunchAgents`), which can be removed, and the
/// system-wide ones in `/Library`, which are shown for information.
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

        /// The app the executable lives in, if it lives in one.
        public var owningAppName: String? {
            guard let program, let range = program.range(of: ".app/") else { return nil }
            return URL(fileURLWithPath: String(program[..<range.lowerBound])).lastPathComponent
        }

        public var isRemovable: Bool {
            scope == .user && !isProtected
        }
    }

    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, coverage: ScanCoverageRecorder? = nil) -> [Item] {
        let locations: [(URL, Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .user),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon),
        ]
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
                items.append(item(at: entry, scope: scope, coverage: coverage))
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func item(at url: URL, scope: Scope, coverage: ScanCoverageRecorder? = nil) -> Item {
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
        } catch { coverage?.failed(url, error: error) }
        let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        let missing: Bool = if let program, program.hasPrefix("/"), !program.hasPrefix("/Volumes/") {
            !FileManager.default.fileExists(atPath: program)
        } else {
            false
        }
        let protection = PathProtection.shared
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
                || protection.shouldProtect(url)
        )
    }

    /// Plan for removing user launch agents. Anything that isn't removable
    /// is dropped here, whatever the caller passed.
    public static func removalPlan(for items: [Item], deleter: SafeFileDeleter = .shared) -> SafeFileDeleter.Plan {
        deleter.preview(items.filter(\.isRemovable).map(\.url), category: .leftover)
    }

    /// Stops a user agent so removing its plist takes effect now rather than
    /// at the next login.
    public static func stop(_ item: Item) async {
        guard item.isRemovable else { return }
        _ = await ProcessRunner.run("/bin/launchctl", ["bootout", "gui/\(getuid())", item.url.path], timeout: 20)
    }
}
