import Foundation

/// Names shared by the app and its privileged helper.
public enum PrivilegedHelperConstants {
    public static let machServiceName = "com.profiveck.myKikau.helper"
    public static let daemonPlistName = "com.profiveck.myKikau.helper.plist"
    public static let helperExecutableName = "myKikauHelper"
    /// The administrator right checked for every helper operation. It is not
    /// defined in the authorization database, so macOS applies its default
    /// rule: authenticate as an administrator.
    public static let authorizationRight = "com.profiveck.myKikau.helper.remove"
    /// Bumped when the protocol changes, so the app can tell an old helper.
    public static let protocolVersion = 1

    /// The helper only talks to myKikau signed by this team…
    public static let clientRequirement =
        "identifier \"com.profiveck.myKikau\" and anchor apple generic and certificate leaf[subject.OU] = \"P523Y49P5B\""
    /// …and the app only talks to a helper signed by it.
    public static let helperRequirement =
        "identifier \"com.profiveck.myKikau.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"P523Y49P5B\""
}

/// The helper's XPC interface. Deliberately one operation: move specific
/// items to the calling user's Trash. No shell commands, no arbitrary paths.
@objc public protocol PrivilegedHelperProtocol {
    func helperVersion(reply: @escaping (Int) -> Void)

    /// Moves each path to the caller's Trash if `HelperPolicy` allows it and
    /// `authorization` proves an administrator approved.
    /// - Parameter reply: removed (original path → Trash path) and failed
    ///   (original path → reason).
    func removeItems(
        atPaths paths: [String],
        authorization: Data,
        reply: @escaping ([String: String], [String: String]) -> Void
    )
}

/// What the helper — which runs as root — is willing to remove. It trusts
/// nothing the app sends: every path is judged here, in the helper, from the
/// file system alone.
///
/// Only three shapes are accepted:
/// 1. an application bundle in `/Applications` (or one folder below it);
/// 2. a launch plist in `/Library/LaunchDaemons` or `/Library/LaunchAgents`;
/// 3. a file in `/Library/PrivilegedHelperTools`.
/// Never Apple's, never security or device-management software, never
/// myKikau itself, never through a symbolic link.
public enum HelperPolicy {
    public enum Kind: Equatable, Sendable {
        case application
        case launchItem
        case helperTool
    }

    public struct Rejection: Error, Equatable, Sendable {
        public let reason: String
    }

    public static func validateRemoval(
        path: String,
        applicationsRoot: String = "/Applications",
        libraryRoot: String = "/Library",
        protection: PathProtection = PathProtection(
            home: URL(fileURLWithPath: "/var/empty"), exclusions: { [] }, extraBundlePrefixes: { [] }
        ),
        fileManager: FileManager = .default
    ) -> Result<Kind, Rejection> {
        func reject(_ reason: String) -> Result<Kind, Rejection> {
            .failure(Rejection(reason: reason))
        }

        guard path.hasPrefix("/"), !path.contains("\0") else { return reject("Not an absolute path.") }
        let url = URL(fileURLWithPath: path)
        // The path must already be in canonical form: no "..", no "//", no
        // trailing slash, and no symbolic link anywhere along it.
        let canonical = PathProtection.normalise(url.standardizedFileURL.path)
        guard PathProtection.normalise(path) == canonical, !path.hasSuffix("/") else {
            return reject("Path is not in canonical form.")
        }
        guard PathProtection.normalise(url.resolvingSymlinksInPath().path) == canonical else {
            return reject("Path goes through a symbolic link.")
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType
        else {
            return reject("No longer exists.")
        }
        guard type != .typeSymbolicLink else { return reject("Is a symbolic link.") }

        let name = url.lastPathComponent
        let parent = PathProtection.normalise(url.deletingLastPathComponent().path)
        let grandparent = PathProtection.normalise(url.deletingLastPathComponent().deletingLastPathComponent().path)
        let apps = PathProtection.normalise(applicationsRoot)
        let library = PathProtection.normalise(libraryRoot)

        if protection.shouldProtect(url) {
            return reject("Protected path.")
        }

        // 1. Application bundle.
        if parent == apps || (grandparent == apps && !parent.hasSuffix(".app")) {
            guard url.pathExtension == "app", type == .typeDirectory else {
                return reject("Only application bundles can be removed from Applications.")
            }
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            guard let bundleID = info?["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
                return reject("Not a valid application bundle.")
            }
            if bundleID == AppDefaults.appDomain {
                return reject("myKikau can't remove itself.")
            }
            if protection.isSystemCriticalBundle(bundleID) {
                return reject("Part of macOS.")
            }
            if protection.isEndpointSecurityBundle(bundleID) {
                return reject("Security or device-management software.")
            }
            return .success(.application)
        }

        // 2. Launch daemon / agent plist.
        if parent == library + "/LaunchDaemons" || parent == library + "/LaunchAgents" {
            guard type == .typeRegular, url.pathExtension == "plist" else { return reject("Not a launch plist.") }
            return validateIdentifier(String(name.dropLast(".plist".count)), protection: protection).map { .launchItem }
        }

        // 3. Privileged helper tool.
        if parent == library + "/PrivilegedHelperTools" {
            guard type == .typeRegular else { return reject("Not a helper tool.") }
            return validateIdentifier(name, protection: protection).map { .helperTool }
        }

        return reject("Outside the locations the helper may modify.")
    }

    /// A launch label / helper name must be a third-party reverse-DNS
    /// identifier.
    private static func validateIdentifier(_ identifier: String, protection: PathProtection) -> Result<Void, Rejection> {
        let labels = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else {
            return .failure(Rejection(reason: "Not named after a bundle identifier."))
        }
        if identifier.lowercased().hasPrefix("com.apple.") {
            return .failure(Rejection(reason: "Part of macOS."))
        }
        if identifier.hasPrefix(PrivilegedHelperConstants.machServiceName) {
            return .failure(Rejection(reason: "myKikau can't remove its own helper."))
        }
        if protection.isSystemCriticalBundle(identifier) {
            return .failure(Rejection(reason: "Protected item."))
        }
        if protection.isEndpointSecurityBundle(identifier) {
            return .failure(Rejection(reason: "Security or device-management software."))
        }
        return .success(())
    }
}

/// Moves an item the way the privileged helper must: without following a
/// symbolic link anywhere in either path, and only if the item is still the
/// one that was validated. Between the policy check and the move, an
/// admin-group user could swap a folder under `/Applications` for a link, so
/// the move walks each path component with `O_NOFOLLOW` and compares the
/// item's device and file number with the ones captured at validation.
public enum SecureMove {
    public struct Identity: Equatable, Sendable {
        public let device: Int32
        public let fileNumber: UInt64

