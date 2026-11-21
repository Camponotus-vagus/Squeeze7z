import Foundation
import Testing
@testable import Squeeze7zCore

/// Regression tests for the final review: data after the end of an archive, and normal mode against fast.
@Suite struct Round4Tests {
    private func makeWorkspace(_ label: String) throws -> (dir: URL, tree: URL) {
        let dir = try TestSupport.makeTempDir(label)
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        return (dir, tree)
    }

    private func optimizer(temp: URL, mode: OptimizationMode = .normal,
                           configure: (inout OptimizerSettings) -> Void = { _ in }) throws -> ArchiveOptimizer {
        var s = OptimizerSettings()
        s.mode = mode
        s.concurrentTrials = 2
        configure(&s)
        return ArchiveOptimizer(tool: try TestSupport.tool(), settings: s, temporaryDirectory: temp)
    }

    private func write(_ rel: String, _ data: Data, in root: URL) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func append(_ extra: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: extra)
    }

    // MARK: Data after the end of the archive

    @Test func listingParserExposesTailAndHeadBytes() throws {
        let text = """
        7-Zip (z) 26.06

        Listing archive: a.zip

        --
        Path = a.zip
        Type = zip
        WARNINGS:
        There are data after the end of archive
        Physical Size = 6076
        Tail Size = 8842

        ----------
        Path = a/f.txt
        Size = 3
        """
        let listing = try ListingParser.parse(text, archivePath: "/x/a.zip", fallbackPhysicalSize: 0)
        #expect(listing.tailBytes == 8842)
        #expect(listing.headBytes == 0)
        let sfx = text.replacingOccurrences(of: "Tail Size = 8842", with: "Embedded Stub Size = 512")
        let withStub = try ListingParser.parse(sfx, archivePath: "/x/a.exe", fallbackPhysicalSize: 0)
        #expect(withStub.tailBytes == 0)
        #expect(withStub.headBytes == 512)
    }

    private func expectRejected(_ source: URL, dir: URL, reason: String = "follow the end of the archive") async throws {
        let before = try Data(contentsOf: source)
        let out = dir.appendingPathComponent("out")
        for outputMode in [OutputMode.newFile, .replaceOriginal] {
            let opt = try optimizer(temp: dir.appendingPathComponent("tmp")) {
                $0.outputDirectory = out
                $0.outputMode = outputMode
            }
            do {
                _ = try await opt.optimize(source) { _ in }
                Issue.record("\(source.lastPathComponent) with trailing data was accepted")
            } catch OptimizerError.notAnArchive(let message) {
                #expect(message.contains(reason), "unexpected message: \(message)")
            }
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(TestSupport.entries(in: out).isEmpty)
        #expect(TestSupport.entries(in: dir.appendingPathComponent("tmp")).isEmpty)
    }

    @Test func zipWithTrailingDataIsRejected() async throws {
        let (dir, tree) = try makeWorkspace("tail-zip")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.txt", TestSupport.textBytes(3000, seed: 1), in: tree)
        let source = dir.appendingPathComponent("t.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        try append(TestSupport.randomBytes(50_000, seed: 9), to: source)
        try await expectRejected(source, dir: dir)
    }

    @Test func sevenZipWithTrailingDataIsRejected() async throws {
        let (dir, tree) = try makeWorkspace("tail-7z")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.txt", TestSupport.textBytes(3000, seed: 1), in: tree)
        let source = dir.appendingPathComponent("t.7z")
        try TestSupport.makeArchive(from: tree, at: source, type: "7z")
        try append(TestSupport.randomBytes(50_000, seed: 9), to: source)
        try await expectRejected(source, dir: dir)
    }

    @Test func concatenatedZipsAreRejected() async throws {
        let (dir, tree) = try makeWorkspace("tail-concat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let second = dir.appendingPathComponent("second", isDirectory: true)
        try write("a.txt", TestSupport.textBytes(3000, seed: 1), in: tree)
        try write("b.txt", TestSupport.textBytes(6000, seed: 2), in: second)
        let one = dir.appendingPathComponent("one.zip"), two = dir.appendingPathComponent("two.zip")
        try TestSupport.makeArchive(from: tree, at: one, type: "zip")
        try TestSupport.makeArchive(from: second, at: two, type: "zip")
        let source = dir.appendingPathComponent("both.zip")
        try Data(contentsOf: one).write(to: source)
        try append(Data(contentsOf: two), to: source)
        try await expectRejected(source, dir: dir)
    }

    @Test func concatenatedTarsStillWorkLikeStandardTar() async throws {
        let (dir, tree) = try makeWorkspace("tail-tar")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.txt", TestSupport.textBytes(30_000, seed: 1), in: tree)
        let one = dir.appendingPathComponent("one.tar")
        try TestSupport.makeArchive(from: tree, at: one, type: "tar")
        let source = dir.appendingPathComponent("both.tar")
        try Data(contentsOf: one).write(to: source)
        try append(Data(contentsOf: one), to: source)
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp")) {
            $0.outputDirectory = dir.appendingPathComponent("out")
        }.optimize(source) { _ in }
        #expect(result.outcome == .optimized)
    }

    // MARK: Normal against fast

    @Test func normalIsNeverWorseThanFastWithoutSampling() async throws {
        let (dir, tree) = try makeWorkspace("normal-vs-fast")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The same text under several extensions: only a whole-archive solid stream sees the repetition.
        let shared = TestSupport.randomBytes(120_000, seed: 5).map { UInt8(97 + $0 % 26) }
        for ext in ["h", "c", "py", "txt"] { try write("src/file.\(ext)", Data(shared), in: tree) }
        let source = dir.appendingPathComponent("src.tar")
        try TestSupport.makeArchive(from: tree, at: source, type: "tar")
        func size(_ mode: OptimizationMode) async throws -> Int64 {
            let result = try await optimizer(temp: dir.appendingPathComponent("tmp-\(mode.rawValue)"), mode: mode) {
                $0.samplingLevel = 0
                $0.outputDirectory = dir.appendingPathComponent("out-\(mode.rawValue)")
            }.optimize(source) { _ in }
            return result.optimizedBytes
        }
        let fast = try await size(.fast)
        let normal = try await size(.normal)
        #expect(normal <= fast, "normal \(normal) > fast \(fast)")
    }
}
