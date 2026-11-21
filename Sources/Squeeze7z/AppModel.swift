import AppKit
import Foundation
import Observation
import os
import Squeeze7zCore

enum DefaultsKey {
    static let settings = "Squeeze7z.settings"
    static let totalOptimized = "Squeeze7z.totalOptimized"
    static let totalSavedBytes = "Squeeze7z.totalSavedBytes"
    static let backupWarningDismissed = "Squeeze7z.backupWarningDismissed"
    static let folderAction = "Squeeze7z.folderAction"
    /// Bumped when the defaults of the stored settings change. 2: Smart mode and the ARM64/RISC-V filters.
    static let settingsVersion = "Squeeze7z.settingsVersion"
    static let currentSettingsVersion = 2
}

/// What happens to a folder that is dropped, opened or picked.
enum FolderAction: String, CaseIterable, Identifiable, Sendable {
    /// The folder becomes one job and is compressed into `<name>.7z`.
    case compress
    /// The folder is searched for archives, each of which becomes a job.
    case scanArchives
    var id: String { rawValue }
}

/// Owns the job queue, the engine handle, persisted settings and statistics.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    // Queue state
    var jobs: [Job] = []
    var selection: Set<Job.ID> = []
    var reportJob: Job?
    var showImporter = false
    var notice: String?
    /// A short message that fades by itself (unlike `notice`, which is a modal alert).
    private(set) var transientNotice: String?
    var isScanning = false
    /// True between Start and the moment the queue drains or Stop is pressed.
    private(set) var queueActive = false

    // Engine
    private(set) var engine: SevenZipTool?
    private(set) var engineError: String?

    // Statistics
    private(set) var sessionOptimized = 0
    private(set) var sessionSavedBytes: Int64 = 0
    private(set) var totalOptimized: Int
    private(set) var totalSavedBytes: Int64
    var backupWarningDismissed: Bool {
        didSet { UserDefaults.standard.set(backupWarningDismissed, forKey: DefaultsKey.backupWarningDismissed) }
    }

    /// "When adding a folder". Not part of `OptimizerSettings`: it only decides what the app queues.
    var folderAction: FolderAction {
        didSet { UserDefaults.standard.set(folderAction.rawValue, forKey: DefaultsKey.folderAction) }
    }

    @ObservationIgnored private var storedSettings: OptimizerSettings
    @ObservationIgnored private var tasks: [Job.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var transientTask: Task<Void, Never>?
    /// The folder scan started by the last `addItems`; tests await it.
    @ObservationIgnored private(set) var scanTask: Task<Void, Never>?

    /// Persisted as JSON in UserDefaults. Mutations are saved immediately.
    var settings: OptimizerSettings {
        get {
            access(keyPath: \.settings)
            return storedSettings
        }
        set {
            let previousParallelJobs = storedSettings.parallelJobs
            withMutation(keyPath: \.settings) { storedSettings = newValue }
            saveSettings()
            // A higher limit takes effect at once instead of when the next job finishes.
            if queueActive && newValue.parallelJobs != previousParallelJobs { pump() }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        storedSettings = Self.loadSettings()
        folderAction = defaults.string(forKey: DefaultsKey.folderAction).flatMap(FolderAction.init(rawValue:)) ?? .compress
        if Self.migrate(&storedSettings, defaults: defaults), let data = try? JSONEncoder().encode(storedSettings) {
            defaults.set(data, forKey: DefaultsKey.settings)
        }
        totalOptimized = defaults.integer(forKey: DefaultsKey.totalOptimized)
        totalSavedBytes = Int64(defaults.integer(forKey: DefaultsKey.totalSavedBytes))
        backupWarningDismissed = defaults.bool(forKey: DefaultsKey.backupWarningDismissed)
        locateEngine()
        if let tool = engine {
            // Working folders left by a crashed or force-quit run.
            Task.detached(priority: .background) {
                ArchiveOptimizer(tool: tool, settings: OptimizerSettings()).sweepStaleTemporaryFiles()
            }
        }
    }

    // MARK: - Engine

    func locateEngine() {
        do {
            let tool = try SevenZipTool.locate()
            engine = tool
            engineError = nil
            Logger(subsystem: "app.squeeze7z", category: "engine")
                .notice("Using 7zz at \(tool.executableURL.path, privacy: .public)")
        } catch {
            engine = nil
            engineError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Derived state

    var runningCount: Int { jobs.filter { $0.status == .running }.count }
    var pendingCount: Int { jobs.filter { $0.status == .queued || $0.status == .running }.count }
    var hasRunningJobs: Bool { runningCount > 0 }
    var canStart: Bool {
        engine != nil && !queueActive && jobs.contains { $0.isStartable }
    }
    func canRetry(ids: Set<Job.ID>) -> Bool {
        jobs(for: ids).contains { $0.status == .failed || $0.status == .noGain }
    }
    var canStop: Bool { queueActive || hasRunningJobs }
    /// Closing the main window quits the app, so it needs the same confirmation while jobs run.
    var mayCloseMainWindow: Bool { !hasRunningJobs }
    var hasFinished: Bool { jobs.contains { $0.status.isFinished } }

    func jobs(for ids: Set<Job.ID>) -> [Job] { jobs.filter { ids.contains($0.id) } }

    // MARK: - Adding

    /// Adds archives and folders. A folder becomes a job of its own or is scanned recursively for archives
    /// (off the main thread), as `folderAction` says.
    func addItems(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        guard engine != nil else {
            notice = "The 7zz engine is missing, so nothing can be added."
            return
        }
        isScanning = true
        let action = folderAction
        scanTask = Task {
            let collected = await Task.detached(priority: .userInitiated) {
                AppModel.collectArchives(from: fileURLs, folderAction: action)
            }.value
            isScanning = false
            var known = Set(jobs.map { $0.url.standardizedFileURL.path })
            var added: [Job] = []
            for url in collected.archives {
                let path = url.standardizedFileURL.path
                if known.insert(path).inserted { added.append(Job(url: url, originalBytes: collected.sizes[path])) }
            }
            jobs.append(contentsOf: added)
            if added.isEmpty {
                if collected.archives.isEmpty {
                    notice = action == .compress
                        ? "Nothing to add: the selected items are not archives or folders."
                        : "No supported archives found in the selected items."
                } else {
                    notice = "The selected archives are already in the queue."
                }
            }
            if collected.ignoredDirect > 0 && !collected.archives.isEmpty {
                showTransientNotice(Self.skippedMessage(count: collected.ignoredDirect))
            }
            if queueActive { pump() }
        }
    }

    struct Collected: Sendable {
        var archives: [URL]
        /// Items given directly (not found in a folder) that are not archives.
        var ignoredDirect: Int
        /// Combined size of all volumes, by standardized path of the first volume.
        var sizes: [String: Int64] = [:]
    }

    nonisolated static func skippedMessage(count: Int) -> String {
        count == 1 ? "1 item skipped: not an archive" : "\(count) items skipped: not archives"
    }

    func showTransientNotice(_ text: String, seconds: Double = 6) {
        transientTask?.cancel()
        transientNotice = text
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
        }
    }

    func dismissTransientNotice() {
        transientTask?.cancel()
        transientNotice = nil
    }

    private nonisolated static func isOwnOutput(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: #"_optimized(-\d+)?\.7z$"#,
                                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated static func collectArchives(from urls: [URL], folderAction: FolderAction = .compress) -> Collected {
        var archives: [URL] = []
        var folders: [URL] = []
        var ignored = 0
        let fm = FileManager.default
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir && folderAction == .compress {
                folders.append(url)
            } else if isDir {
                guard let walker = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                var found: [URL] = []
                while let item = walker.nextObject() as? URL {
                    guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    if isOwnOutput(item) { continue }
                    if ArchiveOptimizer.isPlainArchive(item) { found.append(item) }
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                archives.append(contentsOf: found)
            } else if ArchiveOptimizer.isSupportedArchive(url) {
                archives.append(url)
            } else {
                ignored += 1
            }
        }
        var sizes: [String: Int64] = [:]
        for url in archives { sizes[url.standardizedFileURL.path] = ArchiveOptimizer.totalSize(of: url) }
        for url in folders { sizes[url.standardizedFileURL.path] = Job.folderSize(url) }
        archives.append(contentsOf: folders)
        return Collected(archives: archives, ignoredDirect: ignored, sizes: sizes)
    }

    // MARK: - Queue control

    func start() {
        guard engine != nil else { return }
        for job in jobs where job.status == .cancelled { job.reset() }
        // Jobs still tearing down after Stop go back to the queue as soon as they have stopped.
        for job in jobs where job.status == .running && job.cancelRequested { job.requeueAfterCancel = true }
        guard jobs.contains(where: { $0.status == .queued || $0.requeueAfterCancel }) else { return }
        queueActive = true
        pump()
    }

    /// Puts failed and no-gain jobs back in the queue. They run when the queue is (or gets) started.
    func retry(ids: Set<Job.ID>) {
        let retryable = jobs(for: ids).filter { $0.status == .failed || $0.status == .noGain }
        guard !retryable.isEmpty else { return }
        for job in retryable { job.reset() }
        if queueActive { pump() }
    }

    /// Cancels every running job and stops launching new ones.
    func stop() {
        queueActive = false
        for job in jobs where job.status == .running { job.cancelRequested = true }
        for task in tasks.values { task.cancel() }
        updateActivity()
    }

    /// Waits until all running tasks have wound down, or the timeout elapses.
    func waitUntilIdle(timeout: Duration = .seconds(10)) async {
        await Self.wait(for: Array(tasks.values), timeout: timeout)
    }

    /// Returns when every task has finished or the timeout has passed, whichever comes first. A task group
    /// cannot do this: it waits for all children, and awaiting a task's value ignores cancellation.
    nonisolated static func wait(for tasks: [Task<Void, Never>], timeout: Duration) async {
        guard !tasks.isEmpty else { return }
        let gate = OneShotGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.install(continuation)
            let sleeper = Task {
                try? await Task.sleep(for: timeout)
                gate.open()
            }
            Task {
                for task in tasks { await task.value }
                sleeper.cancel()
                gate.open()
            }
        }
    }

    private func pump() {
        guard queueActive, let tool = engine else {
            updateActivity()
            return
        }
        let limit = max(1, min(settings.parallelJobs, 6))
        // Jobs that will run side by side from now: each one sizes its encoders for its share of the memory.
        let alongside = min(limit, runningCount + jobs.filter { $0.status == .queued }.count)
        while runningCount < limit, let next = jobs.first(where: { $0.status == .queued }) {
            launch(next, tool: tool, alongside: alongside)
        }
        if runningCount == 0 && !jobs.contains(where: { $0.status == .queued }) {
            queueActive = false
        }
        updateActivity()
    }

    private func launch(_ job: Job, tool: SevenZipTool, alongside: Int) {
        job.begin()
        var snapshot = storedSettings
        // The engine reads parallelJobs only for its memory budget: a job alone may use all of it.
        snapshot.parallelJobs = max(1, alongside)
        let url = job.url
        let (stream, continuation) = AsyncStream.makeStream(of: OptimizationEvent.self)

        tasks[job.id] = Task { [weak self] in
            // Events are delivered off-main by the engine; the stream keeps them ordered
            // and this consumer applies them on the main actor.
            let consumer = Task { @MainActor in
                for await event in stream { job.apply(event) }
            }
            let outcome: Result<OptimizationResult, Error>
            do {
                let optimizer = ArchiveOptimizer(tool: tool, settings: snapshot)
                let result = try await optimizer.optimize(url) { continuation.yield($0) }
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            continuation.finish()
            await consumer.value
            self?.finish(job, outcome)
        }
    }

    func finish(_ job: Job, _ outcome: Result<OptimizationResult, Error>) {
        tasks[job.id] = nil
        job.finishedAt = .now
        job.phase = nil
        switch outcome {
        case .success(let result):
            job.result = result
            job.originalBytes = result.originalBytes
            job.trialsDone = max(job.trialsDone, result.trialCount)
            job.trialsTotal = max(job.trialsTotal, result.trialCount)
            switch result.outcome {
            case .optimized:
                job.status = .done
                // A folder stays where it is: the archive is a copy, so nothing was saved.
                if result.sourceFormat != "folder" {
                    sessionOptimized += 1
                    sessionSavedBytes += result.savedBytes
                    totalOptimized += 1
                    totalSavedBytes += result.savedBytes
                    persistTotals()
                }
                job.appendLog("Saved \(Fmt.saved(result.savedBytes, of: result.originalBytes)) using \(result.strategy).")
            case .noGain:
                job.status = .noGain
                job.appendLog("No gain: the optimized archive was not smaller. Source left untouched.")
            }
        case .failure(let error):
            // Only a real cancellation shows as Cancelled: an error that arrives after Stop (a failed
            // verification, an archive kept after a failed replacement) is reported as it is.
            if error is CancellationError || (error as? OptimizerError) == .cancelled {
                if job.requeueAfterCancel && queueActive {
                    job.reset()
                } else {
                    job.status = .cancelled
                    job.appendLog("Cancelled.")
                }
            } else {
                job.status = .failed
                job.requeueAfterCancel = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                job.errorMessage = message
                job.appendLog("Failed: \(message)")
            }
        }
        let wasActive = queueActive
        pump()
        if wasActive && !queueActive, let app = NSApp, !app.isActive {
            app.requestUserAttention(.informationalRequest)
        }
    }

    /// Keeps the Mac awake while archives are being processed.
    private func updateActivity() {
        if hasRunningJobs {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "Squeeze7z is optimizing archives")
            }
        } else if let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    // MARK: - List actions

    func remove(ids: Set<Job.ID>) {
        let removable = Set(jobs(for: ids).filter { $0.status != .running }.map(\.id))
        guard !removable.isEmpty else { return }
        jobs.removeAll { removable.contains($0.id) }
        selection.subtract(removable)
        if let report = reportJob, removable.contains(report.id) { reportJob = nil }
    }

    func clearFinished() {
        remove(ids: Set(jobs.filter { $0.status.isFinished }.map(\.id)))
    }

    func reveal(ids: Set<Job.ID>) {
        let urls = jobs(for: ids).map(\.revealURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func showReport(ids: Set<Job.ID>) {
        if let job = jobs(for: ids).first(where: \.hasReport) ?? jobs(for: ids).first {
            reportJob = job
        }
    }

    // MARK: - Persistence

    /// One-time changes to settings saved by an older version. Returns true when `settings` changed or the
    /// version was recorded for the first time (a fresh install has nothing to change and just gets the new
    /// defaults). Version 2: the ARM64/RISC-V filters and Smart mode become the defaults.
    static func migrate(_ settings: inout OptimizerSettings, defaults: UserDefaults) -> Bool {
        let version = defaults.integer(forKey: DefaultsKey.settingsVersion)
        guard version < DefaultsKey.currentSettingsVersion else { return false }
        defaults.set(DefaultsKey.currentSettingsVersion, forKey: DefaultsKey.settingsVersion)
        guard defaults.data(forKey: DefaultsKey.settings) != nil else { return false }
        settings.allowModernFilters = true
        // Only the old default moves; a mode the user chose stays.
        if settings.mode == .normal { settings.mode = .smart }
        return true
    }

    private static func loadSettings() -> OptimizerSettings {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.settings),
              var loaded = try? JSONDecoder().decode(OptimizerSettings.self, from: data)
        else { return OptimizerSettings() }
        loaded.parallelJobs = min(max(loaded.parallelJobs, 1), 6)
        loaded.concurrentTrials = max(loaded.concurrentTrials, 1)
        loaded.samplingLevel = min(max(loaded.samplingLevel, 0), 6)
        loaded.threadsPerTrial = max(loaded.threadsPerTrial, 0)
        loaded.solidBlockSizeMB = max(loaded.solidBlockSizeMB, 0)
        return loaded
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(storedSettings) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.settings)
        }
    }

    private func persistTotals() {
        let defaults = UserDefaults.standard
        defaults.set(totalOptimized, forKey: DefaultsKey.totalOptimized)
        defaults.set(Int(totalSavedBytes), forKey: DefaultsKey.totalSavedBytes)
    }
}

/// Resumes one continuation the first time it is opened, from whichever thread gets there first.
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isOpen {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
