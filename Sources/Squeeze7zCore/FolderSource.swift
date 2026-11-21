import Foundation

/// Compressing a plain folder: it is staged under the work directory as `<root>/<FolderName>` (an APFS clone
/// where possible, a real copy otherwise) and goes through the same pipeline as the unpacked archive tree.
/// The source folder is only ever read.
enum FolderStage {
    struct Entry {
        enum Kind { case directory, file, link }
        var path: String
        var kind: Kind
        var size: Int64
        var mode: mode_t
        var seconds: Int
        var nanoseconds: Int
    }

    struct Listing {
        var entries: [Entry] = []
        var regularBytes: Int64 = 0
        var skipped: [String] = []
    }

    /// Walks the folder without following links. Sockets, FIFOs and devices hold no data and are skipped;
    /// a file or folder that cannot be read fails with `OptimizerError.unreadable`.
    static func scan(_ root: String) throws -> Listing {
        var listing = Listing()
        try walk(root: root, relative: "", into: &listing)
        try rejectCollisions(listing)
        return listing
    }

    /// The work folder is on a case-insensitive volume that also ignores Unicode forms, so two names that differ
    /// only that way (possible on a case-sensitive source volume) would land on one file.
    static func rejectCollisions(_ listing: Listing) throws {
        var seen: [String: String] = [:]
        for entry in listing.entries {
            let key = SourceChecks.key(entry.path).lowercased()
            if let other = seen[key] {
                throw OptimizerError.folderProblem("\(other) and \(entry.path) differ only in case or Unicode form. They cannot both be stored: the 7z would be extracted on a case-insensitive volume as one file, so the folder cannot be compressed safely.")
            }
            seen[key] = entry.path
        }
    }

