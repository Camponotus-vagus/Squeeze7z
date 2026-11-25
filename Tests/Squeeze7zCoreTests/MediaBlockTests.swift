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
        s.parallelJobs = 1
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

    @Test func parallelJobsShareTheMemory() {
        // The case that thrashed: 10.6 GB of JPEGs that still compress, two jobs on a 32 GB Mac.
        #expect(spec(10_600 * mib, compressible: true) == "LZMA2:d=256m:fb=64:lc=4:c=253m")
        // Five encoders x 11 x 128 MB = 7 GB per job: two jobs stay within half of 32 GB.
        #expect(spec(10_600 * mib, compressible: true) { $0.parallelJobs = 2 } == "LZMA2:d=128m:fb=64:lc=4:c=253m")
        #expect(spec(10_600 * mib, compressible: true) { $0.parallelJobs = 4 } == "LZMA2:d=64m:fb=64:lc=4:c=253m")
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
        var one = OptimizerSettings()
        one.parallelJobs = 1
        let two = OptimizerSettings()   // the app default: two jobs at once
        #expect(Job.canBuildConcurrently(dictionary: "256m", ppmdMB: 256, physicalMemory: 32 * gib, settings: one))
        #expect(!Job.canBuildConcurrently(dictionary: "256m", ppmdMB: 256, physicalMemory: 8 * gib, settings: one))
        #expect(Job.canBuildConcurrently(dictionary: "64m", ppmdMB: 256, physicalMemory: 8 * gib, settings: one))
        #expect(!Job.canBuildConcurrently(dictionary: "x", ppmdMB: 256, physicalMemory: 32 * gib, settings: one))
        // Two jobs share the budget: on 16 GB each job has 4 GB, too little for 2 x 11 x 256 MB.
        #expect(Job.canBuildConcurrently(dictionary: "256m", ppmdMB: 256, physicalMemory: 16 * gib, settings: one))
        #expect(!Job.canBuildConcurrently(dictionary: "256m", ppmdMB: 256, physicalMemory: 16 * gib, settings: two))
        #expect(Job.canBuildConcurrently(dictionary: "128m", ppmdMB: 256, physicalMemory: 16 * gib, settings: two))
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
        let log = TestSupport.EventLog()
        let result = try await ArchiveOptimizer(tool: try TestSupport.tool(), settings: s, temporaryDirectory: dir)
            .optimize(folder, progress: log.add)
        #expect(result.strategy.hasSuffix(MediaBlock.strategySuffix), "strategy \(result.strategy)")
        // The media block reports its progress: fractions in range, the file count of the block.
        let media = log.steps.filter { $0.step == .compressingMedia }
        #expect(media.allSatisfy { (0...1).contains($0.fraction) && $0.filesTotal == 9 })
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

    // MARK: Progress lines of 7zz

    @Test func progressLinesAreParsed() {
        let b = String(repeating: "\u{8}", count: 19)
        let add = "  0M Scan  ./\(b)             \(b)  0%\u{8}\u{8}\u{8}\u{8}    \u{8}\u{8}\u{8}\u{8}  9% 3 + in/f12.jpg\(b)"
            + "                   \(b) 99% 30 + in/f9 copy.jpg\(b)                   \(b)"
        #expect(SevenZipTool.parseProgress(Data(add.utf8)) == ToolProgress(percent: 99, files: 30, currentFile: "in/f9 copy.jpg"))
        #expect(SevenZipTool.parseProgress(Data(" 42% 12 - photos/a.jpg\(b)".utf8))
                == ToolProgress(percent: 42, files: 12, currentFile: "photos/a.jpg"))
        // `7zz t` marks the file under test with "T" and shortens long names with " . ".
        #expect(SevenZipTool.parseProgress(Data(" 39% 36124 T data/raw/Fo . prima/IMG_1.jpg\(b)".utf8))
                == ToolProgress(percent: 39, files: 36124, currentFile: "data/raw/Fo . prima/IMG_1.jpg"))
        #expect(SevenZipTool.parseProgress(Data(" 37%\u{8}\u{8}\u{8}\u{8}".utf8)) == ToolProgress(percent: 37, files: nil, currentFile: nil))
        #expect(SevenZipTool.parseProgress(Data("  0M Scan\(b)".utf8)) == nil)
        #expect(SevenZipTool.parseProgress(Data()) == nil)
    }

    @Test func progressLinesAreNotReadAsMessages() {
        // A file named like an error must not make the archive look encrypted, nor end up in an error message.
        let out = "\n  12% 3 + docs/Wrong password.txt\u{8}\u{8}\u{8}\u{8}\nEverything is Ok\n"
        let output = ProcessOutput(exitCode: 2, standardOutput: Data(out.utf8), standardError: Data(), hadProgress: true)
        #expect(!output.outputText.contains("Wrong password"))
        #expect(!SevenZipTool.looksEncrypted(output))
        #expect(output.outputText.contains("Everything is Ok"))
        // A message printed right after the progress is erased, on the same line, is kept.
        let erase = String(repeating: "\u{8}", count: 8)
        let prompt = "  37% 2 + a.txt\(erase)        \(erase)Enter password (will not be echoed):"
        let asked = ProcessOutput(exitCode: 2, standardOutput: Data(prompt.utf8), standardError: Data(), hadProgress: true)
        #expect(asked.outputText == "Enter password (will not be echoed):")
        #expect(SevenZipTool.looksEncrypted(asked))
        // Without progress (a listing), a backspace in a file name is left alone.
        let listing = ProcessOutput(exitCode: 0, standardOutput: Data("Path = a\u{8}b.txt\n".utf8), standardError: Data())
        #expect(listing.outputText == "Path = a\u{8}b.txt\n")
    }

    // MARK: Live saving estimate

    @Test func estimateIsAgainstTheOriginalSize() {
        let mb: Int64 = 1 << 20
        let chunk: Int64 = 254 * mb
        // A 7z of JPEGs: 11,450 MB of photos packed into 10,630 MB. Three chunks written, at 92.8% each.
        let written = Int64(Double(3 * chunk) * 0.928)
        let fromSource = Job.estimatedSaving(written: written, base: 0, input: 11_450 * mb, fraction: 0.4, chunk: chunk,
                                             prior: 0.07, original: 10_630 * mb)
        let raw = Job.estimatedSaving(written: written, base: 0, input: 11_450 * mb, fraction: 0.4, chunk: chunk,
                                      prior: 0.07, original: nil)
        // Against the raw photos the run saves 7.2%; against the 7z it came from, almost nothing.
        #expect(abs((raw ?? 0) - 0.072) < 0.001)
        #expect(abs(fromSource ?? 1) < 0.01)
        // A folder: original and raw data are the same bytes, so both readings agree.
        let folder = Job.estimatedSaving(written: written, base: 0, input: 11_450 * mb, fraction: 0.4, chunk: chunk,
                                         prior: 0.07, original: 11_450 * mb)
        #expect(abs((folder ?? 0) - 0.072) < 0.001)
        // What is already in the archive (base) and the parts still to come count toward the projection.
        let withRest = Job.estimatedSaving(written: 50 * mb, base: 10 * mb, input: 200 * mb, fraction: 0.5, chunk: nil,
                                           prior: nil, pending: 40 * mb, original: 400 * mb)
        #expect(abs((withRest ?? 0) - 0.625) < 0.001)   // 10 + 0.5 x 200 + 40 = 150 MB of 400
        // Nothing written and no prior: no estimate.
        #expect(Job.estimatedSaving(written: 0, base: 0, input: 200 * mb, fraction: 0.5, chunk: nil, prior: nil,
                                    original: 400 * mb) == nil)
    }
}
