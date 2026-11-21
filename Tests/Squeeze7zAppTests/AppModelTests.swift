import Foundation
import Testing
import Squeeze7zCore
@testable import Squeeze7z

@MainActor @Suite struct AppModelTests {
    /// A small zip with compressible text, so a job finishes quickly in fast mode.
    private func makeArchive(_ name: String, in dir: URL, seed: UInt64) throws -> URL {
        let tree = dir.appendingPathComponent("tree-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        var text = ""
        var state = seed | 1
        for _ in 0..<40_000 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; text += "w\(state % 50) " }
        try Data(text.utf8).write(to: tree.appendingPathComponent("a.txt"))
        let archive = dir.appendingPathComponent("\(name).zip")
        let p = Process()
        p.executableURL = try SevenZipTool.locate().executableURL
        p.arguments = ["a", "-tzip", "-mx=0", "-y", archive.path, "."]
        p.currentDirectoryURL = tree
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return archive
    }

    private func makeModel(archives: [URL], configure: (inout OptimizerSettings) -> Void = { _ in }) -> AppModel {
        let model = AppModel()
        var s = OptimizerSettings()
        s.mode = .fast
        s.outputMode = .newFile
        s.parallelJobs = 2
        configure(&s)
        model.settings = s
        model.jobs = archives.map { Job(url: $0) }
        return model
    }

