import AppKit
import SwiftUI
import Core

/// Whether a deletion is running right now. The main window watches this and
/// holds navigation still until it finishes: switching screens would tear
/// down the sheet that shows the run's progress, its Cancel button and its
/// result.
@MainActor
public final class DeletionActivity: ObservableObject {
    public static let shared = DeletionActivity()
    @Published public private(set) var isRunning = false

    private var lease: UUID?
    private init() {}

    func begin() -> Bool {
        guard let lease = WorkCoordinator.shared.begin("Moving reviewed files", kind: .deletion) else { return false }
        self.lease = lease
        isRunning = true
        return true
    }

    func end() {
        if let lease {
            WorkCoordinator.shared.finish(lease)
        }
        lease = nil
        isRunning = false
    }
}

/// The one place a deletion plan is reviewed, confirmed, run and reported.
/// Used by Clean, Uninstall, Files and Purge.
///
/// Three stages in one sheet:
/// 1. **Review** — every item has a checkbox, grouped by kind; the primary
///    button says exactly what will happen ("Move 12 Items to Trash").
///    Anything that would be removed for good needs a second confirmation.
/// 2. **Running** — progress, the item in hand, and Cancel.
/// 3. **Result** — space freed, what went to the Trash, and each failure
///    with a reason.
public struct PlanReviewView: View {
    /// Work to do before files are touched — Uninstall stops the app's
    /// background services here. Receives whether this is a simulation and
    /// the IDs the user left ticked; returns notes for the result page.
    public typealias Prepare = (_ simulate: Bool, _ selectedIDs: Set<String>) async -> [String]

    /// Retries items that failed for lack of administrator rights, through
    /// the privileged helper. Returns the paths it removed and, for the rest,
    /// why not (path → reason).
    public typealias Elevate = (_ paths: [String]) async -> (removed: Set<String>, failed: [String: String])

    private let plan: SafeFileDeleter.Plan
    private let title: String
    private let subtitle: String?
    private let action: String
    private let deleter: SafeFileDeleter
    private let prepare: Prepare?
    private let revalidate: ((SafeFileDeleter.Plan) async -> SafeFileDeleter.Plan)?
    private let elevate: Elevate?
    private let onClose: (SafeFileDeleter.ExecutionResult?) -> Void

    private enum Stage {
        case review
        case running(completed: Int, total: Int, path: String)
        case finished(SafeFileDeleter.ExecutionResult, notes: [String])
    }

    /// Action name for emptying the Trash. That review is Finder's single
    /// "Empty Trash" question with the exact items listed, so it runs on the
    /// first confirmation instead of asking a second time.
    public static let emptyTrashAction = "menubar.emptyTrash"

    @ObservedObject private var activity = WorkCoordinator.shared
    @State private var stage: Stage = .review
    @State private var selection: Set<String>
    @State private var confirmingPermanent = false
    @State private var runTask: Task<Void, Never>?

    /// - Parameters:
    ///   - action: operation-log action name (e.g. `"clean"`).
    ///   - preselected: whether every item starts ticked.
    ///   - onClose: called when the sheet should be dismissed. The result is
    ///     `nil` if the user cancelled without running anything.
    public init(
        plan: SafeFileDeleter.Plan,
        title: String,
        subtitle: String? = nil,
        action: String,
        deleter: SafeFileDeleter = .shared,
        preselected: Bool = true,
        prepare: Prepare? = nil,
        revalidate: ((SafeFileDeleter.Plan) async -> SafeFileDeleter.Plan)? = nil,
        elevate: Elevate? = nil,
        onClose: @escaping (SafeFileDeleter.ExecutionResult?) -> Void
    ) {
        self.plan = plan
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.deleter = deleter
        self.prepare = prepare
        self.revalidate = revalidate
        self.elevate = elevate
        self.onClose = onClose
        // Suggestions built on weaker evidence start unticked: the user
        // opts in to each one.
        _selection = State(initialValue: preselected ? Set(plan.items.map(\.id)) : [])
    }

