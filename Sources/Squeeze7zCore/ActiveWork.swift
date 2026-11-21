import Foundation

/// Process-wide record of what a run leaves behind: child processes and working directories.
/// Normal completion and cancellation clean up through the regular code paths; this registry covers
/// `exit()` while jobs run (the exit hook), and the owner marker lets the next start sweep what a
/// crash or `kill -9` left in the temporary folder.
final class ActiveWork: @unchecked Sendable {
    static let shared = ActiveWork()

    private let lock = NSLock()
    private var pids = Set<Int32>()
    private var directories = Set<String>()
    private var hookInstalled = false

    /// File inside every working directory holding the pid of the process that owns it.
    static let ownerFileName = ".owner-pid"

    func addChild(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(pid)
        installHookLocked()
    }

    func removeChild(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        pids.remove(pid)
    }

    func addDirectory(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        directories.insert(url.path)
        installHookLocked()
    }

    func removeDirectory(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        directories.remove(url.path)
    }

    private func installHookLocked() {
        guard !hookInstalled else { return }
        hookInstalled = true
        atexit { ActiveWork.shared.cleanUpAtExit() }
    }

    /// Kills the children still running and removes the working directories still registered.
    func cleanUpAtExit() {
        lock.lock()
        let children = pids
        let dirs = directories
        pids.removeAll()
        directories.removeAll()
        lock.unlock()
        for pid in children { kill(pid, SIGKILL) }
        for dir in dirs { FileTree.forceRemove(URL(fileURLWithPath: dir)) }
    }

    // MARK: Owner marker and sweeping

    static func writeOwnerMarker(in directory: URL) {
        let file = directory.appendingPathComponent(ownerFileName)
        try? Data("\(getpid())\n".utf8).write(to: file)
    }

    static func removeOwnerMarker(in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(ownerFileName))
    }

    static func isProcessAlive(_ pid: Int32) -> Bool {
        if pid == getpid() { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Removes job directories under `root` whose owner process is gone. Directories without a marker
    /// (kept for debugging, or foreign) and directories of live processes are left alone.
    /// Returns the number of directories removed.
    @discardableResult
    static func sweep(root: URL) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let marker = dir.appendingPathComponent(ownerFileName)
            guard let text = try? String(contentsOf: marker, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  !isProcessAlive(pid) else { continue }
            FileTree.forceRemove(dir)
            removed += 1
        }
        return removed
    }

    /// Removes captured-output files of child processes older than `age` seconds.
    static func sweepProcessOutput(in directory: URL, olderThan age: TimeInterval) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let limit = Date().addingTimeInterval(-age)
        for name in names {
            let url = directory.appendingPathComponent(name)
            if let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date, date < limit {
                try? fm.removeItem(at: url)
            }
        }
    }
}
