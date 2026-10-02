import Foundation
import Core

/// Looks up whether a newer version of an installed app exists.
///
/// Two sources, both the app's own:
/// - apps that update themselves with Sparkle publish a feed (`SUFeedURL` in
///   their Info.plist) — the same feed the app itself reads;
/// - App Store apps are looked up by bundle ID in Apple's public catalogue.
///
/// This contacts those servers, so it only ever runs when the user asks.
/// myKikau doesn't install anything: it reports, and opens the app or the
/// App Store so the app can update itself.
public enum AppUpdateChecker {
    public struct Update: Hashable, Sendable {
        public let latestVersion: String
        /// Where to get it: the App Store page, when there is one.
        public let storeURL: URL?
    }

    /// Checks every app that has a known update source. Keys are `AppInfo.id`.
    public static func check(
        _ apps: [AppInventory.AppInfo],
        session: URLSession = .shared,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [String: Update] {
        let candidates = apps.filter { $0.version != nil && $0.bundleID != nil && !AppInventory.isProtected($0) }
        var results: [String: Update] = [:]
        var done = 0
        // A few at a time: polite to the servers, and quick enough.
        var remaining = candidates[...]
        await withTaskGroup(of: (String, Update?).self) { group in
            func addNext() {
                guard let app = remaining.popFirst() else { return }
                group.addTask { await (app.id, latest(for: app, session: session)) }
            }
            for _ in 0 ..< 6 {
                addNext()
            }
            for await (id, update) in group {
                if let update {
                    results[id] = update
                }
                done += 1
                onProgress?(done, candidates.count)
                if !Task.isCancelled {
                    addNext()
                }
            }
        }
        return results
    }

    /// The newest published version of one app, if it's newer than what's installed.
    static func latest(for app: AppInventory.AppInfo, session: URLSession) async -> Update? {
        guard let installed = app.version, let bundleID = app.bundleID else { return nil }
        var found: Update?
        if app.isAppStore {
            found = await appStoreVersion(bundleID: bundleID, session: session)
        } else if let feed = sparkleFeedURL(appURL: app.url) {
            if let version = await sparkleVersion(feed: feed, session: session) {
                found = Update(latestVersion: version, storeURL: nil)
            }
        }
        guard let found, isNewer(found.latestVersion, than: installed) else { return nil }
        return found
    }

    /// The app's Sparkle feed, if it has one and it's served over HTTPS.
    static func sparkleFeedURL(appURL: URL) -> URL? {
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        guard let text = info?["SUFeedURL"] as? String,
              let url = URL(string: text), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// True if `candidate` is a higher version than `installed`, comparing
    /// each dotted component as a number ("1.10" is newer than "1.9").
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: .numeric) == .orderedDescending
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("myKikau", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 5_000_000 else { return nil }
        return data
    }

    private static func sparkleVersion(feed: URL, session: URLSession) async -> String? {
        guard let data = await fetch(feed, session: session) else { return nil }
        return latestVersion(inAppcast: data)
    }

    private static func appStoreVersion(bundleID: String, session: URLSession) async -> Update? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "entity", value: "macSoftware")]
        guard let url = components?.url, let data = await fetch(url, session: session) else { return nil }
        return appStoreUpdate(fromLookup: data)
    }

    /// Parses Apple's lookup response.
    static func appStoreUpdate(fromLookup data: Data) -> Update? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let version = first["version"] as? String else { return nil }
        let store = (first["trackViewUrl"] as? String).flatMap(URL.init(string:))
        return Update(latestVersion: version, storeURL: store)
    }

    /// The highest release version in a Sparkle appcast. Items on a named
    /// channel (betas) are ignored.
    static func latestVersion(inAppcast data: Data) -> String? {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Never fetch anything the feed points at.
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
