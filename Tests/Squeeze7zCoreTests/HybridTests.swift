import Foundation
import Testing
@testable import Squeeze7zCore

/// Hybrid groups: families of related extensions stored as one solid block, strategy selection and the
/// dictionary that follows the size of the data.
@Suite struct HybridTests {
    private func group(_ id: String, _ category: FileCategory, files: [String], bytes: Int64,
                       extensions: [String]? = nil) -> FileGroup {
        FileGroup(id: id, category: category,
                  extensions: extensions ?? [FileClassifier.extensionKey(forPath: files.first ?? "")],
                  files: files, totalBytes: bytes)
    }

    // MARK: Family mapping

    @Test func everyCategoryHasAFamily() {
        let expected: [FileCategory: FileFamily] = [
            .text: .text, .executable: .executable, .audioRaw: .audioRaw, .imageRaw: .imageRaw,
            .compressed: .compressed, .binary: .binary, .misc: .binary,
        ]
        for category in FileCategory.allCases { #expect(FileFamily(category: category) == expected[category]) }
        #expect(FileFamily.allCases.count == 6)
        #expect(FileFamily.text.groupID == "fam:text")
    }

    @Test func familiesNeedTwoGroupsAndOrderFilesByExtensionThenPath() {
        let groups = [
            group("ext:h", .text, files: ["z/b.h", "a/a.h"], bytes: 300),
            group("ext:1", .text, files: ["man/x.1"], bytes: 200),
            group("ext:(none)#text", .text, files: ["README", "a/LICENSE"], bytes: 100, extensions: [""]),
            group("ext:wav", .audioRaw, files: ["t.wav"], bytes: 900),
            group("ext:bin", .binary, files: ["d.bin"], bytes: 50),
            group("ext:zzz", .misc, files: ["q.zzz"], bytes: 40),
        ]
        let families = Hybrid.families(of: groups)
        #expect(families.map(\.family) == [.text, .binary])
        let text = families[0]
        #expect(text.members == [0, 1, 2])
        #expect(text.group.id == "fam:text")
        #expect(text.group.category == .text)
        #expect(text.group.totalBytes == 600)
        // Empty extension first, then "1", then "h"; paths within an extension.
        #expect(text.group.files == ["README", "a/LICENSE", "man/x.1", "a/a.h", "z/b.h"])
        #expect(text.group.extensions == ["", "1", "h"])
        #expect(families[1].members == [4, 5])   // binary and misc share a family
        #expect(Hybrid.families(of: [groups[3]]).isEmpty)
    }

    @Test func executableFamilyMergesArchitecturesByVolume() {
        var big = group("ext:(none)#executable", .executable, files: ["a"], bytes: 900)
        big.executableArchitectures = [.arm64, .x86]
        var small = group("ext:dylib", .executable, files: ["b.dylib"], bytes: 100)
        small.executableArchitectures = [.x86, .arm]
        let family = Hybrid.families(of: [small, big])[0]
        #expect(family.group.executableArchitectures == [.arm64, .x86, .arm])
    }

    // MARK: Method keys and candidates

    @Test func methodKeysIgnoreDictionaryAndSortingButNotParameters() {
        func spec(_ coders: [String], _ extra: [String] = []) -> MethodSpec { MethodSpec(coders: coders, extraArgs: extra) }
        #expect(Hybrid.key(spec(["LZMA:d=128m:fb=273"])) == Hybrid.key(spec(["LZMA:d=256m:fb=273"])))
        #expect(Hybrid.key(spec(["LZMA:d=128m:fb=273"])) != Hybrid.key(spec(["LZMA:d=128m:fb=64"])))
        #expect(Hybrid.key(spec(["LZMA2:d=1m:fb=64"])) == Hybrid.key(spec(["LZMA2:d=1m:fb=64"], ["-mqs=on"])))
        #expect(Hybrid.key(spec(["ARM64", "LZMA:d=1m:fb=64"])) != Hybrid.key(spec(["LZMA:d=1m:fb=64"])))
        #expect(Hybrid.key(spec(["PPMd:mem=256m:o=16"])) != Hybrid.key(spec(["PPMd:mem=256m:o=8"])))
    }

    @Test func familyCandidatesAreTheCheapTierPlusMemberWinners() {
        let groups = [
            group("ext:h", .text, files: ["a.h"], bytes: 100 << 20),
            group("ext:1", .text, files: ["a.1"], bytes: 20 << 20),
        ]
        var settings = OptimizerSettings()
        settings.mode = .best
        let family = Hybrid.families(of: groups)[0]
        let winner = MethodSpec(coders: ["PPMd:mem=256m:o=16"])
        let list = Hybrid.candidates(for: family, groups: groups, winners: [winner, .copy], settings: settings,
                                     concurrentBuilds: 2, physicalMemory: 32 << 30)
        #expect(list.contains(winner))
        // Cheapest tier of the mode: LZMA2 with the dictionary grown to the family (120 MB -> 128m is enough).
        #expect(list.first?.description.hasPrefix("LZMA2:d=128m") == true)
        // Not the whole best-mode table: only the winner of the groups and the cheap tier.
        #expect(list.count < 6)
        // PPMd won on a group: the same and higher orders are tried on the block (o=32 is in the best-mode table).
        #expect(list.contains { $0.coders == ["PPMd:mem=256m:o=32"] })
        #expect(!list.contains { $0.coders == ["PPMd:mem=256m:o=8"] })
        #expect(list.allSatisfy { !$0.extraArgs.contains("-mqs=on") })
    }

    @Test func ppmdOrderIsReadFromPlainPPMdMethodsOnly() {
        #expect(Hybrid.ppmdOrder(MethodSpec(coders: ["PPMd:mem=256m:o=16"])) == 16)
        #expect(Hybrid.ppmdOrder(MethodSpec(coders: ["PPMD:o=6:mem=1g"])) == 6)
        #expect(Hybrid.ppmdOrder(MethodSpec(coders: ["LZMA:d=1m:fb=64"])) == nil)
        #expect(Hybrid.ppmdOrder(MethodSpec(coders: ["Delta:4", "PPMd:o=6"])) == nil)
    }

    @Test func sortedByTypeIsTriedOnTheTwoLeaders() {
        func trial(_ coder: String, _ bytes: Int64, extra: [String] = []) -> TrialResult {
            TrialResult(method: MethodSpec(coders: [coder], extraArgs: extra), compressedBytes: bytes, seconds: 0, sampled: false)
        }
        let variants = Hybrid.sortedVariants(of: [trial("LZMA2:d=1m", 300), trial("PPMd:o=6", 200), trial("PPMd:o=16", 250)])
        #expect(variants.map(\.coders) == [["PPMd:o=6"], ["PPMd:o=16"]])
        #expect(variants.allSatisfy { $0.extraArgs == ["-mqs=on"] })
        #expect(variants[0].description == "PPMd:o=6 [sorted by type]")
        // A leader that is already sorted is not sorted again.
        #expect(Hybrid.sortedVariants(of: [trial("PPMd:o=6", 100, extra: ["-mqs=on"]), trial("LZMA2:d=1m", 300)], count: 1).isEmpty)
        #expect(Hybrid.sortedVariants(of: []).isEmpty)
    }

    @Test func aFamilyDominatedByOneGroupIsNotTriedAsABlock() {
        let big = group("ext:a", .executable, files: ["a"], bytes: 90 << 20)
        let crumb = group("ext:dylib", .executable, files: ["b.dylib"], bytes: 10 << 20)
        let family = Hybrid.families(of: [big, crumb])[0]
        #expect(!Hybrid.isDominated(family, groups: [big, crumb]))
        let small = group("ext:dylib", .executable, files: ["b.dylib"], bytes: 3 << 20)
        #expect(Hybrid.isDominated(Hybrid.families(of: [big, small])[0], groups: [big, small]))
    }

    @Test func familyCandidatesGrowTheDictionaryPastTheSetting() {
        let groups = [
            group("ext:h", .text, files: ["a.h"], bytes: 150 << 20),
            group("ext:1", .text, files: ["a.1"], bytes: 30 << 20),
        ]
        let settings = OptimizerSettings()   // dictionary setting 128 MB
        let family = Hybrid.families(of: groups)[0]
        let list = Hybrid.candidates(for: family, groups: groups, winners: [], settings: settings,
                                     concurrentBuilds: 1, physicalMemory: 32 << 30)
        #expect(list.first?.description.hasPrefix("LZMA2:d=256m") == true)
        // The per-group candidates of the same data stay at the setting.
        let perGroup = CandidateGenerator.candidates(for: family.group, settings: settings, isSingleExtensionArchive: false)
        #expect(perGroup.first?.description.hasPrefix("LZMA2:d=128m") == true)
    }

    @Test func binaryFamilyKeepsWinnersOfBothCategories() {
        let groups = [
            group("ext:dat", .binary, files: ["a.dat"], bytes: 2 << 20),
            group("ext:zzz", .misc, files: ["a.zzz"], bytes: 2 << 20),
        ]
        var settings = OptimizerSettings()
        settings.mode = .best
        let family = Hybrid.families(of: groups)[0]
        // PPMd o=8 is a candidate of misc data only in the best mode.
        let list = Hybrid.candidates(for: family, groups: groups, winners: [MethodSpec(coders: ["PPMd:mem=256m:o=8"])],
                                     settings: settings, concurrentBuilds: 1, physicalMemory: 32 << 30)
        #expect(list.contains { $0.coders == ["PPMd:mem=256m:o=8"] })
    }

    // MARK: Dictionary scaling

    @Test func dictionaryFollowsTheDataUpToTheCap() {
        let settings = { var s = OptimizerSettings(); s.parallelJobs = 1; return s }()  // one job: the whole budget   // 128 MB
        func d(_ bytes: Int64, _ s: OptimizerSettings = settings, memory: UInt64 = 32 << 30, builds: Int = 1) -> String {
            CandidateGenerator.scaledDictionaryString(forBytes: bytes, settings: s, concurrentBuilds: builds, physicalMemory: memory)
        }
        #expect(d(100_000) == "1m")
        #expect(d(3 << 20) == "4m")
        #expect(d(129 << 20) == "256m")
        #expect(d(310 << 20) == "256m")      // capped at max(setting, 256)
        #expect(d(10 << 30) == "256m")
        var big = settings
        big.lzmaDictionaryMB = 512
        #expect(d(10 << 30, big) == "512m")
        big.lzmaDictionaryMB = 4000
        #expect(d(10 << 30, big, memory: 64 << 30) == "1536m")
        #expect(d(10 << 30, big) == "768m")   // 11 x 1536 MB does not fit in half of 32 GB
        // A setting below the default is an explicit request for lighter extraction and is kept.
        var small = settings
        small.lzmaDictionaryMB = 32
        #expect(d(310 << 20, small) == "32m")
    }

    @Test func dictionaryStaysWithinHalfOfPhysicalMemory() {
        let settings = { var s = OptimizerSettings(); s.parallelJobs = 1; return s }()  // one job: the whole budget
        // 11x the dictionary must fit in half the memory: 4 GB -> 2 GB / 11 = 186 MB -> 128m.
        #expect(CandidateGenerator.scaledDictionaryString(forBytes: 310 << 20, settings: settings,
                                                          concurrentBuilds: 1, physicalMemory: 4 << 30) == "128m")
        // Two builds in flight share the budget.
        #expect(CandidateGenerator.scaledDictionaryString(forBytes: 310 << 20, settings: settings,
                                                          concurrentBuilds: 2, physicalMemory: 8 << 30) == "128m")
        #expect(CandidateGenerator.scaledDictionaryString(forBytes: 310 << 20, settings: settings,
                                                          concurrentBuilds: 1, physicalMemory: 1 << 30) == "32m")
        #expect(CandidateGenerator.scaledDictionaryString(forBytes: 310 << 20, settings: settings,
                                                          concurrentBuilds: 1, physicalMemory: 0) == "1m")
    }

    @Test func baselineDictionaryIsScaledToTheTree() {
        var settings = OptimizerSettings()
        settings.mode = .normal
        let big = CandidateGenerator.wholeArchiveBaselines(totalBytes: 310 << 20, settings: settings, physicalMemory: 32 << 30)
        #expect(big.first?.description.hasPrefix("LZMA2:d=256m") == true)
        let small = CandidateGenerator.wholeArchiveBaselines(totalBytes: 5 << 20, settings: settings, physicalMemory: 32 << 30)
        #expect(small.first?.description.hasPrefix("LZMA2:d=8m") == true)
        settings.mode = .fast
        let fast = CandidateGenerator.wholeArchiveBaselines(totalBytes: 310 << 20, settings: settings, physicalMemory: 32 << 30)
        #expect(fast.count == 1 && fast[0].description.hasPrefix("LZMA2:d=256m"))
    }


    // MARK: LZMA2 chunks, memory

    @Test func largeDataGetsAnExplicitChunkSizeThatCoversIt() {
        var settings = OptimizerSettings()
        settings.mode = .normal
        func spec(_ bytes: Int64, threads: Int = 10) -> String {
            CandidateGenerator.wholeArchiveBaselines(totalBytes: bytes, settings: settings, threads: threads,
                                                     physicalMemory: 32 << 30)[0].description
        }
        // Up to the default chunk (256 MB) nothing changes.
        #expect(spec(200 << 20) == "LZMA2:d=256m:fb=64")
        #expect(!spec(5 << 20).contains(":c="))
        // Above it the chunk is the power of two that covers the data, whatever the thread count.
        #expect(spec(310 << 20) == "LZMA2:d=256m:fb=64:c=512m")
        #expect(spec(1_640 << 20) == "LZMA2:d=256m:fb=64:c=2g")
        #expect(spec(1_640 << 20, threads: 2) == spec(1_640 << 20, threads: 10))
        #expect(spec(3 << 30) == "LZMA2:d=256m:fb=64:c=4g")
        // Plain LZMA has no chunks and no `c=`.
        settings.mode = .ultra
        let all = CandidateGenerator.wholeArchiveBaselines(totalBytes: 1_640 << 20, settings: settings, threads: 10,
                                                           physicalMemory: 32 << 30)
        #expect(all.count == 3 && all[1].description.hasPrefix("LZMA:") && !all[1].description.contains("c="))
    }

    @Test func chunkSizeCoversEveryCandidateOfAFamilyBlock() {
        let groups = [
            group("ext:h", .text, files: ["a.h"], bytes: 400 << 20),
            group("ext:1", .text, files: ["a.1"], bytes: 30 << 20),
        ]
        var settings = OptimizerSettings()
        settings.mode = .best
        let family = Hybrid.families(of: groups)[0]
        let list = Hybrid.candidates(for: family, groups: groups, winners: [], settings: settings,
                                     concurrentBuilds: 2, threads: 5, physicalMemory: 32 << 30)
        let lzma2 = list.filter { $0.coders[0].hasPrefix("LZMA2") }
        #expect(!lzma2.isEmpty && lzma2.allSatisfy { $0.coders[0].hasSuffix(":c=512m") })
        // The group's method (d=128m, no chunk size) is the same method as the block's.
        #expect(Hybrid.key(MethodSpec(coders: ["LZMA2:d=128m:fb=64"])) == Hybrid.key(lzma2[0]))
        #expect(Hybrid.key(MethodSpec(coders: ["LZMA2:d=256m:fb=64:c=2g"])) == Hybrid.key(MethodSpec(coders: ["LZMA2:d=1m:fb=64"])))
    }

    /// The encoder takes about 11 times its dictionary per chunk encoder in flight. Measured with the vendored 7zz
    /// on 1.64 GB and d=256m: 13.5 GB with default threads (chunks of 256 MB, five encoders), 2.7 GB with one stream.
    @Test func baselineOfALargeTreeFitsA16GBMac() {
        let settings = { var s = OptimizerSettings(); s.parallelJobs = 1; return s }()  // one job: the whole budget
        let physical: UInt64 = 16 << 30
        let tree: Int64 = 1_640 << 20
        let scaled = CandidateGenerator.scaledLZMA(forBytes: tree, settings: settings, concurrentBuilds: 1,
                                                   threads: 10, physicalMemory: physical)
        #expect(scaled.dictionary == "256m" && scaled.blockSize == "2g")
        // One stream: 11 dictionaries, not 5 x 11.
        #expect(11 * 256 << 20 <= Int(physical / 2))
        // Two family trials of that size at once (5 threads each) still fit; four would not at 256m.
        let two = CandidateGenerator.scaledLZMA(forBytes: tree, settings: settings, concurrentBuilds: 2,
                                                threads: 5, physicalMemory: physical)
        #expect(two.dictionary == "256m" && two.blockSize == "2g")
        #expect(2 * 11 * 256 << 20 <= Int(physical / 2))
        let four = CandidateGenerator.scaledLZMA(forBytes: tree, settings: settings, concurrentBuilds: 4,
                                                 threads: 2, physicalMemory: physical)
        #expect(four.dictionary == "128m" && 4 * 11 * 128 << 20 <= Int(physical / 2))
    }

    @Test func dataBeyondTheLargestChunkSharesTheMemoryBetweenItsEncoders() {
        let settings = { var s = OptimizerSettings(); s.parallelJobs = 1; return s }()  // one job: the whole budget
        // 200 GB in 64 GB chunks: four encoders with 10 threads, one with 1 thread (or 2).
        func d(threads: Int) -> String {
            CandidateGenerator.scaledLZMA(forBytes: 200 << 30, settings: settings, concurrentBuilds: 1, threads: threads,
                                          physicalMemory: 16 << 30).dictionary
        }
        #expect(d(threads: 10) == "128m")    // 8 GB / 4 / 11 = 186 MB
        #expect(d(threads: 2) == "256m")
        #expect(d(threads: 1) == "256m")
        #expect(CandidateGenerator.blockThreads(forBytes: 1 << 30, threads: 10) == 1)
        #expect(CandidateGenerator.blockThreads(forBytes: 200 << 30, threads: 10) == 4)
        #expect(CandidateGenerator.blockThreads(forBytes: 500 << 30, threads: 4) == 2)
        #expect(CandidateGenerator.blockThreads(forBytes: 0, threads: 0) == 1)
    }

    @Test func settingsThreadCountsFollowTheSwitchesOf7zz() {
        var s = OptimizerSettings()
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        #expect(s.soloThreads == cores)
        #expect(s.trialThreads(concurrent: 2) == max(1, cores / 2))
        #expect(s.trialThreads(concurrent: 1) == cores)
        s.threadsPerTrial = 3
        #expect(s.soloThreads == 3 && s.trialThreads(concurrent: 2) == 3)
        s.lowCPU = true
        #expect(s.soloThreads == 1 && s.trialThreads(concurrent: 4) == 1)
    }

    @Test func chunkingOnlyDiffersAboveTheChunkWhenThreadCountsStraddleFour() {
        #expect(Hybrid.chunkingDiffers(bytes: 391 << 20, trialThreads: 3, soloThreads: 10))
        #expect(!Hybrid.chunkingDiffers(bytes: 391 << 20, trialThreads: 5, soloThreads: 10))
        #expect(!Hybrid.chunkingDiffers(bytes: 391 << 20, trialThreads: 1, soloThreads: 2))
        #expect(!Hybrid.chunkingDiffers(bytes: 200 << 20, trialThreads: 3, soloThreads: 10))
    }

    // MARK: Families that cannot win

    private func report(_ g: FileGroup, winner: MethodSpec, packed: Int64) -> GroupReport {
        GroupReport(group: g, trials: [TrialResult(method: winner, compressedBytes: packed, seconds: 0, sampled: false)],
                    winner: winner)
    }

    @Test func familiesOfStoredOrIncompressibleGroupsAreNotTried() {
        let groups = [
            group("ext:jpg", .compressed, files: ["a.jpg"], bytes: 100 << 20),
            group("ext:mp4", .compressed, files: ["a.mp4"], bytes: 80 << 20),
            group("ext:zip", .compressed, files: ["a.zip"], bytes: 60 << 20),
        ]
        let family = Hybrid.families(of: groups)[0]
        let inputs: [TrialInput?] = [nil, nil, nil]
        let settings = { () -> OptimizerSettings in var s = OptimizerSettings(); s.mode = .best; return s }()
        let lzma = MethodSpec(coders: ["LZMA2:d=128m:fb=64"])
        // Everything stored.
        let stored = groups.map { report($0, winner: .copy, packed: $0.totalBytes + 200) }
        #expect(Hybrid.cannotWin(family, reports: stored, inputs: inputs))
        #expect(!Hybrid.worthTrial(family, groups: groups, reports: stored, inputs: inputs, settings: settings))
        // LZMA2 won everywhere but saves 0.3%: still not worth whole-family passes.
        let barely = groups.map { report($0, winner: lzma, packed: $0.totalBytes * 997 / 1000) }
        #expect(Hybrid.cannotWin(family, reports: barely, inputs: inputs))
        // Real savings: tried.
        let useful = groups.map { report($0, winner: lzma, packed: $0.totalBytes * 9 / 10) }
        #expect(!Hybrid.cannotWin(family, reports: useful, inputs: inputs))
        #expect(Hybrid.worthTrial(family, groups: groups, reports: useful, inputs: inputs, settings: settings))
        // A group with no trial of its own (too small) is unknown, not incompressible.
        var mixed = stored
        mixed[2] = GroupReport(group: groups[2], trials: [], winner: lzma)
        #expect(!Hybrid.cannotWin(family, reports: mixed, inputs: inputs))
    }

    @Test func normalModeSkipsLargeFamilyBlocksOnFullDataOnly() {
        let groups = [
            group("ext:h", .text, files: ["a.h"], bytes: 90 << 20),
            group("ext:1", .text, files: ["a.1"], bytes: 60 << 20),
        ]
        let family = Hybrid.families(of: groups)[0]
        let inputs: [TrialInput?] = [nil, nil]
        let lzma = MethodSpec(coders: ["LZMA2:d=128m:fb=64"])
        let reports = groups.map { report($0, winner: lzma, packed: $0.totalBytes / 4) }
        var s = OptimizerSettings()
        s.mode = .normal
        #expect(!Hybrid.worthTrial(family, groups: groups, reports: reports, inputs: inputs, settings: s))
        s.samplingLevel = 1   // sampled trials are cheap
        #expect(Hybrid.worthTrial(family, groups: groups, reports: reports, inputs: inputs, settings: s))
        s.samplingLevel = 0
        s.mode = .good
        #expect(Hybrid.worthTrial(family, groups: groups, reports: reports, inputs: inputs, settings: s))
        // Small families stay in normal mode.
        let small = [group("ext:h", .text, files: ["a.h"], bytes: 20 << 20), group("ext:1", .text, files: ["a.1"], bytes: 5 << 20)]
        let smallFamily = Hybrid.families(of: small)[0]
        let smallReports = small.map { report($0, winner: lzma, packed: $0.totalBytes / 4) }
        s.mode = .normal
        #expect(Hybrid.worthTrial(smallFamily, groups: small, reports: smallReports, inputs: inputs, settings: s))
    }

    @Test func storedMethodIsNotSortedByType() {
        let copy = TrialResult(method: .copy, compressedBytes: 100, seconds: 0, sampled: false)
        let lzma = TrialResult(method: MethodSpec(coders: ["LZMA2:d=1m"]), compressedBytes: 200, seconds: 0, sampled: false)
        let variants = Hybrid.sortedVariants(of: [copy, lzma])
        #expect(variants.map(\.coders) == [["LZMA2:d=1m"]])
    }

    // MARK: Estimates and strategy selection

    @Test func estimatesScaleSampledTrialsToTheFullData() {
        let trial = TrialResult(method: .copy, compressedBytes: 1_000, seconds: 1, sampled: true)
        #expect(Hybrid.scaledSize(trial, inputBytes: 5 << 20, totalBytes: 50 << 20) == 10_000)
        #expect(Hybrid.scaledSize(trial, inputBytes: 5 << 20, totalBytes: 5 << 20) == 1_000)
        let g = group("ext:txt", .text, files: ["a.txt"], bytes: 4_000)
        let report = GroupReport(group: g, trials: [TrialResult(method: .copy, compressedBytes: 900, seconds: 0, sampled: false)],
                                 winner: .copy)
        #expect(Hybrid.estimate(report, input: nil) == 900)
        #expect(Hybrid.estimate(GroupReport(group: g, trials: [], winner: .copy), input: nil) == 4_000)
    }

    @Test func blockMustBeatTheSplitByMoreThanTheHeaderSlack() {
        #expect(Hybrid.blockWins(block: 900_000, split: 1_000_000, groups: 3))
        #expect(!Hybrid.blockWins(block: 999_900, split: 1_000_000, groups: 3))   // noise-level difference
        #expect(!Hybrid.blockWins(block: 1_000_000, split: 1_000_000, groups: 2))
        #expect(!Hybrid.blockWins(block: .max, split: 1_000_000, groups: 2))
        #expect(!Hybrid.blockWins(block: 10, split: 1_000_000, groups: 1))
    }

    @Test func layoutSelectionBuildsOnlyWhatTheEstimatesLeaveOpen() {
        // No hybrid layout: per-group only.
        #expect(Hybrid.layoutsToBuild(perGroup: 1_000, hybrid: nil, sampled: false) == (true, false))
        // Exact trials, clear winner: the other layout is never built.
        #expect(Hybrid.layoutsToBuild(perGroup: 1_000_000, hybrid: 900_000, sampled: false) == (false, true))
        // Exact trials, difference below the margin: both.
        #expect(Hybrid.layoutsToBuild(perGroup: 1_000_000, hybrid: 998_000, sampled: false) == (true, true))
        // Sampled trials are estimates: both.
        #expect(Hybrid.layoutsToBuild(perGroup: 1_000_000, hybrid: 500_000, sampled: true) == (true, true))
    }

    @Test func settingsDecodeKeepsHybridOnWhenKeyIsMissing() throws {
        let decoded = try JSONDecoder().decode(OptimizerSettings.self, from: Data("{\"mode\":\"best\"}".utf8))
        #expect(decoded.hybridGroups)
        var off = OptimizerSettings()
        off.hybridGroups = false
        let again = try JSONDecoder().decode(OptimizerSettings.self, from: JSONEncoder().encode(off))
        #expect(!again.hybridGroups)
    }

    // MARK: End to end

    private func makeWorkspace(_ label: String) throws -> (dir: URL, tree: URL) {
        let dir = try TestSupport.makeTempDir(label)
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        return (dir, tree)
    }

    private func write(_ rel: String, _ data: Data, in root: URL) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func optimize(_ source: URL, in dir: URL, label: String, mode: OptimizationMode = .normal,
                          configure: (inout OptimizerSettings) -> Void = { _ in }) async throws -> OptimizationResult {
        var s = OptimizerSettings()
        s.mode = mode
        s.concurrentTrials = 2
        s.outputDirectory = dir.appendingPathComponent("out-\(label)")
        configure(&s)
        let optimizer = ArchiveOptimizer(tool: try TestSupport.tool(), settings: s,
                                         temporaryDirectory: dir.appendingPathComponent("tmp-\(label)"))
        return try await optimizer.optimize(source) { _ in }
    }

    /// Many small text files, each extension with its own few kilobytes of the same vocabulary: one block per
    /// extension pays the start-up cost of its coder and its block headers over and over.
    private func makeRelatedTextTree(_ tree: URL) throws {
        let extensions = ["txt", "md", "h", "c", "cpp", "py", "js", "css", "html", "xml", "json", "csv", "log", "ini",
                          "cfg", "yml", "toml", "rst", "tex", "sql", "sh", "rb", "go", "java", "swift", "php", "pl",
                          "lua", "rs", "ts"]
        for (i, ext) in extensions.enumerated() {
            for n in 0..<3 {
                try write("src/f\(n).\(ext)", TestSupport.textBytes(150, seed: UInt64(i * 10 + n + 1)), in: tree)
            }
        }
    }

    @Test func relatedTextUnderManyExtensionsBeatsPerGroupAsOneBlock() async throws {
        let (dir, tree) = try makeWorkspace("hybrid-win")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRelatedTextTree(tree)
        let source = dir.appendingPathComponent("related.tar")
        try TestSupport.makeArchive(from: tree, at: source, type: "tar")

        let hybrid = try await optimize(source, in: dir, label: "on") { $0.minGroupBytes = 256 }
        let split = try await optimize(source, in: dir, label: "off") { $0.minGroupBytes = 256; $0.hybridGroups = false }

        #expect(hybrid.strategy == "hybrid")
        #expect(hybrid.optimizedBytes < split.optimizedBytes, "hybrid \(hybrid.optimizedBytes) vs per-group \(split.optimizedBytes)")
        #expect(split.strategy != "hybrid" && split.families.isEmpty)
        let family = try #require(hybrid.families.first { $0.id == "fam:text" })
        #expect(family.useBlock && family.blockBytes < family.splitBytes)
        #expect(family.groupIDs.count >= 20 && family.winner != nil && family.trialCount >= 2)
        // The report lists the layout that won: one family block instead of the extension groups.
        let block = try #require(hybrid.groups.first { $0.group.id == "fam:text" })
        #expect(block.trials.contains { $0.method == block.winner })
        #expect(!hybrid.groups.contains { $0.group.id == "ext:txt" })
        #expect(hybrid.trialCount > split.trialCount)

        // The archive holds the family as a single solid block and extracts to the same tree.
        let output = try #require(hybrid.outputURL)
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
        let listing = try await TestSupport.tool().list(output)
        let textMethods = Set(listing.entries.filter { $0.path.hasPrefix("src/") }.compactMap(\.method))
        #expect(textMethods.count == 1, "the text files should share one coder: \(textMethods)")
        #expect(TestSupport.entries(in: dir.appendingPathComponent("tmp-on")).isEmpty)
    }

    @Test func mediaHeavyTreeKeepsPerGroupBlocks() async throws {
        let (dir, tree) = try makeWorkspace("hybrid-media")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two compressed groups (the family block is a plain copy, no better than two copies), raw audio, raw
        // image, text and a program: every family has one group or loses as a block.
        try write("a/photo.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0]) + TestSupport.randomBytes(120_000, seed: 3), in: tree)
        try write("a/clip.mp3", Data([0x49, 0x44, 0x33, 0x03]) + TestSupport.randomBytes(110_000, seed: 4), in: tree)
        try write("b/tone.wav", TestSupport.wavBytes(frames: 150_000), in: tree)
        try write("b/pic.bmp", TestSupport.bmpBytes(width: 300, height: 200), in: tree)
        try write("c/notes.txt", TestSupport.textBytes(30_000, seed: 8), in: tree)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: tree.appendingPathComponent("tool"))
        let source = dir.appendingPathComponent("media.tar")
        try TestSupport.makeArchive(from: tree, at: source, type: "tar")

        let result = try await optimize(source, in: dir, label: "media") { $0.minGroupBytes = 4096 }
        #expect(result.outcome == .optimized)
        #expect(result.strategy == "per-group", "strategy \(result.strategy)")
        #expect(result.families.allSatisfy { !$0.useBlock })
        // Both compressed groups were stored: a block of copies cannot win, so no trial is spent on it.
        #expect(!result.families.contains { $0.id == "fam:compressed" })
        for id in ["ext:jpg", "ext:mp3", "ext:wav", "ext:bmp", "ext:txt"] {
            #expect(result.groups.contains { $0.group.id == id }, "missing \(id)")
        }
        #expect(!result.groups.contains { $0.group.id.hasPrefix("fam:") })
        let wav = try #require(result.groups.first { $0.group.id == "ext:wav" })
        #expect(wav.winner.description.contains("Delta"))
        let output = try #require(result.outputURL)
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    @Test func hybridWithSamplingStillRoundTripsAndNeverLosesToPerGroup() async throws {
        let (dir, tree) = try makeWorkspace("hybrid-sampled")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRelatedTextTree(tree)
        let source = dir.appendingPathComponent("related.zip")
        try TestSupport.makeArchive(from: tree, at: source, type: "zip")
        let sampled = try await optimize(source, in: dir, label: "s1", mode: .good) {
            $0.minGroupBytes = 256
            $0.samplingLevel = 1
        }
        #expect(sampled.outcome == .optimized)
        let output = try #require(sampled.outputURL)
        let extracted = dir.appendingPathComponent("extracted")
        try TestSupport.extract(output, into: extracted)
        #expect(try TestSupport.fingerprint(extracted) == TestSupport.fingerprint(tree))
    }

    @Test func fastModeSkipsFamilies() async throws {
        let (dir, tree) = try makeWorkspace("hybrid-fast")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRelatedTextTree(tree)
        let source = dir.appendingPathComponent("related.tar")
        try TestSupport.makeArchive(from: tree, at: source, type: "tar")
        let result = try await optimize(source, in: dir, label: "fast", mode: .fast)
        #expect(result.families.isEmpty)
        #expect(result.strategy.hasPrefix("whole-archive LZMA2"))
        #expect(result.trialCount == 1)
    }
}
