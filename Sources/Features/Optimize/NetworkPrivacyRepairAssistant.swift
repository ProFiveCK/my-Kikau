import CryptoKit
import Foundation

/// Prepares a reversible, user-driven repair package for macOS's Local Network
/// privacy store. It never disables SIP, deletes system files, or restarts the
/// Mac; those security-sensitive steps remain explicit Recovery actions.
public enum NetworkPrivacyRepairAssistant {
    public struct PreparedRepair: Hashable, Sendable {
        public let directory: URL
        public let copiedFiles: [URL]
        public let checksumsURL: URL
        public let instructionsURL: URL
    }

    public enum PreparationError: LocalizedError {
        case noSourceFiles

        public var errorDescription: String? {
            switch self {
            case .noSourceFiles: "No Network Extension preference files were available to back up."
            }
        }
    }

    public static let systemPreferenceFiles = [
        "com.apple.networkextension.plist",
        "com.apple.networkextension.uuidcache.plist",
        "com.apple.networkextension.cache.plist",
        "com.apple.networkextension.control.plist",
        "com.apple.networkextension.necp.plist",
    ].map { URL(fileURLWithPath: "/Library/Preferences").appendingPathComponent($0) }

    public static func prepare(
        sourceFiles: [URL] = systemPreferenceFiles,
        destinationRoot: URL? = nil,
        date: Date = Date()
    ) throws -> PreparedRepair {
        let existing = sourceFiles.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !existing.isEmpty else { throw PreparationError.noSourceFiles }

        let root = destinationRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/myKikau Repairs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = root.appendingPathComponent(
            "Network-Privacy-Repair-\(formatter.string(from: date))"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        var copiedFiles: [URL] = []
        var checksumLines: [String] = []
        for source in existing {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            copiedFiles.append(destination)
            let data = try Data(contentsOf: destination)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            checksumLines.append("\(digest)  \(destination.lastPathComponent)")
        }

        let checksumsURL = directory.appendingPathComponent("SHA256SUMS.txt")
        try (checksumLines.sorted().joined(separator: "\n") + "\n")
            .write(to: checksumsURL, atomically: true, encoding: .utf8)

        let instructionsURL = directory.appendingPathComponent("RECOVERY-INSTRUCTIONS.txt")
        try recoveryInstructions(backupDirectory: directory)
            .write(to: instructionsURL, atomically: true, encoding: .utf8)

        return PreparedRepair(
            directory: directory,
            copiedFiles: copiedFiles.sorted { $0.lastPathComponent < $1.lastPathComponent },
            checksumsURL: checksumsURL,
            instructionsURL: instructionsURL
        )
    }

    private static func recoveryInstructions(backupDirectory: URL) -> String {
        """
        myKikau — Local Network Privacy guided repair

        Backup directory:
        \(backupDirectory.path)

        WHY THIS IS GUIDED
        macOS provides no supported per-app reset for Local Network privacy.
        The preference store is protected by System Integrity Protection (SIP).
        myKikau has created a verified backup but will not disable SIP or delete
        protected system settings without your explicit Recovery actions.

        IMPACT
        This resets Local Network privacy entries for all apps. VPN, DNS-filter,
        and network-filter apps may ask to be approved or re-enabled afterward.

        STEPS
        1. Shut down the Mac. Hold the power button until startup options appear.
        2. Choose Options > Continue, then Utilities > Terminal.
        3. Run: csrutil disable
        4. Reboot normally.
        5. In Terminal, run these commands individually:
           sudo rm -f /Library/Preferences/com.apple.networkextension.plist
           sudo rm -f /Library/Preferences/com.apple.networkextension.uuidcache.plist
           sudo reboot
        6. After login, open the affected app and approve Local Network access.
        7. Confirm the app works before continuing.
        8. Return to Recovery and run:
           csrutil enable
           reboot
        9. Verify in normal macOS: csrutil status
           It must report: System Integrity Protection status: enabled.

        Keep this backup until the repaired apps and network extensions work.
        """
    }
}
