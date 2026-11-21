import Foundation

/// Affinity family of a file category: files of one family tend to repeat each other's content, so storing
/// them in a single solid block can beat one block per extension (headers next to extensionless headers,
/// man pages next to their sources). The compressor has to differ from family to family, not within one.
public enum FileFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Text, source code, markup, data in text form.
    case text
    /// Mach-O, PE, ELF programs and libraries.
    case executable
    case audioRaw
    case imageRaw
    /// Already compressed or incompressible (jpg, mp4, zip, …).
    case compressed
    /// Generic binary data and unknown extensions.
    case binary

    public var id: String { rawValue }

    public init(category: FileCategory) {
        switch category {
        case .text: self = .text
        case .executable: self = .executable
        case .audioRaw: self = .audioRaw
        case .imageRaw: self = .imageRaw
        case .compressed: self = .compressed
        case .binary, .misc: self = .binary
        }
    }

    /// Id of the family group in reports: "fam:<name>".
    public var groupID: String { "fam:\(rawValue)" }

    public var displayName: String {
        switch self {
        case .text: "Text and source"
        case .executable: "Executables"
        case .audioRaw: "Raw audio"
        case .imageRaw: "Raw images"
        case .compressed: "Compressed"
        case .binary: "Binary data"
        }
    }
}

/// Planning of the hybrid layout: one solid block per family where that is smaller than one per extension.
enum Hybrid {
    /// Two or more extension groups of one family, and the group that holds all their files.
    struct Family: Sendable {
        var family: FileFamily
        /// Indices into the array of extension groups.
        var members: [Int]
        /// Id "fam:<name>"; files ordered by extension, then path (the order `-mqs=on` gives).
        var group: FileGroup
    }

    /// Families that have at least two extension groups. A family with a single group is that group:
    /// its trials already exist and a second block layout would be identical.
    static func families(of groups: [FileGroup]) -> [Family] {
        var byFamily: [FileFamily: [Int]] = [:]
        for (i, g) in groups.enumerated() { byFamily[FileFamily(category: g.category), default: []].append(i) }
        var result: [Family] = []
        for family in FileFamily.allCases {
            guard let members = byFamily[family], members.count >= 2 else { continue }
            result.append(Family(family: family, members: members, group: familyGroup(family, members: members.map { groups[$0] })))
        }
        return result
    }

    static func familyGroup(_ family: FileFamily, members: [FileGroup]) -> FileGroup {
        var keyed: [(ext: String, path: String)] = []
        for g in members { for path in g.files { keyed.append((FileClassifier.extensionKey(forPath: path), path)) } }
        keyed.sort { ($0.ext, $0.path) < ($1.ext, $1.path) }
        // Most voluminous category first so the family reads like its biggest member.
        let lead = members.max { $0.totalBytes < $1.totalBytes }!
        var group = FileGroup(id: family.groupID, category: lead.category,
                              extensions: Set(members.flatMap(\.extensions)).sorted(),
                              files: keyed.map(\.path), totalBytes: members.reduce(Int64(0)) { $0 + $1.totalBytes })
        var architectures: [ExecutableArchitecture] = []
        for g in members.sorted(by: { $0.totalBytes > $1.totalBytes }) {
            for a in g.executableArchitectures where !architectures.contains(a) { architectures.append(a) }
        }
        group.executableArchitectures = architectures
        return group
    }

    /// A method without its dictionary size and chunk size, so that "LZMA2:d=128m:fb=273" of an extension group
    /// matches the "LZMA2:d=256m:fb=273:c=512m" of the family block that holds it. Sorting switches do not count either.
    static func key(_ spec: MethodSpec) -> String {
        let coders = spec.coders.map { coder in
            coder.split(separator: ":").filter { !$0.hasPrefix("d=") && !$0.hasPrefix("c=") }.joined(separator: ":")
        }
        let extras = spec.extraArgs.filter { $0 != MethodSpec.sortByTypeSwitch }
        return (coders + extras).joined(separator: "|")
    }

    /// A family whose biggest group holds at least this share of its bytes is not tried as a block: the block is
    /// that group plus crumbs, the trials would repeat the group's own, and the gain is bounded by the crumbs.
    static let dominantShare = 0.95

    /// In normal mode a family block is only tried on full data up to this size: the trials read it once per
    /// method (and again for the sorted variants), which on a 100 MB block costs about as much as the rest of the
    /// run for a gain of a few hundredths of a percent. Good and above pay the price, as does any run that samples.
    static let normalModeBlockLimit: Int64 = 32 << 20

