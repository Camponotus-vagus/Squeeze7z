import Foundation

/// Smart mode: next to the whole-archive LZMA2 baseline, a text-heavy tree is also built as two solid blocks,
/// all text files with PPMd and everything else with the baseline's LZMA2. The smaller archive wins.
struct SmartPlan: Sendable {
    static let strategy = "smart split"
    /// Text files must reach this size, and this share of the regular bytes, for the split to be worth building.
    static let minTextBytes: Int64 = 1 << 20
    static let minTextShare = 0.10
    static let maxPPMdMemoryMB = 256

    let text: FileGroup
    let textSpec: MethodSpec
    let textList: URL
    /// Everything that is not text (symlinks included); nil when the text files are the whole tree.
    let rest: FileGroup?
    let restSpec: MethodSpec
    let restList: URL?

    var restFileCount: Int { rest?.files.count ?? 0 }

    /// Report layout of the archive when the split wins.
    var reports: [GroupReport] {
        var list = [GroupReport(group: text, trials: [], winner: textSpec)]
        if let rest { list.append(GroupReport(group: rest, trials: [], winner: restSpec)) }
        return list
    }

    /// nil when the split does not apply: too little text, or PPMd not allowed.
    static func make(groups: [FileGroup], allPaths: [String], totalBytes: Int64, baseline: MethodSpec?,
                     settings: OptimizerSettings, listsDir: URL) throws -> SmartPlan? {
        guard let baseline, totalBytes > 0 else { return nil }
        let textGroups = groups.filter { $0.category == .text }
        let textBytes = textGroups.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard textBytes >= minTextBytes, Double(textBytes) >= minTextShare * Double(totalBytes),
              CandidateGenerator.isPPMdAllowed(bytes: textBytes, settings: settings) else { return nil }
        let textFiles = textGroups.flatMap(\.files).sorted()
        let textSet = Set(textFiles)
        let restFiles = allPaths.filter { !textSet.contains($0) }
        let restBytes = totalBytes - textBytes

        var text = FileGroup(id: "smart:text", category: .text,
                             extensions: Array(Set(textGroups.flatMap(\.extensions))).sorted(),
                             files: textFiles, totalBytes: textBytes)
        text.executableArchitectures = []
        let textList = listsDir.appendingPathComponent("smart_text.txt")
        try ListFile.write(textFiles, to: textList)
        var rest: FileGroup?
        var restList: URL?
        if !restFiles.isEmpty {
            let others = groups.filter { $0.category != .text }
            rest = FileGroup(id: "smart:rest", category: .misc,
                             extensions: Array(Set(others.flatMap(\.extensions))).sorted(),
                             files: restFiles, totalBytes: restBytes)
            restList = listsDir.appendingPathComponent("smart_rest.txt")
            try ListFile.write(restFiles, to: restList!)
        }
        let mem = max(1, min(settings.ppmdMemoryMB, maxPPMdMemoryMB))
        return SmartPlan(text: text, textSpec: MethodSpec(coders: ["PPMd:o=16:mem=\(mem)m"]), textList: textList,
                         rest: rest, restSpec: baseline, restList: restList)
    }
}

extension Job {
    /// Builds the two-block archive: the text block first, then the rest with 7zz's automatic branch filters
    /// (the ARM64 and RISC-V ones only when `allowModernFilters` is on), then the directory entries.
    func buildSmartSplit(_ plan: SmartPlan, directories: DirectoryStage?, into archive: URL) async throws {
        var restFiltersOff = false
        for attempt in 0..<2 {
            try? FileManager.default.removeItem(at: archive)
            try await tool.runChecked(addArguments(archive: archive, list: plan.textList, spec: plan.textSpec,
                                                   filtersOff: true, threads: soloThreadSwitch), currentDirectory: root)
            if let restList = plan.restList {
                try await tool.runChecked(addArguments(archive: archive, list: restList, spec: plan.restSpec,
                                                       filtersOff: restFiltersOff, threads: soloThreadSwitch),
                                          currentDirectory: root)
            }
            try await appendDirectories(directories, to: archive)
            if attempt == 0, !restFiltersOff, !settings.allowModernFilters,
               Self.usesModernFilter(try await tool.list(archive)) {
                restFiltersOff = true
                continue
            }
            break
        }
    }
}
