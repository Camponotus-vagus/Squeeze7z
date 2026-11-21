import Foundation

/// Result of grouping an extracted tree.
struct GroupingResult: Sendable {
    /// Groups of regular files, largest first.
    var groups: [FileGroup]
    /// Symbolic links (stored as tiny entries, never trialled).
    var symlinks: [String]
    /// True when every regular file has the same extension.
    var isSingleExtensionArchive: Bool
}

enum Grouper {
    private struct Bucket {
        var ext: String
        var category: FileCategory
        var files: [String] = []
        var bytes: Int64 = 0
        var archBytes: [ExecutableArchitecture: Int64] = [:]
        var extensions: Set<String> = []
    }

    /// Groups regular files by lowercased extension. Groups below `minGroupBytes` are merged into one
    /// group per category. Unknown extensions are classified by sniffing the file header.
    static func makeGroups(snapshot: TreeSnapshot, root: URL, minGroupBytes: Int) -> GroupingResult {
        var buckets: [String: Bucket] = [:]
        var symlinks: [String] = []

        for path in snapshot.files.keys.sorted() {
            guard let info = snapshot.files[path] else { continue }
            if info.isSymlink { symlinks.append(path); continue }
            let ext = FileClassifier.extensionKey(forPath: path)
            var category = FileClassifier.category(forExtension: ext)
            var archs = Set<ExecutableArchitecture>()
            if (category == .misc || category == .executable || category == .binary) && info.size > 0 {
                let url = root.appendingPathComponent(path)
                if let prefix = ExecutableSniffer.readPrefix(of: url, count: 4096) {
                    let sniff = FileClassifier.sniff(prefix)
                    switch sniff {
                    case .executable(let a):
                        category = .executable
                        archs = a
                    case .compressed where category == .misc:
                        category = .compressed
                    case .text where category == .misc:
                        category = .text
                    default:
                        break
                    }
                }
            }
            let key = "\(ext)\u{0}\(category.rawValue)"
            // Mutated in place: a copy out of the dictionary would copy the file list on every append.
            buckets[key, default: Bucket(ext: ext, category: category)].files.append(path)
            buckets[key]!.bytes += info.size
            buckets[key]!.extensions.insert(ext)
            for a in archs { buckets[key]!.archBytes[a, default: 0] += max(info.size, 1) }
        }

        // Group ids: "ext:<ext>", disambiguated by category when one extension has several.
        var categoriesPerExt: [String: Int] = [:]
        for b in buckets.values { categoriesPerExt[b.ext, default: 0] += 1 }

        var finalGroups: [FileGroup] = []
        var merged: [FileCategory: Bucket] = [:]
        for b in buckets.values.sorted(by: { ($0.ext, $0.category.rawValue) < ($1.ext, $1.category.rawValue) }) {
            if b.bytes < Int64(minGroupBytes) {
                merged[b.category, default: Bucket(ext: "", category: b.category)].files += b.files
                merged[b.category]!.bytes += b.bytes
                merged[b.category]!.extensions.formUnion(b.extensions)
                for (a, w) in b.archBytes { merged[b.category]!.archBytes[a, default: 0] += w }
                continue
            }
            var id = "ext:" + (b.ext.isEmpty ? "(none)" : b.ext)
            if (categoriesPerExt[b.ext] ?? 1) > 1 { id += "#\(b.category.rawValue)" }
            finalGroups.append(makeGroup(id: id, bucket: b))
        }
        for (category, m) in merged {
            finalGroups.append(makeGroup(id: "cat:\(category.rawValue)", bucket: m))
        }
        finalGroups.sort { ($0.totalBytes, $1.id) > ($1.totalBytes, $0.id) }
        let regularExtensions = Set(buckets.values.map(\.ext))
        return GroupingResult(groups: finalGroups, symlinks: symlinks, isSingleExtensionArchive: regularExtensions.count <= 1)
    }

    private static func makeGroup(id: String, bucket b: Bucket) -> FileGroup {
        var g = FileGroup(id: id, category: b.category, extensions: b.extensions.sorted(),
                          files: b.files.sorted(), totalBytes: b.bytes)
        g.executableArchitectures = b.archBytes
            .sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
            .map(\.key)
        return g
    }
}
