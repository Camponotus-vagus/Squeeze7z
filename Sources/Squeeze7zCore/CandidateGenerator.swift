import Foundation

extension OptimizationMode {
    /// 0 (fast, smart) … 6 (extreme2). Candidate tables are cumulative in this rank.
    var rank: Int {
        switch self {
        case .fast, .smart: 0
        case .normal: 1
        case .good: 2
        case .best: 3
        case .ultra: 4
        case .extreme: 5
        case .extreme2: 6
        }
    }
}

extension OptimizationMode {
    /// Fast and smart skip per-group trials, family blocks and per-group assembly.
    var runsTrials: Bool { self != .fast && self != .smart }
}

extension MethodSpec {
    /// Position of the main compressor in the "cheapest to decompress" order used to break ties:
    /// Copy < LZMA2 < LZMA < Deflate < BZip2 < PPMd.
    var decompressionRank: Int {
        for coder in coders {
            let name = coder.split(separator: ":").first.map { $0.uppercased() } ?? ""
            switch name {
            case "COPY": return 0
            case "LZMA2": return 1
            case "LZMA": return 2
            case "DEFLATE", "DEFLATE64": return 3
            case "BZIP2": return 4
            case "PPMD": return 5
            default: continue
            }
        }
        return 6
    }
}

/// LZMA/LZMA2 parameters rendered in a fixed order so equal settings produce equal strings.
struct LZMAParams: Hashable, Sendable {
    var dictionary: String
    var fastBytes: Int
    var matchCycles: Int?
    var matchFinder: String?
    var lc: Int?
    var lp: Int?
    var pb: Int?
    /// LZMA2 chunk size (`c=`). Set explicitly when the data is larger than the default chunk (256 MB at most), so
    /// the result does not depend on the thread count: without it 7zz splits the data into independent chunks and
    /// runs one encoder per chunk, each with its own dictionary. Not rendered for LZMA, which has no chunks.
    var blockSize: String?

    init(dictionary: String, fastBytes: Int, matchCycles: Int? = nil, matchFinder: String? = nil,
         lc: Int? = nil, lp: Int? = nil, pb: Int? = nil, blockSize: String? = nil) {
        self.dictionary = dictionary; self.fastBytes = fastBytes; self.matchCycles = matchCycles
        self.matchFinder = matchFinder; self.lc = lc; self.lp = lp; self.pb = pb; self.blockSize = blockSize
    }

    func with(fb: Int? = nil, mc: Int? = nil, mf: String? = nil, lc: Int? = nil, lp: Int? = nil, pb: Int? = nil) -> LZMAParams {
        var p = self
        if let fb { p.fastBytes = fb }
        if let mc { p.matchCycles = mc }
        if let mf { p.matchFinder = mf }
        if let lc { p.lc = lc }
        if let lp { p.lp = lp }
        if let pb { p.pb = pb }
        return p
    }

    func render(_ method: String) -> String {
        var s = "\(method):d=\(dictionary):fb=\(fastBytes)"
        if let matchCycles { s += ":mc=\(matchCycles)" }
        if let matchFinder { s += ":mf=\(matchFinder)" }
        if let lc { s += ":lc=\(lc)" }
        if let lp { s += ":lp=\(lp)" }
        if let pb { s += ":pb=\(pb)" }
        if let blockSize, method.uppercased() == "LZMA2" { s += ":c=\(blockSize)" }
        return s
    }
}

public enum CandidateGenerator {
    static let mebibyte: Int64 = 1 << 20
    /// Deflate64 and Deflate only get a chance on groups up to this size (their window is 32-64 KiB).
    static let smallGroupLimit: Int64 = 4 * mebibyte

    // MARK: Public API

    /// Candidate methods for one group, cumulative in `settings.mode` (see the Modes table in README.md).
    public static func candidates(for group: FileGroup, settings: OptimizerSettings,
                                  isSingleExtensionArchive: Bool) -> [MethodSpec] {
        candidates(for: group, settings: settings, isSingleExtensionArchive: isSingleExtensionArchive,
                   growDictionary: false, concurrentBuilds: 1)
    }