    /// A family whose members all stored their files (Copy won) cannot be beaten by a block, which is a copy
    /// plus a block header, and neither can one whose groups together are within 1% of their raw size: the
    /// trials would be whole-family passes that cannot win. Groups without a trial of their own (too small) count
    /// as unknown, never as incompressible.
    static let incompressibleShare = 0.99

    static func cannotWin(_ family: Family, reports: [GroupReport], inputs: [TrialInput?]) -> Bool {
        var split: Int64 = 0
        var allStored = true
        for i in family.members {
            guard reports[i].trials.contains(where: { $0.method == reports[i].winner }) else { return false }
            if reports[i].winner != .copy { allStored = false }
            split += estimate(reports[i], input: inputs[i])
        }
        if allStored { return true }
        return Double(split) >= incompressibleShare * Double(family.group.totalBytes)
    }

    /// Whether a family block is worth its trials: not dominated by one group, not a family that cannot win, and
    /// in normal mode on full data not larger than `normalModeBlockLimit`.
    static func worthTrial(_ family: Family, groups: [FileGroup], reports: [GroupReport], inputs: [TrialInput?],
                           settings: OptimizerSettings) -> Bool {
        if isDominated(family, groups: groups) || cannotWin(family, reports: reports, inputs: inputs) { return false }
        if settings.mode.rank <= 1 && settings.samplingLevel == 0 && family.group.totalBytes > normalModeBlockLimit { return false }
        return true
    }

    /// True when trials and assembly of a group of `bytes` may not give the same size: LZMA2 cuts data larger
    /// than 256 MB into independent chunks only when 7zz has at least four threads, and a trial may have fewer.
    static func chunkingDiffers(bytes: Int64, trialThreads: Int, soloThreads: Int) -> Bool {
        bytes > 256 << 20 && (trialThreads >= 4) != (soloThreads >= 4)
    }

    static func isDominated(_ family: Family, groups: [FileGroup]) -> Bool {
        let total = family.group.totalBytes
        guard total > 0 else { return true }
        let biggest = family.members.map { groups[$0].totalBytes }.max() ?? 0
        return Double(biggest) >= dominantShare * Double(total)
    }

