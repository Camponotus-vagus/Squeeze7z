import Foundation

/// A mirror of the directory structure of the extracted tree (no files), with the same modes and
/// modification times. Adding it to an archive stores one entry per directory.
struct DirectoryStage: Sendable {
    let root: URL
    /// Names of the top-level directories, one per line, quoted for 7zz.
    let list: URL

    /// Creates the mirror under `work/dirs`. Returns nil when the tree has no directories.
    static func build(directories: [String: TreeSnapshot.DirectoryInfo], in work: URL) throws -> DirectoryStage? {
        guard !directories.isEmpty else { return nil }
        let root = work.appendingPathComponent("dirs", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func depth(_ path: String) -> Int { path.reduce(0) { $1 == "/" ? $0 + 1 : $0 } }
        let ordered = directories.keys.sorted { (depth($0), $0) < (depth($1), $1) }
        // Parents first, all owner-writable; the real modes are applied afterwards.
        for path in ordered {
            let full = root.path + "/" + path
            guard mkdir(full, 0o700) == 0 else {
                throw OptimizerError.toolFailed(command: "mkdir", exitCode: errno, stderr: full)
            }
        }
        // Children first, so that changing a parent never stops us from reaching a child.
        for path in ordered.reversed() {
            guard let info = directories[path] else { continue }
            let full = root.path + "/" + path
            var times = [timespec(tv_sec: info.mtimeSeconds, tv_nsec: info.mtimeNanoseconds),
                         timespec(tv_sec: info.mtimeSeconds, tv_nsec: info.mtimeNanoseconds)]
            if utimensat(AT_FDCWD, full, &times, AT_SYMLINK_NOFOLLOW) != 0 || chmod(full, mode_t(info.mode)) != 0 {
                throw OptimizerError.toolFailed(command: "chmod", exitCode: errno, stderr: full)
            }
        }
        let top = ordered.filter { !$0.contains("/") }
        let list = work.appendingPathComponent("lists/dirs.txt")
        try fm.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ListFile.write(top, to: list)
        return DirectoryStage(root: root, list: list)
    }
}

enum FileTree {
    /// Removes `url` even when it contains directories without write permission (which `removeItem` cannot
    /// delete): permissions are restored from the top down first.
    static func forceRemove(_ url: URL) {
        let fm = FileManager.default
        if (try? fm.removeItem(at: url)) != nil { return }
        restoreOwnerAccess(url.path)
        try? fm.removeItem(at: url)
    }

    /// Flags that stop a file from being deleted (a file locked in Finder has `uchg`).
    static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)

    /// Clears the lock flags of one item, without following a symlink.
    static func clearLockFlags(_ path: String) {
        var st = stat()
        if lstat(path, &st) == 0, st.st_flags & lockFlags != 0 { _ = lchflags(path, st.st_flags & ~lockFlags) }
    }

    private static func restoreOwnerAccess(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        if st.st_flags & lockFlags != 0 { _ = lchflags(path, st.st_flags & ~lockFlags) }
        guard st.st_mode & S_IFMT == S_IFDIR else { return }
        chmod(path, st.st_mode | 0o700)
        for name in (try? TreeScanner.listDirectory(path)) ?? [] { restoreOwnerAccess(path + "/" + name) }
    }
}
