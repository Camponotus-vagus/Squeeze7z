import Foundation
import Testing
@testable import Squeeze7zCore

// MARK: - Listing parser

@Suite struct ListingParserTests {
    static let sample = """

    7-Zip (z) 26.06 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-11-06

    Scanning the drive for archives:
    1 file, 257 bytes (1 KiB)

    Listing archive: x.7z

    --
    Path = x.7z
    Type = 7z
    Physical Size = 257
    Headers Size = 235
    Method = LZMA2:12
    Solid = +
    Blocks = 1

    ----------
    Path = sub
    Size = 0
    Packed Size = 0
    Modified = 2026-11-20 14:44:32.9853184
    Attributes = D drwxr-xr-x
    CRC =
    Encrypted = -
    Method =
    Block =

    Path = sub/we ird = [1]*.txt
    Size = 3
    Packed Size = 22
    Modified = 2026-11-20 14:40:44
    Attributes = A -rw-r--r--
    CRC = ED6F7A7A
    Encrypted = -
    Method = LZMA2:12
    Block = 0

    Path = link
    Size = 5
    Packed Size =
    Modified = 2026-11-20 14:40:44.8288051
    Attributes = A lrwxr-xr-x
    CRC = C1EBF7BA
    Encrypted = +
    Method = LZMA2:12
    Block = 0

    Path = win.txt
    Size = 10
    Attributes = A
    CRC = 0000000F

    Path = windir
    Size = 0
    Attributes = D

    """

    @Test func parsesArchiveAndEntries() throws {
        let listing = try ListingParser.parse(Self.sample, archivePath: "/tmp/x.7z", fallbackPhysicalSize: 1)
        #expect(listing.format == "7z")
        #expect(listing.physicalSize == 257)
        #expect(listing.isSolid)
        #expect(listing.methods == "LZMA2:12")
        #expect(listing.entries.count == 5)

        let dir = listing.entries[0]
        #expect(dir.path == "sub" && dir.isDirectory && dir.crc == nil && dir.method == nil)

        let file = listing.entries[1]
        #expect(file.path == "sub/we ird = [1]*.txt")
        #expect(!file.isDirectory && !file.isSymlink && !file.isEncrypted)
        #expect(file.size == 3 && file.packedSize == 22 && file.crc == 0xED6F7A7A)
        #expect(file.method == "LZMA2:12")
        #expect(file.modified != nil)

        let link = listing.entries[2]
        #expect(link.isSymlink && !link.isDirectory && link.isEncrypted)
        #expect(link.packedSize == nil)
        #expect(link.modified != nil)

        #expect(listing.entries[3].crc == 0xF && !listing.entries[3].isDirectory)
        #expect(listing.entries[4].isDirectory)
    }

    @Test func rejectsTextWithoutArchiveType() {
        #expect(throws: OptimizerError.self) {
            try ListingParser.parse("nothing useful here\n", archivePath: "/tmp/no.bin", fallbackPhysicalSize: 0)
        }
    }

    @Test func entryWithoutPathAndNestedContainerLayers() throws {
        // .tbz2 lists its single entry without a Path.
        let nameless = "--\nPath = x.tbz2\nType = bzip2\n\n----------\nSize = \nPacked Size = \n\n"
        let a = try ListingParser.parse(nameless, archivePath: "/tmp/x.tbz2", fallbackPhysicalSize: 5)
        #expect(a.format == "bzip2" && a.entries.count == 1 && a.entries[0].path.isEmpty && !a.entries[0].isDirectory)
        // Split volumes wrap the real archive in a second "--" layer; the innermost one is the archive.
        let split = "--\nPath = s.7z.001\nType = Split\nVolumes = 3\n----\nPath = s.7z\nSize = 300\n--\nPath = s.7z\nType = 7z\nPhysical Size = 300\nSolid = +\n\n----------\nPath = f.txt\nSize = 3\nAttributes = A -rw-r--r--\nCRC = 00000001\n\n"
        let b = try ListingParser.parse(split, archivePath: "/tmp/s.7z.001", fallbackPhysicalSize: 1)
        #expect(b.format == "7z" && b.physicalSize == 300 && b.isSolid && b.entries.map(\.path) == ["f.txt"])
    }

    @Test func attributeForms() {
        #expect(ListingParser.parseAttributes("D drwxr-xr-x") == (true, false))
        #expect(ListingParser.parseAttributes("A lrwxr-xr-x") == (false, true))
        #expect(ListingParser.parseAttributes("-rw-r--r--") == (false, false))
        #expect(ListingParser.parseAttributes("....D") == (true, false))
        #expect(ListingParser.parseAttributes("drwxr-xr-x") == (true, false))
    }

    @Test func parsesDates() throws {
        let a = try #require(ListingParser.parseDate("2026-11-20 14:40:44.5"))
        let b = try #require(ListingParser.parseDate("2026-11-20 14:40:44"))
        #expect(abs(a.timeIntervalSince(b) - 0.5) < 0.001)
        #expect(ListingParser.parseDate("garbage") == nil)
    }

    @Test func listsARealArchive() async throws {
        let dir = try TestSupport.makeTempDir("list")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try TestSupport.makeMixedTree(at: tree)
        for type in ["7z", "zip"] {
            let archive = dir.appendingPathComponent("a.\(type)")
            try TestSupport.makeArchive(from: tree, at: archive, type: type)
            let listing = try await TestSupport.tool().list(archive)
            #expect(listing.format == type)
            #expect(listing.entries.contains { $0.path == "empty/nested" && $0.isDirectory })
            #expect(listing.entries.contains { $0.path == "link_note" && $0.isSymlink })
            let wav = try #require(listing.entries.first { $0.path == "audio/tone.wav" })
            #expect(wav.size == TestSupport.size(tree.appendingPathComponent("audio/tone.wav")))
            #expect(wav.crc == (try CRC32.checksum(of: tree.appendingPathComponent("audio/tone.wav"))))
            #expect(!listing.entries.contains { $0.isEncrypted })
        }
    }

    @Test func versionIsReported() async throws {
        let v = try await TestSupport.tool().version
        #expect(v.first?.isNumber == true)
    }
}

