import Core
import Foundation
import Security
import ServiceManagement

/// The app's side of the privileged helper: installing it, and asking it to
/// remove items the logged-in user can't (apps installed for all users,
/// system-wide launch plists).
///
/// The helper is optional. Nothing here runs unless the user has installed it
/// from Settings and an administrator has approved it in System Settings.
public enum PrivilegedHelperClient {
    public enum Status: Equatable, Sendable {
        /// This build doesn't include the helper (a development build).
        case notBundled
        case notInstalled
        /// Registered, waiting for approval in System Settings → Login Items.
        case requiresApproval
        case enabled
    }

    public struct RemovalResult: Sendable {
        /// Original path → where it now is in the Trash.
        public var removed: [String: String] = [:]
        /// Original path → why it wasn't removed.
        public var failed: [String: String] = [:]
    }

    private static var service: SMAppService {
        SMAppService.daemon(plistName: PrivilegedHelperConstants.daemonPlistName)
    }

    /// Whether the helper and its launchd plist are inside this app bundle.
    public static var isBundled: Bool {
        let bundle = Bundle.main.bundleURL
        let fm = FileManager.default
        return fm.fileExists(atPath: bundle.appendingPathComponent(
            "Contents/Library/LaunchDaemons/\(PrivilegedHelperConstants.daemonPlistName)"
        ).path) && fm.fileExists(atPath: bundle.appendingPathComponent(
            "Contents/MacOS/\(PrivilegedHelperConstants.helperExecutableName)"
        ).path)
    }

    public static var status: Status {
        guard isBundled else { return .notBundled }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .notInstalled
        }
    }

    public static var isEnabled: Bool {
        status == .enabled
    }

    /// Registers the helper with launchd. macOS then asks an administrator
    /// to allow it under System Settings → General → Login Items & Extensions.
    public static func install() throws {
        try service.register()
    }

    public static func uninstall() async throws {
        try await service.unregister()
    }

    public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Asks for an administrator password, then asks the helper to move
    /// `paths` to the Trash. The helper decides for itself whether each path
    /// is allowed; anything it refuses comes back in `failed` with the reason.
    public static func removeItems(_ paths: [String]) async -> RemovalResult {
        var result = RemovalResult()
        func failAll(_ reason: String) -> RemovalResult {
            for path in paths {
                result.failed[path] = reason
            }
            return result
        }
        guard !paths.isEmpty else { return result }
        guard isEnabled else { return failAll("The administrator helper isn't installed.") }

        let authorization: Data
        switch await Task.detached(operation: { authorize() }).value {
        case let .success(data): authorization = data
        case let .failure(error): return failAll(error.message)
        }

        let connection = NSXPCConnection(
            machServiceName: PrivilegedHelperConstants.machServiceName, options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        // Only ever talk to a helper signed by us.
        connection.setCodeSigningRequirement(PrivilegedHelperConstants.helperRequirement)
        connection.resume()
        defer { connection.invalidate() }

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(failAll("Couldn't reach the helper: \(error.localizedDescription)"))
            } as? PrivilegedHelperProtocol
            guard let proxy else {
                once.resume(failAll("Couldn't reach the helper."))
                return
            }
            proxy.removeItems(atPaths: paths, authorization: authorization) { removed, failed in
                once.resume(RemovalResult(removed: removed, failed: failed))
            }
        }
    }

    private struct AuthorizationError: Error {
        let message: String
    }

    /// Shows the standard administrator password prompt for our right and
    /// returns the authorization in the form the helper can verify.
    private static func authorize() -> Result<Data, AuthorizationError> {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
            return .failure(AuthorizationError(message: "Couldn't start authorization."))
        }
        defer { AuthorizationFree(reference, []) }

        let status = PrivilegedHelperConstants.authorizationRight.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(
                    reference, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil
                )
            }
        }
        if status == errAuthorizationCanceled {
            return .failure(AuthorizationError(message: "Cancelled — nothing was changed."))
        }
        guard status == errAuthorizationSuccess else {
            return .failure(AuthorizationError(message: "An administrator didn't approve this."))
        }

        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &form) == errAuthorizationSuccess else {
            return .failure(AuthorizationError(message: "Couldn't pass the authorization to the helper."))
        }
        return .success(withUnsafeBytes(of: &form) { Data($0) })
    }
}

/// A continuation that both the reply and the error handler may try to
/// resume; only the first one does.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