    /// `growDictionary` lets the dictionary follow the size of the data past `lzmaDictionaryMB` (family blocks),
    /// within the limits of `scaledDictionaryString`.
    static func candidates(for group: FileGroup, settings: OptimizerSettings, isSingleExtensionArchive: Bool,
                           growDictionary: Bool, concurrentBuilds: Int,
                           threads: Int = ProcessInfo.processInfo.activeProcessorCount,
                           physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [MethodSpec] {
        let rank = settings.mode.rank
        let base = growDictionary
            ? baseParams(scaledForBytes: group.totalBytes, settings: settings, concurrentBuilds: concurrentBuilds,
                         threads: threads, physicalMemory: physicalMemory)
            : baseParams(forBytes: group.totalBytes, settings: settings)
        var list = CandidateList()
        if rank == 0 {
            list.add([lzma2(base)])
            return list.specs
        }
        let ppmdAllowed = isPPMdAllowed(bytes: group.totalBytes, settings: settings)
        let bzip2Allowed = !settings.disableBZip2
        let small = group.totalBytes <= smallGroupLimit
        let ppmdMem = max(1, settings.ppmdMemoryMB)
        func ppmd(_ order: Int) -> MethodSpec { MethodSpec(coders: ["PPMd:mem=\(ppmdMem)m:o=\(order)"]) }
        let bzip2 = MethodSpec(coders: ["BZip2:d=900k:pass=2"])
        let singleExt = isSingleExtensionArchive

        switch group.category {
        case .compressed:
            list.add([.copy, lzma2(base)])
            if rank >= 2 { list.add([lzma(base.with(fb: 32))]) }

        case .text:
            list.add([lzma2(base)])
            if ppmdAllowed { list.add([ppmd(6)]) }
            if rank >= 2 {
                list.add([lzma(base)])
                if ppmdAllowed { list.add([ppmd(8)]) }
            }
            if rank >= 3 {
                if ppmdAllowed { list.add([ppmd(16), ppmd(32)]) }
                if bzip2Allowed { list.add([bzip2]) }
                list.add([lzma(base.with(fb: 273)), lzma(base.with(lc: 1, lp: 0, pb: 0))])
            }
            if rank >= 4 {
                if ppmdAllowed { list.add([ppmd(24)]) }
                list.add([lzma(base.with(mf: "bt2")), lzma(base.with(mf: "bt3"))])
                if small { list.add(deflateFamily()) }
            }
            if rank >= 5 {
                list.add([lzma(base.with(fb: 273, mc: 1000)),
                          lzma(base.with(fb: 273, mc: 1000, lc: 1, lp: 0, pb: 0)),
                          lzma(base.with(mf: "hc4"))])
            }
            if rank >= 6 {
                list.add([lzma(base.with(mf: "bt5"))])
                list.add(fastBytesSweep(base).map(lzma))
                if singleExt { list.add((0...4).map { lzma(base.with(lc: $0, lp: 0, pb: 0)) }) }
            }

        case .binary, .misc:
            list.add([lzma2(base)])
            if rank >= 2, group.category == .misc, ppmdAllowed { list.add([ppmd(6)]) }
            list.add(binaryLZMAVariants(base, rank: rank, singleExt: singleExt).map(lzma))
            if rank >= 3 {
                if group.category == .misc, ppmdAllowed { list.add([ppmd(8)]) }
                if group.category == .binary, ppmdAllowed { list.add([ppmd(6)]) }
                if bzip2Allowed { list.add([bzip2]) }
            }
            if rank >= 4, small { list.add(deflateFamily()) }

        case .executable:
            list.add([lzma2(base)])
            // ARM64 and RISC-V filters only exist in 7-Zip 23+: without the setting those executables get no branch filter.
            let archs = group.executableArchitectures.filter { settings.allowModernFilters || !$0.requiresModernSevenZip }
            for arch in archs { list.add([filterChain(arch, main: lzma2(base))]) }
            let variants = binaryLZMAVariants(base, rank: rank, singleExt: singleExt)
            for v in variants {
                list.add([lzma(v)])
                for arch in archs { list.add(filterChains(arch, params: v, includeBCJ2: true)) }
            }
            if rank >= 3 {
                for arch in archs where arch == .x86 {
                    list.add([MethodSpec(coders: ["BCJ", lzma(base).coders[0]])])
                }
            }

        case .imageRaw, .audioRaw:
            list.add([lzma2(base)])
            // 7zz's own auto-detection would pick a delta filter for WAV and BMP; with it switched off
            // for trials, the common sample widths are tried explicitly even in the cheapest mode.
            let widths = group.category == .audioRaw ? [2, 4] : [3, 4]
            list.add(widths.map { MethodSpec(coders: ["Delta:\($0)", base.render("LZMA2")]) })
            // Samples that repeat every 2 or 4 bytes: lc=0 with matching position bits (7zz's own pick for WAV).
            list.add(widths.filter { $0 == 2 || $0 == 4 }.map {
                MethodSpec(coders: ["Delta:\($0)", base.with(lc: 0, lp: $0 == 4 ? 2 : 1, pb: $0 == 4 ? 2 : 1).render("LZMA2")])
            })
            if rank >= 2 {
                list.add([lzma(base)])
                list.add([2, 4].map { delta($0, base) })
            }
            if rank >= 3 {
                list.add([1, 3].map { delta($0, base) })
                list.add([lzma(base.with(fb: 273))])
            }
            if rank >= 4 { list.add([8, 16, 32].map { delta($0, base) }) }
            if rank >= 5 {
                list.add([lzma(base.with(fb: 273, mc: 1000))])
                for n in 1...4 { list.add([delta(n, base.with(lc: 0, lp: 0, pb: 0))]) }
            }
            if rank >= 6 {
                for n in 1...4 { list.add([delta(n, base.with(fb: 273, mc: 1000, mf: "bt5", lc: 0, lp: 0, pb: 0))]) }
                if singleExt {
                    for n in 1...4 { list.add((1...4).map { delta(n, base.with(lc: $0, lp: 0, pb: 0)) }) }
                }
            }
        }
        return list.specs
    }

    /// The method used for groups that are too small for trials, and the one used in "fast" mode.
    public static func defaultMethod(for group: FileGroup, settings: OptimizerSettings) -> MethodSpec {
        lzma2(baseParams(forBytes: group.totalBytes, settings: settings))
    }

    /// Whole-archive solid methods tried against the per-group result (every mode from normal up).
    /// In `fast` mode the single LZMA2 method is the only strategy. The LZMA2 baseline is built in normal mode
    /// too: per-extension groups lose the redundancy between extensions, and the baseline is the floor that makes
    /// normal never worse than fast. `includeGuard` is kept for source compatibility and has no effect.
    public static func wholeArchiveBaselines(totalBytes: Int64, settings: OptimizerSettings,
                                             includeGuard: Bool = false) -> [MethodSpec] {
        wholeArchiveBaselines(totalBytes: totalBytes, settings: settings, threads: settings.soloThreads,
                              physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    static func wholeArchiveBaselines(totalBytes: Int64, settings: OptimizerSettings,
                                      threads: Int = ProcessInfo.processInfo.activeProcessorCount,
                                      physicalMemory: UInt64) -> [MethodSpec] {
        let rank = settings.mode.rank
        let base = baseParams(scaledForBytes: totalBytes, settings: settings, concurrentBuilds: 1,
                              threads: threads, physicalMemory: physicalMemory)
        if rank == 0 { return [lzma2(base)] }
        var list = CandidateList()
        list.add([lzma2(base)])
        if rank >= 4 {
            list.add([lzma(base)])
            if isPPMdAllowed(bytes: totalBytes, settings: settings) {
                list.add([MethodSpec(coders: ["PPMd:mem=\(max(1, settings.ppmdMemoryMB))m:o=8"])])
            }
        }
        return list.specs
    }

    // MARK: Building blocks

    /// `d` never larger than needed: the next power of two >= `bytes`, at least 1 MiB, at most the setting.
    static func dictionaryString(forBytes bytes: Int64, settings: OptimizerSettings) -> String {
        let limit = Int64(min(max(settings.lzmaDictionaryMB, 1), 1536)) * mebibyte
        var needed = mebibyte
        while needed < bytes && needed < limit { needed <<= 1 }
        return "\(min(needed, limit) / mebibyte)m"
    }

    /// Largest chunk size `c=` is set to; 7zz takes the value as a 64-bit number.
    static let maxBlockBytes: Int64 = 64 << 30

    /// LZMA2 chunk size 7zz uses when none is given: four dictionaries, between 1 MB and 256 MB.
    static func defaultChunkBytes(dictionaryBytes: Int64) -> Int64 {
        min(max(dictionaryBytes * 4, mebibyte), 256 * mebibyte)
    }

    /// Encoders that run at once for `bytes` of data in one LZMA2 stream: one per chunk, at most one per two threads
    /// (7zz gives each chunk encoder two threads). One while `c=` covers all the data.
    static func blockThreads(forBytes bytes: Int64, threads: Int) -> Int {
        let chunks = (max(bytes, 1) + maxBlockBytes - 1) / maxBlockBytes
        return Int(min(chunks, Int64(max(1, threads / 2))))
    }

    /// Dictionary (and chunk size) for a block that holds a large share of the archive (whole-archive baselines,
    /// family blocks): the smallest power of two that covers `bytes`, so every match in the data is reachable.
    /// It may exceed `lzmaDictionaryMB` up to 256 MB, but only when that setting is at least its default (128 MB):
    /// a smaller value is an explicit request for lighter extraction. It never exceeds 1536 MB.
    /// The encoder takes about 11 times the dictionary per encoder in flight, and each build runs one encoder per
    /// chunk that is encoded at once (`blockThreads`): the product stays within half of the physical memory.
    /// Data larger than the default chunk gets `c=` (the power of two that covers it): one stream instead of
    /// independent chunks, which is smaller (matches reach across chunks), needs one dictionary of memory instead
    /// of `threads / 2`, and does not change with the thread count.
    static func scaledLZMA(forBytes bytes: Int64, settings: OptimizerSettings, concurrentBuilds: Int,
                           threads: Int, physicalMemory: UInt64) -> (dictionary: String, blockSize: String?) {
        let setting = Int64(min(max(settings.lzmaDictionaryMB, 1), 1536))
        var limit = (setting >= 128 ? max(setting, 256) : setting) * mebibyte
        let encoders = Int64(max(1, concurrentBuilds)) * Int64(blockThreads(forBytes: bytes, threads: threads))
        let budget = Int64(clamping: physicalMemory / 2) / encoders
        while limit > mebibyte && limit > budget / 11 { limit /= 2 }
        var needed = mebibyte
        while needed < bytes && needed < limit { needed <<= 1 }
        let dictionary = min(needed, limit)
        var blockSize: String?
        if bytes > defaultChunkBytes(dictionaryBytes: dictionary) {
            var chunk = defaultChunkBytes(dictionaryBytes: dictionary)
            while chunk < bytes && chunk < maxBlockBytes { chunk <<= 1 }
            blockSize = chunk % (1 << 30) == 0 ? "\(chunk >> 30)g" : "\(chunk >> 20)m"
        }
        return ("\(dictionary / mebibyte)m", blockSize)
    }

    static func scaledDictionaryString(forBytes bytes: Int64, settings: OptimizerSettings, concurrentBuilds: Int,
                                       threads: Int = ProcessInfo.processInfo.activeProcessorCount,
                                       physicalMemory: UInt64) -> String {
        scaledLZMA(forBytes: bytes, settings: settings, concurrentBuilds: concurrentBuilds, threads: threads,
                   physicalMemory: physicalMemory).dictionary
    }

    static func baseParams(scaledForBytes bytes: Int64, settings: OptimizerSettings, concurrentBuilds: Int,
                           threads: Int = ProcessInfo.processInfo.activeProcessorCount,
                           physicalMemory: UInt64) -> LZMAParams {
        let scaled = scaledLZMA(forBytes: bytes, settings: settings, concurrentBuilds: concurrentBuilds,
                                threads: threads, physicalMemory: physicalMemory)
        return LZMAParams(dictionary: scaled.dictionary, fastBytes: min(max(settings.lzmaWordSize, 5), 273),
                          blockSize: scaled.blockSize)
    }

    static func baseParams(forBytes bytes: Int64, settings: OptimizerSettings) -> LZMAParams {
        LZMAParams(dictionary: dictionaryString(forBytes: bytes, settings: settings),
                   fastBytes: min(max(settings.lzmaWordSize, 5), 273))
    }

    static func isPPMdAllowed(bytes: Int64, settings: OptimizerSettings) -> Bool {
        if settings.disablePPMd { return false }
        if let limit = settings.noPPMdAboveMB, bytes > Int64(limit) * mebibyte { return false }
        return true
    }

    static func lzma(_ p: LZMAParams) -> MethodSpec { MethodSpec(coders: [p.render("LZMA")]) }
    static func lzma2(_ p: LZMAParams) -> MethodSpec { MethodSpec(coders: [p.render("LZMA2")]) }

    static func delta(_ n: Int, _ p: LZMAParams) -> MethodSpec {
        MethodSpec(coders: ["Delta:\(n)", p.render("LZMA")])
    }

    static func deflateFamily() -> [MethodSpec] {
        [MethodSpec(coders: ["Deflate:fb=258:pass=15"]), MethodSpec(coders: ["Deflate64"])]
    }

    static func fastBytesSweep(_ base: LZMAParams) -> [LZMAParams] {
        [32, 64, 128, 192, 273].map { base.with(fb: $0) }
    }

    /// LZMA parameter variants for binary-like data, cumulative in rank.
    static func binaryLZMAVariants(_ base: LZMAParams, rank: Int, singleExt: Bool) -> [LZMAParams] {
        var v: [LZMAParams] = []
        if rank >= 2 { v += [base, base.with(lc: 0, lp: 2, pb: 2)] }
        if rank >= 3 { v += [base.with(fb: 273)] }
        if rank >= 4 { v += [base.with(mf: "bt2"), base.with(mf: "bt3")] }
        if rank >= 5 {
            v += [base.with(fb: 273, mc: 1000), base.with(fb: 273, mc: 1000, lc: 0, lp: 2, pb: 2), base.with(mf: "hc4")]
            for lp in 0...2 { for pb in 0...2 { v.append(base.with(lc: 0, lp: lp, pb: pb)) } }
        }
        if rank >= 6 {
            v += [base.with(mf: "bt5")]
            v += fastBytesSweep(base)
            if singleExt { v += (0...4).map { base.with(lc: $0) } }
        }
        return v
    }

    /// Branch filter followed by one main coder.
    static func filterChain(_ arch: ExecutableArchitecture, main: MethodSpec) -> MethodSpec {
        let filter: String
        switch arch {
        case .x86: filter = "BCJ"
        case .arm64: filter = "ARM64"
        case .arm: filter = "ARM"
        case .armThumb: filter = "ARMT"
        case .powerPC: filter = "PPC"
        case .sparc: filter = "SPARC"
        case .ia64: filter = "IA64"
        case .riscv: filter = "RISCV"
        }
        return MethodSpec(coders: [filter] + main.coders)
    }

    /// Filter chains with LZMA for one architecture. x86 gets the four-coder BCJ2 chain.
    static func filterChains(_ arch: ExecutableArchitecture, params: LZMAParams, includeBCJ2: Bool) -> [MethodSpec] {
        if arch == .x86 {
            guard includeBCJ2 else { return [filterChain(arch, main: lzma(params))] }
            return [MethodSpec(
                coders: ["BCJ2", params.render("LZMA"), "LZMA:d=1m:lc=0:lp=2", "LZMA:d=1m"],
                extraArgs: ["-mb0s0:1", "-mb0s1:2", "-mb0s2:3"])]
        }
        return [filterChain(arch, main: lzma(params))]
    }
}

/// Insertion-ordered set of method specs.
private struct CandidateList {
    private(set) var specs: [MethodSpec] = []
    private var seen = Set<MethodSpec>()

    mutating func add(_ items: [MethodSpec]) {
        for s in items where seen.insert(s).inserted { specs.append(s) }
    }
}