// MARK: - Classification and grouping

@Suite struct ClassificationTests {
    @Test func extensionCategories() {
        #expect(FileClassifier.category(forExtension: "TXT") == .text)
        #expect(FileClassifier.category(forExtension: ".swift") == .text)
        #expect(FileClassifier.category(forExtension: "wav") == .audioRaw)
        #expect(FileClassifier.category(forExtension: "bmp") == .imageRaw)
        #expect(FileClassifier.category(forExtension: "dll") == .executable)
        #expect(FileClassifier.category(forExtension: "jpg") == .compressed)
        #expect(FileClassifier.category(forExtension: "docx") == .compressed)
        #expect(FileClassifier.category(forExtension: "sqlite") == .binary)
        #expect(FileClassifier.category(forExtension: "zzzunknown") == .misc)
        // every category has at least one extension
        for c in [FileCategory.text, .binary, .executable, .imageRaw, .audioRaw, .compressed] {
            #expect(["txt", "dat", "exe", "bmp", "wav", "zip"].contains { FileClassifier.category(forExtension: $0) == c })
        }
    }

    @Test func extensionKeys() {
        #expect(FileClassifier.extensionKey(forPath: "a/b/File.TXT") == "txt")
        #expect(FileClassifier.extensionKey(forPath: "a/archive.tar.gz") == "gz")
        #expect(FileClassifier.extensionKey(forPath: "a/.gitignore") == "")
        #expect(FileClassifier.extensionKey(forPath: "a/README") == "")
        #expect(FileClassifier.extensionKey(forPath: "a/Mr. Smith notes") == "")
        #expect(FileClassifier.extensionKey(forPath: "a/trailing.") == "")
    }

    @Test func executableMagic() {
        func macho(_ cpu: UInt32) -> [UInt8] {
            [0xCF, 0xFA, 0xED, 0xFE, UInt8(cpu & 0xFF), UInt8((cpu >> 8) & 0xFF), UInt8((cpu >> 16) & 0xFF), UInt8(cpu >> 24)]
                + [UInt8](repeating: 0, count: 32)
        }
        #expect(ExecutableSniffer.architectures(inHeader: macho(0x0100_000C)) == [.arm64])
        #expect(ExecutableSniffer.architectures(inHeader: macho(0x0100_0007)) == [.x86])

        // Universal binary with x86_64 and arm64e
        var fat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]
        fat += [0x01, 0x00, 0x00, 0x07] + [UInt8](repeating: 0, count: 16)
        fat += [0x01, 0x00, 0x00, 0x0C] + [UInt8](repeating: 0, count: 16)
        #expect(ExecutableSniffer.architectures(inHeader: fat) == [.x86, .arm64])

        // A Java class file shares the first four bytes with fat Mach-O but is not an executable here.
        #expect(ExecutableSniffer.architectures(inHeader: [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52, 0, 0]) == nil)

