import Testing
@testable import Features
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@Suite("AppUpdateChecker")
struct AppUpdateCheckerTests {
    @Test("Versions compare numerically, component by component")
    func versionComparison() {
        #expect(AppUpdateChecker.isNewer("1.10", than: "1.9"))
        #expect(AppUpdateChecker.isNewer("2.0", than: "1.99.9"))
        #expect(AppUpdateChecker.isNewer("1.2.1", than: "1.2"))
        #expect(!AppUpdateChecker.isNewer("1.2", than: "1.2"))
        #expect(!AppUpdateChecker.isNewer("1.9", than: "1.10"))
    }

    @Test("The newest release in an appcast wins; beta-channel items are ignored")
    func parsesAppcast() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>2.9</title>
              <sparkle:version>290</sparkle:version>
              <sparkle:shortVersionString>2.9</sparkle:shortVersionString>
              <enclosure url="https://example.com/a.dmg" length="1"/>
            </item>
            <item>
              <title>2.10</title>
              <enclosure url="https://example.com/b.dmg" sparkle:version="2100" sparkle:shortVersionString="2.10" length="1"/>
            </item>
            <item>
              <title>3.0 beta</title>
              <sparkle:channel>beta</sparkle:channel>
              <sparkle:shortVersionString>3.0</sparkle:shortVersionString>
              <enclosure url="https://example.com/c.dmg" length="1"/>
            </item>
          </channel>
        </rss>
        """
        #expect(AppUpdateChecker.latestVersion(inAppcast: Data(xml.utf8)) == "2.10")
        #expect(AppUpdateChecker.latestVersion(inAppcast: Data("not xml".utf8)) == nil)
        #expect(AppUpdateChecker.latestVersion(inAppcast: Data("<rss><channel></channel></rss>".utf8)) == nil)
    }

    @Test("The App Store lookup response yields a version and a store page")
    func parsesAppStoreLookup() {
        let json = #"{"resultCount":1,"results":[{"version":"4.2.1","trackViewUrl":"https://apps.apple.com/app/id123"}]}"#
        let update = AppUpdateChecker.appStoreUpdate(fromLookup: Data(json.utf8))
        #expect(update?.latestVersion == "4.2.1")
        #expect(update?.storeURL?.absoluteString == "https://apps.apple.com/app/id123")
        #expect(AppUpdateChecker.appStoreUpdate(fromLookup: Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
    }

    @Test("Only an HTTPS feed is ever contacted")
    func feedMustBeHTTPS() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func app(_ name: String, feed: String?) throws -> URL {
            let url = dir.appendingPathComponent("\(name).app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "com.example.\(name)"]
            if let feed { info["SUFeedURL"] = feed }
            (info as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true)
            return url
        }
        #expect(AppUpdateChecker.sparkleFeedURL(appURL: try app("secure", feed: "https://example.com/appcast.xml")) != nil)
        #expect(AppUpdateChecker.sparkleFeedURL(appURL: try app("plain", feed: "http://example.com/appcast.xml")) == nil)
        #expect(AppUpdateChecker.sparkleFeedURL(appURL: try app("file", feed: "file:///etc/hosts")) == nil)
        #expect(AppUpdateChecker.sparkleFeedURL(appURL: try app("none", feed: nil)) == nil)
    }
}

@Suite("SimilarImageFinder")
struct SimilarImageFinderTests {
    /// Real photographs that ship with macOS — synthetic test images don't
    /// exercise an image model meaningfully.
    private func systemPictures() -> [URL] {
        let names = ["Sonoma.heic", "Valley Light.heic", "Radial Sky Blue.heic"]
        return names.map { URL(fileURLWithPath: "/System/Library/Desktop Pictures/\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func writeJPEG(of source: URL, maxPixelSize: Int, quality: Double, to destination: URL) throws {
        let image = try #require(SimilarImageFinder.thumbnail(of: source, maxPixelSize: maxPixelSize))
        let output = try #require(CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(output))
    }

    @Test("A resized, recompressed copy is grouped with its original; an unrelated picture is not")
    func groupsLookAlikes() throws {
        let pictures = systemPictures()
        // Needs two different system pictures; skip quietly on a Mac without them.
        guard pictures.count >= 2 else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("original.jpg")
        let smaller = dir.appendingPathComponent("smaller-copy.jpg")
        let unrelated = dir.appendingPathComponent("unrelated.jpg")
        try writeJPEG(of: pictures[0], maxPixelSize: 1600, quality: 0.9, to: original)
        try writeJPEG(of: pictures[0], maxPixelSize: 1200, quality: 0.75, to: smaller)
        try writeJPEG(of: pictures[1], maxPixelSize: 1600, quality: 0.9, to: unrelated)

        let files = try [original, smaller, unrelated].map { url -> DuplicateFinder.FileEntry in
            let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            return DuplicateFinder.FileEntry(url: url, sizeBytes: Int64(size), modified: nil)
        }
        let report = SimilarImageFinder.find(in: files)

        #expect(report.imagesExamined == 3)
        #expect(report.groups.count == 1)
        let names = report.groups.first?.files.map(\.url.lastPathComponent) ?? []
        #expect(Set(names) == ["original.jpg", "smaller-copy.jpg"])
        // Largest first: the copy worth keeping.
        #expect(names.first == "original.jpg")
    }

    @Test("Non-images and tiny images are left out")
    func ignoresNonImages() {
        let files = [
            DuplicateFinder.FileEntry(url: URL(fileURLWithPath: "/tmp/a.pdf"), sizeBytes: 5_000_000, modified: nil),
            DuplicateFinder.FileEntry(url: URL(fileURLWithPath: "/tmp/icon.png"), sizeBytes: 2000, modified: nil),
        ]
        let report = SimilarImageFinder.find(in: files)
        #expect(report.imagesExamined == 0)
        #expect(report.groups.isEmpty)
    }
}
