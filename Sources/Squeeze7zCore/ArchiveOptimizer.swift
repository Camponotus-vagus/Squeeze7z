import Foundation

public struct ArchiveOptimizer: Sendable {
    public let tool: SevenZipTool
    public let settings: OptimizerSettings
    let temporaryRoot: URL
    /// Moves a file to the Trash; replaceable in tests.
    var trash: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Groups smaller than this are not trialled (the default method is used).
    static let minTrialBytes: Int64 = 1024

    public init(tool: SevenZipTool, settings: OptimizerSettings, temporaryDirectory: URL? = nil) {
        self.tool = tool
        self.settings = settings
        self.temporaryRoot = temporaryDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Squeeze7z", isDirectory: true)
    }

    /// Removes working directories left behind by runs that died without cleaning up (crash, force quit,
    /// `kill -9`), plus stale captured process output. Directories of live processes are never touched.
    /// Call once at start-up. Returns the number of working directories removed.
    @discardableResult
    public func sweepStaleTemporaryFiles() -> Int {
        ActiveWork.sweepProcessOutput(in: ProcessRunner.outputDirectory, olderThan: 24 * 3600)
        return ActiveWork.sweep(root: temporaryRoot)
    }

    public static let supportedExtensions: Set<String> = VolumeSet.archiveExtensions

    /// By extension, plus volume patterns: `.001`, `.part1.rar` are accepted; later volumes are not.
    public static func isSupportedArchive(_ url: URL) -> Bool { VolumeSet.isSupported(url) }

    /// Supported and a plain container of files (not a jar, apk, cbz, dmg, iso, deb, …). Folder scans queue
    /// only these; the others are accepted when the user adds them directly.
    public static func isPlainArchive(_ url: URL) -> Bool { VolumeSet.isPlainArchive(url) }

    /// Combined size of all volumes of the archive whose first volume is `url` (the size of a single file otherwise).
    public static func totalSize(of url: URL) -> Int64 {
        VolumeSet.volumes(of: url).reduce(Int64(0)) { $0 + Job.fileSize($1) }
    }

    /// jar, apk, cbz, dmg, iso, deb, … Never replaced by the result, whatever the output mode.
    public static func isFunctionalContainer(_ url: URL) -> Bool { VolumeSet.isFunctionalContainer(url) }

    // MARK: Entry point