    private var selectedItems: [SafeFileDeleter.Item] {
        plan.items.filter { selection.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private var permanentCount: Int {
        selectedItems.filter(\.isPermanentRemoval).count
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .review:
                reviewStage
            case let .running(completed, total, path):
                runningStage(completed: completed, total: total, path: path)
            case let .finished(result, notes):
                ResultStage(
                    result: result,
                    notes: notes,
                    sizes: Dictionary(plan.items.map { ($0.id, $0.sizeBytes) }, uniquingKeysWith: { first, _ in first }),
                    elevate: elevate,
                    onDone: onClose
                )
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 520)
        .careScreen()
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool {
        if case .running = stage {
            return true
        }
        return false
    }

    // MARK: - Review

    private var groups: [(category: SafeFileDeleter.Category, items: [SafeFileDeleter.Item])] {
        let order: [SafeFileDeleter.Category] = [
            .app, .leftover, .cache, .log, .artifact, .duplicate, .largeFile, .installer, .trash,
        ]
        let byCategory = Dictionary(grouping: plan.items, by: \.category)
        return order.compactMap { category in
            guard let items = byCategory[category], !items.isEmpty else { return nil }
            return (category, items.sorted { $0.sizeBytes > $1.sizeBytes })
        }
    }

    private var reviewStage: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                AppBrandIcon(size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(.title, design: .rounded).weight(.bold))
                    Text(subtitle ?? "Untick anything you want to keep.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select All") { selection = Set(plan.items.map(\.id)) }
                    .disabled(selection.count == plan.items.count)
                Button("Select None") { selection = [] }
                    .disabled(selection.isEmpty || activity.isBusy)
            }
            .controlSize(.small)
            .padding()

            Divider()

            List {
                ForEach(groups, id: \.category) { group in
                    Section {
                        ForEach(group.items) { item in
                            PlanItemRow(item: item, isSelected: binding(for: item.id))
                        }
                    } header: {
                        GroupHeader(
                            title: Self.title(for: group.category),
                            items: group.items,
                            selection: $selection
                        )
                    }
                }
                if !plan.protectedItems.isEmpty {
                    Section("Protected — will not be touched (\(plan.protectedItems.count))") {
                        ForEach(plan.protectedItems) { item in
                            ProtectedItemRow(item: item)
                        }
                    }
                }
            }

            if permanentCount > 0 {
                Label(
                    "\(permanentCount) item\(permanentCount == 1 ? " is" : "s are") already in the Trash and will be deleted permanently.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
            }

            Divider()
            if let current = activity.activity {
                Text("\(current.title) is running. Finish or cancel it before changing files.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            HStack {
                Text("\(selection.count) of \(plan.items.count) selected · \(ByteSizeFormatter.format(selectedBytes))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Simulate") { run(simulate: true) }
                    .disabled(selection.isEmpty || activity.isBusy)
                    .help("Runs through the plan and records it in the log without touching any file")
                Button("Cancel") { onClose(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(primaryLabel) {
                    if permanentCount > 0, action != Self.emptyTrashAction {
                        confirmingPermanent = true
                    } else {
                        run(simulate: false)
                    }
                }
                .buttonStyle(CarePrimaryButtonStyle(fill: permanentCount > 0 ? CareTheme.rose : CareTheme.accent))
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || activity.isBusy)
            }
            .padding()
        }
        .confirmationDialog(
            "Permanently delete \(permanentCount) item\(permanentCount == 1 ? "" : "s")?",
            isPresented: $confirmingPermanent,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { run(simulate: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items already in the Trash can't be recovered once deleted.")
        }
    }

    private var primaryLabel: String {
        let count = selection.count
        let noun = "\(count) Item\(count == 1 ? "" : "s")"
        if action == Self.emptyTrashAction {
            return count == plan.items.count ? "Empty Trash" : "Erase \(noun)"
        }
        if permanentCount == count, count > 0 {
            return "Delete \(noun) Permanently"
        }
        if permanentCount > 0 {
            return "Remove \(noun)"
        }
        return "Move \(noun) to Trash"
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn {
                    selection.insert(id)
                } else {
                    selection.remove(id)
                }
            }
        )
    }

    static func title(for category: SafeFileDeleter.Category) -> String {
        switch category {
        case .app: String(localized: "Application")
        case .leftover: String(localized: "Leftovers & Settings")
        case .cache: String(localized: "Caches")
        case .log: String(localized: "Logs & Temporary Files")
        case .artifact: String(localized: "Build Artifacts")
        case .duplicate: String(localized: "Duplicate Copies")
        case .largeFile: String(localized: "Large Files")
        case .installer: String(localized: "Installers")
        case .trash: String(localized: "In the Trash")
        }
    }

    // MARK: - Running

    private func runningStage(completed: Int, total: Int, path: String) -> some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                Text(total > 0 ? "Working — \(completed) of \(total)" : "Preparing…")
                    .font(.headline)
            } currentValueLabel: {
                Text(path.isEmpty ? " " : path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 420)
            Button("Cancel") { runTask?.cancel() }
                .keyboardShortcut(.cancelAction)
            Text("Items already moved stay in the Trash, where you can put them back.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private func run(simulate: Bool) {
        let selected = selection
        let chosen = plan.keeping(selected)
        guard DeletionActivity.shared.begin() else { return }
        stage = .running(completed: 0, total: 0, path: "")
        runTask = Task {
            defer { DeletionActivity.shared.end() }
            var notes = await prepare?(simulate, selected) ?? []
            // A long-open review can become stale. Only keep reviewed paths;
            // validation may remove candidates, never introduce new ones.
            let validated = await revalidate?(chosen) ?? chosen
            let eligible = chosen.keeping(Set(validated.items.map(\.id)))
            let dropped = chosen.items.count - eligible.items.count
            if dropped > 0 {
                notes.append("Left \(dropped) item(s) alone because they are now in use or no longer eligible for cleanup.")
            }
            let result: SafeFileDeleter.ExecutionResult = if Task.isCancelled {
                SafeFileDeleter.ExecutionResult(
                    freedBytes: 0, succeeded: 0, failed: 0, skipped: 0, errors: [], cancelled: true, dryRun: simulate
                )
            } else {
                await deleter.executeAsync(eligible, mode: .trash, dryRun: simulate, action: action) { progress in
                    Task { @MainActor in
                        guard isRunning else { return }
                        stage = .running(completed: progress.completed, total: progress.total, path: progress.currentPath)
                    }
                }
            }
            stage = .finished(result, notes: notes)
            runTask = nil
        }
    }
}

// MARK: - Rows

private struct GroupHeader: View {
    let title: String
    let items: [SafeFileDeleter.Item]
    @Binding var selection: Set<String>

    private var ids: Set<String> {
        Set(items.map(\.id))
    }

    private var selectedCount: Int {
        ids.intersection(selection).count
    }

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { selectedCount == items.count },
                set: { isOn in
                    if isOn {
                        selection.formUnion(ids)
                    } else {
                        selection.subtract(ids)
                    }
                }
            )) {
                Text("\(title) (\(selectedCount)/\(items.count))")
            }
            .toggleStyle(.checkbox)
            Spacer()
            Text(ByteSizeFormatter.format(items.reduce(0) { $0 + $1.sizeBytes }))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PlanItemRow: View {
    let item: SafeFileDeleter.Item
    @Binding var isSelected: Bool

    var body: some View {
        HStack {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: categoryIcon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if item.isPermanentRemoval {
                Text("Permanent")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            }
            Text(ByteSizeFormatter.format(item.sizeBytes))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .help(item.url.path)
        .contextMenu {
            // Excluding an item also unticks it, so the plan can't go on to
            // report it as skipped.
            PathMenu(url: item.url, onExcluded: { isSelected = false })
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.url.lastPathComponent), \(ByteSizeFormatter.format(item.sizeBytes))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isSelected.toggle() }
    }

    private var categoryIcon: String {
        switch item.category {
        case .cache: "internaldrive"
        case .log: "doc.text"
        case .trash: "trash"
        case .leftover: "app.dashed"
        case .artifact: "hammer"
        case .app: "xmark.app.fill"
        case .installer: "archivebox"
        case .duplicate: "doc.on.doc"
        case .largeFile: "doc.badge.arrow.up"
        }
    }
}

private struct ProtectedItemRow: View {
    let item: SafeFileDeleter.Item