        // ELF x86-64 and aarch64 (little endian)
        var elf = [UInt8](repeating: 0, count: 64)
        elf[0] = 0x7F; elf[1] = 0x45; elf[2] = 0x4C; elf[3] = 0x46; elf[4] = 2; elf[5] = 1
        elf[18] = 62
        #expect(ExecutableSniffer.architectures(inHeader: elf) == [.x86])
        elf[18] = 183
        #expect(ExecutableSniffer.architectures(inHeader: elf) == [.arm64])

        // PE with machine = x64 and ARM64
        var pe = [UInt8](repeating: 0, count: 256)
        pe[0] = 0x4D; pe[1] = 0x5A; pe[0x3C] = 0x80
        pe[0x80] = 0x50; pe[0x81] = 0x45
        pe[0x84] = 0x64; pe[0x85] = 0x86
        #expect(ExecutableSniffer.architectures(inHeader: pe) == [.x86])
        pe[0x84] = 0x64; pe[0x85] = 0xAA
        #expect(ExecutableSniffer.architectures(inHeader: pe) == [.arm64])

        #expect(ExecutableSniffer.architectures(inHeader: Array("hello world, plain text".utf8)) == nil)
    }

    @Test func realMachOIsDetected() throws {
        let archs = try #require(ExecutableSniffer.architectures(of: URL(fileURLWithPath: "/bin/ls")))
        #expect(!archs.isEmpty)
    }

    @Test func contentSniffing() {
        #expect(FileClassifier.sniff(Array("Just some text\nwith lines\n".utf8)) == .text)
        #expect(FileClassifier.sniff(Array("Caffè ☃ con accenti\n".utf8)) == .text)
        #expect(FileClassifier.sniff([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]) == .compressed)
        #expect(FileClassifier.sniff([0x50, 0x4B, 0x03, 0x04, 9, 9]) == .compressed)
        #expect(FileClassifier.sniff([1, 0, 2, 0, 3, 0, 4, 0]) == .other)
    }

    private func makeTree(_ files: [(String, Data)]) throws -> (URL, TreeSnapshot) {
        let root = try TestSupport.makeTempDir("group")
        var snap = TreeSnapshot()
        for (rel, data) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            snap.files[rel] = .init(size: Int64(data.count), crc: 0, isSymlink: false)
        }
        return (root, snap)
    }

    @Test func groupsByExtensionAndMergesSmallOnes() throws {
        let big = Data(repeating: 0x41, count: 100_000)
        let small = Data(repeating: 0x42, count: 2_000)
        let (root, snap) = try makeTree([
            ("a/one.TXT", big), ("a/two.txt", big),
            ("b/x.md", small), ("b/y.json", small), ("b/z.xml", small),   // small text files → cat:text
            ("c/small.dat", small),                                          // small binary → cat:binary
            ("c/pic.bmp", Data(repeating: 7, count: 70_000)),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = Grouper.makeGroups(snapshot: snap, root: root, minGroupBytes: 64 * 1024)
        let ids = result.groups.map(\.id)
        #expect(ids.contains("ext:txt"))
        #expect(ids.contains("ext:bmp"))
        #expect(ids.contains("cat:text"))
        #expect(ids.contains("cat:binary"))
        #expect(!ids.contains("ext:md"))
        let txt = try #require(result.groups.first { $0.id == "ext:txt" })
        #expect(txt.files == ["a/one.TXT", "a/two.txt"] && txt.totalBytes == 200_000 && txt.category == .text)
        let merged = try #require(result.groups.first { $0.id == "cat:text" })
        #expect(merged.extensions == ["json", "md", "xml"] && merged.totalBytes == 6_000)
        // largest first
        #expect(result.groups.map(\.totalBytes) == result.groups.map(\.totalBytes).sorted(by: >))
        #expect(!result.isSingleExtensionArchive)
        // every file is in exactly one group
        #expect(result.groups.flatMap(\.files).sorted() == snap.files.keys.sorted())
    }

    @Test func extensionlessFilesAreSniffed() throws {
        var exe = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])
        exe.append(Data(repeating: 0, count: 100_000))
        let (root, snap) = try makeTree([
            ("tool", exe),
            ("README", Data(String(repeating: "readme line\n", count: 8000).utf8)),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = Grouper.makeGroups(snapshot: snap, root: root, minGroupBytes: 1024)
        let categories = Dictionary(uniqueKeysWithValues: result.groups.flatMap { g in g.files.map { ($0, g) } })
        #expect(categories["tool"]?.category == .executable)
        #expect(categories["tool"]?.executableArchitectures == [.arm64])
        #expect(categories["README"]?.category == .text)
    }

    @Test func singleExtensionArchive() throws {
        let (root, snap) = try makeTree([("a.txt", Data(repeating: 1, count: 10)), ("d/b.txt", Data(repeating: 2, count: 10))])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Grouper.makeGroups(snapshot: snap, root: root, minGroupBytes: 64).isSingleExtensionArchive)
    }
}

