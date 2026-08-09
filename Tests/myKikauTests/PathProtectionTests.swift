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
        #expect(protection.shouldProtect(URL(fileURLWithPath: "/Applications")) == false)
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
}