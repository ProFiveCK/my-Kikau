import AppKit
import SwiftUI
import Core

/// Coverage stays visible even when the scan found no cleanup candidates.
public struct ScanCoverageView: View {
    public let coverage: ScanCoverage
    @State private var expanded = false
    public init(_ coverage: ScanCoverage) {
        self.coverage = coverage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(coverage.checkedPaths.prefix(100)), id: \.self) { path in
                            Label(path, systemImage: "checkmark.circle")
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(path)
                        }
                        if coverage.checkedPaths.count > 100 {
                            Text("\(coverage.checkedPaths.count - 100) more locations checked.").foregroundStyle(.secondary)
                        }
                        ForEach(coverage.issues) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(issue.path, systemImage: icon(for: issue.kind))
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(issue.path)
                                Text(issue.kind == .missing ? "Not present · skipped" : issue.detail).foregroundStyle(.secondary)
                            }
                        }
                        if coverage.additionalIssueCount > 0 {
                            Text("\(coverage.additionalIssueCount) additional read failures.")
                        }
                        if coverage.skippedCloudOnly > 0 {
                            Text("\(coverage.skippedCloudOnly) cloud-only files skipped to avoid downloading them.")
                        }
                    }
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .frame(maxHeight: 180)
            } label: {
                Label {
                    Text(coverage.isPartial
                        ? "Partial scan · \(coverage.unavailableCount) read failure\(coverage.unavailableCount == 1 ? "" : "s")"
                        : "Scan coverage · \(coverage.checkedPaths.count) locations checked"
                        + (coverage.restrictedCount > 0 ? " · \(coverage.restrictedCount) protected folders not measured" : ""))
                } icon: { Image(systemName: coverage.isPartial ? "exclamationmark.circle" : "checkmark.circle") }
                    .font(.caption).foregroundStyle(coverage.isPartial ? Color.orange : .secondary)
            }
            if coverage.issues.contains(where: { $0.kind == .denied }) {
                Menu("Review access in System Settings") {
                    Button("Files and Folders…") { openSettings("Privacy_FilesAndFolders") }
                    Button("Full Disk Access…") { openSettings("Privacy_AllFiles") }
                }
                .font(.caption).fixedSize()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHint("Expand to see checked, unavailable and skipped locations")
    }

    private func icon(for kind: ScanCoverage.Kind) -> String {
        switch kind {
        case .missing: "minus.circle"
        case .restricted: "lock.circle"
        case .denied, .unavailable: "exclamationmark.circle"
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"), !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
