import Foundation
import Testing
@testable import Squeeze7zCore

/// Regression tests for the second review round: path traversal, special files, leftover temp files and
/// functional containers.
@Suite struct Round2Tests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    private func optimizer(temp: URL, mode: OptimizationMode = .normal,
                           configure: (inout OptimizerSettings) -> Void = { _ in }) throws -> ArchiveOptimizer {
        var s = OptimizerSettings()
        s.mode = mode
        s.concurrentTrials = 2
        configure(&s)
        return ArchiveOptimizer(tool: try TestSupport.tool(), settings: s, temporaryDirectory: temp)
    }

    /// Runs a Python helper (isolated mode) that writes the fixture archive.
    private func python(_ code: String, in dir: URL, arguments: [String]) throws {
        let script = dir.appendingPathComponent("mk-\(UUID().uuidString).py")
        try Data(code.utf8).write(to: script)
        #expect(try TestSupport.runSystem("/usr/bin/python3", ["-I", script.path] + arguments) == 0)
    }

    /// An archive with a victim file outside the temp root and a symlink entry whose name climbs out
    /// of the extraction folder and lands on the victim (or its directory).
    private func makeTraversalArchive(type: String, dir: URL, victim: String) throws -> URL {
        let source = dir.appendingPathComponent("evil.\(type)")
        let code = """
        import io, sys, tarfile, zipfile
        out, kind, victim = sys.argv[1], sys.argv[2], sys.argv[3]
        name = "sub/" + "../" * 40 + victim.lstrip("/")
        payload = b"hello world " * 3000
        if kind == "tar":
            with tarfile.open(out, "w") as t:
                info = tarfile.TarInfo("ok.txt"); info.size = len(payload)
                t.addfile(info, io.BytesIO(payload))
                link = tarfile.TarInfo(name); link.type = tarfile.SYMTYPE; link.linkname = "/etc/hosts"
                t.addfile(link)
        else:
            with zipfile.ZipFile(out, "w") as z:
                z.writestr("ok.txt", payload)
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (0o120777 << 16)
                z.writestr(info, "/etc/hosts")
        """
        try python(code, in: dir, arguments: [source.path, type, victim])
        return source
    }

    @Test(arguments: ["tar", "zip"])
    func traversalSymlinkEntryIsRejectedAndNothingOutsideIsTouched(type: String) async throws {
        let dir = try TestSupport.makeTempDir("traversal")
        defer { try? FileManager.default.removeItem(at: dir) }
        let victimDir = dir.appendingPathComponent("victimdir/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: victimDir, withIntermediateDirectories: true)
        let victim = victimDir.appendingPathComponent("data.txt")
        try Data("precious".utf8).write(to: victim)
        // Target both a file and a whole directory.
        for target in [victim.path, dir.appendingPathComponent("victimdir").path] {
            let source = try makeTraversalArchive(type: type, dir: dir, victim: target)
            let temp = dir.appendingPathComponent("tmp")
            do {
                _ = try await optimizer(temp: temp).optimize(source) { _ in }
                Issue.record("expected the archive to be refused")
            } catch OptimizerError.notAnArchive(let reason) {
                #expect(reason.contains(".."))
            }
            #expect(TestSupport.entries(in: temp).isEmpty)
            #expect(try String(contentsOf: victim, encoding: .utf8) == "precious")
            var st = stat()
            #expect(lstat(dir.appendingPathComponent("victimdir").path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR)
        }
    }

    @Test func restoreSymlinksRefusesToLeaveTheRootEvenWithoutThePreCheck() async throws {
        let dir = try TestSupport.makeTempDir("traversal-direct")
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("victim.txt")
        try Data("precious".utf8).write(to: victim)
        let source = try makeTraversalArchive(type: "tar", dir: dir, victim: victim.path)
        let tool = try TestSupport.tool()
        let listing = try await tool.list(source)
        #expect(throws: OptimizerError.self) { try SourceChecks.ensureSafe(listing) }
        // Bypass ensureSafe: the extraction step must still refuse and leave the victim alone.
        do {
            try await tool.extract(source, listing: listing, to: dir.appendingPathComponent("root/x"))
            Issue.record("expected extraction to refuse the entry")
        } catch is OptimizerError {}
        #expect(try String(contentsOf: victim, encoding: .utf8) == "precious")
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func linkLocationRefusesSymlinkedParentsAndNeverDeletesDirectories() throws {
        let dir = try TestSupport.makeTempDir("linkloc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("root", isDirectory: true)
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path,
                                                   withDestinationPath: outside.path)
        #expect(throws: OptimizerError.self) {
            _ = try SourceChecks.prepareLinkLocation(components: ["escape", "l"], root: root)
        }
        let url = try SourceChecks.prepareLinkLocation(components: ["a", "b", "l"], root: root)
        #expect(url.path.hasSuffix("/root/a/b/l"))
        var st = stat()
        #expect(lstat(root.appendingPathComponent("a/b").path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR)
    }

    @Test func parentComponentsAreRejectedByEnsureSafe() throws {
        func listing(_ paths: [String]) -> ArchiveListing {
            ArchiveListing(archivePath: "x", format: "tar", physicalSize: 1, isSolid: false, methods: nil,
                           entries: paths.map { ArchiveEntry(path: $0, size: 1) })
        }
        #expect(throws: OptimizerError.self) { try SourceChecks.ensureSafe(listing(["a/../../b"])) }
        #expect(throws: OptimizerError.self) { try SourceChecks.ensureSafe(listing([".."])) }
        try SourceChecks.ensureSafe(listing(["a/b..c", "...", "a/..x/y", "a/b"]))
    }

    // MARK: Special files

    @Test func listingMarksFifoAndDeviceEntries() throws {
        #expect(ListingParser.hasSpecialMode("prw-r--r--"))
        #expect(ListingParser.hasSpecialMode("crw-rw-rw-"))
        #expect(ListingParser.hasSpecialMode("brw-------"))
        #expect(ListingParser.hasSpecialMode("srwxrwxrwx"))
        #expect(ListingParser.hasSpecialMode("D prw-r--r--"))
        #expect(!ListingParser.hasSpecialMode("-rw-r--r--"))
        #expect(!ListingParser.hasSpecialMode("drwxr-xr-x"))
        #expect(!ListingParser.hasSpecialMode("lrwxrwxrwx"))
        #expect(!ListingParser.hasSpecialMode("A"))
        let entry = ListingParser.makeEntry(["Path": "pipe", "Size": "0", "Mode": "prw-r--r--"])
        #expect(entry?.isSpecialFile == true)
        let plain = ListingParser.makeEntry(["Path": "a.txt", "Size": "3", "Mode": "-rw-r--r--"])
        #expect(plain?.isSpecialFile == false)
    }

    @Test func archiveWithFifoAndDeviceIsRefusedAndNeverReplaced() async throws {
        let dir = try TestSupport.makeTempDir("fifo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("rootfs.tar")
        try python("""
        import io, sys, tarfile
        with tarfile.open(sys.argv[1], "w") as t:
            data = b"hello world " * 3000
            info = tarfile.TarInfo("a.txt"); info.size = len(data)
            t.addfile(info, io.BytesIO(data))
            fifo = tarfile.TarInfo("pipe"); fifo.type = tarfile.FIFOTYPE; t.addfile(fifo)
            dev = tarfile.TarInfo("dev"); dev.type = tarfile.CHRTYPE; dev.devmajor = 1; dev.devminor = 3; t.addfile(dev)
        """, in: dir, arguments: [source.path])
        let temp = dir.appendingPathComponent("tmp")
        var opt = try optimizer(temp: temp) { $0.outputMode = .replaceOriginal }
        let trashed = Counter()
        opt.trash = { _ in _ = trashed.next() }
        do {
            _ = try await opt.optimize(source) { _ in }
            Issue.record("expected the archive to be refused")
        } catch OptimizerError.notAnArchive(let reason) {
            #expect(reason.contains("FIFO"))
        }
        #expect(trashed.next() == 1, "the source must not be trashed")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(TestSupport.entries(in: dir).filter { $0.hasSuffix(".7z") }.isEmpty)
        #expect(TestSupport.entries(in: temp).isEmpty)
    }

    // MARK: Leftover temporary files

    @Test func sweepRemovesOnlyDirectoriesOfDeadProcesses() throws {
        let dir = try TestSupport.makeTempDir("sweep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        func job(_ name: String, owner: String?) throws {
            let d = dir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d.appendingPathComponent("x"), withIntermediateDirectories: true)
            try Data("data".utf8).write(to: d.appendingPathComponent("x/f"))
            if let owner { try Data((owner + "\n").utf8).write(to: d.appendingPathComponent(ActiveWork.ownerFileName)) }
        }
        // A pid that is certainly gone: a child that already exited.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        try job("dead", owner: String(child.processIdentifier))
        try job("alive", owner: String(getpid()))
        try job("kept-for-debugging", owner: nil)
        try job("garbage-marker", owner: "not a pid")
        #expect(ActiveWork.sweep(root: dir) == 1)
        #expect(TestSupport.entries(in: dir) == ["alive", "garbage-marker", "kept-for-debugging"])
    }

    @Test func runLeavesNoMarkerOrDirectoryAndSweepApiIsSafeToCall() async throws {
        let dir = try TestSupport.makeTempDir("sweep-run")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try TestSupport.textBytes(15_000).write(to: tree.appendingPathComponent("a.txt"))
        let source = dir.appendingPathComponent("a.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        let temp = dir.appendingPathComponent("tmp")
        // A leftover of a crashed run.
        let stale = temp.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("2147483646\n".utf8).write(to: stale.appendingPathComponent(ActiveWork.ownerFileName))
        let opt = try optimizer(temp: temp, mode: .fast) { $0.outputDirectory = dir.appendingPathComponent("out") }
        #expect(opt.sweepStaleTemporaryFiles() == 1)
        _ = try await opt.optimize(source) { _ in }
        #expect(TestSupport.entries(in: temp).isEmpty)
    }

    @Test func keptTempDirectoryHasNoOwnerMarker() async throws {
        let dir = try TestSupport.makeTempDir("keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try TestSupport.textBytes(15_000).write(to: tree.appendingPathComponent("a.txt"))
        let source = dir.appendingPathComponent("a.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        let temp = dir.appendingPathComponent("tmp")
        let opt = try optimizer(temp: temp, mode: .fast) {
            $0.keepTempFiles = true
            $0.outputDirectory = dir.appendingPathComponent("out")
        }
        _ = try await opt.optimize(source) { _ in }
        #expect(opt.sweepStaleTemporaryFiles() == 0)
        let kept = TestSupport.entries(in: temp)
        #expect(kept.count == 1)
    }

    // MARK: Functional containers

    @Test func functionalContainersAreClassified() {
        for name in ["a.jar", "a.APK", "b.cbz", "c.dmg", "d.iso", "e.deb", "f.rpm", "g.wim"] {
            let url = URL(fileURLWithPath: "/x/\(name)")
            #expect(ArchiveOptimizer.isSupportedArchive(url), "\(name)")
            #expect(ArchiveOptimizer.isFunctionalContainer(url), "\(name)")
            #expect(!ArchiveOptimizer.isPlainArchive(url), "\(name)")
        }
        for name in ["a.7z", "a.zip", "a.rar", "a.tar.gz", "a.tgz", "a.cab", "a.7z.001", "a.part1.rar", "a.cpio"] {
            let url = URL(fileURLWithPath: "/x/\(name)")
            #expect(ArchiveOptimizer.isPlainArchive(url), "\(name)")
        }
        #expect(!ArchiveOptimizer.isPlainArchive(URL(fileURLWithPath: "/x/a.txt")))
    }

    @Test func replaceOriginalNeverTrashesAJar() async throws {
        let dir = try TestSupport.makeTempDir("jar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try TestSupport.textBytes(20_000).write(to: tree.appendingPathComponent("META-INF/MANIFEST.MF"))
        try TestSupport.textBytes(20_000, seed: 4).write(to: tree.appendingPathComponent("Main.class"))
        let source = dir.appendingPathComponent("app.jar")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        var opt = try optimizer(temp: dir.appendingPathComponent("tmp"), mode: .fast) { $0.outputMode = .replaceOriginal }
        let trashed = Counter()
        opt.trash = { _ in _ = trashed.next() }
        let result = try await opt.optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        #expect(result.outputURL?.lastPathComponent == "app_optimized.7z")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(trashed.next() == 1)
    }
}
