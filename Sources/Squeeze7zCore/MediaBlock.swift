import Foundation

/// Fast and Smart modes: already compressed files (jpg, mp4, zip, …) go into their own solid block, encoded as
/// independent LZMA2 chunks so every core works on them. One LZMA2 stream over hundreds of megabytes uses two
/// threads; on data that does not compress, the chunks lose nothing (matches between photos or videos are rare)
/// and the block is built several times faster. Everything else keeps the single-stream baseline.
struct MediaBlock: Sendable {
    static let strategySuffix = " + parallel media block"
    /// Below this the single stream is fast enough, and fewer than two chunks would run at once.
    static let minBytes: Int64 = 64 << 20
    static let minChunkBytes: Int64 = 32 << 20
    static let maxChunkBytes: Int64 = 256 << 20
    /// Data a probe compresses: enough files, spread over the block, to tell noise from data that still shrinks.
    static let probeBytes: Int64 = 32 << 20
    /// A probe that saves at least this share means the files still hold structure LZMA2 learns as it goes
    /// (many small JPEGs with near-identical headers and tables, for instance).
    static let compressibleSaving = 0.01

    let files: [String]
    let bytes: Int64
    let spec: MethodSpec
    let list: URL
    /// Whether the probe found that the files still compress (fewer, larger chunks are used then).
    let compressible: Bool

    /// nil when the tree has too few compressed bytes, the machine too few threads, or the setting is off.
    static func make(groups: [FileGroup], snapshot: TreeSnapshot, job: Job, physicalMemory: UInt64) async throws -> MediaBlock? {
        let media = groups.filter { $0.category == .compressed }
        let bytes = media.reduce(Int64(0)) { $0 + $1.totalBytes }
        let settings = job.settings
        guard spec(forBytes: bytes, settings: settings, threads: job.soloThreads, physicalMemory: physicalMemory,
                   compressible: false) != nil else { return nil }
        let files = media.flatMap(\.files).sorted()
        let saving = try await job.probeSaving(files: files, snapshot: snapshot)
        let compressible = saving >= compressibleSaving
        guard let spec = spec(forBytes: bytes, settings: settings, threads: job.soloThreads,
                              physicalMemory: physicalMemory, compressible: compressible) else { return nil }
        let list = job.listsDir.appendingPathComponent("media.txt")
        try ListFile.write(files, to: list)
        job.log(String(format: "Media probe: %.2f%% saved on a sample, %@", saving * 100,
                       compressible ? "few large chunks" : "one chunk per two cores"))
        return MediaBlock(files: files, bytes: bytes, spec: spec, list: list, compressible: compressible)
    }

    /// LZMA2 in independent chunks, a dictionary that covers one chunk, within half of the physical memory for
    /// all encoders at once (each encoder takes two threads).
    /// Data that does not compress (`compressible` false): one chunk per encoder, 32 to 256 MB, so every core
    /// works and nothing is lost. Data that still compresses: as many chunks as `7zz -mx9` makes (one per
    /// 256 MB) but of equal size, so the longest chunk, and the time, never exceed those of `-mx9`; every new
    /// chunk starts its model from scratch, which costs size on such data. `lc=4` helps there.
    static func spec(forBytes bytes: Int64, settings: OptimizerSettings, threads: Int,
                     physicalMemory: UInt64, compressible: Bool) -> MethodSpec? {
        let maxEncoders = Int64(threads / 2)
        guard settings.parallelMediaBlocks, !settings.mode.runsTrials, maxEncoders >= 2, bytes >= minBytes else { return nil }
        let mebibyte: Int64 = 1 << 20
        let chunks = compressible ? (bytes + maxChunkBytes - 1) / maxChunkBytes : maxEncoders
        var chunk = (bytes + chunks - 1) / chunks
        chunk = (chunk + mebibyte - 1) / mebibyte * mebibyte
        chunk = min(max(chunk, compressible ? mebibyte : minChunkBytes), maxChunkBytes)
        var dictionary = mebibyte
        while dictionary < chunk { dictionary <<= 1 }
        let encoders = min(maxEncoders, max(1, (bytes + chunk - 1) / chunk))
        let budget = CandidateGenerator.memoryBudget(physicalMemory: physicalMemory, settings: settings) / encoders
        while dictionary > mebibyte && dictionary * 11 > budget { dictionary >>= 1 }
        let params = LZMAParams(dictionary: "\(dictionary / mebibyte)m", fastBytes: min(max(settings.lzmaWordSize, 5), 273),
                                lc: compressible ? 4 : nil, blockSize: "\(chunk / mebibyte)m")
        return CandidateGenerator.lzma2(params)
    }
}