    public func optimize(_ source: URL,
                         progress: @escaping @Sendable (OptimizationEvent) -> Void) async throws -> OptimizationResult {
        let started = Date()
        let source = source.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw OptimizerError.notAnArchive("\(source.lastPathComponent) does not exist")
        }
        let work = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let job = Job(tool: tool, settings: settings, work: work, emit: progress)
        let keep = settings.keepTempFiles
        if !keep {
            ActiveWork.writeOwnerMarker(in: work)
            ActiveWork.shared.addDirectory(work)
        }
        defer {
            if keep { progress(.log("Temporary files kept in \(work.path)")) }
            else {
                FileTree.forceRemove(work)
                ActiveWork.shared.removeDirectory(work)
            }
        }
        do {
            return try await run(job: job, source: source, started: started)
        } catch is CancellationError {
            throw OptimizerError.cancelled
        } catch {
            // A verified archive that was kept after a failed replacement must be reported as it is.
            if case OptimizerError.outputKept = error { throw error }
            if Task.isCancelled { throw OptimizerError.cancelled }
            throw error
        }
    }

    // MARK: Pipeline

    private func run(job: Job, source: URL, started: Date) async throws -> OptimizationResult {
        if Self.isFolder(source) { return try await runFolder(job: job, source: source, started: started) }
        let fm = FileManager.default
        let volumes = VolumeSet.volumes(of: source)
        let originalBytes = volumes.reduce(Int64(0)) { $0 + Job.fileSize($1) }

        // 1. Inspect
        job.emit(.phase(.inspecting))
        let listing = try await tool.list(source)
        guard !listing.entries.contains(where: \.isEncrypted) else { throw OptimizerError.encrypted }
        // 7zz neither lists nor extracts data after the end of the archive (a second concatenated zip, appended
        // junk), so the result would silently lack it while the size comparison counts it as saved space. Tar
        // is exempt: bytes after its end marker are ignored by standard tar as well.
        if listing.tailBytes > 0 && listing.format.lowercased() != "tar" {
            throw OptimizerError.notAnArchive("\(listing.tailBytes) bytes follow the end of the archive and would be lost")
        }
        if listing.headBytes > 0 {
            job.log("\(listing.headBytes) bytes before the archive data (such as an SFX stub) are not carried over.")
        }
        try SourceChecks.ensureSafe(listing)
        job.log("\(listing.format): \(listing.entries.filter { !$0.isDirectory }.count) files, \(ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file))")

        // 2. Extract (single-stream compressors holding a tar are unpacked twice)
        job.emit(.phase(.extracting))
        let singleStreamFormats: Set<String> = ["gzip", "bzip2", "xz", "zstd", "z", "lzma", "lzip", "lz4"]
        let regularEntries = listing.entries.filter { !$0.isDirectory }
        var comparisonListing: ArchiveListing? = listing
        if singleStreamFormats.contains(listing.format.lowercased()) && regularEntries.count == 1 {
            let outer = job.work.appendingPathComponent("outer", isDirectory: true)
            let unpacked = regularEntries[0].size > 0 ? regularEntries[0].size : originalBytes * 5
            try checkDiskSpace(unpacked: unpacked)
            try await tool.extract(source, listing: listing, to: outer)
            // readdir, not FileManager: the inner name may start with "._", which FileManager hides.
            let names = try TreeScanner.listDirectory(outer.path)
            guard names.count == 1 else { throw OptimizerError.notAnArchive("unexpected content in \(source.lastPathComponent)") }
            let extracted = [outer.appendingPathComponent(names[0])]
            let inner = try? await tool.list(extracted[0])
            if let inner, inner.format.lowercased() == "tar" {
                guard !inner.entries.contains(where: \.isEncrypted) else { throw OptimizerError.encrypted }
                try SourceChecks.ensureSafe(inner)
                try checkDiskSpace(unpacked: inner.entries.reduce(0) { $0 + $1.size }, alreadyUsed: unpacked)
                job.log("tar inside \(listing.format): \(inner.entries.filter { !$0.isDirectory }.count) files")
                try await tool.extract(extracted[0], listing: inner, to: job.root)
                comparisonListing = inner
                try? fm.removeItem(at: outer)
            } else {
                try fm.moveItem(at: outer, to: job.root)
                comparisonListing = nil
            }
        } else {
            try checkDiskSpace(unpacked: listing.entries.reduce(0) { $0 + $1.size })
            try await tool.extract(source, listing: listing, to: job.root)
        }
        var snapshot = try await TreeScanner.scan(root: job.root)
        for path in Array(snapshot.files.keys) + Array(snapshot.directories.keys) + snapshot.emptyDirectories
        where path.contains("\n") || path.contains("\r") {
            var message = "file names containing line breaks are not supported (\(path.debugDescription))"
            if listing.format.lowercased() == "hfs" {
                message += ". HFS+ images hold an internal folder (.HFS+ Private Directory Data) whose name ends with a carriage return"
            }
            throw OptimizerError.notAnArchive(message)
        }
        if let comparisonListing {
            try SourceChecks.verifyExtraction(listing: comparisonListing, snapshot: snapshot)
            snapshot.adoptDirectoryModes(from: comparisonListing)
        }
        if !settings.keepMacOSMetadata {
            let dropped = try MacOSMetadata.strip(root: job.root, snapshot: &snapshot)
            if dropped > 0 {
                job.log("Left out the __MACOSX folder (\(dropped) AppleDouble files of extended attributes): Archive Utility would expand it over the real files.")
            }
        }
        if SevenZipTool.skipsAlternateStreams(listing) {
            job.log("Extended attributes of the files in the disk image are not carried over: 7z cannot store them.")
        }
        if snapshot.files.isEmpty && snapshot.emptyDirectories.isEmpty {
            job.log("The archive is empty.")
            return OptimizationResult(sourceURL: source, outputURL: nil, sourceFormat: listing.format,
                                      originalBytes: originalBytes, optimizedBytes: originalBytes, outcome: .noGain,
                                      groups: [], strategy: "per-group", trialCount: 0,
                                      startedAt: started, finishedAt: Date())
        }

        return try await pack(job: job, source: source, started: started, snapshot: snapshot,
                              sourceFormat: listing.format, originalBytes: originalBytes, volumes: volumes, isFolder: false)
    }

    /// Steps 3 to 8 of the pipeline, shared by archives and folders: group, trials, assembly, baselines,
    /// verification and output. `snapshot` describes the tree under `job.root`.
    func pack(job: Job, source: URL, started: Date, snapshot: TreeSnapshot, sourceFormat: String,
              originalBytes: Int64, volumes: [URL], isFolder: Bool) async throws -> OptimizationResult {
        let fm = FileManager.default
        // 3. Group
        job.emit(.phase(.grouping))
        let grouping = Grouper.makeGroups(snapshot: snapshot, root: job.root, minGroupBytes: settings.minGroupBytes)
        let groups = grouping.groups
        job.log("\(groups.count) groups, \(snapshot.files.count) entries")
        try fm.createDirectory(at: job.listsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: job.trialsDir, withIntermediateDirectories: true)

        let allPaths = snapshot.files.keys.sorted()
        let allList = job.listsDir.appendingPathComponent("all.txt")
        try ListFile.write(allPaths, to: allList)
        let directoryStage = try DirectoryStage.build(directories: snapshot.directories, in: job.work)
        let totalBytes = snapshot.regularBytes
        let mode = settings.mode

        // 4. Trials
        var candidates: [[MethodSpec]] = groups.map { _ in [] }
        var inputs: [TrialInput?] = groups.map { _ in nil }
        var trialJobs: [Job.TrialJob] = []
        if mode.runsTrials {
            for (i, g) in groups.enumerated() where g.totalBytes >= Self.minTrialBytes {
                candidates[i] = CandidateGenerator.candidates(for: g, settings: settings,
                                                              isSingleExtensionArchive: grouping.isSingleExtensionArchive)
                let input = try Sampling.prepare(group: g, root: job.root, snapshot: snapshot,
                                                 level: settings.samplingLevel,
                                                 directory: job.sampleDir.appendingPathComponent("g\(i)", isDirectory: true),
                                                 listFile: job.listsDir.appendingPathComponent("trial_\(i).txt"))
                inputs[i] = input
                for spec in candidates[i] { trialJobs.append(Job.TrialJob(groupIndex: i, spec: spec, input: input)) }
            }
        }
        // The whole-archive LZMA2 baseline is built in every mode: it is the floor under the per-group winners
        // (those can lose on the full data when sampled, and per-extension groups lose cross-extension redundancy).
        // Fast and Smart modes: already compressed files get their own block of parallel LZMA2 chunks, and the
        // baseline (and the Smart split) cover the rest of the tree.
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let media = try await MediaBlock.make(groups: groups, snapshot: snapshot, job: job, physicalMemory: physicalMemory)
        let mediaFiles = Set(media?.files ?? [])
        let restGroups = media == nil ? groups : groups.filter { $0.category != .compressed }
        let restPaths = media == nil ? allPaths : allPaths.filter { !mediaFiles.contains($0) }
        let restBytes = totalBytes - (media?.bytes ?? 0)
        let baselines = CandidateGenerator.wholeArchiveBaselines(totalBytes: restBytes, settings: settings,
                                                             threads: job.soloThreads,
                                                             physicalMemory: physicalMemory)
        // Smart mode: a text-heavy tree is also built as a PPMd text block plus an LZMA2 block for the rest.
        let smartPlan: SmartPlan? = mode == .smart
            ? try SmartPlan.make(groups: restGroups, allPaths: restPaths, totalBytes: restBytes,
                                 baseline: baselines.first, settings: settings, listsDir: job.listsDir)
            : nil
        var plannedTotal = trialJobs.count + baselines.count + (smartPlan == nil ? 0 : 1) + (media == nil ? 0 : 1)
        var trialsByGroup: [[TrialResult]] = groups.map { _ in [] }
        var done = 0
        if trialJobs.isEmpty && mode == .smart { job.emit(.trialProgress(done: 0, total: plannedTotal)) }
        if !trialJobs.isEmpty {
            job.emit(.phase(.trials))
            job.emit(.trialProgress(done: 0, total: plannedTotal))
            let jobs = trialJobs
            try await Job.runBounded(limit: job.concurrentTrials, count: jobs.count,
                                     work: { try await job.runTrial(jobs[$0], id: $0) },
                                     onResult: { index, outcome in
                switch outcome {
                case .measured(let r): trialsByGroup[jobs[index].groupIndex].append(r)
                case .failed(let message): job.log("Trial skipped: \(message)")
                }
                done += 1
                job.emit(.trialProgress(done: done, total: plannedTotal))
            })
        }

        var reports: [GroupReport] = []
        var chosen: [(group: FileGroup, spec: MethodSpec, list: URL)] = []
        for (i, g) in groups.enumerated() {
            // Trials finish out of order; restore candidate order for a stable report.
            let order = Dictionary(uniqueKeysWithValues: candidates[i].enumerated().map { ($1, $0) })
            let trials = trialsByGroup[i].sorted { (order[$0.method] ?? 0) < (order[$1.method] ?? 0) }
            let winner = Job.pickWinner(trials)?.method ?? CandidateGenerator.defaultMethod(for: g, settings: settings)
            reports.append(GroupReport(group: g, trials: trials, winner: winner))
            let list = job.listsDir.appendingPathComponent("full_\(i).txt")
            try ListFile.write(g.files, to: list)
            chosen.append((g, winner, list))
            job.log("\(g.id): \(winner)")
        }

        // 4b. Hybrid families: related extension groups tried as one solid block (not in fast mode)
        var familyOutcomes: [FamilyOutcome] = []
        var familyTrialCount = 0
        if mode.runsTrials && settings.hybridGroups {
            let groupsDone = done
            let plannedBefore = plannedTotal
            familyOutcomes = try await evaluateFamilies(job: job, groups: groups, reports: reports, inputs: inputs,
                                                        snapshot: snapshot, firstTrialID: trialJobs.count,
                                                        progress: { finished, planned in
                if finished == 0 { job.emit(.phase(.trials)) }
                familyTrialCount = finished == planned ? finished : planned
                job.emit(.trialProgress(done: groupsDone + finished, total: plannedBefore + planned))
            })
            done += familyTrialCount
            plannedTotal += familyTrialCount
        }
        let blocks = familyOutcomes.filter(\.useBlock)

        // 5. Assemble the per-group and hybrid archives (not in fast mode). Trials on full data are exact, so
        // the layout the estimates favour is built alone unless the other one is close.
        var archives: [(url: URL, size: Int64, strategy: String)] = []
        // Keeps only the smallest archive so far: at most two full-size archives exist at once.
        func keepSmallest() {
            guard let keep = archives.indices.min(by: { (archives[$0].size, $0) < (archives[$1].size, $1) }) else { return }
            for (n, archive) in archives.enumerated() where n != keep {
                try? FileManager.default.removeItem(at: archive.url)
            }
            archives = [archives[keep]]
        }
        if mode.runsTrials {
            job.emit(.phase(.assembling))
            var symlinkList: URL?
            if !grouping.symlinks.isEmpty {
                symlinkList = job.listsDir.appendingPathComponent("symlinks.txt")
                try ListFile.write(grouping.symlinks, to: symlinkList!)
            }
            let perGroupEstimate = groups.indices.reduce(Int64(0)) { $0 + Hybrid.estimate(reports[$1], input: inputs[$1]) }
            let hybridEstimate: Int64? = blocks.isEmpty ? nil
                : blocks.reduce(perGroupEstimate) { $0 - $1.splitBytes + $1.blockBytes }
            // Per-group trials of a group above the LZMA2 chunk size may chunk differently from its assembly
            // (fewer threads in a trial): their sum is then an estimate as well.
            let chunkSensitive = groups.contains {
                Hybrid.chunkingDiffers(bytes: $0.totalBytes, trialThreads: job.trialThreads, soloThreads: job.soloThreads)
            }
            let sampled = inputs.contains { $0?.sampled == true } || familyOutcomes.contains { $0.trials.contains(where: \.sampled) }
                || chunkSensitive
            let build = Hybrid.layoutsToBuild(perGroup: perGroupEstimate, hybrid: hybridEstimate, sampled: sampled)
            if build.perGroup {
                let assembled = job.work.appendingPathComponent("assembled.7z")
                try await job.assemble(groups: chosen, symlinkList: symlinkList, directories: directoryStage, into: assembled)
                archives.append((assembled, Job.fileSize(assembled), "per-group"))
                job.log("Per-group archive: \(Job.fileSize(assembled)) bytes")
                keepSmallest()
            }
            if build.hybrid {
                let inBlocks = Set(blocks.flatMap(\.family.members))
                var layout = chosen.enumerated().filter { !inBlocks.contains($0.offset) }.map(\.element)
                for block in blocks {
                    if let winner = block.winner { layout.append((block.family.group, winner, block.list)) }
                }
                let hybrid = job.work.appendingPathComponent("hybrid.7z")
                try await job.assemble(groups: layout, symlinkList: symlinkList, directories: directoryStage, into: hybrid)
                archives.append((hybrid, Job.fileSize(hybrid), "hybrid"))
                job.log("Hybrid archive (\(blocks.map(\.family.group.id).joined(separator: ", "))): \(Job.fileSize(hybrid)) bytes")
                keepSmallest()
            }
        }

        // 6. Fast and Smart: the baseline and the Smart split of everything but the media block, side by side;
        // then the directory entries and the media block are appended to the smaller one. 7zz rewrites the whole
        // archive on every append, so the large media block goes last and is compressed once.
        if !mode.runsTrials, let baseSpec = baselines.first {
            job.emit(.phase(.baseline))
            let layerDirectories = media == nil ? directoryStage : nil
            var restList = allList
            if media != nil {
                restList = job.listsDir.appendingPathComponent("rest.txt")
                try ListFile.write(restPaths, to: restList)
            }
            let suffix = media == nil ? "" : MediaBlock.strategySuffix
            let baselineURL = job.work.appendingPathComponent("baseline_0.7z")
            let baselineBlocks = restPaths.isEmpty ? [] : [Job.Block(list: restList, spec: baseSpec, autoFilters: true)]
            let baselineName = restPaths.isEmpty ? "parallel media block" : "whole-archive \(baseSpec)" + suffix
            @Sendable func buildBaselineLayer() async throws -> Int64 {
                try await job.buildLayered(base: nil, blocks: baselineBlocks, directories: layerDirectories, into: baselineURL)
                return Job.fileSize(baselineURL)
            }
            func recordBaseline(_ size: Int64) {
                archives.append((baselineURL, size, baselineName))
                keepSmallest()
                job.log("Baseline \(baseSpec)\(media == nil ? "" : " (without the media block)"): \(size) bytes")
                done += 1
                job.emit(.trialProgress(done: done, total: plannedTotal))
            }
            if let plan = smartPlan {
                let splitURL = job.work.appendingPathComponent("smart.7z")
                var splitBlocks = [Job.Block(list: plan.textList, spec: plan.textSpec, autoFilters: false)]
                if let list = plan.restList { splitBlocks.append(Job.Block(list: list, spec: plan.restSpec, autoFilters: true)) }
                let blocks = splitBlocks
                @Sendable func buildSplitLayer() async throws -> Int64 {
                    try await job.buildLayered(base: nil, blocks: blocks, directories: layerDirectories, into: splitURL)
                    return Job.fileSize(splitURL)
                }
                func recordSplit(_ size: Int64) {
                    archives.append((splitURL, size, SmartPlan.strategy + suffix))
                    keepSmallest()
                    job.log("Smart split (\(plan.text.files.count) text files as PPMd, \(plan.restFileCount) others as LZMA2)\(media == nil ? "" : " without the media block"): \(size) bytes")
                    done += 1
                    job.emit(.trialProgress(done: done, total: plannedTotal))
                }
                let lzma = baseSpec.coders.first ?? ""
                let dictionary = lzma.split(separator: ":").first { $0.hasPrefix("d=") }.map { String($0.dropFirst(2)) } ?? "1536m"
                let mem = max(1, min(settings.ppmdMemoryMB, SmartPlan.maxPPMdMemoryMB))
                if job.soloThreads >= 4,
                   Job.canBuildConcurrently(dictionary: dictionary, ppmdMB: mem, physicalMemory: physicalMemory) {
                    // LZMA2 on one stream uses two threads and PPMd one: the two layouts are built side by side.
                    job.emit(.phase(.assembling))
                    async let splitSize = buildSplitLayer()
                    let baselineSize = try await buildBaselineLayer()
                    recordBaseline(baselineSize)
                    recordSplit(try await splitSize)
                } else {
                    recordBaseline(try await buildBaselineLayer())
                    job.emit(.phase(.assembling))
                    recordSplit(try await buildSplitLayer())
                }
            } else {
                recordBaseline(try await buildBaselineLayer())
            }
            if let media, !archives.isEmpty {
                // keepSmallest left one archive: both layouts get the same media block, so the smaller one wins.
                let target = archives[0].url
                try await job.appendDirectories(directoryStage, to: target)
                try await job.tool.runChecked(job.addArguments(archive: target, list: media.list, spec: media.spec,
                                                               filtersOff: true, threads: job.soloThreadSwitch),
                                              currentDirectory: job.root)
                archives[0].size = Job.fileSize(target)
                job.log("Media block (\(media.files.count) files, \(media.bytes) bytes) as parallel chunks \(media.spec): archive \(archives[0].size) bytes")
                done += 1
                job.emit(.trialProgress(done: done, total: plannedTotal))
            }
        } else if !baselines.isEmpty {
        // 6'. Whole-archive baselines (modes with trials)
            job.emit(.phase(.baseline))
            let specs = baselines
            let urls = specs.indices.map { job.work.appendingPathComponent("baseline_\($0).7z") }
            try await Job.runBounded(limit: 1, count: specs.count,
                                     work: { i -> Int64 in
                try await job.buildBaseline(spec: specs[i], list: allList, hasEntries: !allPaths.isEmpty,
                                            directories: directoryStage, into: urls[i])
                return Job.fileSize(urls[i])
            }, onResult: { i, size in
                archives.append((urls[i], size, "whole-archive \(specs[i])"))
                keepSmallest()
                job.log("Baseline \(specs[i]): \(size) bytes")
                done += 1
                job.emit(.trialProgress(done: done, total: plannedTotal))
            })
        }
        guard let best = archives.enumerated().min(by: { ($0.element.size, $0.offset) < ($1.element.size, $1.offset) })?.element else {
            throw OptimizerError.toolFailed(command: "7zz a", exitCode: -1, stderr: "No archive was produced.")
        }
        let trialCount = trialJobs.count + familyTrialCount + baselines.count + (smartPlan == nil ? 0 : 1)
            + (media == nil ? 0 : 1)

        // The groups of the report are the layout of the archive that won; a whole-archive baseline reports the
        // extension groups, as it has none of its own.
        var reportedGroups = reports
        if best.strategy == "hybrid" {
            let inBlocks = Set(blocks.flatMap(\.family.members))
            reportedGroups = reports.enumerated().filter { !inBlocks.contains($0.offset) }.map(\.element)
            for block in blocks {
                if let winner = block.winner {
                    reportedGroups.append(GroupReport(group: block.family.group, trials: block.trials, winner: winner))
                }
            }
            reportedGroups.sort { ($0.group.totalBytes, $1.group.id) > ($1.group.totalBytes, $0.group.id) }
        }
        if best.strategy.hasPrefix(SmartPlan.strategy), let plan = smartPlan { reportedGroups = plan.reports }
        if let media, best.strategy.hasSuffix(MediaBlock.strategySuffix) || best.strategy == "parallel media block" {
            let mediaGroups = groups.filter { $0.category == .compressed }
            var group = FileGroup(id: "media", category: .compressed,
                                  extensions: Array(Set(mediaGroups.flatMap(\.extensions))).sorted(),
                                  files: media.files, totalBytes: media.bytes)
            group.executableArchitectures = []
            let rest = reportedGroups.filter { $0.group.category != .compressed }
            reportedGroups = [GroupReport(group: group, trials: [], winner: media.spec)] + rest
        }
        let familyReports = familyOutcomes.map { outcome in
            FamilyReport(id: outcome.family.group.id, family: outcome.family.family,
                         groupIDs: outcome.family.members.map { groups[$0].id },
                         totalBytes: outcome.family.group.totalBytes, blockBytes: outcome.blockBytes,
                         splitBytes: outcome.splitBytes, useBlock: outcome.useBlock, winner: outcome.winner,
                         trialCount: outcome.trials.count)
        }

        // 7. Verify
        job.emit(.phase(.verifying))
        try await job.verify(archive: best.url, snapshot: snapshot)

        // 8. Decide and write
        job.emit(.phase(.finishing))
        var result = OptimizationResult(sourceURL: source, outputURL: nil, sourceFormat: sourceFormat,
                                        originalBytes: originalBytes, optimizedBytes: best.size, outcome: .noGain,
                                        groups: reportedGroups, strategy: best.strategy, trialCount: trialCount,
                                        startedAt: started, finishedAt: Date(), families: familyReports)
        if best.size >= originalBytes {
            job.log("No gain: \(best.size) bytes is not smaller than \(originalBytes).")
            return result
        }
        try Task.checkCancellation()
        if isFolder && settings.outputMode == .replaceOriginal {
            job.log("A folder is never moved to the Trash: the archive is written next to it and the folder is left in place.")
        } else if settings.outputMode == .replaceOriginal && VolumeSet.isFunctionalContainer(source) {
            job.log("\(source.lastPathComponent) is a functional container (jar, apk, disk image, …): the original is kept and the result is written as a new file.")
        }
        let output = try publish(archive: best.url, source: source, volumes: volumes, folder: isFolder)
        result.outputURL = output
        result.outcome = .optimized
        result.finishedAt = Date()
        job.log("Written \(output.path)")
        return result
    }

    // MARK: Disk space

    /// Free space needed for a tree of `unpacked` bytes, counting the tree itself: the best archive so far
    /// and the one being built (per-group, hybrid or baseline: up to 1x each, since the larger of two is deleted
    /// at once, so a third full-size archive never exists), and, when trials run on full data, the archives of
    /// the trials in flight (already compressed groups produce full-size ones; half a tree per trial is assumed;
    /// the trials of family blocks run after those of the groups and are bounded the same way).
    func requiredSpace(unpacked: Int64) -> Int64 {
        // Smart: the baseline and the split are built at the same time, then the media block is appended to one.
        var factor = settings.mode == .smart ? 4.0 : 3.0
        if settings.mode.runsTrials && settings.samplingLevel == 0 {
            factor += 0.5 * Double(settings.lowCPU ? 1 : max(1, settings.concurrentTrials))
        }
        let needed = Double(max(unpacked, 0)) * factor
        return needed >= Double(Int64.max / 2) ? Int64.max / 2 : Int64(needed)
    }

    func checkDiskSpace(unpacked: Int64, alreadyUsed: Int64 = 0) throws {
        let needed = requiredSpace(unpacked: unpacked) + alreadyUsed
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let values = try? temporaryRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init) ?? Int64.max
        if available < needed { throw OptimizerError.insufficientDiskSpace(needed: needed, available: available) }
    }

    // MARK: Output

    /// Places the finished archive next to the source (or in `outputDirectory`) and returns its URL.
    func publish(archive: URL, source: URL, volumes: [URL], folder: Bool = false) throws -> URL {
        let fm = FileManager.default
        let base = folder ? source.lastPathComponent : VolumeSet.baseName(of: source)
        let sourceDir = source.deletingLastPathComponent()
        let mtime = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date

        // Repacking loses what makes a jar, cbz or disk image usable, so those are never trashed.
        // A folder is never trashed either: its archive is `<name>.7z` beside it, whatever the output mode.
        let outputMode: OutputMode = folder || VolumeSet.isFunctionalContainer(source) ? .newFile : settings.outputMode

        let directory: URL
        if settings.outputMode == .replaceOriginal { directory = sourceDir }
        else { directory = settings.outputDirectory ?? sourceDir }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Copy next to the destination first, so a full disk fails before anything is touched.
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).squeeze7z-partial")
        do {
            try fm.moveItem(at: archive, to: partial)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        var trashed = 0
        let final: URL
        do {
            switch outputMode {
            case .newFile:
                final = Self.uniqueURL(in: directory, stem: folder ? base : base + "_optimized", separator: "-")
            case .replaceOriginal:
                for volume in volumes {
                    try trash(volume)
                    trashed += 1
                }
                final = Self.uniqueURL(in: directory, stem: base, separator: "-")
            }
            try fm.moveItem(at: partial, to: final)
        } catch {
            if trashed == 0 {
                try? fm.removeItem(at: partial)
                throw error
            }
            // Part of the source is already in the Trash: the verified archive must survive, under a visible name.
            let kept = Self.uniqueURL(in: directory, stem: base + "_optimized", separator: "-")
            let location = (try? fm.moveItem(at: partial, to: kept)) != nil ? kept : partial
            throw OptimizerError.outputKept(path: location.path, reason: error.localizedDescription)
        }
        if let mtime { try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: final.path) }
        return final
    }

    /// `stem.7z`, then `stem-2.7z`, `stem-3.7z`, …
    static func uniqueURL(in directory: URL, stem: String, separator: String) -> URL {
        let fm = FileManager.default
        var url = directory.appendingPathComponent(stem + ".7z")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem)\(separator)\(n).7z")
            n += 1
        }
        return url
    }
}