    private func waitForIdle(_ model: AppModel, seconds: Double = 60) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while (model.queueActive || model.hasRunningJobs) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!model.queueActive && !model.hasRunningJobs, "queue did not drain")
    }

    @Test func startRightAfterStopRequeuesTheJobsStillStopping() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archives = try (0..<5).map { try makeArchive("job\($0)", in: dir, seed: UInt64($0 + 1)) }
        let model = makeModel(archives: archives)
        model.start()
        let running = model.jobs.filter { $0.status == .running }
        #expect(running.count == 2)
        model.stop()
        #expect(model.canStart)
        model.start()
        #expect(model.queueActive)
        try await waitForIdle(model)
        #expect(model.jobs.allSatisfy { $0.status == .done }, "statuses: \(model.jobs.map(\.status))")
    }

    @Test func startWithOnlyStoppingJobsStillRuns() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archives: [try makeArchive("solo", in: dir, seed: 9)])
        model.start()
        model.stop()
        #expect(model.canStart)
        model.start()
        try await waitForIdle(model)
        #expect(model.jobs.first?.status == .done)
    }

    @Test func stopWithoutStartLeavesJobsCancelled() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archives: [try makeArchive("one", in: dir, seed: 3), try makeArchive("two", in: dir, seed: 4)])
        model.start()
        model.stop()
        try await waitForIdle(model)
        #expect(model.jobs.allSatisfy { $0.status == .cancelled || $0.status == .done || $0.status == .queued })
        #expect(!model.jobs.contains { $0.status == .running })
    }

    @Test func raisingParallelJobsStartsMoreJobsAtOnce() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archives = try (0..<4).map { try makeArchive("p\($0)", in: dir, seed: UInt64($0 + 20)) }
        let model = makeModel(archives: archives) { $0.parallelJobs = 1 }
        model.start()
        #expect(model.runningCount == 1)
        var s = model.settings
        s.parallelJobs = 3
        model.settings = s
        #expect(model.runningCount == 3)
        model.stop()
        try await waitForIdle(model)
    }

    @Test func failedJobsCanBeRetried() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.zip")
        try Data("this is not an archive".utf8).write(to: bad)
        let model = makeModel(archives: [bad])
        model.start()
        try await waitForIdle(model)
        let job = try #require(model.jobs.first)
        #expect(job.status == .failed)
        #expect(!model.canStart)
        #expect(model.canRetry(ids: [job.id]))
        model.retry(ids: [job.id])
        #expect(job.status == .queued && job.errorMessage == nil)
        #expect(model.canStart)
        model.start()
        try await waitForIdle(model)
        #expect(job.status == .failed)
    }

    @Test func retryWhileTheQueueRunsLaunchesAtOnce() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.zip")
        try Data("nope".utf8).write(to: bad)
        let good = try makeArchive("good", in: dir, seed: 5)
        let model = makeModel(archives: [bad, good]) { $0.parallelJobs = 1 }
        model.start()
        try await waitForIdle(model)
        let failed = try #require(model.jobs.first)
        model.start()   // nothing queued: no-op
        #expect(!model.queueActive)
        model.retry(ids: [failed.id])
        model.start()
        #expect(failed.status == .running)
        try await waitForIdle(model)
    }

    // MARK: Review round 3

    @Test func multiVolumeOriginalSizeCoversAllVolumes() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, size) in [("big.7z.001", 1000), ("big.7z.002", 2000), ("big.7z.003", 300),
                             ("set.part1.rar", 10), ("set.part2.rar", 20)] {
            try Data(count: size).write(to: dir.appendingPathComponent(name))
        }
        #expect(Job(url: dir.appendingPathComponent("big.7z.001")).originalBytes == 3300)
        #expect(Job(url: dir.appendingPathComponent("set.part1.rar")).originalBytes == 30)

        let model = AppModel()
        model.addItems([dir.appendingPathComponent("big.7z.001"), dir.appendingPathComponent("set.part1.rar")])
        await model.scanTask?.value
        #expect(model.jobs.map(\.originalBytes) == [3300, 30])
    }

    @Test func skippedItemsAreAnnouncedWithoutAnAlert() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try makeArchive("ok", in: dir, seed: 7)
        let notes = dir.appendingPathComponent("notes.txt"), photo = dir.appendingPathComponent("p.jpg")
        try Data("x".utf8).write(to: notes)
        try Data("x".utf8).write(to: photo)
        let model = AppModel()
        model.addItems([archive, notes, photo])
        await model.scanTask?.value
        #expect(model.jobs.count == 1)
        #expect(model.transientNotice == "2 items skipped: not archives")
        #expect(model.notice == nil)
        model.dismissTransientNotice()
        #expect(model.transientNotice == nil)

        let single = AppModel()
        single.addItems([notes, archive])
        await single.scanTask?.value
        #expect(single.transientNotice == "1 item skipped: not an archive")

        let none = AppModel()
        none.addItems([archive])
        await none.scanTask?.value
        #expect(none.transientNotice == nil)
    }

    @Test func transientNoticeFadesByItself() async throws {
        let model = AppModel()
        model.showTransientNotice("hello", seconds: 0.2)
        #expect(model.transientNotice == "hello")
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.transientNotice == nil)
    }

    @Test func realErrorAfterStopIsNotShownAsCancelled() throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()
        func run(_ error: any Error) -> Job {
            let job = Job(url: dir.appendingPathComponent("a.zip"))
            job.begin()
            job.cancelRequested = true   // Stop was pressed
            model.finish(job, .failure(error))
            return job
        }
        let kept = run(OptimizerError.outputKept(path: "/tmp/x_optimized.7z", reason: "disk full"))
        #expect(kept.status == .failed)
        #expect(kept.errorMessage?.contains("/tmp/x_optimized.7z") == true)
        let broken = run(OptimizerError.verificationFailed("CRC of a differs"))
        #expect(broken.status == .failed)
        #expect(broken.errorMessage?.contains("CRC of a differs") == true)
        #expect(run(OptimizerError.cancelled).status == .cancelled)
        #expect(run(CancellationError()).status == .cancelled)
    }

    @Test func closingTheMainWindowNeedsConfirmationWhileJobsRun() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(archives: [try makeArchive("busy", in: dir, seed: 11)])
        #expect(model.mayCloseMainWindow)
        model.start()
        #expect(!model.mayCloseMainWindow)
        model.stop()
        try await waitForIdle(model)
        #expect(model.mayCloseMainWindow)
    }

    @Test func waitReturnsAtTheTimeoutNotWhenTheSlowestTaskEnds() async {
        let slow = Task<Void, Never> { try? await Task.sleep(for: .seconds(4)) }
        let started = Date()
        await AppModel.wait(for: [slow], timeout: .milliseconds(300))
        #expect(Date().timeIntervalSince(started) < 2)
        slow.cancel()
    }

    @Test func waitReturnsEarlyWhenTasksFinish() async {
        let quick = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(100)) }
        let started = Date()
        await AppModel.wait(for: [quick], timeout: .seconds(30))
        #expect(Date().timeIntervalSince(started) < 5)
        await AppModel.wait(for: [], timeout: .seconds(30))
    }
}

