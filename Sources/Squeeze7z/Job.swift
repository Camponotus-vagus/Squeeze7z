import Foundation
import Observation
import Squeeze7zCore

enum JobStatus: Sendable, Equatable {
    case queued, running, done, noGain, failed, cancelled

    var isFinished: Bool {
        switch self {
        case .done, .noGain, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

/// One archive in the queue. Mutated on the main actor only.
@MainActor @Observable
final class Job: Identifiable {
    nonisolated let id = UUID()
    nonisolated let url: URL

    var status: JobStatus = .queued
    var phase: OptimizationPhase?
    var trialsDone = 0
    var trialsTotal = 0
    /// The long step under way (extraction, compression, verification), with its live numbers.
    var step: StepProgress?
    var stepStartedAt: Date?
    /// Seconds left in the step as last estimated, and when.
    private(set) var stepRemaining: TimeInterval?
    private(set) var stepRemainingAt: Date?
    var result: OptimizationResult?
    var errorMessage: String?
    var log: [String] = []
    var originalBytes: Int64
    var startedAt: Date?
    var finishedAt: Date?
    /// Set by Stop while the engine is still tearing down.
    var cancelRequested = false
    /// Start was pressed while this job was still winding down after Stop: run it again once it has stopped.
    var requeueAfterCancel = false

    private let formatGuess: String
    private static let maxLogLines = 5000

    /// `originalBytes` is the size of all volumes; when nil it is worked out here (on the main actor).
    init(url: URL, originalBytes: Int64? = nil) {
        self.url = url
        let folder = ArchiveOptimizer.isFolder(url)
        self.originalBytes = originalBytes ?? (folder ? Job.folderSize(url) : ArchiveOptimizer.totalSize(of: url))
        self.formatGuess = folder ? "folder" : Job.guessFormat(url)
    }

    var name: String { url.lastPathComponent }
    var formatLabel: String { (result?.sourceFormat ?? formatGuess).uppercased() }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        if let result { return result.duration }
        return (finishedAt ?? .now).timeIntervalSince(startedAt)
    }

    /// Can be picked up by Start: waiting, cancelled, or still stopping with a restart requested.
    var isStartable: Bool {
        status == .queued || status == .cancelled || (status == .running && cancelRequested)
    }

    var hasReport: Bool { result != nil || errorMessage != nil || !log.isEmpty }

    /// The file to show in Finder: the output when there is one, otherwise the source.
    var revealURL: URL { result?.outputURL ?? url }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > Job.maxLogLines { log.removeFirst(log.count - Job.maxLogLines) }
    }

    func begin() {
        status = .running
        cancelRequested = false
        requeueAfterCancel = false
        startedAt = .now
        finishedAt = nil
        phase = nil
        trialsDone = 0
        trialsTotal = 0
        clearStep()
        errorMessage = nil
        result = nil
        log.removeAll()
    }

    func reset() {
        status = .queued
        phase = nil
        trialsDone = 0
        trialsTotal = 0
        clearStep()
        errorMessage = nil
        result = nil
        cancelRequested = false
        requeueAfterCancel = false
        startedAt = nil
        finishedAt = nil
        log.removeAll()
    }

    func apply(_ event: OptimizationEvent) {
        switch event {
        case .phase(let p):
            phase = p
            clearStep()
            appendLog("Phase: \(p.displayName)")
        case .trialProgress(let done, let total):
            trialsDone = done
            trialsTotal = total
        case .log(let line):
            appendLog(line)
        case .stepProgress(let p):
            updateStep(p, now: .now)
        }
    }

    /// Seconds left in the current step at `date`, once there is enough of it to tell.
    func remaining(at date: Date) -> TimeInterval? {
        guard let stepRemaining, let stepRemainingAt else { return nil }
        return max(0, stepRemaining - date.timeIntervalSince(stepRemainingAt))
    }

    func updateStep(_ p: StepProgress, now: Date) {
        if step?.step != p.step || stepStartedAt == nil {
            stepStartedAt = now
            stepRemaining = nil
            stepRemainingAt = nil
        }
        step = p
        guard let started = stepStartedAt else { return }
        let elapsed = now.timeIntervalSince(started)
        // Too early, the rate says little: wait for 2% of the step and 8 seconds.
        guard p.fraction >= 0.02, p.fraction < 1, elapsed >= 8 else { return }
        let measured = elapsed * (1 - p.fraction) / p.fraction
        // Smoothed against the previous estimate, carried forward to now.
        let smoothed = remaining(at: now).map { 0.7 * $0 + 0.3 * measured } ?? measured
        stepRemaining = smoothed
        stepRemainingAt = now
    }

    private func clearStep() {
        step = nil
        stepStartedAt = nil
        stepRemaining = nil
        stepRemainingAt = nil
    }

    /// Combined size of the regular files in a folder (links are not followed).
    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        while let item = walker.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private nonisolated static func guessFormat(_ url: URL) -> String {
        var name = url.lastPathComponent.lowercased()
        // Multi-volume names: "x.7z.001", "x.part1.rar", "x.zip".
        if let ext = name.split(separator: ".").last, ext.allSatisfy(\.isNumber), name.contains(".") {
            name = String(name.dropLast(ext.count + 1))
        }
        if name.contains(".part") && name.hasSuffix(".rar") { return "RAR" }
        let ext = (name as NSString).pathExtension
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "TGZ" }
        return ext.isEmpty ? "?" : ext.uppercased()
    }
}
