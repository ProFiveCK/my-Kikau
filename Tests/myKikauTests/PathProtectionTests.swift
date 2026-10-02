import Testing
import Core
import Foundation

@Suite("PathProtection")
struct PathProtectionTests {
    let protection = PathProtection.shared

    @Test("Protects system paths")
    func protectsSystemPaths() {
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/System")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/System/Library")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Library/Apple")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/usr/bin")) == true)
    }

    @Test("Does not protect user paths")
    func doesNotProtectUserPaths() {
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Users/test/Library/Caches")) == false)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Applications/SomeApp.app")) == false)
    }

    @Test("Protects system critical bundles")
    func protectsCriticalBundles() {
        #expect(protection.isSystemCriticalBundle("com.apple.finder") == true)
        #expect(protection.isSystemCriticalBundle("com.apple.dock") == true)
        #expect(protection.isSystemCriticalBundle("com.apple.Safari") == true)
    }

    @Test("Does not protect user-installed Apple apps")
    func allowsUserAppleApps() {
        #expect(protection.isSystemCriticalBundle("com.apple.dt.Xcode") == false)
        #expect(protection.isSystemCriticalBundle("com.apple.FinalCutPro") == false)
    }

    @Test("Detects endpoint security bundles")
    func detectsEndpointSecurity() {
        #expect(protection.isEndpointSecurityBundle("com.crowdstrike.falcon") == true)
        #expect(protection.isEndpointSecurityBundle("com.sentinelone.agent") == true)
        #expect(protection.isEndpointSecurityBundle("com.example.app") == false)
    }

    @Test("Glob wildcard matching")
    func globMatching() {
        #expect(protection.isSystemCriticalBundle("com.apple.SettingsSystemSettings") == true)
        #expect(protection.isSystemCriticalBundle("com.apple.controlcenter") == true)
    }

    // MARK: - Containers and user data

    @Test("Top-level containers are protected; their contents are judged individually")
    func protectsContainers() {
        for path in ["/", "/Users", "/Applications", "/Library", "/Volumes", "/private/var", "/var/folders", "/tmp"] {
            #expect(protection.shouldProtect(URL(fileURLWithPath: path)) == true, "\(path) should be protected")
        }
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Library/Caches/com.example.app")) == false)
    }

    @Test("The home folder and its standard folders are protected; ordinary contents are not")
    func protectsHomeContainers() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let protection = PathProtection(home: home, exclusions: { [] }, extraBundlePrefixes: { [] })
        for relative in ["", "Library", "Library/Caches", "Library/Preferences", "Library/Logs", "Documents", "Desktop", "Downloads", ".Trash"] {
            let url = relative.isEmpty ? home : home.appendingPathComponent(relative)
            #expect(protection.shouldProtect(url) == true, "~/\(relative) should be protected")
        }
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Caches/com.example.app")) == false)
        #expect(protection.shouldProtect(home.appendingPathComponent("Documents/report.pdf")) == false)
        #expect(protection.shouldProtect(home.appendingPathComponent(".Trash/old.zip")) == false)
    }

    @Test("Credentials, mail, iCloud data and myKikau's own log are protected subtrees")
    func protectsUserDataSubtrees() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let protection = PathProtection(home: home, exclusions: { [] }, extraBundlePrefixes: { [] })
        for relative in [
            "Library/Keychains/login.keychain-db", ".ssh/id_ed25519", ".gnupg/pubring.kbx",
            "Library/Mail/V10", "Library/Messages/chat.db", "Library/Mobile Documents/com~apple~CloudDocs/a.txt",
            "Library/Logs/myKikau", "Library/Logs/myKikau/operations.log"
        ] {
            #expect(protection.shouldProtect(home.appendingPathComponent(relative)) == true, "~/\(relative) should be protected")
        }
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Logs/SomeApp")) == false)
    }

    // MARK: - Path tricks

    @Test("A `..` segment that lands in a protected tree is caught")
    func catchesParentTraversal() {
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Users/Shared/../../System/Library")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/private/etc/hosts")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/etc/hosts")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/private/var/db/receipts")) == true)
    }

    @Test("A symlink into a protected tree is protected")
    func catchesSymlinks() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let link = tmp.appendingPathComponent("innocent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System/Library"))

        #expect(protection.shouldProtect(link) == true)
        #expect(protection.shouldProtect(link.appendingPathComponent("CoreServices")) == true)
        // An ordinary sibling isn't affected.
        #expect(protection.shouldProtect(tmp.appendingPathComponent("plain")) == false)
    }

    @Test("normalise drops the /private alias and trailing slashes")
    func normalises() {
        #expect(PathProtection.normalise("/private/var/folders/x/") == "/var/folders/x")
        #expect(PathProtection.normalise("/private/tmp") == "/tmp")
        #expect(PathProtection.normalise("/private/other") == "/private/other")
        #expect(PathProtection.normalise("/") == "/")
    }

    // MARK: - Security agents and exclusions

    @Test("Anything owned by a security or device-management agent is protected, wherever it lives")
    func protectsEndpointSecurityPaths() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let protection = PathProtection(home: home, exclusions: { [] }, extraBundlePrefixes: { [] })
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Caches/com.crowdstrike.falcon.Agent")) == true)
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Preferences/com.jamf.connect.plist")) == true)
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Group Containers/UBF8T346G9.com.microsoft.wdav")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Library/LaunchDaemons/com.sentinelone.sentineld.plist")) == true)
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Caches/com.example.app")) == false)
        #expect(protection.isEndpointSecurityBundle("com.microsoft.wdav") == true)
    }

    @Test("Administrator-supplied bundle prefixes are honoured")
    func honoursManagedBundlePrefixes() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let protection = PathProtection(home: home, exclusions: { [] }, extraBundlePrefixes: { ["com.acme.security."] })
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Caches/com.acme.security.agent")) == true)
        #expect(protection.isEndpointSecurityBundle("com.acme.security.agent") == true)
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Caches/com.acme.notes")) == false)
    }

    @Test("Excluded paths protect themselves and everything beneath them")
    func honoursExclusions() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let protection = PathProtection(
            home: home,
            exclusions: { ["/Users/tester/Projects/keep"] },
            extraBundlePrefixes: { [] }
        )
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Users/tester/Projects/keep")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Users/tester/Projects/keep/node_modules")) == true)
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Users/tester/Projects/keeper")) == false)
    }

    @Test("A folder that contains a protected or excluded item can't be removed whole")
    func protectsAncestorsOfProtectedItems() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let protection = PathProtection(
            home: home,
            exclusions: { ["/Users/tester/Library/Developer/Xcode/DerivedData/MyApp-abc"] },
            extraBundlePrefixes: { [] }
        )
        // The exclusion itself, things in it, and every folder above it.
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/MyApp-abc/Build")))
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Developer/Xcode/DerivedData")))
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Developer")))
        // A sibling is unaffected.
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Other-xyz")) == false)
        // Same for the built-in user-data subtrees.
        #expect(protection.shouldProtect(home.appendingPathComponent("Library/Logs")))
    }

    @Test("Exclusions match regardless of letter case")
    func exclusionsIgnoreCase() {
        let protection = PathProtection(
            home: URL(fileURLWithPath: "/Users/tester"),
            exclusions: { ["/Users/tester/Projects/keep"] },
            extraBundlePrefixes: { [] }
        )
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Users/tester/Projects/Keep/data.bin")))
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/users/tester/projects/KEEP")))
    }

    @Test("Only a real Team ID is stripped — not any ten-letter word")
    func teamIDStripping() {
        #expect(PathProtection.strippingTeamID("ABCDE12345.com.example.app") == "com.example.app")
        #expect(PathProtection.strippingTeamID("university.example.app") == "university.example.app")
        #expect(PathProtection.strippingTeamID("abcde12345.com.example.app") == "abcde12345.com.example.app")
        #expect(PathProtection.strippingTeamID("SHORT.com.example.app") == "SHORT.com.example.app")
    }

    @Test("A security agent's folder nested inside a vendor folder protects the vendor folder")
    func nestedSecurityAgentFolder() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let vendor = tmp.appendingPathComponent("VendorCache")
        try FileManager.default.createDirectory(
            at: vendor.appendingPathComponent("plugins/com.crowdstrike.falcon.Agent"), withIntermediateDirectories: true
        )
        let plain = tmp.appendingPathComponent("PlainCache")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("data"), withIntermediateDirectories: true)

        #expect(protection.containsEndpointSecurityItem(vendor))
        #expect(protection.containsEndpointSecurityItem(plain) == false)

        let plan = SafeFileDeleter().preview([vendor, plain], category: .cache)
        #expect(plan.items.map(\.url.lastPathComponent) == ["PlainCache"])
        #expect(plan.protectedItems.map(\.url.lastPathComponent) == ["VendorCache"])
    }
}