@MainActor @Suite struct FolderAndMigrationTests {
    private func makeFolder(in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 30_000).write(to: folder.appendingPathComponent("a.txt"))
        try Data(repeating: 0x62, count: 20_000).write(to: folder.appendingPathComponent("sub/b.txt"))
        return folder
    }

    @Test func foldersBecomeJobsOrAreScannedAsTheSettingSays() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(in: dir)
        let before = AppModel.shared.folderAction
        defer { AppModel.shared.folderAction = before }

        let compress = AppModel.collectArchives(from: [folder], folderAction: .compress)
        #expect(compress.archives == [folder])
        #expect(compress.sizes[folder.standardizedFileURL.path] == 50_000)

        let model = AppModel()
        model.folderAction = .compress
        model.addItems([folder])
        await model.scanTask?.value
        let job = try #require(model.jobs.first)
        #expect(model.jobs.count == 1 && job.url == folder)
        #expect(job.formatLabel == "FOLDER")
        #expect(job.originalBytes == 50_000)
        #expect(model.notice == nil)

        // The same folder is not queued twice.
        model.addItems([folder])
        await model.scanTask?.value
        #expect(model.jobs.count == 1 && model.notice == "The selected archives are already in the queue.")

        let scanning = AppModel()
        scanning.folderAction = .scanArchives
        scanning.addItems([folder])
        await scanning.scanTask?.value
        #expect(scanning.jobs.isEmpty)
        #expect(scanning.notice == "No supported archives found in the selected items.")

        let plain = AppModel()
        plain.folderAction = .compress
        plain.addItems([folder.appendingPathComponent("a.txt")])
        await plain.scanTask?.value
        #expect(plain.jobs.isEmpty)
        #expect(plain.notice == "Nothing to add: the selected items are not archives or folders.")
    }

    @Test func finishedFolderJobsAreNotCountedAsSavedBytes() throws {
        let model = AppModel()
        let before = (model.sessionOptimized, model.sessionSavedBytes)
        let folder = Job(url: URL(fileURLWithPath: "/tmp/Folder"), originalBytes: 100)
        folder.begin()
        model.finish(folder, .success(OptimizationResult(
            sourceURL: folder.url, outputURL: URL(fileURLWithPath: "/tmp/Folder.7z"), sourceFormat: "folder",
            originalBytes: 100, optimizedBytes: 10, outcome: .optimized, groups: [], strategy: "x", trialCount: 1,
            startedAt: .now, finishedAt: .now)))
        #expect(folder.status == .done)
        #expect(model.sessionOptimized == before.0 && model.sessionSavedBytes == before.1)
    }

    @Test func aFolderJobRunsAndWritesItsArchive() async throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(in: dir)
        let model = AppModel()
        var s = OptimizerSettings()
        s.mode = .fast
        model.settings = s
        model.jobs = [Job(url: folder)]
        model.start()
        let deadline = Date().addingTimeInterval(60)
        while (model.queueActive || model.hasRunningJobs) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let job = try #require(model.jobs.first)
        #expect(job.status == .done)
        #expect(job.result?.outputURL == dir.appendingPathComponent("Photos.7z"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt").path))
    }

    @Test func settingsFromAnOlderVersionMoveToSmartModeAndModernFiltersOnce() throws {
        let suite = "Squeeze7zTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // A fresh install has nothing stored: only the version is recorded, the defaults stay.
        var fresh = OptimizerSettings()
        #expect(AppModel.migrate(&fresh, defaults: defaults) == false)
        #expect(fresh.mode == .smart && fresh.allowModernFilters)
        #expect(defaults.integer(forKey: DefaultsKey.settingsVersion) == DefaultsKey.currentSettingsVersion)

        let other = "Squeeze7zTests-\(UUID().uuidString)"
        let old = try #require(UserDefaults(suiteName: other))
        defer { old.removePersistentDomain(forName: other) }
        var stored = OptimizerSettings()
        stored.mode = .normal
        stored.allowModernFilters = false
        old.set(try JSONEncoder().encode(stored), forKey: DefaultsKey.settings)
        var loaded = stored
        #expect(AppModel.migrate(&loaded, defaults: old))
        #expect(loaded.mode == .smart && loaded.allowModernFilters)
        // Only the old default moves to Smart; a mode the user picked stays.
        var chosen = stored
        chosen.mode = .best
        let third = "Squeeze7zTests-\(UUID().uuidString)"
        let kept = try #require(UserDefaults(suiteName: third))
        defer { kept.removePersistentDomain(forName: third) }
        kept.set(try JSONEncoder().encode(chosen), forKey: DefaultsKey.settings)
        #expect(AppModel.migrate(&chosen, defaults: kept))
        #expect(chosen.mode == .best && chosen.allowModernFilters)
        // Done once: a later choice of the user is kept.
        loaded.mode = .best
        loaded.allowModernFilters = false
        #expect(AppModel.migrate(&loaded, defaults: old) == false)
        #expect(loaded.mode == .best && !loaded.allowModernFilters)
    }
}

