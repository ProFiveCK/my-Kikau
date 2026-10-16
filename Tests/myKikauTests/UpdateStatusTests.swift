import Foundation
import Testing
@testable import Features

private final class UpdateFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.invalid" || request.url?.host == "itunes.apple.com"
    }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let status = url.path.contains("offline") ? 503 : 200
        let text: String
        if url.path.contains("malformed") {
            text = "bad response"
        } else if url.host == "itunes.apple.com" {
            text = #"{"resultCount":0,"results":[]}"#
        } else {
            let version = url.path.contains("newer") ? "3.0" : "1.0"
            text = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
              <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            </item></channel></rss>
            """
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("App update evidence")
struct UpdateStatusTests {
    @Test("Available, up to date, unsupported and failed remain distinct")
    func statuses() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func app(_ name: String, feed: String?, store: Bool = false) throws -> AppInventory.AppInfo {
            let url = dir.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "com.fixture.\(name)"]
            if let feed { info["SUFeedURL"] = feed }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
            return .init(
                url: url, name: name, bundleID: "com.fixture.\(name)", version: "1.0",
                sizeBytes: 1, lastModified: nil, isAppStore: store
            )
        }
        let apps = try [app("current", feed: "https://fixture.invalid/current"),
                        app("newer", feed: "https://fixture.invalid/newer"),
                        app("unsupported", feed: nil),
                        app("offline", feed: "https://fixture.invalid/offline"),
                        app("malformed", feed: "https://fixture.invalid/malformed"),
                        app("store", feed: nil, store: true)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let report = await AppUpdateChecker.checkReport(apps, session: session)
        #expect(report.statuses.count == 6)
        #expect(report.upToDateCount == 1)
        #expect(report.updates.count == 1)
        #expect(report.unsupportedCount == 2)
        #expect(report.failedCount == 2)
        #expect(report.statuses[apps[0].id] == .upToDate)
        #expect(report.updates[apps[1].id]?.latestVersion == "3.0")
        #expect(report.summary.contains("2 failed"))
        #expect(!report.summary.contains("all up to date"))
    }
}
