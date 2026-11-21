import Foundation

extension OptimizerSettings {
    /// Threads 7zz uses for a build that runs alone (assembly, baselines): `-mmt` as `soloThreadSwitch` sets it,
    /// or every core when it leaves the choice to 7zz.
    var soloThreads: Int {
        if lowCPU { return 1 }
        if threadsPerTrial > 0 { return threadsPerTrial }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Threads of one trial when `concurrent` trials run at once (see `Job.trialThreadSwitch`).
    func trialThreads(concurrent: Int) -> Int {
        if lowCPU { return 1 }
        if threadsPerTrial > 0 { return threadsPerTrial }
        if concurrent > 1 { return max(1, ProcessInfo.processInfo.activeProcessorCount / concurrent) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }
}

/// Shared context of one optimization run: the engine, settings, work directory and event sink.
struct Job: Sendable {
    let tool: SevenZipTool
    let settings: OptimizerSettings
    let work: URL
    let emit: @Sendable (OptimizationEvent) -> Void

    var root: URL { work.appendingPathComponent("x", isDirectory: true) }
    var listsDir: URL { work.appendingPathComponent("lists", isDirectory: true) }
    var trialsDir: URL { work.appendingPathComponent("trials", isDirectory: true) }
    var sampleDir: URL { work.appendingPathComponent("sample", isDirectory: true) }

    var concurrentTrials: Int { settings.lowCPU ? 1 : max(1, settings.concurrentTrials) }
    var trialThreads: Int { settings.trialThreads(concurrent: concurrentTrials) }
    var soloThreads: Int { settings.soloThreads }

    var solidSwitch: String {
        settings.solidBlockSizeMB > 0 ? "-ms=\(settings.solidBlockSizeMB)m" : "-ms=on"
    }

    /// Switches shared by every `7zz a` call (trials, assembly, baselines).
    var commonAddSwitches: [String] {
        ["-snl", "-spd", "-scsUTF-8", "-mx=9", "-mhc=on", "-mtm=on", "-mtc=off", "-mta=off", solidSwitch]
    }

    /// Threads of a trial. With several trials in flight and no explicit setting, the cores are shared.
    var trialThreadSwitch: [String] {
        if settings.lowCPU { return ["-mmt=1"] }
        if settings.threadsPerTrial > 0 { return ["-mmt=\(settings.threadsPerTrial)"] }
        if concurrentTrials > 1 {
            return ["-mmt=\(max(1, ProcessInfo.processInfo.activeProcessorCount / concurrentTrials))"]
        }
        return []
    }

    /// Threads of assembly and baseline builds, which run alone.
    var soloThreadSwitch: [String] {
        if settings.lowCPU { return ["-mmt=1"] }
        if settings.threadsPerTrial > 0 { return ["-mmt=\(settings.threadsPerTrial)"] }
        return []
    }

    func addArguments(archive: URL, list: URL, spec: MethodSpec, filtersOff: Bool, threads: [String]) -> [String] {
        ["a"] + SevenZipTool.quietSwitches + commonAddSwitches + (filtersOff ? ["-mf=off"] : []) + threads
            + spec.arguments + [archive.path, "@" + list.path]
    }

    func log(_ s: String) { emit(.log(s)) }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Bounded concurrency

    /// Runs `count` jobs with at most `limit` in flight; `onResult` runs on the calling task.
    static func runBounded<T: Sendable>(limit: Int, count: Int,
                                        work: @escaping @Sendable (Int) async throws -> T,
                                        onResult: (Int, T) -> Void) async throws {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var next = 0
            var running = 0
            while next < count || running > 0 {
                while next < count && running < max(1, limit) {
                    let index = next
                    group.addTask { (index, try await work(index)) }
                    next += 1
                    running += 1
                }
                if let (index, value) = try await group.next() {
                    running -= 1
                    onResult(index, value)
                }
            }
        }
    }

    // MARK: Trials

    struct TrialJob: Sendable {
        var groupIndex: Int
        var spec: MethodSpec
        var input: TrialInput
    }

    enum TrialOutcome: Sendable {
        case measured(TrialResult)
        case failed(String)
    }

    /// Runs one candidate on one group and removes its archive immediately.
    func runTrial(_ job: TrialJob, id: Int) async throws -> TrialOutcome {
        let archive = trialsDir.appendingPathComponent("trial_\(id).7z")
        defer { try? FileManager.default.removeItem(at: archive) }
        let args = addArguments(archive: archive, list: job.input.listFile, spec: job.spec,
                                filtersOff: true, threads: trialThreadSwitch)
        let start = Date()
        let out = try await tool.run(args, currentDirectory: job.input.directory)
        guard out.exitCode == 0 else {
            return .failed("\(job.spec): exit \(out.exitCode) \(out.diagnostics.prefix(200))")
        }
        let size = Job.fileSize(archive)
        guard size > 0 else { return .failed("\(job.spec): no output") }
        return .measured(TrialResult(method: job.spec, compressedBytes: size,
                                     seconds: Date().timeIntervalSince(start), sampled: job.input.sampled))
    }

    /// Smallest archive wins; ties go to the method that is cheapest to decompress, then the shorter chain,
    /// then the earlier candidate.
    static func pickWinner(_ trials: [TrialResult]) -> TrialResult? {
        var best: (index: Int, trial: TrialResult)?
        for (i, t) in trials.enumerated() {
            guard let b = best else { best = (i, t); continue }
            let a = (t.compressedBytes, t.method.decompressionRank, t.method.coders.count)
            let c = (b.trial.compressedBytes, b.trial.method.decompressionRank, b.trial.method.coders.count)
            if a < c { best = (i, t) }
        }
        return best?.trial
    }

    // MARK: Assembly

    /// Builds the per-group archive by appending each group (largest first) with its winning method.
    /// 7-Zip leaves earlier solid blocks untouched, so every group keeps its own coder chain.
    /// Directory entries (mode and time) come last.
    func assemble(groups: [(group: FileGroup, spec: MethodSpec, list: URL)], symlinkList: URL?,
                  directories: DirectoryStage?, into archive: URL) async throws {
        try? FileManager.default.removeItem(at: archive)
        let ordered = groups.sorted { $0.group.totalBytes > $1.group.totalBytes }
        for item in ordered {
            let args = addArguments(archive: archive, list: item.list, spec: item.spec,
                                    filtersOff: true, threads: soloThreadSwitch)
            try await tool.runChecked(args, currentDirectory: root)
        }
        if let symlinkList {
            let spec = MethodSpec(coders: ["LZMA2:d=1m"])
            try await tool.runChecked(addArguments(archive: archive, list: symlinkList, spec: spec,
                                                   filtersOff: true, threads: soloThreadSwitch), currentDirectory: root)
        }
        try await appendDirectories(directories, to: archive)
    }

    /// Adds an entry for every directory of the tree. They come from a mirror that holds only the
    /// directories: 7zz always recurses into a directory it is given, so adding the real ones would
    /// pull in content that is already stored elsewhere.
    func appendDirectories(_ stage: DirectoryStage?, to archive: URL) async throws {
        guard let stage else { return }
        try await tool.runChecked(addArguments(archive: archive, list: stage.list, spec: .copy,
                                               filtersOff: true, threads: soloThreadSwitch),
                                  currentDirectory: stage.root)
    }

    /// Builds the whole tree as one archive with a single method (7-Zip's own filters stay enabled).
    /// `list` holds the files and links; `hasEntries` is false for a tree made only of directories.
    func buildBaseline(spec: MethodSpec, list: URL, hasEntries: Bool, directories: DirectoryStage?,
                       into archive: URL, progress: ProgressPlan? = nil) async throws {
        try? FileManager.default.removeItem(at: archive)
        if hasEntries {
            let args = addArguments(archive: archive, list: list, spec: spec, filtersOff: false, threads: soloThreadSwitch)
            try await tool.runChecked(args, currentDirectory: root, progress: progress.map(progressHandler))
            // 7zz picks a branch filter by itself; the ARM64 and RISC-V ones need 7-Zip 23+ to extract.
            if !settings.allowModernFilters, Self.usesModernFilter(try await tool.list(archive)) {
                try? FileManager.default.removeItem(at: archive)
                let plain = addArguments(archive: archive, list: list, spec: spec, filtersOff: true, threads: soloThreadSwitch)
                try await tool.runChecked(plain, currentDirectory: root)
            }
        }
        try await appendDirectories(directories, to: archive)
    }

    /// True when a method chain of the listing names the ARM64 or RISC-V branch filter.
    static func usesModernFilter(_ listing: ArchiveListing) -> Bool {
        let chains = [listing.methods].compactMap { $0 } + listing.entries.compactMap(\.method)
        return chains.contains { chain in
            chain.split(whereSeparator: { $0 == " " || $0 == ":" }).contains {
                let name = $0.uppercased()
                return name == "ARM64" || name == "RISCV"
            }
        }
    }

    // MARK: Progress

    /// What a 7zz run reports while it works.
    struct ProgressPlan: Sendable {
        var step: StepProgress.Step
        var files: Int?
        /// Bytes the run compresses, for the live saving estimate (with `output`).
        var inputBytes: Int64? = nil
        /// The archive being written; 7zz writes an update to `<archive>.tmp`.
        var output: URL? = nil
        /// Size of the independent LZMA2 chunks (media block): output is written a whole chunk at a time.
        var chunkBytes: Int64? = nil
        /// Saving shown until enough has been written to measure one (the media probe).
        var prior: Double? = nil
        /// Size of the source (archive or folder): the estimate is the share of it that the finished archive
        /// will save, as in the final result. A source that is itself compressed saves less than its raw data.
        var originalBytes: Int64? = nil
        /// Raw bytes that later blocks of the same layout compress, taken at this run's ratio.
        var pendingRawBytes: Int64 = 0
        /// Expected compressed size of parts still to come with their own estimate (the media block).
        var pendingBytes: Int64 = 0
    }

    /// Share of `original` the finished archive should save. The ratio compressed/raw of this run comes from
    /// what has been written (whole chunks for a chunked block, everything read for a single stream), else from
    /// `prior`. The archive is projected as what was there before the run (`base`), this run and the parts to
    /// come. Without `original`, the share saved on this run's raw data.
    static func estimatedSaving(written: Int64, base: Int64, input: Int64, fraction: Double, chunk: Int64?,
                                prior: Double?, pendingRaw: Int64 = 0, pending: Int64 = 0,
                                original: Int64?) -> Double? {
        guard input > 0 else { return nil }
        var ratio: Double?
        if written > 0, let chunk, chunk > 0 {
            let chunks = Double((input + chunk - 1) / chunk)
            let perChunk = Double(chunk) * (1 - (prior ?? 0))
            let complete = min(max((Double(written) / perChunk).rounded(), 1), chunks)
            ratio = Double(written) / min(complete * Double(chunk), Double(input))
        } else if written > 0, chunk == nil, Double(input) * fraction > 16 * 1_048_576 {
            ratio = Double(written) / (Double(input) * fraction)
        } else if let prior {
            ratio = 1 - prior
        }
        guard let ratio else { return nil }
        let saving: Double
        if let original, original > 0 {
            let projected = Double(base) + ratio * Double(input + pendingRaw) + Double(pending)
            saving = 1 - projected / Double(original)
        } else {
            saving = 1 - ratio
        }
        return min(max(saving, -0.5), 1)
    }

    /// Turns 7zz progress lines into `.stepProgress` events.
    ///
    /// Files done: 7zz counts the files it has read, which runs ahead of the compression (encoders read ahead)
    /// and behind it when testing; only extraction counts them as it goes. Compression and verification derive
    /// the count from the share of the data done instead.
    ///
    /// Saving: what has been written against the input it stands for. Parallel chunks are written whole, so
    /// the written size tells how many chunks are complete; a single stream is written as it goes. Until enough
    /// is written, `prior` (the media probe) is shown.
    func progressHandler(_ plan: ProgressPlan) -> @Sendable (ToolProgress) -> Void {
        let base = plan.output.map { Job.fileSize($0) } ?? 0
        let emit = self.emit
        return { line in
            let fraction = Double(line.percent) / 100
            var filesDone = line.files
            var currentFile = line.currentFile
            if plan.step != .extracting, let total = plan.files {
                filesDone = min(total, Int((Double(total) * fraction).rounded()))
                // Once 7zz has read every file, the name it shows is the last one read, not the one being
                // compressed: better none than a stale one.
                if plan.step != .verifying, (line.files ?? 0) >= total, fraction < 1 { currentFile = nil }
            }
            var saving: Double?
            if let output = plan.output, let input = plan.inputBytes {
                let written = max(Job.fileSize(output), Job.fileSize(output.appendingPathExtension("tmp"))) - base
                saving = Job.estimatedSaving(written: max(written, 0), base: base, input: input, fraction: fraction,
                                             chunk: plan.chunkBytes, prior: plan.prior,
                                             pendingRaw: plan.pendingRawBytes, pending: plan.pendingBytes,
                                             original: plan.originalBytes)
            }
            emit(.stepProgress(StepProgress(step: plan.step, fraction: fraction, filesDone: filesDone,
                                            filesTotal: plan.files, currentFile: currentFile,
                                            estimatedSaving: saving)))
        }
    }

    // MARK: Verification

    /// `7zz t` plus a listing comparison against the extracted tree (paths, sizes, CRC32).
    func verify(archive: URL, snapshot: TreeSnapshot) async throws {
        do {
            try await tool.runChecked(["t"] + SevenZipTool.quietSwitches + ["-spd", archive.path],
                                      progress: progressHandler(ProgressPlan(step: .verifying, files: snapshot.files.count)))
        } catch let OptimizerError.toolFailed(_, code, stderr) {
            throw OptimizerError.verificationFailed("7zz t failed (\(code)): \(stderr)")
        }
        let listing = try await tool.list(archive)
        if !settings.allowModernFilters, Self.usesModernFilter(listing) {
            throw OptimizerError.verificationFailed("the archive uses an ARM64 or RISC-V filter, which needs 7-Zip 23 or later")
        }
        try SourceChecks.verifyArchive(listing: listing, snapshot: snapshot)
    }
}
