import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Core
import Features
import UI

/// Everything myKikau has done, newest first: what was removed, when, how
/// much it freed — and a way to put a trashed item back. Backed by the
/// operation log, which is also what "freed to date" is counted from.
struct HistoryView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case removed = "Removed"
        case failed = "Failed"
        case simulated = "Simulated"
        var id: String {
            rawValue
        }
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @State private var sessions: [CleanupSession] = []
    @State private var recovery: CleanupSession?
    @ObservedObject private var work = WorkCoordinator.shared
    @State private var entries: [OperationLog.Entry] = []
    @State private var totals = OperationLog.Totals()
    @State private var loading = true
    @State private var filter: Filter = .all
    @State private var notice: Notice?
    @State private var loggingEnabled = OperationLog.shared.enabled

    private let tint = ContentView.SidebarItem.history.tint
    private static let entryLimit = 2000

    private var visible: [OperationLog.Entry] {
        switch filter {
        // Optimise's scan checks every task as a simulation; those are
        // routine, so they stay under "Simulated" rather than crowding "All".
        case .all: entries.filter { !($0.dryRun && $0.path.isEmpty) }
        case .removed: entries.filter { $0.outcome == .success && !$0.dryRun && !$0.path.isEmpty }
        case .failed: entries.filter { $0.outcome == .failed }
        case .simulated: entries.filter(\.dryRun)
        }
    }

    private var subtitle: String {
        "\(ByteSizeFormatter.format(totals.trashedBytes)) moved to Trash · \(ByteSizeFormatter.format(totals.freedBytes)) permanently removed"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("History", subtitle: subtitle, systemImage: ContentView.SidebarItem.history.icon, tint: tint) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(LocalizedStringKey(option.rawValue)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Menu {
                    Button("Export as CSV…") { export(.csv) }
                    Button("Export as JSON Lines…") { export(.jsonl) }
                    Divider()
                    Button("Check Log Integrity") { verify() }
                    Button("Reveal Log File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([OperationLog.shared.fileURL])
                    }
                } label: {
                    Label("Log", systemImage: "ellipsis.circle")
                }
                .fixedSize()
            }

            if !entries.isEmpty {
                CareSummary([("Moved to Trash", ByteSizeFormatter.format(totals.trashedBytes)),
                             ("Permanently removed", ByteSizeFormatter.format(totals.freedBytes)),
                             ("Recent sessions", sessions.count.formatted())])
            }
            if totals.legacyProcessedBytes > 0 {
                Text("Earlier activity used a combined counter. Separate totals start with this update; the original log is retained.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
            }
            if !loggingEnabled {
                Label("The operation log is switched off in Settings — new activity isn't being recorded.", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                CareEmptyState(
                    entries.isEmpty ? "No Activity Yet" : "Nothing Matches",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(entries.isEmpty
                        ? "Everything myKikau removes or repairs is recorded here."
                        : "No entries fit the “\(filter.rawValue)” filter.")
                )
            } else {
                List {
                    if filter == .all || filter == .removed, !sessions.isEmpty {
                        Section("Cleanup sessions") {
                            ForEach(sessions) { session in
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(tint)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(HistoryRow.actionLabel(session.action)).fontWeight(.medium)
                                        Text(
                                            "\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(session.entries.count) recorded items"
                                        )
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Review & Restore…") { recovery = session }.disabled(work.isBusy)
                                }.padding(.vertical, 5)
                            }
                            Text("Most recent 20 cleanups from retained history. Older activity remains below and in the exported log.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(groupedByDay(visible), id: \.day) { group in
                        Section(group.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry, onPutBack: { putBack(entry) })
                            }
                        }
                    }
                    if entries.count >= Self.entryLimit {
                        Text("Showing the most recent \(Self.entryLimit.formatted()) entries. Export the log for the full record.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }.careResults()
            }
        }
        .careScreen()
        .task { await reload() }
        .sheet(item: $recovery) { session in CleanupRecoverySheet(session: session) { Task { await reload() } } }
        .onChange(of: work.isBusy) {
            _, busy in if !busy {
                Task { await reload() }
            }
        }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private func groupedByDay(_ entries: [OperationLog.Entry]) -> [(day: Date, entries: [OperationLog.Entry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.timestamp) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    private func reload() async {
        let limit = Self.entryLimit
        let loaded = await Task.detached(priority: .userInitiated) {
            (OperationLog.shared.recent(limit: limit), OperationLog.shared.totals(), OperationLog.shared.cleanupSessions())
        }.value
        entries = loaded.0
        totals = loaded.1
        sessions = loaded.2
        loggingEnabled = OperationLog.shared.enabled
        loading = false
    }

    private func putBack(_ entry: OperationLog.Entry) {
        guard let trashedPath = entry.trashedPath else { return }
        guard let lease = WorkCoordinator.shared.begin("Putting a file back", kind: .deletion) else {
            notice = Notice(title: "Another Task Is Running", message: "Finish or cancel the current task before restoring files.")
            return
        }
        Task {
            defer { WorkCoordinator.shared.finish(lease) }
            let error = await Task.detached { () -> String? in
                do {
                    try SafeFileDeleter.shared.putBack(
                        trashedPath: trashedPath, originalPath: entry.path,
                        fileNumber: entry.trashedFileNumber, sessionID: entry.sessionID
                    )
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let error {
                notice = Notice(title: "Couldn't Put Back", message: error)
            }
            await reload()
        }
    }

    private func verify() {
        Task {
            let status = await Task.detached { OperationLog.shared.verifyChain() }.value
            if let line = status.firstBrokenLine {
                notice = Notice(
                    title: "Log Integrity Problem",
                    message: "Entry \(line) doesn't match the one before it. The log file was edited, or an entry was removed, outside myKikau."
                )
            } else if status.truncated {
                notice = Notice(
                    title: "Log Integrity Problem",
                    message: "Entries are missing from the start or the end of the log. They were removed outside myKikau."
                )
            } else {
                notice = Notice(
                    title: "Log Is Intact",
                    message: "\(status.verified.formatted()) entries verified against the entry before them."
                        + (status.unchained > 1 ? " \(status.unchained.formatted()) older entries predate integrity checking." : "")
                )
            }
        }
    }

    private func export(_ format: OperationLog.ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "myKikau-operations." + (format == .csv ? "csv" : "jsonl")
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OperationLog.shared.export(to: url, format: format)
        } catch {
            notice = Notice(title: "Export Failed", message: error.localizedDescription)
        }
    }
}

private struct HistoryRow: View {
    let entry: OperationLog.Entry
    let onPutBack: () -> Void

    private var canPutBack: Bool {
        guard entry.outcome == .success, !entry.dryRun, let trashed = entry.trashedPath else { return false }
        return SafeFileDeleter.shared.canPutBack(
            trashedPath: trashed, originalPath: entry.path, fileNumber: entry.trashedFileNumber
        )
    }

    private var badge: (label: String, icon: String, color: Color) {
        if entry.dryRun {
            return ("Simulated", "eye", .blue)
        }
        switch entry.outcome {
        case .success:
            return entry.mode == .permanent && !entry.path.isEmpty
                ? ("Deleted", "trash.slash", .secondary)
                : ("Done", "checkmark.circle", .green)
        case .failed: return ("Failed", "exclamationmark.triangle", .orange)
        case .skipped: return ("Skipped", "minus.circle", .secondary)
        case .dryRun: return ("Simulated", "eye", .blue)
        }
    }

    private var title: String {
        entry.path.isEmpty ? Self.actionLabel(entry.action) : URL(fileURLWithPath: entry.path).lastPathComponent
    }

    private var detail: String {
        // An entry without a path (a maintenance task) is titled by its
        // action, so the second line carries only what it did.
        if entry.path.isEmpty {
            return entry.detail ?? ""
        }
        let folder = URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
        if entry.outcome == .failed, let reason = entry.detail, !reason.isEmpty {
            return "\(Self.actionLabel(entry.action)) · \(reason)"
        }
        return "\(Self.actionLabel(entry.action)) · \(folder)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: badge.icon)
                .foregroundStyle(badge.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if canPutBack {
                Button("Put Back", action: onPutBack)
                    .disabled(WorkCoordinator.shared.isBusy)
                    .controlSize(.small)
                    .accessibilityLabel("Put back \(title)")
            }
            if entry.sizeBytes > 0 {
                Text(ByteSizeFormatter.format(entry.sizeBytes))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(CareTheme.secondaryInk)
                .frame(width: 64, alignment: .trailing)
        }
        .help(entry.path.isEmpty ? (entry.detail ?? "") : entry.path)
        .contextMenu {
            if !entry.path.isEmpty {
                PathMenu(url: URL(fileURLWithPath: entry.trashedPath ?? entry.path))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.label): \(title), \(Self.actionLabel(entry.action))")
    }

    static func actionLabel(_ action: String) -> String {
        if action.hasPrefix("optimize.") {
            let id = String(action.dropFirst("optimize.".count))
            return "Optimise — " + (MaintenanceCatalog.tasks.first { $0.id == id }?.name ?? id)
        }
        switch action {
        case "clean": return String(localized: "Clean")
        case "uninstall", "uninstall.app", "uninstall.leftovers": return String(localized: "Uninstall")
        case "uninstall.admin": return String(localized: "Uninstall — administrator helper")
        case "uninstall.orphans": return String(localized: "Leftovers from removed apps")
        case "startup": return String(localized: "Startup Items")
        case "uninstall.teardown": return String(localized: "Uninstall — background services stopped")
        case "duplicates": return String(localized: "Duplicates")
        case "largeFiles": return String(localized: "Large Files")
        case "similarPhotos": return String(localized: "Similar Photos")
        case "purge": return String(localized: "Project Purge")
        case "analyze": return String(localized: "Disk Analyser")
        case "menubar.emptyTrash": return String(localized: "Empty Trash")
        case "putBack": return String(localized: "Put Back")
        default: return action
        }
    }
}
