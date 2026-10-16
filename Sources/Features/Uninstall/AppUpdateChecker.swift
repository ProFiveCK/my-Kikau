import Foundation
import Core

/// Queries publisher feeds and Apple's catalogue only on request. Every app
/// receives a status; lack of evidence is never reported as "up to date".
public enum AppUpdateChecker {
    public struct Update: Hashable, Sendable {
        public let latestVersion: String
        public let storeURL: URL?
    }

    public enum CheckStatus: Hashable, Sendable {
        case upToDate
        case available(Update)
        case unsupported(String)
        case failed(String)
        public var label: String {
            switch self {
            case .upToDate: "Up to date"
            case .available: "Update available"
            case .unsupported: "Unsupported"
            case .failed: "Check failed"
            }
        }

        public var detail: String? {
            switch self { case let .unsupported(s), let .failed(s): s; default: nil }
        }
    }

    public struct Report: Sendable {
        public var statuses: [String: CheckStatus]
        public init(statuses: [String: CheckStatus] = [:]) {
            self.statuses = statuses
        }

        public var updates: [String: Update] {
            statuses.compactMapValues {
                if case let .available(update) = $0 {
                    update
                } else {
                    nil
                }
            }
        }

        public var upToDateCount: Int {
            statuses.values.filter { $0 == .upToDate }.count
        }

        public var unsupportedCount: Int {
            statuses.values.filter {
                if case .unsupported = $0 {
                    true
                } else {
                    false
                }
            }.count
        }

        public var failedCount: Int {
            statuses.values.filter {
                if case .failed = $0 {
                    true
                } else {
                    false
                }
            }.count
        }

        public var summary: String {
            "\(updates.count) updates · \(upToDateCount) up to date · \(unsupportedCount) unsupported · \(failedCount) failed"
        }
    }

    public static func checkReport(
        _ apps: [AppInventory.AppInfo], session: URLSession = .shared,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> Report {
        var statuses: [String: CheckStatus] = [:]
        var remaining = apps[...]
        var done = 0
        await withTaskGroup(of: (String, CheckStatus).self) { group in
            func addNext() {
                guard let app = remaining.popFirst(), !Task.isCancelled else { return }
                group.addTask { await (app.id, status(for: app, session: session)) }
            }
            for _ in 0 ..< 6 {
                addNext()
            }
            for await (id, status) in group {
                statuses[id] = status
                done += 1
                onProgress?(done, apps.count)
                addNext()
            }
        }
        return Report(statuses: statuses)
    }

    /// Compatibility for reporting clients that only need available updates.
    public static func check(
        _ apps: [AppInventory.AppInfo],
        session: URLSession = .shared,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [String: Update] {
        await checkReport(apps, session: session, onProgress: onProgress).updates
    }

    static func status(for app: AppInventory.AppInfo, session: URLSession) async -> CheckStatus {
        guard !AppInventory.isProtected(app) else { return .unsupported("Protected application") }
        guard let installed = app.version, let bundleID = app.bundleID else {
            return .unsupported("The app does not provide a version and bundle identifier.")
        }
        do {
            let found: Update
            if app.isAppStore {
                var components = URLComponents(string: "https://itunes.apple.com/lookup")!
                components.queryItems = [
                    URLQueryItem(name: "bundleId", value: bundleID),
                    URLQueryItem(name: "entity", value: "macSoftware"),
                ]
                let data = try await fetch(components.url!, session: session)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = root["results"] as? [[String: Any]] else { throw CheckFailure.invalidResponse }
                guard !results.isEmpty else { return .unsupported("Not listed in the queried App Store catalogue.") }
                guard let update = appStoreUpdate(fromLookup: data) else { throw CheckFailure.invalidResponse }
                found = update
            } else {
                guard let feed = sparkleFeedURL(appURL: app.url) else {
                    return .unsupported("No supported HTTPS publisher feed. Check within the app.")
                }
                let data = try await fetch(feed, session: session)
                guard let version = latestVersion(inAppcast: data) else { throw CheckFailure.invalidResponse }
                found = Update(latestVersion: version, storeURL: nil)
            }
            return isNewer(found.latestVersion, than: installed) ? .available(found) : .upToDate
        } catch { return .failed(error.localizedDescription) }
    }

    static func latest(for app: AppInventory.AppInfo, session: URLSession) async -> Update? {
        if case let .available(update) = await status(for: app, session: session) {
            return update
        }
        return nil
    }

    static func sparkleFeedURL(appURL: URL) -> URL? {
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        guard let text = info?["SUFeedURL"] as? String, let url = URL(string: text),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }

    private enum CheckFailure: LocalizedError {
        case invalidResponse
        var errorDescription: String? {
            "The update source did not return a usable version."
        }
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("myKikau", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else {
            throw CheckFailure.invalidResponse
        }
        return data
    }

    static func appStoreUpdate(fromLookup data: Data) -> Update? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let version = first["version"] as? String else { return nil }
        return Update(latestVersion: version, storeURL: (first["trackViewUrl"] as? String).flatMap(URL.init(string:)))
    }

    static func latestVersion(inAppcast data: Data) -> String? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return delegate.versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    var versions: [String] = []
    private var inItem = false
    private var itemVersion: String?
    private var itemBuild: String?
    private var itemHasChannel = false
    private var text = ""

    func parser(
        _: XMLParser, didStartElement name: String, namespaceURI _: String?,
        qualifiedName _: String?, attributes: [String: String] = [:]
    ) {
        text = ""
        if name == "item" {
            inItem = true
            itemVersion = nil
            itemBuild = nil
            itemHasChannel = false
        } else if inItem, name == "enclosure" {
            itemVersion = itemVersion ?? attributes["sparkle:shortVersionString"]
            itemBuild = itemBuild ?? attributes["sparkle:version"]
        } else if inItem, name == "sparkle:channel" {
            itemHasChannel = true
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_: XMLParser, didEndElement name: String, namespaceURI _: String?, qualifiedName _: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem, name == "sparkle:shortVersionString", !value.isEmpty {
            itemVersion = value
        } else if inItem, name == "sparkle:version", !value.isEmpty {
            itemBuild = value
        } else if name == "item" {
            // The marketing version is what the user sees and what
            // CFBundleShortVersionString holds; a build number alone can't be
            // compared with it.
            if !itemHasChannel, let version = itemVersion {
                versions.append(version)
            }
            inItem = false
        }
        text = ""
    }
}