// MARK: - Method specs and candidates

@Suite struct MethodSpecTests {
    @Test func rendersArguments() {
        let bcj2 = MethodSpec(coders: ["BCJ2", "LZMA:d=64m", "LZMA:d=1m", "LZMA:d=1m"],
                              extraArgs: ["-mb0s0:1", "-mb0s1:2", "-mb0s2:3"])
        #expect(bcj2.arguments == ["-m0=BCJ2", "-m1=LZMA:d=64m", "-m2=LZMA:d=1m", "-m3=LZMA:d=1m",
                                   "-mb0s0:1", "-mb0s1:2", "-mb0s2:3"])
        #expect(bcj2.description == "BCJ2 + LZMA:d=64m + LZMA:d=1m + LZMA:d=1m")
        #expect(MethodSpec.copy.arguments == ["-m0=Copy"])
        #expect(MethodSpec(coders: ["Delta:4", "LZMA2:d=1m"]).arguments == ["-m0=Delta:4", "-m1=LZMA2:d=1m"])
    }

    @Test func decompressionOrder() {
        func rank(_ s: String) -> Int { MethodSpec(coders: [s]).decompressionRank }
        #expect(rank("Copy") < rank("LZMA2:d=1m"))
        #expect(rank("LZMA2:d=1m") < rank("LZMA:d=1m"))
        #expect(rank("LZMA:d=1m") < rank("Deflate64"))
        #expect(rank("Deflate") < rank("BZip2:d=900k"))
        #expect(rank("BZip2:d=900k") < rank("PPMd:mem=64m:o=6"))
        #expect(MethodSpec(coders: ["Delta:4", "LZMA:d=1m"]).decompressionRank == rank("LZMA"))
    }

    @Test func winnerPicksSmallestThenCheapestToDecode() {
        func trial(_ coder: String, _ size: Int64) -> TrialResult {
            TrialResult(method: MethodSpec(coders: [coder]), compressedBytes: size, seconds: 1, sampled: false)
        }
        #expect(Job.pickWinner([trial("PPMd:o=6", 100), trial("LZMA2:d=1m", 90), trial("LZMA:d=1m", 95)])?.method.coders == ["LZMA2:d=1m"])
        #expect(Job.pickWinner([trial("PPMd:o=6", 100), trial("LZMA:d=1m", 100), trial("BZip2", 100)])?.method.coders == ["LZMA:d=1m"])
        #expect(Job.pickWinner([trial("LZMA2:d=1m", 100), trial("Copy", 100)])?.method.coders == ["Copy"])
        #expect(Job.pickWinner([]) == nil)
    }
}

@Suite struct CandidateTests {
    func group(_ category: FileCategory, bytes: Int64 = 10 << 20, archs: [ExecutableArchitecture] = []) -> FileGroup {
        var g = FileGroup(id: "ext:x", category: category, extensions: ["x"], files: ["a.x"], totalBytes: bytes)
        g.executableArchitectures = archs
        return g
    }

    func settings(_ mode: OptimizationMode) -> OptimizerSettings {
        var s = OptimizerSettings()
        s.mode = mode
        return s
    }

    func texts(_ c: [MethodSpec]) -> [String] { c.map(\.description) }

    @Test func fastModeIsOneLZMA2() {
        for cat in FileCategory.allCases {
            let c = CandidateGenerator.candidates(for: group(cat), settings: settings(.fast), isSingleExtensionArchive: false)
            #expect(c.count == 1 && c[0].coders[0].hasPrefix("LZMA2:"))
        }
    }

    @Test func normalMode() {
        let text = texts(CandidateGenerator.candidates(for: group(.text), settings: settings(.normal), isSingleExtensionArchive: false))
        #expect(text == ["LZMA2:d=16m:fb=64", "PPMd:mem=256m:o=6"])
        let comp = texts(CandidateGenerator.candidates(for: group(.compressed), settings: settings(.normal), isSingleExtensionArchive: false))
        #expect(comp == ["Copy", "LZMA2:d=16m:fb=64"])
        let bin = texts(CandidateGenerator.candidates(for: group(.binary), settings: settings(.normal), isSingleExtensionArchive: false))
        #expect(bin == ["LZMA2:d=16m:fb=64"])
    }

