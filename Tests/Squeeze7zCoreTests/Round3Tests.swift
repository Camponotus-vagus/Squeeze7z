import Foundation
import Testing
@testable import Squeeze7zCore

/// Regression tests for the third review round: compatibility of filters, listing robustness,
/// sampling, disk images and directory modes.
@Suite struct Round3Tests {
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

    // MARK: 1. Modern filters

    @Test func modernFiltersAreOnByDefaultAndOldSettingsStillDecode() throws {
        #expect(OptimizerSettings().allowModernFilters)
        #expect(OptimizerSettings().mode == .smart)
        let old = Data(#"{"mode":"good","lzmaDictionaryMB":64}"#.utf8)
        let decoded = try JSONDecoder().decode(OptimizerSettings.self, from: old)
        #expect(decoded.mode == .good)
        #expect(decoded.lzmaDictionaryMB == 64)
        #expect(decoded.allowModernFilters)
        let stored = try JSONDecoder().decode(OptimizerSettings.self, from: Data(#"{"allowModernFilters":false}"#.utf8))
        #expect(!stored.allowModernFilters)
        #expect(decoded.parallelJobs == OptimizerSettings().parallelJobs)
        #expect(try JSONDecoder().decode(OptimizerSettings.self, from: Data("{}".utf8)) == OptimizerSettings())
        var on = OptimizerSettings()
        on.allowModernFilters = false
        on.noPPMdAboveMB = 7
        on.outputDirectory = URL(fileURLWithPath: "/tmp/x")
        let back = try JSONDecoder().decode(OptimizerSettings.self, from: JSONEncoder().encode(on))
        #expect(back == on)
    }

    @Test(arguments: OptimizationMode.allCases)
    func candidatesSkipModernFiltersUnlessAllowed(mode: OptimizationMode) {
        var group = FileGroup(id: "cat:executable", category: .executable, extensions: [], files: ["a"], totalBytes: 3_000_000)
        group.executableArchitectures = [.arm64, .x86, .riscv, .arm]
        func chains(allow: Bool) -> [String] {
            var s = OptimizerSettings()
            s.mode = mode
            s.allowModernFilters = allow
            return CandidateGenerator.candidates(for: group, settings: s, isSingleExtensionArchive: false)
                .flatMap(\.coders).map { $0.split(separator: ":")[0].uppercased() }
        }
        let off = Set(chains(allow: false))
        #expect(!off.contains("ARM64") && !off.contains("RISCV"))
        if mode.runsTrials {
            #expect(off.contains("BCJ"))
            #expect(off.contains("ARM"))
            let on = Set(chains(allow: true))
            #expect(on.contains("ARM64") && on.contains("RISCV"))
        }
    }

    /// A thin arm64 Mach-O copy of /bin/ls: 7zz picks the ARM64 filter for it on its own.
    private func makeArm64Binary(at url: URL) throws {
        for arch in ["arm64e", "arm64"] {
            try? FileManager.default.removeItem(at: url)
            if try TestSupport.runSystem("/usr/bin/lipo", ["/bin/ls", "-thin", arch, "-output", url.path]) == 0 { return }
        }
        throw OptimizerError.notAnArchive("no arm64 slice in /bin/ls")
    }

    private func usesModern(_ archive: URL) async throws -> Bool {
        Job.usesModernFilter(try await TestSupport.tool().list(archive))
    }

    @Test(arguments: [OptimizationMode.fast, .smart, .good, .ultra])
    func outputHasNoArm64FilterWhenModernFiltersAreOff(mode: OptimizationMode) async throws {
        let (dir, tree) = try makeWorkspace("modern-off")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeArm64Binary(at: tree.appendingPathComponent("tool_arm64"))
        try write("notes.txt", TestSupport.textBytes(20_000), in: tree)
        let source = dir.appendingPathComponent("in.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp"), mode: mode) {
            $0.outputDirectory = dir.appendingPathComponent("out")
            $0.allowModernFilters = false
        }.optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        let output = try #require(result.outputURL)
        #expect(try await !usesModern(output))
    }

    @Test(arguments: [OptimizationMode.fast, .smart])
    func arm64FilterIsUsedByDefault(mode: OptimizationMode) async throws {
        let (dir, tree) = try makeWorkspace("modern-default")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeArm64Binary(at: tree.appendingPathComponent("tool_arm64"))
        let source = dir.appendingPathComponent("in.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp"), mode: mode) {
            $0.outputDirectory = dir.appendingPathComponent("out")
        }.optimize(source) { _ in }
        #expect(try await usesModern(try #require(result.outputURL)))
    }

    @Test func fastModeUsesArm64OnlyWhenAllowed() async throws {
        let (dir, tree) = try makeWorkspace("modern-on")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeArm64Binary(at: tree.appendingPathComponent("tool_arm64"))
        let source = dir.appendingPathComponent("in.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip", extra: ["-mx=0"])
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp"), mode: .fast) {
            $0.outputDirectory = dir.appendingPathComponent("out")
            $0.allowModernFilters = true
        }.optimize(source) { _ in }
        #expect(try await usesModern(try #require(result.outputURL)))
    }