extension Job {
    /// Share of bytes LZMA2 saves on a sample of `files` (about `MediaBlock.probeBytes`, files taken at even
    /// steps through the list), in 8 MB chunks so the probe runs on several cores. Symlinks and empty files are
    /// skipped; 0 when there is nothing to sample.
    func probeSaving(files: [String], snapshot: TreeSnapshot) async throws -> Double {
        let regular = files.filter { (snapshot.files[$0].map { !$0.isSymlink && $0.size > 0 }) ?? false }
        let total = regular.reduce(Int64(0)) { $0 + (snapshot.files[$1]?.size ?? 0) }
        guard total > 0 else { return 0 }
        let step = max(1, Int((Double(total) / Double(MediaBlock.probeBytes)).rounded(.up)))
        var sample: [String] = []
        var sampleBytes: Int64 = 0
        for index in stride(from: 0, to: regular.count, by: step) where sampleBytes < MediaBlock.probeBytes {
            sample.append(regular[index])
            sampleBytes += snapshot.files[regular[index]]?.size ?? 0
        }
        guard sampleBytes > 0 else { return 0 }
        let list = listsDir.appendingPathComponent("media_probe.txt")
        let archive = trialsDir.appendingPathComponent("media_probe.7z")
        try ListFile.write(sample, to: list)
        try? FileManager.default.removeItem(at: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        try await tool.runChecked(["a"] + SevenZipTool.quietSwitches + commonAddSwitches + ["-mf=off"] + soloThreadSwitch
                                  + ["-m0=LZMA2:d=8m:fb=64:lc=4:c=8m", archive.path, "@" + list.path], currentDirectory: root)
        return max(0, 1 - Double(Job.fileSize(archive)) / Double(sampleBytes))
    }

    /// One block of a layered archive: the files of `list`, compressed with `spec`. `autoFilters` lets 7zz pick
    /// a branch filter for executables (dropped on a retry when the ARM64 or RISC-V filters are not allowed).
    struct Block: Sendable {
        let list: URL
        let spec: MethodSpec
        let autoFilters: Bool
    }

    /// Builds `archive` as a copy of `base` (an APFS clone when possible) with `blocks` appended in order, then
    /// the directory entries. Without `base` the archive starts empty.
    func buildLayered(base: URL?, blocks: [Block], directories: DirectoryStage?, into archive: URL) async throws {
        var filtersOff = false
        for attempt in 0..<2 {
            try? FileManager.default.removeItem(at: archive)
            if let base { try FileManager.default.copyItem(at: base, to: archive) }
            for block in blocks {
                try await tool.runChecked(addArguments(archive: archive, list: block.list, spec: block.spec,
                                                       filtersOff: filtersOff || !block.autoFilters,
                                                       threads: soloThreadSwitch), currentDirectory: root)
            }
            try await appendDirectories(directories, to: archive)
            if attempt == 0, !filtersOff, !settings.allowModernFilters, blocks.contains(where: \.autoFilters),
               Self.usesModernFilter(try await tool.list(archive)) {
                filtersOff = true
                continue
            }
            break
        }
    }

    /// Whether two LZMA2 encoders with `dictionary` (plus PPMd's model) fit in the job's memory budget, so the
    /// baseline and the Smart split can be built at the same time.
    static func canBuildConcurrently(dictionary: String, ppmdMB: Int, physicalMemory: UInt64,
                                     settings: OptimizerSettings) -> Bool {
        let digits = dictionary.prefix { $0.isNumber }
        guard let value = Int64(digits) else { return false }
        let unit: Int64 = dictionary.hasSuffix("g") ? 1 << 30 : dictionary.hasSuffix("k") ? 1 << 10 : 1 << 20
        let needed = 2 * 11 * value * unit + Int64(ppmdMB) << 20
        return needed <= CandidateGenerator.memoryBudget(physicalMemory: physicalMemory, settings: settings)
    }
}