    @Test func goodModeAddsSpecialisedChains() {
        let s = settings(.good)
        let text = texts(CandidateGenerator.candidates(for: group(.text), settings: s, isSingleExtensionArchive: false))
        #expect(text.contains("PPMd:mem=256m:o=8") && text.contains("LZMA:d=16m:fb=64"))
        let audio = texts(CandidateGenerator.candidates(for: group(.audioRaw), settings: s, isSingleExtensionArchive: false))
        #expect(audio.contains("Delta:2 + LZMA:d=16m:fb=64") && audio.contains("Delta:4 + LZMA:d=16m:fb=64"))
        let bin = texts(CandidateGenerator.candidates(for: group(.binary), settings: s, isSingleExtensionArchive: false))
        #expect(bin.contains("LZMA:d=16m:fb=64:lc=0:lp=2:pb=2"))
        var legacy = s
        legacy.allowModernFilters = false
        let armOff = CandidateGenerator.candidates(for: group(.executable, archs: [.arm64]), settings: legacy, isSingleExtensionArchive: false)
        #expect(!texts(armOff).contains { $0.hasPrefix("ARM64") })
        let modern = s
        let arm = CandidateGenerator.candidates(for: group(.executable, archs: [.arm64]), settings: modern, isSingleExtensionArchive: false)
        #expect(texts(arm).contains("ARM64 + LZMA:d=16m:fb=64"))
        let x86 = CandidateGenerator.candidates(for: group(.executable, archs: [.x86]), settings: s, isSingleExtensionArchive: false)
        let bcj2 = x86.first { $0.coders.first == "BCJ2" }
        #expect(bcj2 != nil && bcj2?.extraArgs == ["-mb0s0:1", "-mb0s1:2", "-mb0s2:3"] && bcj2?.coders.count == 4)
    }

    @Test func tablesAreCumulativeInMode() {
        let modes = OptimizationMode.allCases.filter { $0.runsTrials }
        for cat in FileCategory.allCases {
            var previous = Set<MethodSpec>()
            var previousCount = 0
            for mode in modes {
                let list = CandidateGenerator.candidates(for: group(cat, bytes: 1 << 20, archs: [.x86, .arm64]),
                                                         settings: settings(mode), isSingleExtensionArchive: true)
                let set = Set(list)
                #expect(set.count == list.count, "duplicates in \(cat) \(mode)")
                #expect(previous.isSubset(of: set), "\(cat): \(mode) lost candidates of the previous mode")
                #expect(list.count >= previousCount)
                previous = set
                previousCount = list.count
            }
        }
    }

    @Test func higherModesAddTheDocumentedMethods() {
        func all(_ cat: FileCategory, _ mode: OptimizationMode, single: Bool = false) -> [String] {
            texts(CandidateGenerator.candidates(for: group(cat, bytes: 1 << 20), settings: settings(mode), isSingleExtensionArchive: single))
        }
        let best = all(.text, .best)
        #expect(best.contains("PPMd:mem=256m:o=16") && best.contains("PPMd:mem=256m:o=32"))
        #expect(best.contains("BZip2:d=900k:pass=2") && best.contains("LZMA:d=1m:fb=273") && best.contains("LZMA:d=1m:fb=64:lc=1:lp=0:pb=0"))
        let ultra = all(.text, .ultra)
        #expect(ultra.contains("PPMd:mem=256m:o=24") && ultra.contains("LZMA:d=1m:fb=64:mf=bt2") && ultra.contains("Deflate64"))
        let extreme = all(.text, .extreme)
        #expect(extreme.contains("LZMA:d=1m:fb=273:mc=1000") && extreme.contains("LZMA:d=1m:fb=64:mf=hc4"))
        let extreme2 = all(.text, .extreme2, single: true)
        #expect(extreme2.contains("LZMA:d=1m:fb=64:mf=bt5") && extreme2.contains("LZMA:d=1m:fb=192"))
        #expect(extreme2.contains("LZMA:d=1m:fb=64:lc=4:lp=0:pb=0"))
        #expect(!all(.text, .extreme2, single: false).contains("LZMA:d=1m:fb=64:lc=4:lp=0:pb=0"))
        #expect(all(.audioRaw, .best).contains("Delta:1 + LZMA:d=1m:fb=64") && all(.audioRaw, .best).contains("Delta:3 + LZMA:d=1m:fb=64"))
        #expect(all(.imageRaw, .ultra).contains("Delta:32 + LZMA:d=1m:fb=64"))
        #expect(all(.binary, .extreme).contains("LZMA:d=1m:fb=64:lc=0:lp=1:pb=1"))
    }