    /// Methods worth a trial on the family block: the cheapest tier of the mode (always), plus every method that
    /// won in one of its extension groups. Those groups were already tried against the full candidate set, so the
    /// rest would rarely win on the union and would cost a full pass over a large block each. Files in name order.
    static func candidates(for family: Family, groups: [FileGroup], winners: [MethodSpec], settings: OptimizerSettings,
                           concurrentBuilds: Int,
                           threads: Int = ProcessInfo.processInfo.activeProcessorCount,
                           physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [MethodSpec] {
        // Binary data and unknown extensions share a family but have separate candidate tables.
        var categories: [FileCategory] = []
        for i in family.members where !categories.contains(groups[i].category) { categories.append(groups[i].category) }
        var tierOne = OrderedSpecs()
        var full = OrderedSpecs()
        var cheapest = settings
        cheapest.mode = .normal
        for category in categories {
            var g = family.group
            g.category = category
            tierOne.add(CandidateGenerator.candidates(for: g, settings: cheapest, isSingleExtensionArchive: false,
                                                      growDictionary: true, concurrentBuilds: concurrentBuilds,
                                                      threads: threads, physicalMemory: physicalMemory))
            full.add(CandidateGenerator.candidates(for: g, settings: settings, isSingleExtensionArchive: false,
                                                   growDictionary: true, concurrentBuilds: concurrentBuilds,
                                                   threads: threads, physicalMemory: physicalMemory))
        }
        let wanted = Set(winners.map(key))
        // A block holds more repeats than any of its groups, so PPMd keeps gaining from a higher order after it
        // stops doing so on a group (o=16 won on the headers of a 135 MB source tree, o=32 on the family).
        let lowestPPMdOrder = winners.compactMap(ppmdOrder).min()
        var kept = OrderedSpecs()
        kept.add(tierOne.specs)
        kept.add(full.specs.filter { spec in
            if wanted.contains(key(spec)) { return true }
            if let lowest = lowestPPMdOrder, let order = ppmdOrder(spec), order >= lowest { return true }
            return false
        })
        return kept.specs
    }

    /// Model order of a plain PPMd method ("PPMd:mem=256m:o=16" gives 16), nil for anything else.
    static func ppmdOrder(_ spec: MethodSpec) -> Int? {
        guard spec.coders.count == 1 else { return nil }
        let parts = spec.coders[0].split(separator: ":")
        guard parts.first?.uppercased() == "PPMD" else { return nil }
        return parts.compactMap { $0.hasPrefix("o=") ? Int($0.dropFirst(2)) : nil }.first
    }

    /// The sorted-by-type (`-mqs=on`) variant of the `count` best methods of a first round of trials. The effect of
    /// the order depends on the compressor (PPMd gains from it, LZMA2 often loses), so it is tried on the leaders
    /// only instead of doubling the whole round.
    static func sortedVariants(of trials: [TrialResult], count: Int = 2) -> [MethodSpec] {
        let leaders = trials.enumerated().sorted { ($0.element.compressedBytes, $0.offset) < ($1.element.compressedBytes, $1.offset) }
        var result: [MethodSpec] = []
        // Copy ignores the order of the files, and a stored block is the sum of its members.
        for (_, trial) in leaders.prefix(count)
        where !trial.method.extraArgs.contains(MethodSpec.sortByTypeSwitch) && trial.method != .copy {
            var spec = trial.method
            spec.extraArgs.append(MethodSpec.sortByTypeSwitch)
            result.append(spec)
        }
        return result
    }

    /// Packed size of a trial scaled from the bytes it saw to the whole group.
    static func scaledSize(_ trial: TrialResult, inputBytes: Int64, totalBytes: Int64) -> Int64 {
        guard inputBytes > 0, inputBytes != totalBytes else { return trial.compressedBytes }
        return Int64((Double(trial.compressedBytes) * Double(totalBytes) / Double(inputBytes)).rounded())
    }

    /// Estimated packed size of an extension group: its winning trial scaled to the full data. A group without a
    /// trial (too small) counts at its raw size.
    static func estimate(_ report: GroupReport, input: TrialInput?) -> Int64 {
        guard let winner = report.trials.first(where: { $0.method == report.winner }) else { return report.group.totalBytes }
        return scaledSize(winner, inputBytes: input?.bytes ?? report.group.totalBytes, totalBytes: report.group.totalBytes)
    }

    /// One block against the split. Each trial archive carries its own headers while the assembled archive has one
    /// set, which favours the block by a few dozen bytes per extra group; the block has to win by more than that
    /// and by 0.05% of the split to count.
    static func blockWins(block: Int64, split: Int64, groups: Int) -> Bool {
        guard block < Int64.max, groups >= 2 else { return false }
        let slack = Int64(groups - 1) * 128 + split / 2000
        return block + slack < split
    }

    /// Which archives to build, given the estimates of the two layouts. Trials on full data are exact (family
    /// blocks carry an explicit LZMA2 chunk size, so the thread count does not change them), so the layout with
    /// the smaller estimate is built alone unless the other is within `margin`; sampled trials are only an
    /// estimate and both layouts are built.
    static func layoutsToBuild(perGroup: Int64, hybrid: Int64?, sampled: Bool,
                               margin: Double = 0.005) -> (perGroup: Bool, hybrid: Bool) {
        guard let hybrid else { return (true, false) }
        if sampled { return (true, true) }
        let best = min(perGroup, hybrid)
        let limit = Double(best) * (1 + margin)
        return (Double(perGroup) <= limit, Double(hybrid) <= limit)
    }
}

/// Insertion-ordered set of method specs.
struct OrderedSpecs {
    private(set) var specs: [MethodSpec] = []
    private var seen = Set<MethodSpec>()
    mutating func add(_ items: [MethodSpec]) {
        for s in items where seen.insert(s).inserted { specs.append(s) }
    }
}

/// What the trials on one family block found.
struct FamilyOutcome: Sendable {
    var family: Hybrid.Family
    var list: URL
    var trials: [TrialResult]
    var winner: MethodSpec?
    var blockBytes: Int64
    var splitBytes: Int64
    var useBlock: Bool {
        winner != nil && Hybrid.blockWins(block: blockBytes, split: splitBytes, groups: family.members.count)
    }
}

extension ArchiveOptimizer {
    /// Family trials in flight at once. Each writes an archive as large as its block, which for a block that does
    /// not compress is the block itself, so the number is held to what `requiredSpace` reserves for the
    /// per-group trials of the same size.
    func familyConcurrency(_ job: Job) -> Int { min(job.concurrentTrials, 4) }

