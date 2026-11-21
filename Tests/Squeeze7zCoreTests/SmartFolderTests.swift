import Foundation
import Testing
@testable import Squeeze7zCore

/// Smart mode (whole-archive LZMA2 or text-as-PPMd split) and compressing plain folders.
@Suite struct SmartFolderTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    private func optimizer(temp: URL, mode: OptimizationMode = .smart,
                           configure: (inout OptimizerSettings) -> Void = { _ in }) throws -> ArchiveOptimizer {
        var s = OptimizerSettings()
        s.mode = mode
        configure(&s)
        return ArchiveOptimizer(tool: try TestSupport.tool(), settings: s, temporaryDirectory: temp)
    }

    private func write(_ rel: String, _ data: Data, in root: URL) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Prose-like text with a skewed vocabulary: PPMd beats LZMA2 on it, as it does on real text.
    private func prose(words: Int, seed: UInt64) -> Data {
        var state: UInt64 = 7919   // one vocabulary for every file, as in a real corpus
        func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        let syllables = ["ba", "ce", "di", "fo", "gu", "la", "me", "ni", "po", "ru", "sa", "te", "vi", "zo"]
        let vocabulary: [String] = (0..<3000).map { _ in
            (0..<(1 + Int(next() % 4))).map { _ in syllables[Int(next() % 14)] }.joined()
        }
        state = seed << 1 | 1
        // Zipf: word i has weight 1 / (i + 1).
        var cumulative: [Double] = []
        var total = 0.0
        for i in 0..<vocabulary.count { total += 1 / Double(i + 1); cumulative.append(total) }
        var out = ""
        for _ in 0..<words {
            let target = Double(next() % 1_000_000) / 1_000_000 * total
            var low = 0, high = cumulative.count - 1
            while low < high {
                let mid = (low + high) / 2
                if cumulative[mid] < target { low = mid + 1 } else { high = mid }
            }
            out += vocabulary[low] + " "
        }
        return Data(out.utf8)
    }

    private func isFIFO(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFIFO
    }

    // MARK: Smart mode

    @Test func smartIsTheDefaultMode() {
        #expect(OptimizerSettings().mode == .smart)
        #expect(OptimizationMode.allCases.prefix(2).map(\.rawValue) == ["fast", "smart"])
        #expect(OptimizationMode.smart.displayName == "Smart")
        #expect(!OptimizationMode.smart.runsTrials && OptimizationMode.smart.rank == 0)
    }

    @Test func smartSplitsATextHeavyTreeAndRoundTrips() async throws {
        let dir = try TestSupport.makeTempDir("smart-text")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        for i in 0..<3 { try write("docs/part\(i).txt", prose(words: 150_000, seed: UInt64(i + 3)), in: tree) }
        try write("data/blob.bin", TestSupport.randomBytes(120_000, seed: 8), in: tree)
        try write("img/photo.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0]) + TestSupport.randomBytes(60_000, seed: 2), in: tree)
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("link").path,
                                                   withDestinationPath: "docs/part0.txt")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("empty/inner"), withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("in.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])

        let log = TestSupport.EventLog()
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp")) {
            $0.outputDirectory = dir.appendingPathComponent("out")
        }.optimize(source, progress: log.add)
        #expect(result.outcome == .optimized)
        #expect(result.strategy == "smart split")
        #expect(result.groups.map(\.group.id) == ["smart:text", "smart:rest"])
        #expect(result.groups[0].winner.description.hasPrefix("PPMd:o=16:mem="))
        #expect(result.groups.allSatisfy { $0.trials.isEmpty })
        // Baseline and split are the only builds; the progress ends complete.
        #expect(result.trialCount == 2)
        let last = try #require(log.progress.last)
        #expect(last.0 == last.1 && last.1 == 2)
        #expect(log.phases.contains(.baseline) && log.phases.contains(.assembling) && log.phases.contains(.verifying))

        let output = try #require(result.outputURL)
        let extracted = dir.appendingPathComponent("extracted", isDirectory: true)
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
        #expect(try TestSupport.directoryMetadata(extracted).keys.sorted() == TestSupport.directoryMetadata(tree).keys.sorted())
        #expect(result.optimizedBytes <= (try TestSupport.referenceSize(of: tree, in: dir)))
    }

    @Test func smartKeepsTheBaselineOnATreeWithoutText() async throws {
        let dir = try TestSupport.makeTempDir("smart-notext")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        try write("audio/tone.wav", TestSupport.wavBytes(frames: 100_000), in: tree)
        try write("img/pic.bmp", TestSupport.bmpBytes(width: 300, height: 200), in: tree)
        try write("notes.txt", TestSupport.textBytes(2_000), in: tree)
        let source = dir.appendingPathComponent("in.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp")) {
            $0.outputDirectory = dir.appendingPathComponent("out")
        }.optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        #expect(result.strategy.hasPrefix("whole-archive LZMA2"))
        #expect(result.trialCount == 1)
        let extracted = dir.appendingPathComponent("extracted", isDirectory: true)
        try TestSupport.extract(try #require(result.outputURL), into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    @Test func smartSplitIsSkippedWhenPPMdIsNotAllowed() async throws {
        let dir = try TestSupport.makeTempDir("smart-noppmd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        for i in 0..<3 { try write("t\(i).txt", prose(words: 150_000, seed: UInt64(i + 1)), in: tree) }
        let source = dir.appendingPathComponent("in.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        for configure in [{ (s: inout OptimizerSettings) in s.disablePPMd = true },
                          { (s: inout OptimizerSettings) in s.noPPMdAboveMB = 1 }] {
            let result = try await optimizer(temp: dir.appendingPathComponent("tmp"), configure: {
                configure(&$0)
                $0.outputDirectory = dir.appendingPathComponent("out")
            }).optimize(source) { _ in }
            #expect(result.strategy.hasPrefix("whole-archive"))
            #expect(result.trialCount == 1)
        }
    }

    // MARK: Folders

    /// text, a symlink, an empty subfolder, a binary file; returns the tree and its fingerprint.
    private func makeFolder(named name: String, in dir: URL) throws -> (URL, [String: String]) {
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        for i in 0..<3 { try write("docs/part\(i).txt", TestSupport.textBytes(30_000, seed: UInt64(i + 1)), in: folder) }
        try write("data/blob.bin", TestSupport.randomBytes(40_000, seed: 3), in: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty/inner"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path,
                                                   withDestinationPath: "docs/part0.txt")
        return (folder, try TestSupport.fingerprint(folder))
    }

    @Test(arguments: [OptimizationMode.fast, .smart, .normal])
    func folderIsCompressedIntoItsOwnArchive(mode: OptimizationMode) async throws {
        let dir = try TestSupport.makeTempDir("folder-\(mode.rawValue)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (folder, expected) = try makeFolder(named: "My Folder", in: dir)
        let fifo = folder.appendingPathComponent("docs/pipe")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        let metadataBefore = try TestSupport.directoryMetadata(folder)

        let log = TestSupport.EventLog()
        let opt = try optimizer(temp: dir.appendingPathComponent("tmp"), mode: mode)
        let result = try await opt.optimize(folder, progress: log.add)
        #expect(result.outcome == .optimized)
        #expect(result.sourceFormat == "folder")
        let textTotal = (0..<3).reduce(0) { $0 + TestSupport.textBytes(30_000, seed: UInt64($1 + 1)).count }
        #expect(result.originalBytes == Int64(textTotal + 40_000))
        #expect(log.logs.contains { $0.contains("pipe") && $0.contains("Skipped") })
        let output = try #require(result.outputURL)
        #expect(output == dir.appendingPathComponent("My Folder.7z"))

        let extracted = dir.appendingPathComponent("extracted", isDirectory: true)
        try TestSupport.extract(output, into: extracted)
        #expect(TestSupport.entries(in: extracted) == ["My Folder"])
        #expect(try TestSupport.fingerprint(extracted.appendingPathComponent("My Folder")) == expected)

        // The source is exactly as it was, FIFO included.
        #expect(isFIFO(fifo))
        try FileManager.default.removeItem(at: fifo)
        #expect(try TestSupport.fingerprint(folder) == expected)
        #expect(try TestSupport.directoryMetadata(folder).filter { $0.key != "docs" } == metadataBefore.filter { $0.key != "docs" })

        // A second run does not overwrite the first archive.
        let again = try await opt.optimize(folder) { _ in }
        #expect(again.outputURL == dir.appendingPathComponent("My Folder-2.7z"))
        #expect(FileManager.default.fileExists(atPath: output.path))
        // Nothing is left in the temporary directory.
        #expect(TestSupport.entries(in: dir.appendingPathComponent("tmp")).isEmpty)
    }

    @Test func replaceOriginalNeverTrashesAFolder() async throws {
        let dir = try TestSupport.makeTempDir("folder-replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (folder, expected) = try makeFolder(named: "Keep", in: dir)
        var opt = try optimizer(temp: dir.appendingPathComponent("tmp"), mode: .fast) { $0.outputMode = .replaceOriginal }
        let trashed = Counter()
        opt.trash = { _ in _ = trashed.next() }
        let log = TestSupport.EventLog()
        let result = try await opt.optimize(folder, progress: log.add)
        #expect(result.outcome == .optimized)
        #expect(result.outputURL?.lastPathComponent == "Keep.7z")
        #expect(trashed.next() == 1)
        #expect(try TestSupport.fingerprint(folder) == expected)
        #expect(log.logs.contains { $0.contains("never moved to the Trash") })
    }

    @Test func folderOutputGoesToTheOutputDirectory() async throws {
        let dir = try TestSupport.makeTempDir("folder-out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (folder, _) = try makeFolder(named: "Pack", in: dir)
        let out = dir.appendingPathComponent("out")
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp"), mode: .fast) { $0.outputDirectory = out }
            .optimize(folder) { _ in }
        #expect(result.outputURL == out.appendingPathComponent("Pack.7z"))
    }

    @Test func emptyAndIncompressibleFoldersWriteNothing() async throws {
        let dir = try TestSupport.makeTempDir("folder-nogain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let random = dir.appendingPathComponent("Random", isDirectory: true)
        try write("a.bin", TestSupport.randomBytes(50_000), in: random)
        let opt = try optimizer(temp: dir.appendingPathComponent("tmp"))
        for folder in [empty, random] {
            let result = try await opt.optimize(folder) { _ in }
            #expect(result.outcome == .noGain && result.outputURL == nil)
        }
        #expect(TestSupport.entries(in: dir).filter { $0.hasSuffix(".7z") }.isEmpty)
    }

    @Test func foldersWithUnreadableFilesFailAndSymlinkedFoldersAreNotFolders() async throws {
        let dir = try TestSupport.makeTempDir("folder-unreadable")
        defer {
            _ = try? TestSupport.runSystem("/bin/chmod", ["-R", "u+rwx", dir.path])
            try? FileManager.default.removeItem(at: dir)
        }
        let folder = dir.appendingPathComponent("Locked", isDirectory: true)
        try write("ok.txt", TestSupport.textBytes(5_000), in: folder)
        try write("secret.txt", TestSupport.textBytes(5_000), in: folder)
        chmod(folder.appendingPathComponent("secret.txt").path, 0)
        let opt = try optimizer(temp: dir.appendingPathComponent("tmp"))
        await #expect(throws: OptimizerError.self) { _ = try await opt.optimize(folder) { _ in } }
        #expect(TestSupport.entries(in: dir).filter { $0.hasSuffix(".7z") }.isEmpty)

        let link = dir.appendingPathComponent("LinkToFolder")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Locked")
        #expect(!ArchiveOptimizer.isFolder(link))
        #expect(ArchiveOptimizer.isFolder(folder))
    }

    // MARK: Review fixes

    /// Runs `body` with an empty case-sensitive APFS volume mounted; detached and deleted afterwards.
    /// Returns false when no such volume could be made (the caller then has nothing to check).
    private func withCaseSensitiveVolume(_ body: (URL) async throws -> Void) async throws -> Bool {
        let dir = try TestSupport.makeTempDir("case-volume")
        let mount = dir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("cs.sparseimage")
        defer {
            // The volume can be briefly busy (Spotlight, fseventsd): retry, or it stays mounted after the run.
            for attempt in 0..<10 {
                if (try? TestSupport.runSystem("/usr/bin/hdiutil", ["detach", "-force", mount.path])) == 0 { break }
                if attempt < 9 { usleep(500_000) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        guard try TestSupport.runSystem("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "Case-sensitive APFS",
                                                              "-volname", "SqzCase", "-type", "SPARSE",
                                                              dir.appendingPathComponent("cs").path]) == 0,
              try TestSupport.runSystem("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mount.path, "-nobrowse"]) == 0
        else { return false }
        try await body(mount)
        return true
    }

    @Test func namesThatDifferOnlyInCaseAreRefusedNotMerged() async throws {
        let ran = try await withCaseSensitiveVolume { mount in
            let folder = mount.appendingPathComponent("Clash", isDirectory: true)
            try write("README.txt", TestSupport.textBytes(2_000, seed: 1), in: folder)
            try write("readme.txt", TestSupport.textBytes(2_000, seed: 2), in: folder)
            try write("other.txt", TestSupport.textBytes(2_000, seed: 3), in: folder)
            let out = try TestSupport.makeTempDir("clash-out")
            defer { try? FileManager.default.removeItem(at: out) }
            let opt = try optimizer(temp: out.appendingPathComponent("tmp"), mode: .fast) { $0.outputDirectory = out }
            do {
                _ = try await opt.optimize(folder) { _ in }
                Issue.record("a folder with README.txt and readme.txt must be refused")
            } catch let error as OptimizerError {
                guard case .folderProblem(let message) = error else { Issue.record("unexpected error \(error)"); return }
                #expect(message.contains("README.txt") && message.contains("readme.txt"))
            }
            #expect(TestSupport.entries(in: out) == ["tmp"] || TestSupport.entries(in: out).isEmpty)
            #expect(try TestSupport.allPaths(folder).count == 3)
        }
        if !ran { print("note: no case-sensitive volume available, collision test not run") }
    }

    @Test func stagingThatLosesFilesIsCaught() throws {
        var listing = FolderStage.Listing()
        func entry(_ path: String, _ kind: FolderStage.Entry.Kind, _ size: Int64 = 0) -> FolderStage.Entry {
            .init(path: path, kind: kind, size: size, mode: 0o755, seconds: 0, nanoseconds: 0)
        }
        listing.entries = [entry("a", .file, 5), entry("b", .file, 7), entry("d", .directory)]
        var snapshot = TreeSnapshot()
        snapshot.files = ["F/a": .init(size: 5, crc: 0, isSymlink: false), "F/b": .init(size: 7, crc: 0, isSymlink: false)]
        snapshot.directories = ["F": .init(mode: 0o755, mtimeSeconds: 0, mtimeNanoseconds: 0),
                                "F/d": .init(mode: 0o755, mtimeSeconds: 0, mtimeNanoseconds: 0)]
        try ArchiveOptimizer.verifyStaging(listing, name: "F", snapshot: snapshot)
        var lost = snapshot
        lost.files["F/b"] = nil
        #expect(throws: OptimizerError.self) { try ArchiveOptimizer.verifyStaging(listing, name: "F", snapshot: lost) }
        var resized = snapshot
        resized.files["F/b"] = .init(size: 6, crc: 0, isSymlink: false)
        #expect(throws: OptimizerError.self) { try ArchiveOptimizer.verifyStaging(listing, name: "F", snapshot: resized) }
        #expect(throws: OptimizerError.self) {
            try FolderStage.rejectCollisions({ var l = FolderStage.Listing(); l.entries = [entry("Ab", .file), entry("aB", .file)]; return l }())
        }
    }

    @Test func aFileLockedInFinderDoesNotStopCleanUp() async throws {
        let dir = try TestSupport.makeTempDir("folder-uchg")
        defer {
            _ = try? TestSupport.runSystem("/usr/bin/chflags", ["-R", "nouchg", dir.path])
            try? FileManager.default.removeItem(at: dir)
        }
        let (folder, _) = try makeFolder(named: "Locked", in: dir)
        let locked = folder.appendingPathComponent("docs/part0.txt")
        #expect(try TestSupport.runSystem("/usr/bin/chflags", ["uchg", locked.path]) == 0)
        let temp = dir.appendingPathComponent("tmp")
        let result = try await optimizer(temp: temp, mode: .fast).optimize(folder) { _ in }
        #expect(result.outcome == .optimized)
        #expect(TestSupport.entries(in: temp).isEmpty)

        // A work folder that a crash left behind with a locked file is swept as well.
        let stale = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try write("x/y.txt", Data("x".utf8), in: stale)
        #expect(try TestSupport.runSystem("/usr/bin/chflags", ["uchg", stale.appendingPathComponent("x/y.txt").path]) == 0)
        FileTree.forceRemove(stale)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func replaceOriginalWritesNextToTheFolderNotToTheOutputDirectory() async throws {
        let dir = try TestSupport.makeTempDir("folder-replace-out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (folder, _) = try makeFolder(named: "Here", in: dir)
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp"), mode: .fast) {
            $0.outputMode = .replaceOriginal
            $0.outputDirectory = dir.appendingPathComponent("elsewhere")
        }.optimize(folder) { _ in }
        #expect(result.outputURL == dir.appendingPathComponent("Here.7z"))
    }

    @Test func outputInsideTheFolderOrUnwritableIsRefusedBeforeAnyWork() async throws {
        let dir = try TestSupport.makeTempDir("folder-dest")
        defer {
            _ = try? TestSupport.runSystem("/bin/chmod", ["-R", "u+rwx", dir.path])
            try? FileManager.default.removeItem(at: dir)
        }
        let (folder, expected) = try makeFolder(named: "Src", in: dir)
        let temp = dir.appendingPathComponent("tmp")
        for target in [folder.appendingPathComponent("docs"), folder.appendingPathComponent("new/deeper"), folder] {
            let opt = try optimizer(temp: temp, mode: .fast) { $0.outputDirectory = target }
            do {
                _ = try await opt.optimize(folder) { _ in }
                Issue.record("output inside the folder must be refused")
            } catch OptimizerError.folderProblem(let message) {
                #expect(message.contains("inside the folder"))
            }
        }
        #expect(TestSupport.entries(in: temp).isEmpty)   // refused before anything was staged
        #expect(try TestSupport.fingerprint(folder) == expected)

        let readOnly = dir.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        chmod(readOnly.path, 0o555)
        let opt = try optimizer(temp: temp, mode: .fast) { $0.outputDirectory = readOnly.appendingPathComponent("sub") }
        do {
            _ = try await opt.optimize(folder) { _ in }
            Issue.record("an unwritable destination must be refused")
        } catch OptimizerError.folderProblem(let message) {
            #expect(message.contains("Cannot write"))
        }
        #expect(TestSupport.entries(in: temp).isEmpty)   // refused before anything was staged
    }

    @Test func smartReportsDeterminateProgressFromTheStart() async throws {
        let dir = try TestSupport.makeTempDir("smart-progress")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (folder, _) = try makeFolder(named: "P", in: dir)
        let log = TestSupport.EventLog()
        _ = try await optimizer(temp: dir.appendingPathComponent("tmp")).optimize(folder, progress: log.add)
        let first = try #require(log.progress.first)
        #expect(first.0 == 0 && first.1 >= 1)
    }
}