    var body: some View {
        HStack {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(item.url.lastPathComponent).lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
        .help(item.url.path)
        .contextMenu { PathMenu(url: item.url) }
    }
}

/// Context-menu actions for anything that is a path on disk.
public struct PathMenu: View {
    private let url: URL
    private let onExcluded: (() -> Void)?

    public init(url: URL, onExcluded: (() -> Void)? = nil) {
        self.url = url
        self.onExcluded = onExcluded
    }

    public var body: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        Divider()
        if ExclusionStore.shared.userPaths.contains(url.path) {
            Text("On the Never Remove list")
        } else {
            Button("Never Remove This") {
                let store = ExclusionStore.shared
                store.setUserPaths(store.userPaths + [url.path])
                onExcluded?()
            }
        }
    }
}

// MARK: - Result

private struct ResultStage: View {
    let initial: SafeFileDeleter.ExecutionResult
    let notes: [String]
    let sizes: [String: Int64]
    let elevate: PlanReviewView.Elevate?
    let onDone: (SafeFileDeleter.ExecutionResult) -> Void

    /// The result as it stands, including anything the administrator helper
    /// removed after the first pass.
    @State private var result: SafeFileDeleter.ExecutionResult
    @State private var elevating = false
    @State private var elevatedCount = 0

    init(
        result: SafeFileDeleter.ExecutionResult,
        notes: [String],
        sizes: [String: Int64],
        elevate: PlanReviewView.Elevate?,
        onDone: @escaping (SafeFileDeleter.ExecutionResult) -> Void
    ) {
        initial = result
        self.notes = notes
        self.sizes = sizes
        self.elevate = elevate
        self.onDone = onDone
        _result = State(initialValue: result)
    }