    /// Runs the family trials: every family with two or more extension groups is compressed as one block with a
    /// reduced candidate set (see `Hybrid.candidates`) and compared with the sum of its groups. A second round
    /// tries the sorted-by-type order on the two best methods of each family. With sampling the trials use a
    /// sample of the family. `progress` receives the trials finished and planned so far; its last call has both
    /// equal to the number of trials run.
    func evaluateFamilies(job: Job, groups: [FileGroup], reports: [GroupReport], inputs: [TrialInput?],
                          snapshot: TreeSnapshot, firstTrialID: Int,
                          progress: (_ done: Int, _ planned: Int) -> Void) async throws -> [FamilyOutcome] {
        struct Plan {
            var family: Hybrid.Family
            var list: URL
            var input: TrialInput
            var candidates: [MethodSpec]
            var trials: [TrialResult] = []
        }
        var plans: [Plan] = []
        for family in Hybrid.families(of: groups)
        where family.group.totalBytes >= Self.minTrialBytes
            && Hybrid.worthTrial(family, groups: groups, reports: reports, inputs: inputs, settings: settings) {
            let winners = family.members.map { reports[$0].winner }
            let candidates = Hybrid.candidates(for: family, groups: groups, winners: winners, settings: settings,
                                               concurrentBuilds: familyConcurrency(job),
                                               threads: job.settings.trialThreads(concurrent: job.concurrentTrials))
            guard !candidates.isEmpty else { continue }
            let name = family.family.rawValue
            let input = try Sampling.prepare(group: family.group, root: job.root, snapshot: snapshot,
                                             level: settings.samplingLevel,
                                             directory: job.sampleDir.appendingPathComponent("fam_\(name)", isDirectory: true),
                                             listFile: job.listsDir.appendingPathComponent("trial_fam_\(name).txt"))
            let list = job.listsDir.appendingPathComponent("full_fam_\(name).txt")
            try ListFile.write(family.group.files, to: list)
            plans.append(Plan(family: family, list: list, input: input, candidates: candidates))
        }
        guard !plans.isEmpty else { return [] }

        var done = 0
        var nextID = firstTrialID
        var planned = plans.reduce(0) { $0 + $1.candidates.count + min(2, $1.candidates.count) }
        func round(_ specs: [(plan: Int, spec: MethodSpec)]) async throws {
            let jobs = specs.map { Job.TrialJob(groupIndex: $0.plan, spec: $0.spec, input: plans[$0.plan].input) }
            let base = nextID
            nextID += jobs.count
            var found: [(plan: Int, trial: TrialResult)] = []
            try await Job.runBounded(limit: familyConcurrency(job), count: jobs.count,
                                     work: { try await job.runTrial(jobs[$0], id: base + $0) },
                                     onResult: { index, outcome in
                switch outcome {
                case .measured(let r): found.append((jobs[index].groupIndex, r))
                case .failed(let message): job.log("Trial skipped: \(message)")
                }
                done += 1
                progress(done, planned)
            })
            for (p, trial) in found { plans[p].trials.append(trial) }
        }
        progress(0, planned)
        try await round(plans.indices.flatMap { p in plans[p].candidates.map { (p, $0) } })
        let second = plans.indices.flatMap { p in
            Hybrid.sortedVariants(of: plans[p].trials).map { (p, $0) }
        }
        planned = done + second.count
        try await round(second)
        progress(done, done)

        var outcomes: [FamilyOutcome] = []
        for plan in plans {
            // Candidate order (plain, then sorted) for a stable report; trials finish out of order.
            let order = Dictionary(plan.candidates.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let trials = plan.trials.enumerated().sorted { a, b in
                let ka = order[a.element.method] ?? (plan.candidates.count + a.offset)
                let kb = order[b.element.method] ?? (plan.candidates.count + b.offset)
                return ka < kb
            }.map(\.element)
            let winnerTrial = Job.pickWinner(trials)
            let total = plan.family.group.totalBytes
            let block = winnerTrial.map { Hybrid.scaledSize($0, inputBytes: plan.input.bytes, totalBytes: total) } ?? Int64.max
            let split = plan.family.members.reduce(Int64(0)) { $0 + Hybrid.estimate(reports[$1], input: inputs[$1]) }
            let outcome = FamilyOutcome(family: plan.family, list: plan.list, trials: trials, winner: winnerTrial?.method,
                                        blockBytes: block, splitBytes: split)
            if let w = outcome.winner {
                job.log("\(plan.family.group.id): one block \(w) ~\(block) bytes vs \(plan.family.members.count) groups ~\(split) bytes -> \(outcome.useBlock ? "one block" : "split by extension")")
            }
            outcomes.append(outcome)
        }
        return outcomes
    }
}