    private static func walk(root: String, relative: String, into listing: inout Listing) throws {
        if Task.isCancelled { throw OptimizerError.cancelled }
        let dir = relative.isEmpty ? root : root + "/" + relative
        for name in try TreeScanner.listDirectory(dir).sorted() {
            let rel = relative.isEmpty ? name : relative + "/" + name
            let full = root + "/" + rel
            var st = stat()
            guard lstat(full, &st) == 0 else { throw unreadable(rel) }
            func entry(_ kind: Entry.Kind, size: Int64 = 0) -> Entry {
                Entry(path: rel, kind: kind, size: size, mode: st.st_mode & 0o7777,
                      seconds: Int(st.st_mtimespec.tv_sec), nanoseconds: Int(st.st_mtimespec.tv_nsec))
            }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                listing.entries.append(entry(.directory))
                try walk(root: root, relative: rel, into: &listing)
            case S_IFREG:
                guard access(full, R_OK) == 0 else { throw unreadable(rel) }
                listing.entries.append(entry(.file, size: Int64(st.st_size)))
                listing.regularBytes += Int64(st.st_size)
            case S_IFLNK:
                listing.entries.append(entry(.link))
            default:
                listing.skipped.append(rel)
            }
        }
    }

    private static func failure(_ path: String, _ code: Int32) -> OptimizerError {
        let text = "\(path) (\(String(cString: strerror(code))))"
        return code == EACCES || code == EPERM ? .unreadable(text) : .folderProblem("Cannot stage \(text).")
    }

    private static func unreadable(_ path: String) -> OptimizerError {
        .unreadable("\(path) (\(String(cString: strerror(errno))))")
    }

    /// Recreates the listed entries under `destination`. Cloning costs no space; the first file that cannot be
    /// cloned (other volume, no APFS) calls `beforeRealCopy` once, then every such file is copied.
    static func stage(_ listing: Listing, from source: String, to destination: String,
                      beforeRealCopy: () throws -> Void) throws {
        guard mkdir(destination, 0o700) == 0 else {
            throw OptimizerError.toolFailed(command: "mkdir", exitCode: errno, stderr: destination)
        }
        for entry in listing.entries where entry.kind == .directory {
            let to = destination + "/" + entry.path
            guard mkdir(to, 0o700) == 0 else {
                throw OptimizerError.toolFailed(command: "mkdir", exitCode: errno, stderr: to)
            }
        }
        if Task.isCancelled { throw OptimizerError.cancelled }
        // Files and links are cloned in parallel (one clonefile call each; a tree of small files spends most of its
        // time in those calls). Entries the volume cannot clone are copied afterwards, one by one.
        let entries = listing.entries.filter { $0.kind != .directory }
        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            var toCopy: [Int] = []
            var failure: OptimizerError?
        }
        let outcome = Outcome()
        DispatchQueue.concurrentPerform(iterations: entries.count) { index in
            let entry = entries[index]
            let to = destination + "/" + entry.path
            if clonefile(source + "/" + entry.path, to, UInt32(CLONE_NOFOLLOW)) == 0 {
                // A file locked in Finder (uchg) would keep the work folder from being removed.
                FileTree.clearLockFlags(to)
                return
            }
            let code = errno
            outcome.lock.lock()
            defer { outcome.lock.unlock() }
            // Only "this volume cannot clone" falls back to a copy; anything else is the real error.
            if code == EXDEV || code == ENOTSUP {
                outcome.toCopy.append(index)
            } else if outcome.failure == nil {
                outcome.failure = failure(entry.path, code)
            }
        }
        if let failure = outcome.failure { throw failure }
        if Task.isCancelled { throw OptimizerError.cancelled }
        if !outcome.toCopy.isEmpty { try beforeRealCopy() }
        for index in outcome.toCopy.sorted() {
            if Task.isCancelled { throw OptimizerError.cancelled }
            let entry = entries[index]
            let from = source + "/" + entry.path
            let to = destination + "/" + entry.path
            if entry.kind == .link {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(from, &buffer, Int(PATH_MAX))
                guard n >= 0 else { throw failure(entry.path, errno) }
                buffer[n] = 0
                guard symlink(buffer, to) == 0 else { throw failure(entry.path, errno) }
            } else if copyfile(from, to, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL)) != 0 {
                throw failure(entry.path, errno)
            }
            FileTree.clearLockFlags(to)
        }
        // Directory modes and times last, children first: a read-only folder cannot be filled afterwards.
        for entry in listing.entries.reversed() where entry.kind == .directory {
            let to = destination + "/" + entry.path
            var times = [timespec(tv_sec: entry.seconds, tv_nsec: entry.nanoseconds),
                         timespec(tv_sec: entry.seconds, tv_nsec: entry.nanoseconds)]
            utimensat(AT_FDCWD, to, &times, AT_SYMLINK_NOFOLLOW)
            chmod(to, entry.mode)
        }
        var times = [timespec(tv_sec: 0, tv_nsec: 0), timespec(tv_sec: 0, tv_nsec: 0)]
        var st = stat()
        if lstat(source, &st) == 0 {
            times = [st.st_mtimespec, st.st_mtimespec]
            utimensat(AT_FDCWD, destination, &times, AT_SYMLINK_NOFOLLOW)
            chmod(destination, st.st_mode & 0o7777)
        }
    }
}

extension ArchiveOptimizer {
    /// The staged tree must hold exactly what the scan of the source listed (paths and sizes). The archive is
    /// verified against the staged tree, so a staging that dropped or merged files would otherwise go unnoticed.
    static func verifyStaging(_ listing: FolderStage.Listing, name: String, snapshot: TreeSnapshot) throws {
        func mismatch(_ what: String) -> OptimizerError {
            .folderProblem("The copy of the folder does not match the folder (\(what)). Nothing was written.")
        }
        let prefix = name + "/"
        let files = listing.entries.filter { $0.kind != .directory }
        guard snapshot.files.count == files.count else {
            throw mismatch("\(snapshot.files.count) files instead of \(files.count)")
        }
        for entry in files {
            guard let staged = snapshot.files[prefix + entry.path] else { throw mismatch("\(entry.path) is missing") }
            if entry.kind == .file && staged.size != entry.size { throw mismatch("\(entry.path) has another size") }
        }
        let directories = Set(listing.entries.filter { $0.kind == .directory }.map { prefix + $0.path } + [name])
        guard Set(snapshot.directories.keys) == directories else { throw mismatch("the folders differ") }
    }

