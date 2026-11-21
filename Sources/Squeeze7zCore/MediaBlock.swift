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

    let files: [String]
    let bytes: Int64
    let spec: MethodSpec
    let list: URL

    /// nil when the tree has too few compressed bytes, the machine too few threads, or the setting is off.
    static func make(groups: [FileGroup], settings: OptimizerSettings, threads: Int, physicalMemory: UInt64,
                     listsDir: URL) throws -> MediaBlock? {
        guard let spec = spec(forBytes: groups.filter { $0.category == .compressed }.reduce(0) { $0 + $1.totalBytes },
                              settings: settings, threads: threads, physicalMemory: physicalMemory) else { return nil }
        let media = groups.filter { $0.category == .compressed }
        let files = media.flatMap(\.files).sorted()
        let list = listsDir.appendingPathComponent("media.txt")
        try ListFile.write(files, to: list)
        return MediaBlock(files: files, bytes: media.reduce(0) { $0 + $1.totalBytes }, spec: spec, list: list)
    }

    /// LZMA2 with a chunk size that gives each encoder (two threads each) at least one chunk, and a dictionary
    /// that covers one chunk, within half of the physical memory for all encoders at once.
    static func spec(forBytes bytes: Int64, settings: OptimizerSettings, threads: Int,
                     physicalMemory: UInt64) -> MethodSpec? {
        let encoders = Int64(threads / 2)
        guard settings.parallelMediaBlocks, !settings.mode.runsTrials, encoders >= 2, bytes >= minBytes else { return nil }
        let mebibyte: Int64 = 1 << 20
        var chunk = (bytes + encoders - 1) / encoders
        chunk = (chunk + mebibyte - 1) / mebibyte * mebibyte
        chunk = min(max(chunk, minChunkBytes), maxChunkBytes)
        var dictionary = mebibyte
        while dictionary < chunk { dictionary <<= 1 }
        let budget = Int64(clamping: physicalMemory / 2) / encoders
        while dictionary > mebibyte && dictionary * 11 > budget { dictionary >>= 1 }
        let params = LZMAParams(dictionary: "\(dictionary / mebibyte)m", fastBytes: min(max(settings.lzmaWordSize, 5), 273),
                                blockSize: "\(chunk / mebibyte)m")
        return CandidateGenerator.lzma2(params)
    }
}

extension Job {
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

    /// Whether two LZMA2 encoders with `dictionary` (plus PPMd's model) fit in half of the physical memory, so the
    /// baseline and the Smart split can be built at the same time.
    static func canBuildConcurrently(dictionary: String, ppmdMB: Int, physicalMemory: UInt64) -> Bool {
        let digits = dictionary.prefix { $0.isNumber }
        guard let value = Int64(digits) else { return false }
        let unit: Int64 = dictionary.hasSuffix("g") ? 1 << 30 : dictionary.hasSuffix("k") ? 1 << 10 : 1 << 20
        let needed = 2 * 11 * value * unit + Int64(ppmdMB) << 20
        return needed <= Int64(clamping: physicalMemory / 2)
    }
}