    @Test func compressedGroupsOnlyTryCheapMethods() {
        for mode in OptimizationMode.allCases where mode.runsTrials {
            let c = CandidateGenerator.candidates(for: group(.compressed), settings: settings(mode), isSingleExtensionArchive: false)
            #expect(c.count <= 3)
            #expect(c.allSatisfy { $0.coders.count == 1 && (["Copy"].contains($0.coders[0]) || $0.coders[0].hasPrefix("LZMA")) })
            #expect(c.contains(.copy))
        }
    }

    @Test func respectsDisabledMethods() {
        for mode in OptimizationMode.allCases where mode.runsTrials {
            var s = settings(mode)
            s.disablePPMd = true
            s.disableBZip2 = true
            for cat in FileCategory.allCases {
                let c = texts(CandidateGenerator.candidates(for: group(cat, bytes: 1 << 20), settings: s, isSingleExtensionArchive: true))
                #expect(!c.contains { $0.contains("PPMd") || $0.contains("BZip2") }, "\(cat) \(mode)")
            }
        }
        var limited = settings(.best)
        limited.noPPMdAboveMB = 50
        let below = texts(CandidateGenerator.candidates(for: group(.text, bytes: 40 << 20), settings: limited, isSingleExtensionArchive: false))
        let above = texts(CandidateGenerator.candidates(for: group(.text, bytes: 60 << 20), settings: limited, isSingleExtensionArchive: false))
        #expect(below.contains { $0.contains("PPMd") })
        #expect(!above.contains { $0.contains("PPMd") })
    }

    @Test func dictionaryNeverLargerThanNeeded() {
        var s = settings(.normal)
        s.lzmaDictionaryMB = 128
        func dict(_ bytes: Int64) -> String {
            CandidateGenerator.candidates(for: group(.binary, bytes: bytes), settings: s, isSingleExtensionArchive: false)[0].coders[0]
        }
        #expect(dict(100) == "LZMA2:d=1m:fb=64")
        #expect(dict(3 << 20) == "LZMA2:d=4m:fb=64")
        #expect(dict(4 << 20) == "LZMA2:d=4m:fb=64")
        #expect(dict((4 << 20) + 1) == "LZMA2:d=8m:fb=64")
        #expect(dict(5 << 30) == "LZMA2:d=128m:fb=64")
        s.lzmaDictionaryMB = 100
        #expect(dict(5 << 30) == "LZMA2:d=100m:fb=64")
        s.lzmaWordSize = 273
        #expect(dict(100) == "LZMA2:d=1m:fb=273")
    }

    @Test func ppmdMemoryIsKeptAsConfigured() {
        var s = settings(.normal)
        s.ppmdMemoryMB = 1024
        let c = texts(CandidateGenerator.candidates(for: group(.text, bytes: 10_000), settings: s, isSingleExtensionArchive: false))
        #expect(c.contains("PPMd:mem=1024m:o=6"))
    }

    @Test func baselines() {
        func b(_ mode: OptimizationMode, bytes: Int64 = 10 << 20) -> [String] {
            texts(CandidateGenerator.wholeArchiveBaselines(totalBytes: bytes, settings: settings(mode)))
        }
        #expect(b(.fast) == ["LZMA2:d=16m:fb=64"])
        #expect(b(.normal) == ["LZMA2:d=16m:fb=64"])
        #expect(b(.good) == ["LZMA2:d=16m:fb=64"])
        #expect(b(.ultra).count == 3)
        var s = settings(.ultra)
        s.disablePPMd = true
        #expect(CandidateGenerator.wholeArchiveBaselines(totalBytes: 1 << 20, settings: s).count == 2)
    }
}

// MARK: - CRC32

