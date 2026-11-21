import Foundation
import Testing
@testable import Squeeze7zCore

/// Regression tests for the first review round (data loss, verification and metadata findings).
@Suite struct RegressionTests {
    private func makeWorkspace(_ label: String) throws -> (dir: URL, tree: URL) {
        let dir = try TestSupport.makeTempDir(label)
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        return (dir, tree)
    }

    private func write(_ rel: String, _ seed: UInt64, in root: URL, words: Int = 15_000) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestSupport.textBytes(words, seed: seed).write(to: url)
    }

    private func optimizer(temp: URL, mode: OptimizationMode = .normal,
                           configure: (inout OptimizerSettings) -> Void = { _ in }) throws -> ArchiveOptimizer {
        var s = OptimizerSettings()
        s.mode = mode
        s.concurrentTrials = 2
        configure(&s)
        return ArchiveOptimizer(tool: try TestSupport.tool(), settings: s, temporaryDirectory: temp)
    }

    /// Optimizes `source` into `dir/out` and checks that the result extracts to exactly `tree`.
    @discardableResult
    private func roundTrip(source: URL, tree: URL, dir: URL, mode: OptimizationMode = .normal) async throws -> OptimizationResult {
        let temp = dir.appendingPathComponent("tmp")
        let out = dir.appendingPathComponent("out")
        let result = try await optimizer(temp: temp, mode: mode) { $0.outputDirectory = out }.optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        let output = try #require(result.outputURL)
        let extracted = dir.appendingPathComponent("extracted-\(UUID().uuidString)")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
        #expect(TestSupport.entries(in: temp).isEmpty)
        return result
    }

    // MARK: AppleDouble names

    @Test func scannerSeesDotUnderscoreNames() async throws {
        let (dir, tree) = try makeWorkspace("scan")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("._a.txt", 1, in: tree, words: 50)
        try write("a.txt", 2, in: tree, words: 50)
        try write(".dotfile", 3, in: tree, words: 50)
        try write("onlyad/._x", 4, in: tree, words: 50)
        let snapshot = try await TreeScanner.scan(root: tree)
        #expect(Set(snapshot.files.keys) == ["._a.txt", "a.txt", ".dotfile", "onlyad/._x"])
        #expect(snapshot.emptyDirectories.isEmpty)
        #expect(Set(snapshot.directories.keys) == ["onlyad"])
    }

    @Test(arguments: ["7z", "zip", "tar"])
    func dotUnderscoreMembersSurvive(type: String) async throws {
        let (dir, tree) = try makeWorkspace("appledouble")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["._a.txt", "._hidden.txt", ".dotfile", "a.txt", "folder/._two.txt", "folder/two.txt", "onlyad/._x"].enumerated() {
            try write(name, UInt64(i + 1), in: tree)
        }
        let source = dir.appendingPathComponent("in.\(type)")
        try TestSupport.makeArchive(from: tree, at: source, type: type, extra: type == "tar" ? [] : ["-mx=0"])
        try await roundTrip(source: source, tree: tree, dir: dir)
    }

    private func makeFinderZip(_ label: String) throws -> (URL, URL) {
        let (dir, tree) = try makeWorkspace(label)
        for (i, name) in ["doc.txt", "folder/two.txt", "folder/three.txt"].enumerated() {
            try write(name, UInt64(i + 1), in: tree)
            try TestSupport.runSystem("/usr/bin/xattr", ["-w", "com.apple.test", "value", tree.appendingPathComponent(name).path])
        }
        let source = dir.appendingPathComponent("finder.zip")
        #expect(try TestSupport.runSystem("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", tree.path, source.path]) == 0)
        return (dir, source)
    }

    @Test func finderZipWithMacosxFolderIsOptimized() async throws {
        let (dir, source) = try makeFinderZip("ditto")
        defer { try? FileManager.default.removeItem(at: dir) }
        let listing = try await TestSupport.tool().list(source)
        #expect(listing.entries.contains { $0.path.hasPrefix("__MACOSX/") }, "ditto did not produce AppleDouble members")

        let temp = dir.appendingPathComponent("tmp")
        let result = try await optimizer(temp: temp) { $0.outputDirectory = dir.appendingPathComponent("out") }
            .optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        // Every member of the zip comes back except the `__MACOSX` folder, which is left out by default.
        let extractedSource = dir.appendingPathComponent("from-zip")
        try TestSupport.extract(source, into: extractedSource)
        try FileManager.default.removeItem(at: extractedSource.appendingPathComponent("__MACOSX"))
        let extractedOutput = dir.appendingPathComponent("from-7z")
        try TestSupport.extract(try #require(result.outputURL), into: extractedOutput)
        #expect(try TestSupport.fingerprint(extractedOutput) == TestSupport.fingerprint(extractedSource))
        #expect(try !TestSupport.allPaths(extractedOutput).contains { $0.hasPrefix("__MACOSX") })
    }

    @Test func finderZipKeepsMacosxFolderWhenAsked() async throws {
        let (dir, source) = try makeFinderZip("ditto-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let temp = dir.appendingPathComponent("tmp")
        let result = try await optimizer(temp: temp) {
            $0.outputDirectory = dir.appendingPathComponent("out")
            $0.keepMacOSMetadata = true
        }.optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        let extractedSource = dir.appendingPathComponent("from-zip")
        try TestSupport.extract(source, into: extractedSource)
        let extractedOutput = dir.appendingPathComponent("from-7z")
        try TestSupport.extract(try #require(result.outputURL), into: extractedOutput)
        #expect(try TestSupport.fingerprint(extractedOutput) == TestSupport.fingerprint(extractedSource))
        #expect(try TestSupport.allPaths(extractedOutput).contains { $0.hasSuffix("._two.txt") })
    }

    @Test func macosxFolderWithOtherFilesIsKept() async throws {
        let (dir, tree) = try makeWorkspace("macosx-real")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("doc.txt", 1, in: tree)
        try write("__MACOSX/notes.txt", 2, in: tree)
        try write("__MACOSX/._fake.txt", 3, in: tree)
        let source = dir.appendingPathComponent("x.zip")
        try TestSupport.runSystem("/usr/bin/ditto", ["-c", "-k", "--norsrc", tree.path, source.path])
        let temp = dir.appendingPathComponent("tmp")
        let result = try await optimizer(temp: temp) { $0.outputDirectory = dir.appendingPathComponent("out") }
            .optimize(source) { _ in }
        let extractedSource = dir.appendingPathComponent("from-zip")
        try TestSupport.extract(source, into: extractedSource)
        let extractedOutput = dir.appendingPathComponent("from-7z")
        try TestSupport.extract(try #require(result.outputURL), into: extractedOutput)
        #expect(try TestSupport.fingerprint(extractedOutput) == TestSupport.fingerprint(extractedSource))
    }

    @Test func bsdtarArchiveWithResourceForks() async throws {
        let (dir, tree) = try makeWorkspace("bsdtar")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["a.txt", "sub/b.txt"].enumerated() {
            try write(name, UInt64(i + 1), in: tree)
            try TestSupport.runSystem("/usr/bin/xattr", ["-w", "com.apple.test", "v", tree.appendingPathComponent(name).path])
        }
        let source = dir.appendingPathComponent("x.tar")
        try TestSupport.runSystem("/usr/bin/tar", ["-cf", source.path, "-C", tree.path, "."])
        let listing = try await TestSupport.tool().list(source)
        let hasAppleDouble = listing.entries.contains { ($0.path as NSString).lastPathComponent.hasPrefix("._") }
        let temp = dir.appendingPathComponent("tmp")
        let result = try await optimizer(temp: temp) { $0.outputDirectory = dir.appendingPathComponent("out") }
            .optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        let extractedSource = dir.appendingPathComponent("from-tar")
        try TestSupport.extract(source, into: extractedSource)
        let extractedOutput = dir.appendingPathComponent("from-7z")
        try TestSupport.extract(try #require(result.outputURL), into: extractedOutput)
        #expect(try TestSupport.fingerprint(extractedOutput) == TestSupport.fingerprint(extractedSource))
        if hasAppleDouble { #expect(try TestSupport.allPaths(extractedOutput).contains { $0.hasSuffix("._a.txt") }) }
    }

    // MARK: Path canonicalization

    @Test func canonicalPaths() {
        #expect(SourceChecks.canonicalPath("./a.txt") == "a.txt")
        #expect(SourceChecks.canonicalPath("/abs/x.txt") == "abs/x.txt")
        #expect(SourceChecks.canonicalPath("d//b.txt") == "d/b.txt")
        #expect(SourceChecks.canonicalPath("./d/./e/") == "d/e")
        #expect(SourceChecks.canonicalPath("//") == "")
        #expect(SourceChecks.canonicalPath("../x") == "../x")
    }

    @Test func tarWithDotSlashAndAbsoluteMembers() async throws {
        let (dir, tree) = try makeWorkspace("dotslash")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["a.txt", "d/b.txt", "d/c.txt"].enumerated() { try write(name, UInt64(i + 1), in: tree) }
        let plain = dir.appendingPathComponent("dot.tar")
        try TestSupport.runSystem("/usr/bin/tar", ["--no-mac-metadata", "-cf", plain.path, "-C", tree.path, "."])
        let gz = dir.appendingPathComponent("dot.tar.gz")
        try TestSupport.runSystem("/usr/bin/tar", ["--no-mac-metadata", "-czf", gz.path, "-C", tree.path, "."])
        try await roundTrip(source: plain, tree: tree, dir: dir)
        try await roundTrip(source: gz, tree: tree, dir: dir)

        // Absolute member names (bsdtar -P keeps the leading slash).
        let abs = dir.appendingPathComponent("abs.tar")
        try TestSupport.runSystem("/usr/bin/tar", ["--no-mac-metadata", "-cPf", abs.path, tree.appendingPathComponent("a.txt").path,
                                                   tree.appendingPathComponent("d/b.txt").path])
        let temp = dir.appendingPathComponent("tmp2")
        let result = try await optimizer(temp: temp) { $0.outputDirectory = dir.appendingPathComponent("out2") }
            .optimize(abs) { _ in }
        #expect(result.outcome == .optimized || result.outcome == .noGain)
        #expect(TestSupport.entries(in: temp).isEmpty)
    }

    @Test func slashOnlyPathDoesNotCrashTheLinkCheck() throws {
        let listing = ArchiveListing(archivePath: "/x.tar", format: "tar", physicalSize: 1, isSolid: false, methods: nil, entries: [
            ArchiveEntry(path: "/", size: 0, isDirectory: true),
            ArchiveEntry(path: "//", size: 0),
            ArchiveEntry(path: "./", size: 0),
            ArchiveEntry(path: "file.txt", size: 3),
            ArchiveEntry(path: "link", size: 8, isSymlink: true),
        ])
        try SourceChecks.ensureSafeLinks(listing)
        let below = ArchiveListing(archivePath: "/x.tar", format: "tar", physicalSize: 1, isSolid: false, methods: nil, entries: [
            ArchiveEntry(path: "./link", size: 8, isSymlink: true),
            ArchiveEntry(path: "link/x.txt", size: 3),
        ])
        #expect(throws: OptimizerError.self) { try SourceChecks.ensureSafeLinks(below) }
    }

    // MARK: List files

    @Test func listFileQuotesEveryName() throws {
        let dir = try TestSupport.makeTempDir("listfile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = dir.appendingPathComponent("l.txt")
        try ListFile.write([" lead.txt", "a b.txt"], to: list)
        #expect(try String(contentsOf: list, encoding: .utf8) == "\" lead.txt\"\n\"a b.txt\"\n")
    }

    @Test func namesWithSpacesQuotesAndWildcards() async throws {
        let (dir, tree) = try makeWorkspace("names")
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = [" leading space.txt", "trailing space.txt ", "\"allquoted.txt\"", "\"half.txt", "tail\".txt\"",
                     "a*b?.txt", "@at.txt", "!bang.txt", "-dash.txt", "semi;colon.txt", "  two  ", "sub dir /in side.txt"]
        for (i, name) in names.enumerated() { try write(name, UInt64(i + 1), in: tree, words: 6_000) }
        let source = dir.appendingPathComponent("names.7z")
        try TestSupport.makeArchive(from: tree, at: source, type: "7z", extra: ["-spd", "-mx=0"])
        try await roundTrip(source: source, tree: tree, dir: dir)
        try await roundTrip(source: source, tree: tree, dir: dir, mode: .fast)
    }

    // MARK: Directories

    @Test func directoryModeAndTimeSurvive() async throws {
        let (dir, tree) = try makeWorkspace("dirs")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("p/private/a.txt", 1, in: tree)
        try write("p/private/deep/b.txt", 2, in: tree)
        try write("p/open/c.txt", 3, in: tree)
        try write("top.txt", 4, in: tree)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("p/emptyone"), withIntermediateDirectories: true)
        func setDir(_ rel: String, mode: mode_t, time: Int) throws {
            let path = tree.appendingPathComponent(rel).path
            var times = [timespec(tv_sec: time, tv_nsec: 0), timespec(tv_sec: time, tv_nsec: 0)]
            #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
            #expect(chmod(path, mode) == 0)
        }
        // Deepest first: changing a parent's mode must not get in the way.
        try setDir("p/private/deep", mode: 0o750, time: 1_600_000_000)
        try setDir("p/private", mode: 0o700, time: 1_700_000_000)
        try setDir("p/open", mode: 0o755, time: 1_650_000_000)
        try setDir("p/emptyone", mode: 0o711, time: 1_640_000_000)
        try setDir("p", mode: 0o755, time: 1_690_000_000)
        defer { FileTree.forceRemove(tree) }

        let source = dir.appendingPathComponent("dirs.tar")
        try TestSupport.runSystem("/usr/bin/tar", ["--no-mac-metadata", "-cf", source.path, "-C", tree.path, "p", "top.txt"])
        let sourceExtract = dir.appendingPathComponent("from-tar")
        try TestSupport.extract(source, into: sourceExtract)
        let expected = try TestSupport.directoryMetadata(sourceExtract)
        #expect(expected["p/private"]?.hasPrefix("700@1700000000") == true)

        for mode in [OptimizationMode.fast, .normal] {
            let result = try await optimizer(temp: dir.appendingPathComponent("tmp"), mode: mode) {
                $0.outputDirectory = dir.appendingPathComponent("out-\(mode.rawValue)")
            }.optimize(source) { _ in }
            #expect(result.outcome == .optimized)
            let output = try #require(result.outputURL)
            let listing = try await TestSupport.tool().list(output)
            #expect(Set(listing.entries.filter(\.isDirectory).map(\.path)) == Set(expected.keys))
            let extracted = dir.appendingPathComponent("from-7z-\(mode.rawValue)")
            try TestSupport.extract(output, into: extracted)
            #expect(try TestSupport.directoryMetadata(extracted) == expected)
            #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(sourceExtract))
        }
        FileTree.forceRemove(sourceExtract)
    }

    @Test func verifierRequiresEveryDirectory() async throws {
        let (dir, tree) = try makeWorkspace("verifydirs")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("d/e/f.txt", 1, in: tree, words: 50)
        let snapshot = try await TreeScanner.scan(root: tree)
        #expect(snapshot.directories.keys.sorted() == ["d", "d/e"])
        // Files only, as an archiver that drops directory entries would produce.
        let archive = dir.appendingPathComponent("files-only.7z")
        #expect(try TestSupport.run7zz(["a", "-y", "-bb0", "-bsp0", archive.path, "d/e/f.txt"], in: tree) == 0)
        let listing = try await TestSupport.tool().list(archive)
        #expect(listing.entries.filter(\.isDirectory).isEmpty)
        #expect(throws: OptimizerError.self) { try SourceChecks.verifyArchive(listing: listing, snapshot: snapshot) }
        var filesGone = snapshot
        filesGone.files = [:]
        #expect(throws: OptimizerError.self) { try SourceChecks.verifyArchive(listing: ArchiveListing(
            archivePath: archive.path, format: "7z", physicalSize: 1, isSolid: false, methods: nil, entries: []), snapshot: filesGone) }
    }

    // MARK: Archive names with wildcards

    @Test func archiveNameWithWildcardCharacters() async throws {
        let (dir, tree) = try makeWorkspace("wild")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.txt", 1, in: tree)
        try write("b.txt", 2, in: tree)
        let source = dir.appendingPathComponent("what?.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        try TestSupport.makeArchive(from: tree, at: dir.appendingPathComponent("whatX.zip"), type: "zip")
        try TestSupport.makeArchive(from: tree, at: dir.appendingPathComponent("whatY.zip"), type: "zip")
        let listing = try await TestSupport.tool().list(source)
        #expect(listing.entries.filter { !$0.isDirectory }.count == 2)
        try await roundTrip(source: source, tree: tree, dir: dir)
        let star = dir.appendingPathComponent("st*r.zip")
        try TestSupport.makeArchive(from: tree, at: star, type: "zip")
        try TestSupport.makeArchive(from: tree, at: dir.appendingPathComponent("stZr.zip"), type: "zip")
        try await roundTrip(source: star, tree: tree, dir: dir)
    }

    // MARK: Disk space and temporary archives

    @Test func requiredSpaceGrowsWithModeAndTrialData() throws {
        func required(_ configure: (inout OptimizerSettings) -> Void) throws -> Int64 {
            try optimizer(temp: FileManager.default.temporaryDirectory, configure: configure).requiredSpace(unpacked: 1_000)
        }
        let fast = try required { $0.mode = .fast }
        let sampled = try required { $0.mode = .ultra; $0.samplingLevel = 3 }
        let full = try required { $0.mode = .ultra; $0.samplingLevel = 0; $0.concurrentTrials = 4 }
        #expect(fast >= 3_000)
        #expect(sampled == fast)
        #expect(full > fast)
        #expect(try required { $0.mode = .fast; $0.samplingLevel = 0 } == fast)
        // Smart builds the baseline and the split at once, both on a copy of the media block.
        #expect(try required { $0.mode = .smart } == 4_000)
    }

    @Test func atMostTwoFullArchivesAreKept() async throws {
        let (dir, tree) = try makeWorkspace("prune")
        defer { try? FileManager.default.removeItem(at: dir) }
        try TestSupport.randomBytes(300_000, seed: 3).write(to: tree.appendingPathComponent("a.mp4"))
        try TestSupport.randomBytes(200_000, seed: 4).write(to: tree.appendingPathComponent("b.mp4"))
        try write("note.txt", 1, in: tree)
        let source = dir.appendingPathComponent("media.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        let temp = dir.appendingPathComponent("tmp")
        let log = TestSupport.EventLog()
        let opt = try optimizer(temp: temp, mode: .ultra) {
            $0.keepTempFiles = true
            $0.outputDirectory = dir.appendingPathComponent("out")
        }
        let result = try await opt.optimize(source) { log.add($0) }
        #expect(result.outcome == .optimized)
        #expect(log.logs.filter { $0.hasPrefix("Baseline") }.count == 3)
        let work = try #require(TestSupport.entries(in: temp).first)
        let kept = TestSupport.entries(in: temp.appendingPathComponent(work)).filter { $0.hasSuffix(".7z") }
        #expect(kept.count <= 2, "archives left in the work directory: \(kept)")
        FileTree.forceRemove(temp)
    }

    // MARK: Replacing the original

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    @Test func failedReplacementAfterTrashingKeepsTheVerifiedArchive() throws {
        let dir = try TestSupport.makeTempDir("publish")
        defer { try? FileManager.default.removeItem(at: dir) }
        let volumes = ["big.7z.001", "big.7z.002"].map { dir.appendingPathComponent($0) }
        for v in volumes { try Data("volume".utf8).write(to: v) }
        let built = dir.appendingPathComponent("built.7z")
        try Data("the verified archive".utf8).write(to: built)

        let calls = Counter()
        var opt = try optimizer(temp: dir.appendingPathComponent("tmp")) { $0.outputMode = .replaceOriginal }
        opt.trash = { url in
            if calls.next() == 2 { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        do {
            _ = try opt.publish(archive: built, source: volumes[0], volumes: volumes)
            Issue.record("expected the second volume to fail")
        } catch let OptimizerError.outputKept(path, _) {
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "the verified archive")
            #expect((path as NSString).lastPathComponent == "big_optimized.7z")
        }
        #expect(TestSupport.entries(in: dir).filter { $0.hasSuffix(".squeeze7z-partial") }.isEmpty)
    }

    @Test func failedFirstTrashLeavesNothingBehind() throws {
        let dir = try TestSupport.makeTempDir("publish2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.7z")
        try Data("source".utf8).write(to: source)
        let built = dir.appendingPathComponent("built.7z")
        try Data("archive".utf8).write(to: built)
        var opt = try optimizer(temp: dir.appendingPathComponent("tmp")) { $0.outputMode = .replaceOriginal }
        opt.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(throws: CocoaError.self) { try opt.publish(archive: built, source: source, volumes: [source]) }
        #expect(TestSupport.entries(in: dir) == ["a.7z"])
    }

    // MARK: Unreadable members

    @Test func unreadableMemberIsReportedClearly() async throws {
        let dir = try TestSupport.makeTempDir("noread")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("mk.py")
        try Data("""
        import io, sys, tarfile
        out = sys.argv[1]
        with tarfile.open(out, "w") as t:
            for name, mode in (("p/ok.txt", 0o644), ("p/noread.txt", 0o000)):
                data = b"hello world " * 2000
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = mode
                t.addfile(info, io.BytesIO(data))
        """.utf8).write(to: script)
        let source = dir.appendingPathComponent("noread.tar")
        try TestSupport.runSystem("/usr/bin/python3", ["-I", script.path, source.path])
        #expect(TestSupport.size(source) > 0)
        let temp = dir.appendingPathComponent("tmp")
        do {
            _ = try await optimizer(temp: temp).optimize(source) { _ in }
            Issue.record("expected an error")
        } catch let error as OptimizerError {
            guard case .unreadable(let what) = error else { Issue.record("unexpected \(error)"); return }
            #expect(what.contains("noread.txt"))
        }
        #expect(TestSupport.entries(in: temp).isEmpty)
        #expect(TestSupport.size(source) > 0)
    }
}