    // MARK: 2. Comments in listings

    @Test func zipWithMultiLineCommentListsOnlyRealEntries() async throws {
        let (dir, tree) = try makeWorkspace("zipcomment")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.txt", TestSupport.textBytes(3000, seed: 1), in: tree)
        try write("b.txt", TestSupport.textBytes(3000, seed: 2), in: tree)
        let comment = "first line\nPath = fake.txt\nSize = 5\nType = 7z\nSolid = +\n----------\nPath = other\n\nCRC = 1234\n}\n\nlast = ok"
        let source = dir.appendingPathComponent("c.zip")
        let script = "cd '\(tree.path)' && printf '%s' '\(comment)' | /usr/bin/zip -z -q '\(source.path)' a.txt b.txt"
        #expect(try TestSupport.runSystem("/bin/sh", ["-c", script]) == 0)
        let listing = try await TestSupport.tool().list(source)
        #expect(listing.format == "zip")
        #expect(listing.entries.map(\.path).sorted() == ["a.txt", "b.txt"])
        #expect(listing.isSolid == false)
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp")) {
            $0.outputDirectory = dir.appendingPathComponent("out")
        }.optimize(source) { _ in }
        #expect(result.outcome == .optimized)
    }

    @Test func parserSkipsBracedCommentsInArchiveAndEntries() throws {
        let text = """
        7-Zip banner
        --
        Path = x.zip
        Type = zip
        Comment =\u{20}
        {
        Type = rar
        Path = fake
        ----------
        }

        ----------
        Path = one.txt
        Size = 3
        Comment =\u{20}
        {
        Path = two.txt
        Size = 99

        }
        CRC = 0000000A

        Path = three.txt
        Size = 4

        """
        let listing = try ListingParser.parse(text, archivePath: "x.zip", fallbackPhysicalSize: 1)
        #expect(listing.format == "zip")
        #expect(listing.entries.map(\.path) == ["one.txt", "three.txt"])
        #expect(listing.entries.first?.crc == 0xA)
        // A comment followed by a nested layer (disk image holding a file system): the inner type wins.
        let nested = "--\nPath = a.dmg\nType = Dmg\nComment =\u{20}\n{\nid: 1\n}\n----\nPath = 4.apfs\n--\nPath = 4.apfs\nType = APFS\nComment =\u{20}\n{\nx: 2\n}\n\n----------\nPath = f.txt\nSize = 2\n"
        let inner = try ListingParser.parse(nested, archivePath: "a.dmg", fallbackPhysicalSize: 1)
        #expect(inner.format == "APFS")
        #expect(inner.entries.map(\.path) == ["f.txt"])
        // Without a closing brace the text is not a block: plain lines are parsed as before.
        let unframed = "--\nType = zip\n\n----------\nPath = q\nComment = \n{\nSize = 4\n"
        #expect(try ListingParser.parse(unframed, archivePath: "q", fallbackPhysicalSize: 1).entries.first?.size == 4)
    }

    @Test func unixPermissionsAreParsedFromAttributes() {
        #expect(ListingParser.unixPermissions("D drwxr-x---") == 0o750)
        #expect(ListingParser.unixPermissions("RD dr-x------") == 0o500)
        #expect(ListingParser.unixPermissions("drwxrwxrwt") == 0o1777)
        #expect(ListingParser.unixPermissions("-rwsr-xr-x") == 0o4755)
        #expect(ListingParser.unixPermissions("-rwxr-sr-x") == 0o2755)
        #expect(ListingParser.unixPermissions("-rwSr--r--") == 0o4644)
        #expect(ListingParser.unixPermissions("....A") == nil)
        #expect(ListingParser.unixPermissions("D") == nil)
    }

    // MARK: 3. Single-stream archives holding a "._" file

    @Test func singleStreamWithDotUnderscoreInnerNameIsAccepted() async throws {
        let (dir, tree) = try makeWorkspace("dotunderscore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = TestSupport.textBytes(20_000, seed: 3)
        try write("._notes.txt", payload, in: tree)
        let source = dir.appendingPathComponent("._notes.txt.gz")
        #expect(try TestSupport.runSystem("/bin/sh", ["-c", "gzip -c '\(tree.path)/._notes.txt' > '\(source.path)'"]) == 0)
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp")) {
            $0.outputDirectory = dir.appendingPathComponent("out")
        }.optimize(source) { _ in }
        #expect(result.outcome == .optimized)
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(try #require(result.outputURL), into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    // MARK: 4. Sampling

    @Test func candidateSetsGrowWithTheMode() {
        let modes = OptimizationMode.allCases.sorted { $0.rank < $1.rank }
        var settingsVariants: [OptimizerSettings] = [OptimizerSettings()]
        var modern = OptimizerSettings(); modern.allowModernFilters = true
        var noPPMd = OptimizerSettings(); noPPMd.disablePPMd = true
        settingsVariants += [modern, noPPMd]
        for category in FileCategory.allCases {
            for bytes in [Int64(10_000), 5 << 20, 100 << 20] {
                for single in [false, true] {
                    var group = FileGroup(id: "g", category: category, extensions: ["x"], files: ["f"], totalBytes: bytes)
                    group.executableArchitectures = category == .executable ? [.x86, .arm64, .arm] : []
                    for base in settingsVariants {
                        var previous: Set<MethodSpec> = []
                        for mode in modes {
                            var s = base
                            s.mode = mode
                            let current = Set(CandidateGenerator.candidates(for: group, settings: s, isSingleExtensionArchive: single))
                            #expect(previous.isSubset(of: current),
                                    "\(category) \(bytes) \(mode): \(previous.subtracting(current))")
                            previous = current
                        }
                    }
                }
            }
        }
    }

    @Test func sampledTrialsAlwaysGetTheWholeArchiveBaseline() async throws {
        let (dir, tree) = try makeWorkspace("sampled-guard")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("big.txt", TestSupport.textBytes(1_400_000, seed: 8), in: tree)
        let source = dir.appendingPathComponent("big.tar")
        try TestSupport.makeArchive(from: tree, at: source, type: "tar")
        func run(sampling: Int) async throws -> (OptimizationResult, [String]) {
            let log = TestSupport.EventLog()
            let result = try await optimizer(temp: dir.appendingPathComponent("tmp-\(sampling)")) {
                $0.outputDirectory = dir.appendingPathComponent("out-\(sampling)")
                $0.samplingLevel = sampling
                $0.disablePPMd = true
            }.optimize(source) { log.add($0) }
            return (result, log.logs)
        }
        let (sampledResult, sampledLogs) = try await run(sampling: 1)
        #expect(sampledLogs.contains { $0.hasPrefix("Baseline") })
        #expect(sampledResult.trialCount == sampledResult.groups.reduce(0) { $0 + $1.trials.count } + 1)
        #expect(sampledResult.groups.allSatisfy { $0.trials.allSatisfy(\.sampled) })
        // Without sampling the baseline is built as well (normal mode included): it is the floor under the groups.
        let (_, fullLogs) = try await run(sampling: 0)
        #expect(fullLogs.contains { $0.hasPrefix("Baseline") })
    }

    // MARK: 5. Disk images with extended attributes

    @Test func apfsImageWithExtendedAttributesIsOptimized() async throws {
        let (dir, tree) = try makeWorkspace("dmg-xattr")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("a.txt", TestSupport.textBytes(2000, seed: 1), in: tree)
        try write("sub/b.txt", TestSupport.textBytes(2000, seed: 2), in: tree)
        #expect(setxattr(tree.appendingPathComponent("a.txt").path, "com.apple.test", "foo", 3, 0, 0) == 0)
        let image = dir.appendingPathComponent("x.dmg")
        let status = try TestSupport.runSystem("/usr/bin/hdiutil",
            ["create", "-quiet", "-srcfolder", tree.path, "-format", "UDZO", "-fs", "APFS", "-volname", "T", image.path])
        guard status == 0 else { return }   // hdiutil unavailable in this environment
        let log = TestSupport.EventLog()
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp")) {
            $0.outputDirectory = dir.appendingPathComponent("out")
        }.optimize(image) { log.add($0) }
        #expect(result.outcome == .optimized)
        #expect(log.logs.contains { $0.contains("Extended attributes") })
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(try #require(result.outputURL), into: extracted)
        let names = try TestSupport.allPaths(extracted)
        #expect(names == ["a.txt", "sub", "sub/b.txt"])
    }

    // MARK: 6. Directory modes

    @Test func directoryModesComeFromTheSourceListing() async throws {
        let (dir, tree) = try makeWorkspace("dirmodes")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("ro/inner/a.txt", TestSupport.textBytes(5000, seed: 1), in: tree)
        try write("ro/b.txt", TestSupport.textBytes(5000, seed: 2), in: tree)
        try write("search/c.txt", TestSupport.textBytes(5000, seed: 3), in: tree)
        try write("open/d.txt", TestSupport.textBytes(5000, seed: 4), in: tree)
        defer { FileTree.forceRemove(tree) }
        // Deepest first, so that a read-only parent never blocks us.
        for (rel, mode) in [("ro/inner", 0o500), ("ro", 0o555), ("search", 0o710), ("open", 0o775)] as [(String, mode_t)] {
            #expect(chmod(tree.appendingPathComponent(rel).path, mode) == 0)
        }
        let source = dir.appendingPathComponent("modes.tar")
        try TestSupport.runSystem("/usr/bin/tar", ["--no-mac-metadata", "-cf", source.path, "-C", tree.path, "ro", "search", "open"])
        let result = try await optimizer(temp: dir.appendingPathComponent("tmp")) {
            $0.outputDirectory = dir.appendingPathComponent("out")
        }.optimize(source) { _ in }
        let listing = try await TestSupport.tool().list(try #require(result.outputURL))
        var modes: [String: UInt16] = [:]
        for entry in listing.entries where entry.isDirectory { modes[entry.path] = entry.unixMode }
        #expect(modes == ["ro": 0o555, "ro/inner": 0o500, "search": 0o710, "open": 0o775])
    }

    @Test func listedModeWinsOverWidenedDiskMode() {
        var snapshot = TreeSnapshot()
        snapshot.directories = ["a": .init(mode: 0o700, mtimeSeconds: 5, mtimeNanoseconds: 0),
                                "b": .init(mode: 0o700, mtimeSeconds: 6, mtimeNanoseconds: 0),
                                "c": .init(mode: 0o755, mtimeSeconds: 7, mtimeNanoseconds: 0)]
        var a = ArchiveEntry(path: "a", size: 0, isDirectory: true); a.unixMode = 0o500
        var b = ArchiveEntry(path: "b/", size: 0, isDirectory: true); b.unixMode = 0o000   // unreadable: stays as extracted
        let c = ArchiveEntry(path: "c", size: 0, isDirectory: true)                         // no mode in the listing
        snapshot.adoptDirectoryModes(from: ArchiveListing(archivePath: "x", format: "7z", physicalSize: 1,
                                                          isSolid: false, methods: nil, entries: [a, b, c]))
        #expect(snapshot.directories["a"]?.mode == 0o500)
        #expect(snapshot.directories["b"]?.mode == 0o700)
        #expect(snapshot.directories["c"]?.mode == 0o755)
        #expect(snapshot.directories["a"]?.mtimeSeconds == 5)
    }
}