@Suite struct CRC32Tests {
    @Test func knownVectors() {
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test func streamingMatchesOneShotForAllAlignments() {
        let data = TestSupport.randomBytes(5_000, seed: 3)
        let whole = CRC32.checksum(data)
        for split in [0, 1, 7, 8, 9, 4999, 5000] {
            var c = CRC32()
            c.update(data.prefix(split))
            c.update(data.dropFirst(split))
            #expect(c.value == whole, "split at \(split)")
        }
        // Byte-by-byte reference
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var v = UInt32(i)
            for _ in 0..<8 { v = v & 1 != 0 ? 0xEDB8_8320 ^ (v >> 1) : v >> 1 }
            table[i] = v
        }
        var ref: UInt32 = 0xFFFF_FFFF
        for b in data { ref = table[Int((ref ^ UInt32(b)) & 0xFF)] ^ (ref >> 8) }
        #expect(whole == ref ^ 0xFFFF_FFFF)
    }

    @Test func fileChecksumMatchesSevenZip() async throws {
        let dir = try TestSupport.makeTempDir("crc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("blob.bin")
        let data = TestSupport.randomBytes(3_500_000, seed: 77)   // larger than the 1 MiB read chunk
        try data.write(to: file)
        let crc = try CRC32.checksum(of: file)
        #expect(crc == CRC32.checksum(data))
        let archive = dir.appendingPathComponent("a.7z")
        try TestSupport.makeArchive(from: dir, at: archive, type: "7z", extra: ["-mx=1"])
        let listing = try await TestSupport.tool().list(archive)
        #expect(listing.entries.first { $0.path == "blob.bin" }?.crc == crc)
    }
}

// MARK: - Sampling, naming and volumes

@Suite struct SamplingAndNamingTests {
    @Test func samplingBudget() {
        #expect(Sampling.budget(level: 0, groupBytes: 1 << 40) == nil)
        #expect(Sampling.budget(level: 2, groupBytes: 5 << 20) == nil)
        #expect(Sampling.budget(level: 2, groupBytes: 11 << 20) == Int64(10 << 20))
        #expect(Sampling.budget(level: 6, groupBytes: 1 << 40) == Int64(30 << 20))
    }

    @Test func samplePlanTakesWholeFilesInPathOrder() {
        let sizes: [String: Int64] = ["a": 4, "b": 4, "c": 4, "d": 100]
        let plan = Sampling.plan(files: ["d", "c", "b", "a"], sizes: { sizes[$0] ?? 0 }, budget: 10)
        #expect(plan.wholeFiles == ["a", "b"])
        #expect(plan.truncated == nil || plan.truncated?.bytes == 2)
    }

    @Test func samplePlanTruncatesAnOversizedFirstFile() {
        let plan = Sampling.plan(files: ["big", "other"], sizes: { $0 == "big" ? 1_000 : 5 }, budget: 100)
        #expect(plan.wholeFiles.isEmpty)
        #expect(plan.truncated?.path == "big" && plan.truncated?.bytes == 100)
    }

    @Test func preparedSampleIsSmallerThanTheGroup() throws {
        let root = try TestSupport.makeTempDir("sample")
        defer { try? FileManager.default.removeItem(at: root) }
        var snap = TreeSnapshot()
        let data = TestSupport.randomBytes(8 << 20, seed: 4)
        try data.write(to: root.appendingPathComponent("big.bin"))
        snap.files["big.bin"] = .init(size: Int64(data.count), crc: 0, isSymlink: false)
        let g = FileGroup(id: "ext:bin", category: .binary, extensions: ["bin"], files: ["big.bin"], totalBytes: Int64(data.count))
        let input = try Sampling.prepare(group: g, root: root, snapshot: snap, level: 1,
                                         directory: root.appendingPathComponent("sample"),
                                         listFile: root.appendingPathComponent("list.txt"))
        #expect(input.sampled)
        // List files carry every name in its own pair of double quotes.
        let names = try String(contentsOf: input.listFile, encoding: .utf8).split(separator: "\n")
            .map { String($0.dropFirst().dropLast()) }
        #expect(names.count == 1)
        #expect(TestSupport.size(input.directory.appendingPathComponent(names[0])) == 5 << 20)
        let whole = try Sampling.prepare(group: g, root: root, snapshot: snap, level: 0,
                                         directory: root.appendingPathComponent("s2"),
                                         listFile: root.appendingPathComponent("list2.txt"))
        #expect(!whole.sampled && whole.directory == root)
    }