@Suite struct CollectArchivesTests {
    @Test func folderScanSkipsFunctionalContainersButDirectAddKeepsThem() throws {
        let dir = try TestDirectory.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["a.7z", "b.zip", "sub/c.tar.gz", "sub/d.7z.001", "app.jar", "book.cbz", "disk.dmg", "image.iso",
                     "pkg.deb", "x.apk", "notes.txt"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let scanned = AppModel.collectArchives(from: [folder], folderAction: .scanArchives).archives.map { $0.lastPathComponent }
        #expect(Set(scanned) == ["a.7z", "b.zip", "c.tar.gz", "d.7z.001"])

        let direct = AppModel.collectArchives(from: ["app.jar", "disk.dmg", "notes.txt"].map { folder.appendingPathComponent($0) })
        #expect(direct.archives.map { $0.lastPathComponent } == ["app.jar", "disk.dmg"])
        #expect(direct.ignoredDirect == 1)
    }
}

enum TestDirectory {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Squeeze7zAppTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The live status of a running job: time left in the current step.
@Suite struct LiveProgressTests {
    @Test @MainActor func timeLeftFollowsTheRateOfTheStep() {
        let job = Job(url: URL(fileURLWithPath: "/tmp/x.zip"), originalBytes: 100)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        job.updateStep(StepProgress(step: .compressingMedia, fraction: 0), now: start)
        // Too early to tell: under 8 seconds, or under 2% of the step.
        job.updateStep(StepProgress(step: .compressingMedia, fraction: 0.2), now: start + 5)
        #expect(job.remaining(at: start + 5) == nil)
        job.updateStep(StepProgress(step: .compressingMedia, fraction: 0.25), now: start + 30)
        #expect(job.remaining(at: start + 30) == 90)      // 30 s for a quarter: 90 s to go
        #expect(job.remaining(at: start + 40) == 80)      // counts down between updates
        // A new step starts its own clock.
        job.updateStep(StepProgress(step: .verifying, fraction: 0.5), now: start + 50)
        #expect(job.remaining(at: start + 50) == nil)
        #expect(Fmt.remaining(30) == "under a minute left")
        #expect(Fmt.remaining(12 * 60) == "about 12 min left")
        #expect(Fmt.remaining(80 * 60) == "about 1 h 20 min left")
    }
}