        public init(device: Int32, fileNumber: UInt64) {
            self.device = device
            self.fileNumber = fileNumber
        }
    }

    public struct Failure: Error, Equatable, Sendable {
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }
    }

    /// The item's identity from `lstat`, or nil if it can't be read.
    public static func identity(of path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, fileNumber: info.st_ino)
    }

    /// Opens a directory by walking every component without following links.
    private static func openDirectoryNoFollow(_ path: String) -> Result<Int32, Failure> {
        var fd = open("/", O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return .failure(Failure(reason: "Couldn't open /.")) }
        for component in path.split(separator: "/") where !component.isEmpty {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd)
            guard next >= 0 else {
                return .failure(Failure(reason: "\(component) is not a real folder."))
            }
            fd = next
        }
        return .success(fd)
    }

    /// Moves `source` into `destinationDirectory` under `destinationName`.
    /// Fails, changing nothing, if any folder on either path is a link, if
    /// the source is no longer `expected`, or if the destination name exists.
    public static func move(
        _ source: String,
        toDirectory destinationDirectory: String,
        name destinationName: String,
        expecting expected: Identity
    ) -> Result<Void, Failure> {
        let sourceName = (source as NSString).lastPathComponent
        let sourceParent = (source as NSString).deletingLastPathComponent
        guard !sourceName.isEmpty, !destinationName.contains("/"), !destinationName.isEmpty else {
            return .failure(Failure(reason: "Invalid name."))
        }
        let parent: Int32
        switch openDirectoryNoFollow(sourceParent) {
        case let .success(fd): parent = fd
        case let .failure(failure): return .failure(failure)
        }
        defer { close(parent) }
        let trash: Int32
        switch openDirectoryNoFollow(destinationDirectory) {
        case let .success(fd): trash = fd
        case let .failure(failure): return .failure(failure)
        }
        defer { close(trash) }

        var info = stat()
        guard fstatat(parent, sourceName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .failure(Failure(reason: "No longer exists."))
        }
        guard Identity(device: info.st_dev, fileNumber: info.st_ino) == expected else {
            return .failure(Failure(reason: "The item changed after it was checked."))
        }
        var existing = stat()
        guard fstatat(trash, destinationName, &existing, AT_SYMLINK_NOFOLLOW) != 0 else {
            return .failure(Failure(reason: "An item with that name is already in the Trash."))
        }
        guard renameat(parent, sourceName, trash, destinationName) == 0 else {
            return .failure(Failure(reason: String(cString: strerror(errno))))
        }
        return .success(())
    }
}
