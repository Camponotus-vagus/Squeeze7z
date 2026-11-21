import Foundation
import Testing
@testable import Squeeze7zCore

@Suite struct EndToEndTests {
    /// Builds the mixed tree and returns (workspace, tree).
    func workspace() throws -> (URL, URL) {
        let dir = try TestSupport.makeTempDir("e2e")
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try TestSupport.makeMixedTree(at: tree)
        return (dir, tree)
    }

    func optimizer(mode: OptimizationMode, temp: URL, configure: (inout OptimizerSettings) -> Void = { _ in }) throws -> ArchiveOptimizer {
        var s = OptimizerSettings()
        s.mode = mode
        s.concurrentTrials = 2
        configure(&s)
        return ArchiveOptimizer(tool: try TestSupport.tool(), settings: s, temporaryDirectory: temp)
    }

    @Test(arguments: ["zip", "7z"])
    func optimizesMixedArchive(type: String) async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("input.\(type)")
        try TestSupport.makeArchive(from: tree, at: source, type: type)
        let sourceSize = TestSupport.size(source)
        let out = dir.appendingPathComponent("out")
        let temp = dir.appendingPathComponent("tmp")

        let log = TestSupport.EventLog()
        let result = try await optimizer(mode: .good, temp: temp) { $0.outputDirectory = out }
            .optimize(source) { log.add($0) }

        #expect(result.outcome == .optimized)
        #expect(result.sourceFormat == type)
        #expect(result.originalBytes == sourceSize)
        let output = try #require(result.outputURL)
        #expect(output.lastPathComponent == "input_optimized.7z" && output.deletingLastPathComponent().lastPathComponent == "out")
        #expect(TestSupport.size(output) == result.optimizedBytes && result.optimizedBytes < sourceSize)
        #expect(result.savedBytes == sourceSize - result.optimizedBytes)
        #expect(TestSupport.size(source) == sourceSize)   // source untouched
        #expect(result.trialCount > 10)

