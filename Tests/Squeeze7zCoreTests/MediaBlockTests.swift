import Foundation
import Testing
@testable import Squeeze7zCore

/// Fast and Smart modes: already compressed files in their own block of parallel LZMA2 chunks.
@Suite struct MediaBlockTests {
    private let gib: UInt64 = 1 << 30
    private let mib: Int64 = 1 << 20

    private func spec(_ bytes: Int64, threads: Int = 10, memory: UInt64 = 32 << 30, compressible: Bool = false,
                      configure: (inout OptimizerSettings) -> Void = { _ in }) -> String? {
        var s = OptimizerSettings()
        configure(&s)
        return MediaBlock.spec(forBytes: bytes, settings: s, threads: threads, physicalMemory: memory,
                               compressible: compressible)?.description
    }

    @Test func chunksGiveEveryEncoderWork() {
        // 240 MB on 10 threads: five encoders, one 48 MB chunk each, a dictionary that covers a chunk.
        #expect(spec(240 * mib) == "LZMA2:d=64m:fb=64:c=48m")
        // Small media: chunks no smaller than 32 MB.
        #expect(spec(64 * mib) == "LZMA2:d=32m:fb=64:c=32m")
        // Large media: chunks no larger than 256 MB.
        #expect(spec(20_000 * mib) == "LZMA2:d=256m:fb=64:c=256m")
        // Little memory: the dictionary shrinks, the chunks stay.
        #expect(spec(20_000 * mib, memory: 8 * gib) == "LZMA2:d=64m:fb=64:c=256m")
    }

    @Test func dataThatStillCompressesGetsTheChunkCountOfMx9() {
        // 603 MB that still compress: three equal chunks (7zz -mx9 makes three, of 256, 256 and 91 MB), lc=4.
        #expect(spec(603 * mib, compressible: true) == "LZMA2:d=256m:fb=64:lc=4:c=201m")
        // Under 256 MB: one chunk, like -mx9.
        #expect(spec(100 * mib, compressible: true) == "LZMA2:d=128m:fb=64:lc=4:c=100m")
        // Large: 256 MB chunks, at most five encoders at once for the memory budget.
        #expect(spec(2_000 * mib, compressible: true) == "LZMA2:d=256m:fb=64:lc=4:c=250m")
    }

    @Test func noMediaBlockWhenItCannotHelp() {
        #expect(spec(63 * mib) == nil)
        #expect(spec(240 * mib, threads: 3) == nil)
        #expect(spec(240 * mib) { $0.parallelMediaBlocks = false } == nil)
        #expect(spec(240 * mib) { $0.lowCPU = true } != nil)   // lowCPU acts through the thread count
        #expect(spec(240 * mib) { $0.mode = .normal } == nil)
        #expect(spec(240 * mib) { $0.mode = .fast } != nil)
    }

    @Test func concurrentBuildsNeedTheMemory() {
        #expect(Job.canBuildConcurrently(dictionary: "256m", ppmdMB: 256, physicalMemory: 32 * gib))
        #expect(!Job.canBuildConcurrently(dictionary: "256m", ppmdMB: 256, physicalMemory: 8 * gib))
        #expect(Job.canBuildConcurrently(dictionary: "64m", ppmdMB: 256, physicalMemory: 8 * gib))
        #expect(!Job.canBuildConcurrently(dictionary: "x", ppmdMB: 256, physicalMemory: 32 * gib))
    }

    private func noise(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
        return data
    }

    @Test func compressibleMediaUsesLargeChunksAndRoundTrips() async throws {
        guard ProcessInfo.processInfo.activeProcessorCount >= 4 else { return }
        let dir = try TestSupport.makeTempDir("media-compressible")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Scans", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // "JPEG" files whose second half repeats: the probe sees that they still compress.
        let pattern = Data((0..<4_000_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        for i in 0..<9 {
            try (Data([0xFF, 0xD8, 0xFF, 0xE0]) + noise(4_000_000) + pattern).write(to: folder.appendingPathComponent("scan\(i).jpg"))
        }
        let expected = try TestSupport.fingerprint(folder)
        var s = OptimizerSettings()
        s.outputDirectory = dir
        let log = TestSupport.EventLog()
        let result = try await ArchiveOptimizer(tool: try TestSupport.tool(), settings: s, temporaryDirectory: dir)
            .optimize(folder, progress: log.add)
        #expect(result.strategy == "parallel media block", "strategy \(result.strategy)")
        let winner = try #require(result.groups.first?.winner.description)
        #expect(winner.contains(":lc=4:c="), "\(winner)")
        let output = try #require(result.outputURL)
        let extracted = dir.appendingPathComponent("extracted", isDirectory: true)
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted.appendingPathComponent("Scans")) == expected)
    }

    @Test(arguments: [OptimizationMode.smart, .fast])
    func photoFolderUsesTheMediaBlockAndRoundTrips(mode: OptimizationMode) async throws {
        guard ProcessInfo.processInfo.activeProcessorCount >= 4 else { return }
        let dir = try TestSupport.makeTempDir("media-\(mode.rawValue)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        for i in 0..<9 {
            try (Data([0xFF, 0xD8, 0xFF, 0xE0]) + noise(8_000_000)).write(to: folder.appendingPathComponent("IMG_\(i).jpg"))
        }
        // Text above the Smart thresholds, so the split is built next to the baseline.
        for i in 0..<4 {
            try TestSupport.textBytes(120_000, seed: UInt64(i + 1)).write(to: folder.appendingPathComponent("raw/notes\(i).txt"))
        }
        let expected = try TestSupport.fingerprint(folder)
        var s = OptimizerSettings()
        s.mode = mode
        s.outputDirectory = dir
        let result = try await ArchiveOptimizer(tool: try TestSupport.tool(), settings: s, temporaryDirectory: dir)
            .optimize(folder) { _ in }
        #expect(result.strategy.hasSuffix(MediaBlock.strategySuffix), "strategy \(result.strategy)")
        #expect(result.groups.first?.group.id == "media")
        #expect(result.groups.first?.group.files.count == 9)
        #expect(result.groups.first?.winner.description.contains(":c=") == true)
        #expect(result.trialCount == (mode == .smart ? 3 : 2))
        let output = try #require(result.outputURL)
        let extracted = dir.appendingPathComponent("extracted", isDirectory: true)
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted.appendingPathComponent("Photos")) == expected)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("work").path))
    }
}
