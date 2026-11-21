import Foundation

/// What is on disk under an extraction root: regular files and symlinks with size and CRC32,
/// every directory with its mode and modification time, and the directories that contain nothing.
struct TreeSnapshot: Sendable {
    struct DirectoryInfo: Sendable, Equatable {
        var mode: UInt16
        var mtimeSeconds: Int
        var mtimeNanoseconds: Int
    }
    struct FileInfo: Sendable, Equatable {
        var size: Int64
        var crc: UInt32
        var isSymlink: Bool
    }
    /// Keyed by path relative to the root, "/" separated.
    var files: [String: FileInfo] = [:]
    var emptyDirectories: [String] = []
    /// Every directory below the root (not the root itself), keyed by relative path.
    var directories: [String: DirectoryInfo] = [:]

    var regularBytes: Int64 { files.values.reduce(0) { $0 + ($1.isSymlink ? 0 : $1.size) } }

    /// 7zz widens directory modes while extracting (it adds owner write, and applies the umask), so the
    /// modes on disk are not the stored ones. Where the source listing shows a Unix mode it wins. A mode
    /// without owner read and search access is left as extracted: the mirror that stores directories
    /// has to stay readable for 7zz. Modification times come out of the extraction intact and stay.
    mutating func adoptDirectoryModes(from listing: ArchiveListing) {
        var stored: [String: UInt16] = [:]
        for entry in listing.entries where entry.isDirectory {
            if let mode = entry.unixMode, mode & 0o500 == 0o500 { stored[SourceChecks.key(entry.path)] = mode }
        }
        guard !stored.isEmpty else { return }
        for path in Array(directories.keys) {
            if let mode = stored[SourceChecks.key(path)] { directories[path]?.mode = mode }
        }
    }
}

enum TreeScanner {
    private struct Item {
        var path: String
        var size: Int64
        var isSymlink: Bool
    }

    /// Walks `root` without following symlinks and computes CRC32 of every file (one file per core at a time,
    /// at least 4).
    /// Special files (sockets, devices, FIFOs) are ignored.
    static func scan(root: URL) async throws -> TreeSnapshot {
        var items: [Item] = []
        var emptyDirs: [String] = []
        var directories: [String: TreeSnapshot.DirectoryInfo] = [:]
        try walk(root: root.path, relative: "", items: &items, emptyDirs: &emptyDirs, directories: &directories)

        var snapshot = TreeSnapshot()
        snapshot.emptyDirectories = emptyDirs.sorted()
        snapshot.directories = directories
        try await withThrowingTaskGroup(of: (String, TreeSnapshot.FileInfo).self) { group in
            var iterator = items.makeIterator()
            var running = 0
            func start(_ item: Item, in group: inout ThrowingTaskGroup<(String, TreeSnapshot.FileInfo), Error>) {
                let url = root.appendingPathComponent(item.path)
                group.addTask {
                    if Task.isCancelled { throw OptimizerError.cancelled }
                    if item.isSymlink {
                        let r = try CRC32.checksumOfLinkTarget(at: url)
                        return (item.path, .init(size: r.size, crc: r.crc, isSymlink: true))
                    }
                    let crc = try CRC32.checksum(of: url) {
                        if Task.isCancelled { throw OptimizerError.cancelled }
                    }
                    return (item.path, .init(size: item.size, crc: crc, isSymlink: false))
                }
            }
            let width = max(4, ProcessInfo.processInfo.activeProcessorCount)
            while running < width, let next = iterator.next() {
                start(next, in: &group)
                running += 1
            }
            while let (path, info) = try await group.next() {
                snapshot.files[path] = info
                if let next = iterator.next() { start(next, in: &group) }
            }
        }
        return snapshot
    }

    /// Names in a directory, read with `readdir` so that nothing is hidden: `FileManager` omits AppleDouble
    /// style names (`._x`), which are ordinary files as far as the archive is concerned.
    static func listDirectory(_ path: String) throws -> [String] {
        guard let dir = opendir(path) else { throw unreadable(path, code: errno) }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    private static func unreadable(_ path: String, code: Int32) -> OptimizerError {
        .unreadable("\(path) (\(String(cString: strerror(code))))")
    }

    private static func walk(root: String, relative: String, items: inout [Item], emptyDirs: inout [String],
                             directories: inout [String: TreeSnapshot.DirectoryInfo]) throws {
        if Task.isCancelled { throw OptimizerError.cancelled }
        let dirPath = relative.isEmpty ? root : root + "/" + relative
        let names = try listDirectory(dirPath)
        var counted = 0
        for name in names {
            let rel = relative.isEmpty ? name : relative + "/" + name
            let full = root + "/" + rel
            var st = stat()
            guard lstat(full, &st) == 0 else { throw unreadable(rel, code: errno) }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                counted += 1
                directories[rel] = .init(mode: UInt16(st.st_mode & 0o7777),
                                         mtimeSeconds: Int(st.st_mtimespec.tv_sec),
                                         mtimeNanoseconds: Int(st.st_mtimespec.tv_nsec))
                try walk(root: root, relative: rel, items: &items, emptyDirs: &emptyDirs, directories: &directories)
            case S_IFREG:
                counted += 1
                guard access(full, R_OK) == 0 else { throw unreadable(rel, code: errno) }
                items.append(Item(path: rel, size: Int64(st.st_size), isSymlink: false))
            case S_IFLNK:
                counted += 1
                items.append(Item(path: rel, size: 0, isSymlink: true))
            default:
                continue
            }
        }
        if counted == 0 && !relative.isEmpty { emptyDirs.append(relative) }
    }
}