        // Extracts to exactly the original tree (files, symlink, empty dirs).
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))

        // Beats `7zz a -mx9` over the same tree.
        let reference = try TestSupport.referenceSize(of: tree, in: dir)
        #expect(result.optimizedBytes <= reference, "optimized \(result.optimizedBytes) vs -mx9 \(reference)")

        // Different groups really got different coder chains, and the archive is solid per group.
        let listing = try await TestSupport.tool().list(output)
        let methods = Set(listing.entries.filter { !$0.isDirectory }.compactMap(\.method))
        #expect(methods.count >= 4, "methods: \(methods)")
        #expect(methods.contains { $0.contains("PPMD") })
        #expect(methods.contains("Copy"))
        let methodOf = { (path: String) in listing.entries.first { $0.path == path }?.method }
        #expect(methodOf("img/photo.jpg") == "Copy")
        #expect(methodOf("docs/note0.txt") != methodOf("rand/blob.bin"))

        // Winner table: one report per group, every group assembled with its winner.
        let jpg = try #require(result.groups.first { $0.group.id == "ext:jpg" })
        #expect(jpg.winner == .copy)
        let txt = try #require(result.groups.first { $0.group.id == "ext:txt" })
        #expect(txt.winner.description.hasPrefix("PPMd") && txt.trials.count >= 3)
        #expect(txt.trials.contains { $0.method == txt.winner })
        let exe = try #require(result.groups.first { $0.group.category == .executable })
        #expect(!exe.group.executableArchitectures.isEmpty)
        #expect(result.groups.flatMap { $0.group.files }.count == 11)   // the symlink is not part of any group

        // Events
        let phases = log.phases
        #expect(phases.first == .inspecting && phases.last == .finishing)
        for p in [OptimizationPhase.extracting, .grouping, .trials, .assembling, .baseline, .verifying] { #expect(phases.contains(p)) }
        let progress = log.progress
        #expect(progress.last.map { $0.0 == $0.1 } == true)
        #expect(progress.map(\.0) == progress.map(\.0).sorted())

        // Temp dir is gone.
        #expect(TestSupport.entries(in: temp).isEmpty)
    }

    @Test func fastModeUsesOneSolidLZMA2Archive() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("input.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        let result = try await optimizer(mode: .fast, temp: dir.appendingPathComponent("tmp")).optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        #expect(result.strategy.hasPrefix("whole-archive LZMA2"))
        #expect(result.trialCount == 1)
        let output = try #require(result.outputURL)
        #expect(output.deletingLastPathComponent() == source.deletingLastPathComponent())
        let listing = try await TestSupport.tool().list(output)
        #expect(listing.isSolid)
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    @Test func higherModesAndSamplingStillRoundTrip() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A group bigger than the 5 MB sample budget so that sampled trials are exercised.
        try TestSupport.textBytes(1_100_000, seed: 99).write(to: tree.appendingPathComponent("docs/big.txt"))
        let source = dir.appendingPathComponent("input.7z")
        try TestSupport.makeArchive(from: tree, at: source, type: "7z", extra: ["-mx=1"])
        let result = try await optimizer(mode: .best, temp: dir.appendingPathComponent("tmp")) {
            $0.samplingLevel = 1
            $0.solidBlockSizeMB = 64
            $0.concurrentTrials = 3
        }.optimize(source) { _ in }
        let txt = try #require(result.groups.first { $0.group.id == "ext:txt" })
        #expect(txt.group.totalBytes > 5 << 20)
        #expect(txt.trials.allSatisfy { $0.sampled })
        let jpg = try #require(result.groups.first { $0.group.id == "ext:jpg" })
        #expect(jpg.trials.allSatisfy { !$0.sampled })
        let output = try #require(result.outputURL)
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    @Test func tarGzIsUnpackedTwice() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tar = dir.appendingPathComponent("bundle.tar")
        try TestSupport.makeArchive(from: tree, at: tar, type: "tar")
        let gz = dir.appendingPathComponent("bundle.tar.gz")
        #expect(try TestSupport.run7zz(["a", "-tgzip", "-y", "-bb0", "-bsp0", gz.path, tar.path]) == 0)
        try FileManager.default.removeItem(at: tar)
        let result = try await optimizer(mode: .normal, temp: dir.appendingPathComponent("tmp")).optimize(gz) { _ in }
        #expect(result.outcome == .optimized)
        let output = try #require(result.outputURL)
        #expect(output.lastPathComponent == "bundle_optimized.7z")
        let listing = try await TestSupport.tool().list(output)
        #expect(listing.entries.contains { $0.path == "docs/note0.txt" })   // inner files, not "bundle.tar"
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    @Test func plainGzipIsOptimizedAsOneFile() async throws {
        let dir = try TestSupport.makeTempDir("gz")
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("notes.txt")
        try TestSupport.textBytes(200_000, seed: 3).write(to: text)
        let gz = dir.appendingPathComponent("notes.txt.gz")
        #expect(try TestSupport.run7zz(["a", "-tgzip", "-y", "-bb0", "-bsp0", gz.path, text.path]) == 0)
        let result = try await optimizer(mode: .normal, temp: dir.appendingPathComponent("tmp")).optimize(gz) { _ in }
        #expect(result.outcome == .optimized)
        let output = try #require(result.outputURL)
        #expect(output.lastPathComponent == "notes.txt_optimized.7z")
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try Data(contentsOf: extracted.appendingPathComponent("notes.txt")) == Data(contentsOf: text))
    }

    @Test func absoluteAndUpwardSymlinksSurvive() async throws {
        let dir = try TestSupport.makeTempDir("links")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try TestSupport.textBytes(30_000).write(to: tree.appendingPathComponent("sub/a.txt"))
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("abs").path, withDestinationPath: "/etc/hosts")
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("sub/up").path, withDestinationPath: "../../outside")
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("dirlink").path, withDestinationPath: "sub")
        let source = dir.appendingPathComponent("links.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        let result = try await optimizer(mode: .normal, temp: dir.appendingPathComponent("tmp")).optimize(source) { _ in }
        let output = try #require(result.outputURL)
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        // 7zz itself re-roots absolute link targets when extracting, so judge "abs" from the listing.
        var got = try TestSupport.fingerprint(extracted)
        var want = try TestSupport.fingerprint(tree)
        got["abs"] = nil
        want["abs"] = nil
        #expect(got == want)
        let listing = try await TestSupport.tool().list(output)
        let abs = try #require(listing.entries.first { $0.path == "abs" })
        #expect(abs.isSymlink && abs.size == 10 && abs.crc == CRC32.checksum(Data("/etc/hosts".utf8)))
    }

    @Test func unicodeAndAwkwardNames() async throws {
        let dir = try TestSupport.makeTempDir("names")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        let fm = FileManager.default
        for rel in ["-dash/-file.txt", "@at.txt", "we ird[1]*.txt", "caffè ☃/Ünï.txt", "emoji 🐜.txt"] {
            let url = tree.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TestSupport.textBytes(5_000, seed: UInt64(rel.count)).write(to: url)
        }
        let source = dir.appendingPathComponent("odd.7z")
        try TestSupport.makeArchive(from: tree, at: source, type: "7z", extra: ["-mx=1"])
        let result = try await optimizer(mode: .good, temp: dir.appendingPathComponent("tmp")).optimize(source) { _ in }
        let output = try #require(result.outputURL)
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    // MARK: Decisions

    @Test func noGainLeavesEverythingUntouched() async throws {
        let dir = try TestSupport.makeTempDir("nogain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try TestSupport.randomBytes(300_000, seed: 11).write(to: tree.appendingPathComponent("noise.bin"))
        // Same switches as the optimizer's own output, so the best possible result is the same size.
        let source = dir.appendingPathComponent("noise.7z")
        try TestSupport.makeArchive(from: tree, at: source, type: "7z",
                                    extra: ["-m0=Copy", "-ms=on", "-mhc=on", "-mtm=on", "-mtc=off", "-mta=off"])
        let before = try Data(contentsOf: source)
        let temp = dir.appendingPathComponent("tmp")
        let result = try await optimizer(mode: .good, temp: temp).optimize(source) { _ in }
        #expect(result.outcome == .noGain)
        #expect(result.outputURL == nil)
        #expect(result.savedBytes == 0)
        #expect(result.optimizedBytes >= result.originalBytes)
        #expect(try Data(contentsOf: source) == before)
        #expect(TestSupport.entries(in: dir).sorted() == ["noise.7z", "tmp", "tree"])
        #expect(TestSupport.entries(in: temp).isEmpty)
    }

    @Test func outputNamesDoNotOverwrite() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("again.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        let opt = try optimizer(mode: .normal, temp: dir.appendingPathComponent("tmp"))
        let first = try #require(try await opt.optimize(source) { _ in }.outputURL)
        let second = try #require(try await opt.optimize(source) { _ in }.outputURL)
        let third = try #require(try await opt.optimize(source) { _ in }.outputURL)
        #expect([first, second, third].map(\.lastPathComponent) == ["again_optimized.7z", "again_optimized-2.7z", "again_optimized-3.7z"])
    }

    @Test func outputKeepsSourceModificationDate() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("dated.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: source.path)
        let output = try #require(try await optimizer(mode: .fast, temp: dir.appendingPathComponent("tmp")).optimize(source) { _ in }.outputURL)
        let date = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date)
        #expect(abs(date.timeIntervalSince(stamp)) < 1)
    }

    @Test func replaceOriginalTrashesTheSource() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("replace.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        let fakeTrash = dir.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        var opt = try optimizer(mode: .fast, temp: dir.appendingPathComponent("tmp")) { $0.outputMode = .replaceOriginal }
        opt.trash = { url in try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent)) }
        let result = try await opt.optimize(source) { _ in }
        let output = try #require(result.outputURL)
        #expect(output.lastPathComponent == "replace.7z")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(TestSupport.entries(in: fakeTrash) == ["replace.zip"])
        #expect(TestSupport.entries(in: dir).contains { $0.hasSuffix("partial") } == false)
    }

    @Test func replaceOriginalTrashesEveryVolume() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("split.7z")
        try TestSupport.makeArchive(from: tree, at: archive, type: "7z", extra: ["-mx=1", "-v100k"])
        let volumes = TestSupport.entries(in: dir).filter { $0.hasPrefix("split.7z.") }
        #expect(volumes.count > 2)
        let first = dir.appendingPathComponent("split.7z.001")
        let fakeTrash = dir.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        var opt = try optimizer(mode: .normal, temp: dir.appendingPathComponent("tmp")) { $0.outputMode = .replaceOriginal }
        opt.trash = { url in try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent)) }
        let result = try await opt.optimize(first) { _ in }
        #expect(result.originalBytes == volumes.reduce(Int64(0)) { $0 + TestSupport.size(fakeTrash.appendingPathComponent($1)) })
        #expect(TestSupport.entries(in: fakeTrash) == volumes)
        let output = try #require(result.outputURL)
        #expect(output.lastPathComponent == "split.7z")
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    @Test func keepTempFilesKeepsTheWorkDirectory() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("keep.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        let temp = dir.appendingPathComponent("tmp")
        _ = try await optimizer(mode: .fast, temp: temp) { $0.keepTempFiles = true }.optimize(source) { _ in }
        #expect(TestSupport.entries(in: temp).count == 1)
    }

    // MARK: Failure paths

    @Test func missingAndInvalidInputs() async throws {
        let dir = try TestSupport.makeTempDir("bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let opt = try optimizer(mode: .fast, temp: dir.appendingPathComponent("tmp"))
        await #expect(throws: OptimizerError.self) { try await opt.optimize(dir.appendingPathComponent("nope.7z")) { _ in } }
        let junk = dir.appendingPathComponent("junk.7z")
        try TestSupport.randomBytes(5_000).write(to: junk)
        do {
            _ = try await opt.optimize(junk) { _ in }
            Issue.record("expected an error")
        } catch let e as OptimizerError {
            if case .notAnArchive = e {} else { Issue.record("unexpected \(e)") }
        }
        #expect(TestSupport.entries(in: dir.appendingPathComponent("tmp")).isEmpty)
    }

    @Test func encryptedArchivesAreRejected() async throws {
        let dir = try TestSupport.makeTempDir("enc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try TestSupport.textBytes(2_000).write(to: tree.appendingPathComponent("secret.txt"))
        let opt = try optimizer(mode: .fast, temp: dir.appendingPathComponent("tmp"))
        for (name, type, extra) in [("z.zip", "zip", ["-psecret"]), ("s.7z", "7z", ["-psecret"]), ("h.7z", "7z", ["-psecret", "-mhe=on"])] {
            let archive = dir.appendingPathComponent(name)
            try TestSupport.makeArchive(from: tree, at: archive, type: type, extra: extra)
            await #expect(throws: OptimizerError.encrypted) { try await opt.optimize(archive) { _ in } }
        }
        #expect(TestSupport.entries(in: dir.appendingPathComponent("tmp")).isEmpty)
    }

    @Test func insufficientDiskSpaceIsReported() throws {
        let opt = try optimizer(mode: .fast, temp: FileManager.default.temporaryDirectory.appendingPathComponent("Squeeze7zTests-space"))
        #expect(throws: OptimizerError.self) { try opt.checkDiskSpace(unpacked: Int64.max / 4) }
    }

    /// A stand-in for 7zz that corrupts the CRCs reported when listing archives the optimizer built.
    func makeCorruptingTool(in dir: URL) throws -> SevenZipTool {
        let real = try TestSupport.tool().executableURL.path
        let script = dir.appendingPathComponent("fake7zz")
        let body = """
        #!/bin/bash
        REAL='\(real)'
        if [ "$1" = "l" ] && [[ "$*" == *assembled.7z* || "$*" == *baseline_* ]]; then
          "$REAL" "$@" | sed -E 's/^CRC = [0-9A-F]{8}$/CRC = DEADBEEF/'
          exit ${PIPESTATUS[0]}
        fi
        exec "$REAL" "$@"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return SevenZipTool(executableURL: script)
    }

    @Test func verificationFailureKeepsNothing() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("v.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        let temp = dir.appendingPathComponent("tmp")
        var s = OptimizerSettings()
        s.mode = .normal
        let opt = ArchiveOptimizer(tool: try makeCorruptingTool(in: dir), settings: s, temporaryDirectory: temp)
        do {
            _ = try await opt.optimize(source) { _ in }
            Issue.record("expected a verification failure")
        } catch let e as OptimizerError {
            guard case .verificationFailed = e else { Issue.record("unexpected \(e)"); return }
        }
        #expect(TestSupport.entries(in: dir).filter { $0.contains("optimized") }.isEmpty)
        #expect(TestSupport.entries(in: temp).isEmpty)
        #expect(TestSupport.size(source) > 0)
    }

    @Test func verifierDetectsEveryKindOfMismatch() async throws {
        let dir = try TestSupport.makeTempDir("verify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("d/e"), withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: tree.appendingPathComponent("a.txt"))
        try Data("second".utf8).write(to: tree.appendingPathComponent("d/b.txt"))
        let snapshot = try await TreeScanner.scan(root: tree)
        #expect(snapshot.files.count == 2 && snapshot.emptyDirectories == ["d/e"])
        let archive = dir.appendingPathComponent("a.7z")
        try TestSupport.makeArchive(from: tree, at: archive, type: "7z")
        let listing = try await TestSupport.tool().list(archive)
        try SourceChecks.verifyArchive(listing: listing, snapshot: snapshot)   // matches

        var changedCRC = snapshot
        changedCRC.files["a.txt"]?.crc ^= 1
        #expect(throws: OptimizerError.self) { try SourceChecks.verifyArchive(listing: listing, snapshot: changedCRC) }
        var changedSize = snapshot
        changedSize.files["a.txt"]?.size += 1
        #expect(throws: OptimizerError.self) { try SourceChecks.verifyArchive(listing: listing, snapshot: changedSize) }
        var extra = snapshot
        extra.files["ghost.txt"] = .init(size: 1, crc: 0, isSymlink: false)
        #expect(throws: OptimizerError.self) { try SourceChecks.verifyArchive(listing: listing, snapshot: extra) }
        var missing = snapshot
        missing.files["d/b.txt"] = nil
        #expect(throws: OptimizerError.self) { try SourceChecks.verifyArchive(listing: listing, snapshot: missing) }
        var noDir = snapshot
        noDir.emptyDirectories.append("not/there")
        #expect(throws: OptimizerError.self) { try SourceChecks.verifyArchive(listing: listing, snapshot: noDir) }

        // The same checks guard the extraction against the source listing.
        try SourceChecks.verifyExtraction(listing: listing, snapshot: snapshot)
        #expect(throws: OptimizerError.self) { try SourceChecks.verifyExtraction(listing: listing, snapshot: changedCRC) }
    }

    @Test func cancellationStopsWorkAndCleansUp() async throws {
        let (dir, tree) = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        try TestSupport.textBytes(2_000_000, seed: 8).write(to: tree.appendingPathComponent("docs/huge.txt"))
        let source = dir.appendingPathComponent("slow.7z")
        try TestSupport.makeArchive(from: tree, at: source, type: "7z", extra: ["-mx=1"])
        let temp = dir.appendingPathComponent("tmp")
        let opt = try optimizer(mode: .extreme2, temp: temp)
        let started = TestSupport.EventLog()
        let task = Task { () -> Error? in
            do { _ = try await opt.optimize(source) { started.add($0) }; return nil } catch { return error }
        }
        // Wait until the trials are running, then cancel.
        for _ in 0..<200 where !started.phases.contains(.trials) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(started.phases.contains(.trials))
        let cancelAt = Date()
        task.cancel()
        let error = await task.value
        #expect(error as? OptimizerError == .cancelled)
        #expect(Date().timeIntervalSince(cancelAt) < 10)
        #expect(TestSupport.entries(in: temp).isEmpty)
        #expect(TestSupport.entries(in: dir).filter { $0.contains("optimized") }.isEmpty)
        // No stray 7zz left behind from this run.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        #expect(!text.contains(temp.path))
    }
}
