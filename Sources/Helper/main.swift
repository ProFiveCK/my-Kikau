import Core
import Foundation
import os
import Security

// myKikauHelper — the privileged helper.
//
// Runs as root, started on demand by launchd when the app connects (it is
// registered with SMAppService and must be approved by an administrator in
// System Settings). It does one thing: move items that `HelperPolicy` allows
// into the calling user's Trash.
//
// Three checks stand between a request and any change:
//   1. the connecting process must be myKikau, signed by our team;
//   2. the request must carry an authorization an administrator approved;
//   3. each path must pass `HelperPolicy`, judged here from the file system.

private let log = Logger(subsystem: "com.profiveck.myKikau.helper", category: "helper")

/// A plain-text trail as well, readable without `log show`:
/// /Library/Logs/myKikau/helper.log (root-owned; the helper only appends).
private func note(_ message: String) {
    log.notice("\(message, privacy: .public)")
    let directory = "/Library/Logs/myKikau"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let path = directory + "/helper.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}

/// Makes sure our right exists in the authorization database with the rule
/// "authenticate as an administrator" and our own prompt. Done at every
/// start; it's a no-op once the right is there.
private func defineAuthorizationRight() {
    let name = PrivilegedHelperConstants.authorizationRight
    if AuthorizationRightGet(name, nil) == errAuthorizationSuccess {
        return
    }
    var reference: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return }
    defer { AuthorizationFree(reference, []) }
    let status = AuthorizationRightSet(
        reference,
        name,
        kAuthorizationRuleAuthenticateAsAdmin as CFTypeRef,
        "myKikau wants to remove software that was installed for all users." as CFString,
        nil,
        nil
    )
    note(status == errAuthorizationSuccess ? "defined authorization right" : "could not define authorization right: \(status)")
}

/// Exit after a quiet period; launchd starts the helper again on demand.
private final class IdleMonitor: @unchecked Sendable {
    static let shared = IdleMonitor()
    private let lock = NSLock()
    private var lastActivity = Date()
    private var active = 0
    private let timer = DispatchSource.makeTimerSource(queue: .global())

    func start() {
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [self] in
            lock.lock()
            let idle = active == 0 && Date().timeIntervalSince(lastActivity) > 60
            lock.unlock()
            if idle {
                exit(0)
            }
        }
        timer.resume()
    }

    func begin() {
        lock.lock()
        active += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        lastActivity = Date()
        lock.unlock()
    }
}

private final class ConnectionHandler: NSObject, PrivilegedHelperProtocol {
    /// The user on the other end of the connection, from the kernel — not
    /// from anything the client says.
    private let userID: uid_t

    init(userID: uid_t) {
        self.userID = userID
    }

    func helperVersion(reply: @escaping (Int) -> Void) {
        reply(PrivilegedHelperConstants.protocolVersion)
    }

    func removeItems(
        atPaths paths: [String],
        authorization: Data,
        reply: @escaping ([String: String], [String: String]) -> Void
    ) {
        IdleMonitor.shared.begin()
        defer { IdleMonitor.shared.end() }

        var removed: [String: String] = [:]
        var failed: [String: String] = [:]

        note("request from uid \(userID) for \(paths.count) item(s)")
        guard isAuthorized(authorization) else {
            note("request from uid \(userID) refused: no administrator authorization")
            for path in paths {
                failed[path] = "An administrator didn't approve this."
            }
            reply(removed, failed)
            return
        }
        guard paths.count <= 500 else {
            for path in paths {
                failed[path] = "Too many items in one request."
            }
            reply(removed, failed)
            return
        }
        guard let trash = userTrash() else {
            for path in paths {
                failed[path] = "Couldn't find your Trash."
            }
            reply(removed, failed)
            return
        }

        for path in paths {
            switch HelperPolicy.validateRemoval(path: path) {
            case let .failure(rejection):
                note("refused \(path): \(rejection.reason)")
                failed[path] = rejection.reason
            case let .success(kind):
                do {
                    if kind == .launchItem {
                        stopLaunchItem(path)
                    }
                    let destination = try moveToTrash(path, trash: trash)
                    removed[path] = destination
                    note("moved \(path) to the Trash of uid \(userID)")
                } catch {
                    note("failed \(path): \(error.localizedDescription)")
                    failed[path] = error.localizedDescription
                }
            }
        }
        reply(removed, failed)
    }

    /// Asks the authorization system for our right using the reference the
    /// app passed over. This is what shows the administrator password prompt
    /// (in the user's session, with the wording defined at startup); it
    /// succeeds only if an administrator authenticates.
    private func isAuthorized(_ data: Data) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else {
            note("authorization blob has the wrong size: \(data.count)")
            return false
        }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { _ = data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        let created = AuthorizationCreateFromExternalForm(&form, &reference)
        guard created == errAuthorizationSuccess, let reference else {
            note("could not read the app's authorization: \(created)")
            return false
        }
        defer { AuthorizationFree(reference, []) }
        let status = PrivilegedHelperConstants.authorizationRight.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, [.extendRights, .interactionAllowed], nil)
            }
        }
        if status != errAuthorizationSuccess {
            note("authorization not granted: \(status)")
        }
        return status == errAuthorizationSuccess
    }

    /// The caller's `~/.Trash`, if it is a real folder they own.
    private func userTrash() -> String? {
        guard let entry = getpwuid(userID), let home = entry.pointee.pw_dir else { return nil }
        let trash = String(cString: home) + "/.Trash"
        var info = stat()
        guard lstat(trash, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == userID else { return nil }
        return trash
    }

    private func moveToTrash(_ path: String, trash: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        var destination = trash + "/" + name
        var counter = 1
        while FileManager.default.fileExists(atPath: destination) {
            counter += 1
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            destination = trash + "/" + base + " \(counter)" + (ext.isEmpty ? "" : "." + ext)
        }
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }

    /// Unloads a launch daemon or agent so removing its plist takes effect now.
    private func stopLaunchItem(_ path: String) {
        let domain = path.contains("/LaunchDaemons/") ? "system" : "gui/\(userID)"
        _ = ProcessRunner.runBlocking("/bin/launchctl", ["bootout", domain, path], timeout: 20)
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Messages from anything that isn't our signed app are dropped by
        // the XPC runtime before they reach the handler.
        connection.setCodeSigningRequirement(PrivilegedHelperConstants.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedObject = ConnectionHandler(userID: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
IdleMonitor.shared.start()
defineAuthorizationRight()
note("helper started (protocol \(PrivilegedHelperConstants.protocolVersion))")
dispatchMain()
