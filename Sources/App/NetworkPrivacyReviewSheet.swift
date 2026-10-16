import AppKit
import SwiftUI
import Features

/// Reviews privacy observations without treating a saved denial or old app
/// metadata as a repair task. Acknowledgments affect only myKikau's reporting.
struct NetworkPrivacyReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var report: NetworkPrivacyAuditor.Report?
    @State private var inspectionError: String?
    @State private var isInspecting = false
    @State private var preparedRepair: NetworkPrivacyRepairAssistant.PreparedRepair?
    @State private var preparationError: String?
    @State private var isPreparing = false

    private let findingStore: NetworkPrivacyFindingStore
    private let onReportChanged: (NetworkPrivacyAuditor.Report) -> Void

    init(
        initialReport: NetworkPrivacyAuditor.Report? = nil,
        findingStore: NetworkPrivacyFindingStore = .shared,
        onReportChanged: @escaping (NetworkPrivacyAuditor.Report) -> Void
    ) {
        _report = State(initialValue: initialReport)
        self.findingStore = findingStore
        self.onReportChanged = onReportChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: hasIssues ? "exclamationmark.shield.fill" : "info.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(hasIssues ? .orange : .blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("System Privacy Records").font(.title2.bold())
                    Text(report?.summary ?? "Reviewing Local Network privacy records…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if report.findings.isEmpty {
                            Label("No Local Network privacy issues need attention", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        }
                        ForEach(report.findings) { finding in
                            findingRow(finding, ignored: false)
                        }
                        if !report.ignoredFindings.isEmpty {
                            DisclosureGroup("Ignored information (\(report.ignoredFindings.count))") {
                                VStack(spacing: 10) {
                                    ForEach(report.ignoredFindings) { finding in
                                        findingRow(finding, ignored: true)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)

                Text("Ignore remembers this observation across scans and app restarts. "
                    + "Changed records appear again. You can restore ignored items above. "
                    + "Your macOS permissions stay as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if report.requiresGuidedRepair {
                    DisclosureGroup("Advanced troubleshooting") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start with Local Network settings. Recovery repair is only for persistent connection problems: "
                                + "it resets shared network preferences, affects other apps, and requires temporarily disabling SIP.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(isPreparing ? "Preparing…" : "Prepare Recovery Instructions…") {
                                Task { await prepareRepair() }
                            }
                            .disabled(isPreparing || isInspecting)
                        }
                        .padding(.top, 6)
                    }
                }
            } else if isInspecting {
                ProgressView("Inspecting Local Network privacy records…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            }

            if let inspectionError {
                Label(inspectionError, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let preparedRepair {
                Button("Reveal Recovery Instructions") {
                    NSWorkspace.shared.activateFileViewerSelecting([preparedRepair.instructionsURL])
                }
            }
            if let preparationError {
                Text(preparationError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Open Local Network Settings") {
                    let settingsURL = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork"
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(isInspecting ? "Refreshing…" : "Refresh") {
                    Task { await inspect() }
                }
                .disabled(isInspecting)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .frame(minHeight: 360)
        .task { await inspect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await inspect() }
            }
        }
    }

    private var hasIssues: Bool {
        (report?.issueCount ?? 0) > 0
    }

    private func findingRow(_ finding: NetworkPrivacyAuditor.Finding, ignored: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(finding.kind.displayName, systemImage: finding.severity.icon)
                    .font(.subheadline.bold())
                    .foregroundStyle(ignored ? .secondary : finding.severity.color)
                Spacer()
                Text("\(finding.affectedRecordCount) record\(finding.affectedRecordCount == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(finding.signingIdentifier)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(finding.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if finding.severity == .information {
                HStack {
                    Text(ignored ? "Ignored" : "Information · no repair needed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(ignored ? "Restore" : "Ignore") {
                        setIgnored(!ignored, finding: finding)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("\(ignored ? "Restore" : "Ignore") \(finding.kind.displayName) for \(finding.signingIdentifier)")
                    .help(ignored ? "Show this observation in future scans" : "Hide this observation until its records change")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func setIgnored(_ ignored: Bool, finding: NetworkPrivacyAuditor.Finding) {
        if ignored {
            findingStore.ignore(finding)
        } else {
            findingStore.restore(finding)
        }
        if let report {
            publish(findingStore.applyingIgnores(to: report))
        }
    }

    private func publish(_ updated: NetworkPrivacyAuditor.Report) {
        report = updated
        onReportChanged(updated)
        if !updated.requiresGuidedRepair {
            preparedRepair = nil
        }
    }

    private func inspect() async {
        guard !isInspecting else { return }
        isInspecting = true
        defer { isInspecting = false }
        do {
            let store = findingStore
            let updated = try await Task.detached(priority: .userInitiated) {
                try NetworkPrivacyAuditor.inspect(
                    installedApplications: NetworkPrivacyAuditor.discoverInstalledApplications(),
                    findingStore: store
                )
            }.value
            guard !Task.isCancelled else { return }
            publish(findingStore.applyingIgnores(to: updated))
            inspectionError = nil
        } catch {
            inspectionError = error.localizedDescription
        }
    }

    private func prepareRepair() async {
        guard report?.requiresGuidedRepair == true, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            preparedRepair = try await Task.detached(priority: .userInitiated) {
                try NetworkPrivacyRepairAssistant.prepare()
            }.value
            preparationError = nil
            if let preparedRepair {
                NSWorkspace.shared.activateFileViewerSelecting([preparedRepair.instructionsURL])
            }
        } catch {
            preparationError = error.localizedDescription
        }
    }
}

private extension NetworkPrivacyAuditor.FindingKind {
    var displayName: String {
        switch self {
        case .excessivePrivacyRecords: "Many current privacy records"
        case .installedApplicationDenied: "Local Network access is off"
        case .conflictingPrivacyDecisions: "Conflicting allow/deny decisions"
        case .stalePrivacyRecords: "Historical app records"
        }
    }
}

private extension NetworkPrivacyAuditor.Severity {
    var icon: String {
        switch self {
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .information: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}
