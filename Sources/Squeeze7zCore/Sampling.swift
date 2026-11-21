import Foundation

/// Input of the trials of one group: a working directory and a 7zz list file with paths relative to it.
struct TrialInput: Sendable {
    var directory: URL
    var listFile: URL
    var sampled: Bool
    /// Uncompressed bytes the trials see (the whole group, or the size of its sample).
    var bytes: Int64
}

enum ListFile {
    /// Writes one relative path per line (UTF-8). 7zz reads such lists with `@file` and `-scsUTF-8`.
    /// It trims each line and strips one pair of surrounding quotes, so every path is wrapped in a pair
    /// of its own: that keeps leading and trailing spaces and names that start and end with a quote.
    static func write(_ paths: [String], to url: URL) throws {
        let text = paths.map { "\"\($0)\"" }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: false, encoding: .utf8)
    }
}

enum Sampling {
    /// Byte budget of a sample for the given level (`n * 5` MiB), nil when trials use full data.
    static func budget(level: Int, groupBytes: Int64) -> Int64? {
        guard level > 0 else { return nil }
        let budget = Int64(min(level, 6)) * 5 * (1 << 20)
        return groupBytes > budget ? budget : nil
    }

    /// Which files make up a sample: whole files in path order while they fit, plus a truncated head of
    /// the first file that does not (when less than half of the budget is used so far).
    struct Plan: Equatable {
        var wholeFiles: [String]
        var truncated: (path: String, bytes: Int64)?
        static func == (a: Plan, b: Plan) -> Bool {
            a.wholeFiles == b.wholeFiles && a.truncated?.path == b.truncated?.path && a.truncated?.bytes == b.truncated?.bytes
        }
    }

    static func plan(files: [String], sizes: (String) -> Int64, budget: Int64) -> Plan {
        var whole: [String] = []
        var used: Int64 = 0
        for path in files.sorted() {
            let size = sizes(path)
            if used + size <= budget {
                whole.append(path)
                used += size
                continue
            }
            if used < budget / 2 {
                return Plan(wholeFiles: whole, truncated: (path, budget - used))
            }
            break
        }
        return Plan(wholeFiles: whole, truncated: nil)
    }

    /// Materializes a sample under `directory` (flat files named `s<N>.<ext>`) and returns its trial input.
    static func prepare(group: FileGroup, root: URL, snapshot: TreeSnapshot, level: Int,
                        directory: URL, listFile: URL) throws -> TrialInput {
        guard let budget = budget(level: level, groupBytes: group.totalBytes) else {
            try ListFile.write(group.files, to: listFile)
            return TrialInput(directory: root, listFile: listFile, sampled: false, bytes: group.totalBytes)
        }
        let plan = plan(files: group.files, sizes: { snapshot.files[$0]?.size ?? 0 }, budget: budget)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var names: [String] = []
        for (i, path) in plan.wholeFiles.enumerated() {
            let ext = FileClassifier.extensionKey(forPath: path)
            let name = ext.isEmpty ? "s\(i)" : "s\(i).\(ext)"
            try fm.copyItem(at: root.appendingPathComponent(path), to: directory.appendingPathComponent(name))
            names.append(name)
        }
        if let truncated = plan.truncated {
            let ext = FileClassifier.extensionKey(forPath: truncated.path)
            let name = ext.isEmpty ? "head" : "head.\(ext)"
            try copyHead(of: root.appendingPathComponent(truncated.path),
                         bytes: truncated.bytes, to: directory.appendingPathComponent(name))
            names.append(name)
        }
        if names.isEmpty {
            // First file alone exceeded the budget but `used < budget/2` always holds for it, so this is
            // unreachable for non-empty groups; fall back to the full list rather than an empty trial.
            try ListFile.write(group.files, to: listFile)
            return TrialInput(directory: root, listFile: listFile, sampled: false, bytes: group.totalBytes)
        }
        try ListFile.write(names, to: listFile)
        let sampleBytes = plan.wholeFiles.reduce(Int64(0)) { $0 + (snapshot.files[$1]?.size ?? 0) } + (plan.truncated?.bytes ?? 0)
        return TrialInput(directory: directory, listFile: listFile, sampled: true, bytes: max(sampleBytes, 1))
    }

    static func copyHead(of source: URL, bytes: Int64, to destination: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        var remaining = bytes
        while remaining > 0 {
            let chunk = Int(min(remaining, 1 << 20))
            guard let data = try reader.read(upToCount: chunk), !data.isEmpty else { break }
            try writer.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
    }
}