    private var needingAdministrator: [SafeFileDeleter.Failure] {
        result.failures.filter(\.needsAdministrator)
    }

    private var headline: String {
        if result.dryRun {
            return "Simulation complete — nothing was changed"
        }
        if result.cancelled {
            return "Stopped"
        }
        if result.failed > 0, result.succeeded == 0 {
            return "Nothing could be removed"
        }
        if result.failed > 0 {
            return "Finished with \(result.failed) problem\(result.failed == 1 ? "" : "s")"
        }
        return "Done"
    }

    private var symbol: (name: String, color: Color) {
        if result.dryRun {
            return ("eye.circle.fill", .blue)
        }
        if result.failed > 0 {
            return ("exclamationmark.triangle.fill", .orange)
        }
        if result.cancelled {
            return ("stop.circle.fill", .secondary)
        }
        return ("checkmark.circle.fill", .green)
    }

    private var summary: String {
        let size = ByteSizeFormatter.format(result.freedBytes)
        let items = "\(result.succeeded) item\(result.succeeded == 1 ? "" : "s")"
        if result.dryRun {
            if result.recoverable == result.succeeded {
                return "\(items) would move to the Trash — \(size). Space is reclaimed only after the Trash is emptied."
            }
            if result.recoverable == 0 {
                return "\(items) would be permanently deleted from the Trash — \(size)."
            }
            return "\(items) would be removed — \(size). Some would move to Trash; items already in Trash would be deleted permanently."
        }
        if result.succeeded == 0 {
            return "No space was freed."
        }
        if result.recoverable == result.succeeded {
            return "\(items) moved to the Trash — \(size). Empty the Trash to reclaim the space, or put anything back from History."
        }
        if result.recoverable == 0 {
            return "\(items) deleted — \(size) freed."
        }
        return "\(items) removed — \(size). \(result.recoverable) went to the Trash and can be put back."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: symbol.name)
                    .font(.system(size: 40))
                    .foregroundStyle(symbol.color)
                    .accessibilityHidden(true)
                Text(headline).font(.title3.bold())
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                if result.skipped > 0 {
                    Text("\(result.skipped) protected item\(result.skipped == 1 ? " was" : "s were") left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if elevatedCount > 0 {
                    Text("\(elevatedCount) item\(elevatedCount == 1 ? " was" : "s were") removed with administrator rights.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, Theme.Spacing.xl)
            .padding(.horizontal)

            if !notes.isEmpty || !result.failures.isEmpty {
                List {
                    if !notes.isEmpty {
                        Section("Also done") {
                            ForEach(notes, id: \.self) { note in
                                Label(note, systemImage: "checkmark")
                                    .font(.subheadline)
                            }
                        }
                    }
                    if !result.failures.isEmpty {
                        Section("Couldn't remove (\(result.failures.count))") {
                            ForEach(result.failures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: failure.path).lastPathComponent)
                                        .lineLimit(1)
                                    Text(failure.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .help(failure.path)
                                .contextMenu { PathMenu(url: URL(fileURLWithPath: failure.path)) }
                            }
                        }
                    }
                }
                .padding(.top, Theme.Spacing.md)
            } else {
                Spacer()
            }

            Divider()
            HStack {
                if !needingAdministrator.isEmpty {
                    if elevate != nil {
                        if elevating {
                            ProgressView().controlSize(.small)
                        }
                        Button("Remove \(needingAdministrator.count) With Administrator Rights…") { runElevated() }
                            .disabled(elevating)
                            .help("Asks for an administrator password, then removes these through the myKikau helper")
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(needingAdministrator.first?.recoverySuggestion ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Show Remaining Items in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    needingAdministrator.map { URL(fileURLWithPath: $0.path) }
                                )
                            }
                        }
                    }
                }
                Spacer()
                Button("Done") { onDone(result) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(elevating)
            }
            .padding()
        }
    }