    /// Where the archive of `source` will be written.
    func outputDirectory(for source: URL) -> URL {
        let parent = source.deletingLastPathComponent()
        return settings.outputMode == .replaceOriginal ? parent : (settings.outputDirectory ?? parent)
    }

    /// Fails before any work when the archive would land inside the folder (it would be written into the source,
    /// and a later run would pack it) or the destination cannot be written.
    func checkDestination(for source: URL) throws {
        let directory = outputDirectory(for: source).standardizedFileURL
        var folder = stat()
        guard lstat(source.path, &folder) == 0 else { return }
        // Walk up to the deepest folder that exists and compare identities: that also catches symlinks and
        // volumes that ignore case.
        var existing = directory.path
        var probe = stat()
        while stat(existing, &probe) != 0 {
            let parent = (existing as NSString).deletingLastPathComponent
            if parent == existing || parent.isEmpty { break }
            existing = parent
        }
        var level = existing
        while true {
            var st = stat()
            if stat(level, &st) == 0, st.st_dev == folder.st_dev, st.st_ino == folder.st_ino {
                throw OptimizerError.folderProblem("The output folder \(directory.path) is inside the folder being compressed. Choose another output folder.")
            }
            let parent = (level as NSString).deletingLastPathComponent
            if parent == level || parent.isEmpty { break }
            level = parent
        }
        guard access(existing, W_OK) == 0 else {
            throw OptimizerError.folderProblem("Cannot write to \(existing). Choose another output folder.")
        }
    }

    /// True for a real directory (a symlink to one is not).
    public static func isFolder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    func runFolder(job: Job, source: URL, started: Date) async throws -> OptimizationResult {
        let name = source.lastPathComponent
        guard !name.isEmpty, name != "/" else { throw OptimizerError.notAnArchive("\(source.path) is not a folder that can be compressed") }
        let fm = FileManager.default
        try checkDestination(for: source)

        job.emit(.phase(.inspecting))
        let listing = try FolderStage.scan(source.path)
        let originalBytes = listing.regularBytes
        for path in listing.skipped { job.log("Skipped \(path): sockets, pipes and device files hold no data.") }
        let fileCount = listing.entries.filter { $0.kind != .directory }.count
        job.log("folder: \(fileCount) files, \(ByteCountFormatter.string(fromByteCount: originalBytes, countStyle: .file))")
        if listing.entries.isEmpty {
            job.log("The folder is empty.")
            return OptimizationResult(sourceURL: source, outputURL: nil, sourceFormat: "folder",
                                      originalBytes: originalBytes, optimizedBytes: originalBytes, outcome: .noGain,
                                      groups: [], strategy: "per-group", trialCount: 0,
                                      startedAt: started, finishedAt: Date())
        }

        // 2. Stage: a clone costs no space for the tree itself, so it is not counted until a copy is needed.
        job.emit(.phase(.extracting))
        try checkDiskSpace(unpacked: originalBytes, alreadyUsed: -originalBytes)
        try fm.createDirectory(at: job.root, withIntermediateDirectories: true)
        try FolderStage.stage(listing, from: source.path, to: job.root.appendingPathComponent(name).path) {
            job.log("The folder cannot be cloned (other volume or not APFS): copying it.")
            try checkDiskSpace(unpacked: originalBytes)
        }
        let snapshot = try await TreeScanner.scan(root: job.root)
        try Self.verifyStaging(listing, name: name, snapshot: snapshot)
        for path in Array(snapshot.files.keys) + Array(snapshot.directories.keys) where path.contains("\n") || path.contains("\r") {
            throw OptimizerError.notAnArchive("file names containing line breaks are not supported (\(path.debugDescription))")
        }
        return try await pack(job: job, source: source, started: started, snapshot: snapshot, sourceFormat: "folder",
                              originalBytes: originalBytes, volumes: [], isFolder: true)
    }
}
