import SwiftUI
import UniformTypeIdentifiers
import Squeeze7zCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    private enum Stage: Equatable {
        case engineMissing, empty, queue
    }

    private var stage: Stage {
        if model.engineError != nil { return .engineMissing }
        return model.jobs.isEmpty ? .empty : .queue
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.backupWarningDismissed {
                BackupBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ZStack {
                switch stage {
                case .engineMissing:
                    EngineMissingView(message: model.engineError ?? "")
                        .transition(.opacity)
                case .empty:
                    EmptyStateView(dropTargeted: dropTargeted)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .queue:
                    JobTable()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The stats float on glass above the list, which scrolls underneath.
            .safeAreaBar(edge: .bottom, spacing: 0) { BottomBar() }
        }
        .animation(.smooth(duration: 0.3), value: stage)
        .animation(.smooth(duration: 0.3), value: model.backupWarningDismissed)
        .frame(minWidth: 900, minHeight: 440)
        .overlay {
            if dropTargeted && model.engine != nil {
                DropOverlay(showsLabel: stage == .queue)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.addItems(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [.item, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addItems(urls) }
        }
        .sheet(item: $model.reportJob) { job in
            ReportView(job: job)
        }
        .alert("Squeeze7z",
               isPresented: Binding(get: { model.notice != nil },
                                    set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
        .background(WindowCloseGuard())
        .toolbar { MainToolbar() }
        .navigationTitle("Squeeze7z")
    }
}

// MARK: - Toolbar

/// The toolbar keeps the system Liquid Glass: related actions share one capsule, the groups are
/// set apart with spacers and Start is the one prominent (tinted) action.
struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            Button { model.showImporter = true } label: {
                Label("Add…", systemImage: "plus")
            }
            .help("Add archives or folders (⌘O)")
            .disabled(model.engine == nil)
        }

        ToolbarItem(placement: .principal) {
            Button { model.start() } label: {
                Label("Start", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help("Start the queue (⌘R)")
            .disabled(!model.canStart)
        }
        ToolbarItem(placement: .principal) {
            Button { model.stop() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop running jobs (⌘.)")
            .disabled(!model.canStop)
        }

        ToolbarItem(placement: .primaryAction) {
            Picker(selection: $model.settings.mode) {
                ForEach(OptimizationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Label("Mode", systemImage: "dial.medium")
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Mode")
            .help("Optimization mode. Applies to jobs started afterwards.")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.remove(ids: model.selection) } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .help("Remove selected jobs (Delete)")
            .disabled(model.jobs(for: model.selection).allSatisfy { $0.status == .running })

            Button { model.clearFinished() } label: {
                Label("Clear Finished", systemImage: "checkmark.circle.badge.xmark")
            }
            .help("Remove finished jobs from the list")
            .disabled(!model.hasFinished)

            Button { model.reveal(ids: model.selection) } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Reveal the selected jobs in Finder")
            .disabled(model.selection.isEmpty)
        }
    }
}

// MARK: - Job table

struct JobTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(model.jobs, selection: $model.selection) {
            TableColumn("Name") { job in NameCell(job: job) }
                .width(min: 180, ideal: 220)
            TableColumn("Format") { job in Text(job.formatLabel).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 64, max: 100)
            TableColumn("Original") { job in
                Text(job.originalBytes > 0 ? Fmt.bytes(job.originalBytes) : "-")
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 84, max: 120)
            .alignment(.trailing)
            TableColumn("Optimized") { job in OptimizedCell(job: job) }
                .width(min: 70, ideal: 84, max: 120)
                .alignment(.trailing)
            TableColumn("Saved") { job in SavedCell(job: job) }
                .width(min: 100, ideal: 125, max: 220)
                .alignment(.trailing)
            TableColumn("Trials") { job in TrialsCell(job: job) }
                .width(min: 50, ideal: 64, max: 90)
                .alignment(.trailing)
            TableColumn("Time") { job in TimeCell(job: job) }
                .width(min: 56, ideal: 72, max: 100)
                .alignment(.trailing)
            TableColumn("Status") { job in StatusCell(job: job) }
                .width(min: 200, ideal: 290)
        }
        .contextMenu(forSelectionType: Job.ID.self) { ids in
            if !ids.isEmpty {
                Button("Reveal in Finder") { model.reveal(ids: ids) }
                Button("Show Report") { model.showReport(ids: ids) }
                Button("Retry") { model.retry(ids: ids) }
                    .disabled(!model.canRetry(ids: ids))
                Divider()
                Button("Remove") { model.remove(ids: ids) }
                    .disabled(model.jobs(for: ids).allSatisfy { $0.status == .running })
            }
        } primaryAction: { ids in
            model.showReport(ids: ids)
        }
        // Handled by the table, so Delete never acts while another window or control has the focus.
        .onDeleteCommand { model.remove(ids: model.selection) }
        .onKeyPress(.return) {
            guard !model.selection.isEmpty else { return .ignored }
            model.showReport(ids: model.selection)
            return .handled
        }
    }
}

private struct NameCell: View {
    let job: Job
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                if job.status == .running, !job.cancelRequested, let file = job.step?.currentFile {
                    // The file 7zz is on right now, last path component first so it survives truncation.
                    Text((file as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: "doc.zipper").foregroundStyle(.secondary)
        }
        .help(job.url.path)
    }
}

private struct OptimizedCell: View {
    let job: Job
    var body: some View {
        if let result = job.result {
            Text(Fmt.bytes(result.optimizedBytes))
                .monospacedDigit()
                .foregroundStyle(job.status == .done ? .primary : .secondary)
        } else {
            Text("-").foregroundStyle(.tertiary)
        }
    }
}

private struct SavedCell: View {
    let job: Job
    var body: some View {
        if job.status == .done, let result = job.result {
            Text(Fmt.saved(result.savedBytes, of: result.originalBytes))
                .monospacedDigit()
                .foregroundStyle(.green)
        } else if job.status == .running, !job.cancelRequested, let saving = job.step?.estimatedSaving {
            // Live estimate while compressing: grey, with "≈", until the verified result replaces it.
            Text("≈ \(Fmt.percent(saving))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .help("Estimated from the part compressed so far. The exact figure appears when the archive has been verified.")
        } else {
            Text("-").foregroundStyle(.tertiary)
        }
    }
}

private struct TrialsCell: View {
    let job: Job
    var body: some View {
        if let result = job.result {
            Text("\(result.trialCount)").monospacedDigit()
        } else if job.trialsTotal > 0 {
            Text("\(job.trialsDone)/\(job.trialsTotal)").monospacedDigit()
        } else {
            Text("-").foregroundStyle(.tertiary)
        }
    }
}

private struct TimeCell: View {
    let job: Job
    var body: some View {
        if job.status == .running, let start = job.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Fmt.duration(context.date.timeIntervalSince(start))).monospacedDigit()
            }
        } else if let elapsed = job.elapsed {
            Text(Fmt.duration(elapsed)).monospacedDigit()
        } else {
            Text("-").foregroundStyle(.tertiary)
        }
    }
}

private struct StatusCell: View {
    let job: Job

    var body: some View {
        Group {
            if let style = StatusStyle.finished(job.status) {
                StatusBadge(style: style, detail: job.status == .failed ? job.errorMessage : nil)
                    .help(job.status == .failed ? (job.errorMessage ?? style.title) : style.title)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                runningView
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: job.status)
    }

    private var runningView: some View {
        HStack(spacing: 8) {
            if let step = job.step, !job.cancelRequested {
                ProgressView(value: step.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
            } else if job.trialsTotal > 0 {
                ProgressView(value: Double(job.trialsDone), total: Double(job.trialsTotal))
                    .progressViewStyle(.linear)
                    .frame(width: 70)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(runningText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if job.step != nil, !job.cancelRequested {
                    // Redrawn every second so the time left counts down between progress updates.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(detailText(at: context.date))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                }
            }
        }
        .help(helpText)
    }

    private var runningText: String {
        if job.cancelRequested { return "Stopping…" }
        if let step = job.step {
            // Percent first: when the column is narrow, the end of the text is what gets cut.
            return "\(step.fraction.formatted(.percent.precision(.fractionLength(0)))) · \(step.step.displayName)"
        }
        // The Trials column already shows x/y, so the status only names the phase.
        return job.phase?.displayName ?? "Starting"
    }

    /// "1,234/20,535 files · about 12 min left"
    private func detailText(at date: Date) -> String {
        var parts: [String] = []
        if let step = job.step, let total = step.filesTotal, total > 0 {
            let done = min(step.filesDone ?? 0, total)
            parts.append("\(done.formatted())/\(total.formatted()) files")
        }
        if let left = job.remaining(at: date) {
            parts.append(Fmt.remaining(left))
        } else if job.step != nil {
            parts.append("estimating time…")
        }
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        guard let step = job.step, !job.cancelRequested else { return runningText }
        var lines = ["\(step.step.displayName): \(Fmt.percent(step.fraction)) of this step"]
        if let file = step.currentFile { lines.append("Now: \(file)") }
        lines.append("The time left is for this step; verification follows the compression.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Floating bars

/// Everything that floats at the bottom of the window: the fading notice, the statistics and,
/// while something is going on, the activity capsule. One container, so the glass shapes blend
/// and morph into each other as they come and go.
struct BottomBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var glass

    private enum Activity: Equatable {
        case idle, scanning, running(Int)
    }

    private var activity: Activity {
        if model.isScanning { return .scanning }
        return model.hasRunningJobs ? .running(model.runningCount) : .idle
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 8) {
                if let text = model.transientNotice {
                    Text(text)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .floatingGlass(in: Capsule())
                        .glassEffectID("notice", in: glass)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .onTapGesture { model.dismissTransientNotice() }
                        .accessibilityAddTraits(.isStaticText)
                }
                HStack(spacing: 10) {
                    StatsBar()
                        .floatingGlass(in: Capsule())
                        .glassEffectID("stats", in: glass)
                    if activity != .idle {
                        activityCapsule
                            .floatingGlass(in: Capsule())
                            .glassEffectID("activity", in: glass)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .animation(.smooth(duration: 0.3), value: model.transientNotice)
        .animation(.smooth(duration: 0.3), value: activity)
    }

    private var activityCapsule: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(activityText)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: StatsBar.height)
        .accessibilityElement(children: .combine)
    }

    private var activityText: String {
        switch activity {
        case .idle: ""
        case .scanning: "Scanning…"
        case .running(let count): "\(count) running"
        }
    }
}

struct StatsBar: View {
    @Environment(AppModel.self) private var model

    static let height: CGFloat = 34

    var body: some View {
        HStack(spacing: 16) {
            stat("Queue", value: "\(model.pendingCount)", systemImage: "list.bullet")
            separator
            stat("Optimized",
                 value: "\(model.sessionOptimized) session · \(model.totalOptimized) total",
                 systemImage: "checkmark.seal")
            separator
            stat("Saved",
                 value: "\(Fmt.bytes(model.sessionSavedBytes)) session · \(Fmt.bytes(model.totalSavedBytes)) total",
                 systemImage: "arrow.down.circle")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: StatsBar.height)
    }

    private var separator: some View {
        Divider().frame(height: 14)
    }

    private func stat(_ title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// Shown while files are dragged over the window.
struct DropOverlay: View {
    /// The empty state already says where to drop, so the label is only for a window with jobs.
    let showsLabel: Bool

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack {
            frame
                .fill(Color.accentColor.opacity(0.08))
                .overlay { frame.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6])) }
                .padding(8)
            if showsLabel {
                Label("Drop to add to the queue", systemImage: "arrow.down.circle.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .floatingGlass(in: Capsule(), tint: .accentColor)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Banner and empty states

struct BackupBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep backups; verify results").fontWeight(.semibold)
                Text("Every new archive is tested and compared file by file before it is kept, but keep a copy of important originals, especially when using “Replace original”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Got It") { model.backupWarningDismissed = true }
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: .yellow)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    var dropTargeted = false

    private static let formats = ["7z", "zip", "rar", "tar", "gz", "xz", "iso", "dmg"]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 76, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: dropTargeted)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Drop archives or folders here")
                    .font(.title.weight(.semibold))
                Text("Squeeze7z repacks 7z, zip, rar and other archives into a standard 7z, choosing the best compression method for each file type. The result is kept only if it is smaller.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 6) {
                ForEach(Self.formats, id: \.self) { format in
                    Text(format)
                        .font(.caption.weight(.medium).monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Supported formats include \(Self.formats.joined(separator: ", "))")
            Button { model.showImporter = true } label: {
                Label("Add Archives or Folders…", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .controlSize(.extraLarge)
            .buttonStyle(.glassProminent)
            .padding(.top, 4)
            Text(model.folderAction == .compress
                 ? "A folder is compressed into a 7z of its own. Change this in Settings."
                 : "Folders are scanned recursively. Files ending in _optimized.7z are skipped.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EngineMissingView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("7-Zip engine not found", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        } description: {
            VStack(spacing: 6) {
                Text(message)
                Text("Squeeze7z needs the 7zz binary. Set SQUEEZE7Z_7ZZ to its path, reinstall the app, or install 7-Zip with Homebrew (brew install sevenzip).")
                    .font(.callout)
            }
        } actions: {
            Button("Look Again") { model.locateEngine() }
        }
    }
}