    @Test func supportedArchives() {
        func ok(_ n: String) -> Bool { ArchiveOptimizer.isSupportedArchive(URL(fileURLWithPath: "/tmp/\(n)")) }
        for n in ["a.7z", "a.ZIP", "a.rar", "a.tar.gz", "a.tgz", "a.iso", "a.cab", "a.xz", "a.zst", "a.7z.001", "a.part1.rar", "a.part01.rar"] {
            #expect(ok(n), "\(n)")
        }
        for n in ["a.txt", "a.7z.002", "a.part2.rar", "a.part02.rar", "a.jpg", "noext"] { #expect(!ok(n), "\(n)") }
        #expect(ArchiveOptimizer.supportedExtensions.isSuperset(of: ["7z", "zip", "rar", "gz", "bz2", "xz", "zst", "tar", "iso"]))
    }

    @Test func baseNames() {
        func base(_ n: String) -> String { VolumeSet.baseName(of: URL(fileURLWithPath: "/tmp/\(n)")) }
        #expect(base("data.7z") == "data")
        #expect(base("data.tar.gz") == "data")
        #expect(base("data.tgz") == "data")
        #expect(base("notes.txt.gz") == "notes.txt")
        #expect(base("data.7z.001") == "data")
        #expect(base("data.part1.rar") == "data")
        #expect(base("my.photos.zip") == "my.photos")
    }

    @Test func volumeDiscovery() throws {
        let dir = try TestSupport.makeTempDir("volumes")
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["a.7z.001", "a.7z.002", "a.7z.003", "b.part01.rar", "b.part02.rar", "c.zip", "c.z01", "c.z02", "d.rar", "d.r00", "d.r01", "e.7z"] {
            try Data([1]).write(to: dir.appendingPathComponent(n))
        }
        func names(_ n: String) -> [String] { VolumeSet.volumes(of: dir.appendingPathComponent(n)).map(\.lastPathComponent) }
        #expect(names("a.7z.001") == ["a.7z.001", "a.7z.002", "a.7z.003"])
        #expect(names("b.part01.rar") == ["b.part01.rar", "b.part02.rar"])
        #expect(names("c.zip") == ["c.z01", "c.z02", "c.zip"])
        #expect(names("d.rar") == ["d.rar", "d.r00", "d.r01"])
        #expect(names("e.7z") == ["e.7z"])
    }

    @Test func uniqueOutputNames() throws {
        let dir = try TestSupport.makeTempDir("names")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ArchiveOptimizer.uniqueURL(in: dir, stem: "x_optimized", separator: "-").lastPathComponent == "x_optimized.7z")
        try Data().write(to: dir.appendingPathComponent("x_optimized.7z"))
        #expect(ArchiveOptimizer.uniqueURL(in: dir, stem: "x_optimized", separator: "-").lastPathComponent == "x_optimized-2.7z")
        try Data().write(to: dir.appendingPathComponent("x_optimized-2.7z"))
        #expect(ArchiveOptimizer.uniqueURL(in: dir, stem: "x_optimized", separator: "-").lastPathComponent == "x_optimized-3.7z")
    }
}

// MARK: - Process runner

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputWithoutDeadlock() async throws {
        // 2 MB on each stream would block a pipe-based runner that reads them one after the other.
        let out = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 2000000 /dev/zero | tr '\\0' 'a'; head -c 2000000 /dev/zero | tr '\\0' 'b' 1>&2; exit 3"])
        #expect(out.exitCode == 3)
        #expect(out.standardOutput.count == 2_000_000 && out.standardError.count == 2_000_000)
    }

    @Test func stdinIsDevNull() async throws {
        let out = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        #expect(out.exitCode == 0 && out.standardOutput.isEmpty)
    }

    @Test func cancellationTerminatesTheChild() async throws {
        let task = Task { () -> Error? in
            do {
                _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
                return nil
            } catch { return error }
        }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        task.cancel()
        let error = await task.value
        #expect(error as? OptimizerError == .cancelled)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func alreadyCancelledTaskDoesNotLaunch() async {
        let task = Task { () -> Error? in
            try? await Task.sleep(for: .milliseconds(50))
            do {
                _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
                return nil
            } catch { return error }
        }
        task.cancel()
        #expect(await task.value as? OptimizerError == .cancelled)
    }

    @Test func locateFindsTheVendoredBinary() throws {
        let tool = try SevenZipTool.locate()
        #expect(FileManager.default.isExecutableFile(atPath: tool.executableURL.path))
    }

    @Test func bogusEnvironmentOverrideIsIgnored() throws {
        // locate() reads SQUEEZE7Z_7ZZ; a bogus value must fall through to the next candidate.
        setenv("SQUEEZE7Z_7ZZ", "/nonexistent/7zz", 1)
        defer { unsetenv("SQUEEZE7Z_7ZZ") }
        let tool = try SevenZipTool.locate()
        #expect(tool.executableURL.path != "/nonexistent/7zz")
    }
}
