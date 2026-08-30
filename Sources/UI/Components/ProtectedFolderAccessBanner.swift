import AppKit
import SwiftUI
import Core

/// Surfaces what would otherwise be a silent scan failure: macOS gates
/// Desktop/Documents/Downloads access separately from Full Disk Access
/// (System Settings → Privacy & Security → Files and Folders), and neither
/// `DuplicateFinder` nor `DiskScanner` can tell "genuinely empty" apart from
/// "denied" on their own — see `ProtectedFolderAccessCheck`. Shared between
/// Analyse and Files/Duplicates since both scan these same folders.
public struct ProtectedFolderAccessBanner: View {
    public let deniedFolders: [String]

    public init(deniedFolders: [String]) {
        self.deniedFolders = deniedFolders
    }

    public var body: some View {
        HStack {
            Label(
                "myKikau can't read your \(deniedFolders.joined(separator: ", ")) folder\(deniedFolders.count == 1 ? "" : "s") — scans here will under-report or find nothing.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            Spacer()
            Button("Open Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Documents") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