    /// Hands the items that needed an administrator to the helper, then
    /// folds what it removed into the result.
    private func runElevated() {
        guard let elevate, DeletionActivity.shared.begin() else { return }
        let paths = needingAdministrator.map(\.path)
        elevating = true
        Task {
            defer { DeletionActivity.shared.end() }
            let outcome = await elevate(paths)
            let freed = outcome.removed.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            let remaining = result.failures.compactMap { failure -> SafeFileDeleter.Failure? in
                if outcome.removed.contains(failure.path) {
                    return nil
                }
                if let reason = outcome.failed[failure.path] {
                    // The helper has spoken; don't offer it the same item again.
                    return SafeFileDeleter.Failure(path: failure.path, reason: reason, needsAdministrator: false)
                }
                return failure
            }
            result = SafeFileDeleter.ExecutionResult(
                freedBytes: result.freedBytes + freed,
                succeeded: result.succeeded + outcome.removed.count,
                failed: remaining.count,
                skipped: result.skipped,
                errors: remaining.map { "\($0.path): \($0.reason)" },
                failures: remaining,
                removedIDs: result.removedIDs.union(outcome.removed),
                recoverable: result.recoverable + outcome.removed.count,
                cancelled: result.cancelled,
                dryRun: result.dryRun
            )
            elevatedCount += outcome.removed.count
            elevating = false
        }
    }
}
