import Foundation

/// Captured result of a child process.
struct ProcessOutput: Sendable {
    var exitCode: Int32
    var standardOutput: Data
    var standardError: Data
    /// 7zz ran with `-bsp1`: standard output holds progress segments to be left out when it is read.
    var hadProgress = false

    /// Standard output without 7zz's progress segments (`-bsp1`). Those redraw themselves with backspaces and
    /// carry file names, which must not be read as messages ("Wrong password" in a file name, for instance).
    /// Only the segments go: a message 7zz prints right after erasing the progress, on the same line (the
    /// password prompt), stays. Output of runs without progress is left as it is (a name may hold a backspace).
    var outputText: String {
        let text = String(decoding: standardOutput, as: UTF8.self)
        guard hadProgress, text.contains("\u{8}") else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            guard line.contains("\u{8}") else { return String(line) }
            let kept = line.split(separator: "\u{8}").filter { segment in
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return false }
                return trimmed.wholeMatch(of: /\d{1,3}%.*/) == nil && trimmed.wholeMatch(of: /\d+M Scan.*/) == nil
            }
            let joined = kept.joined().trimmingCharacters(in: .whitespaces)
            return joined.isEmpty ? nil : joined
        }.joined(separator: "\n")
    }
    var errorText: String { String(decoding: standardError, as: UTF8.self) }

    /// Text useful in an error message: stderr plus the tail of stdout (7zz prints some errors on stdout).
    var diagnostics: String {
        var parts: [String] = []
        let err = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { parts.append(err) }
        let out = outputText
        // Keep only the lines of stdout that look like problems, to avoid dumping banners and listings.
        let interesting = out.split(separator: "\n").filter {
            $0.contains("ERROR") || $0.contains("rror") || $0.contains("Can not") || $0.contains("Cannot")
                || $0.contains("Wrong password") || $0.contains("WARNING")
        }
        if !interesting.isEmpty { parts.append(interesting.prefix(8).joined(separator: "\n")) }
        let joined = parts.joined(separator: "\n")
        return joined.count > 2000 ? String(joined.prefix(2000)) + "…" : joined
    }
}

/// Bridges task cancellation to a child process. All state is guarded by a lock.
private final class ProcessCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Launches the process unless cancellation already happened. Returns false when cancelled.
    func launch(_ process: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        try process.run()
        self.process = process
        ActiveWork.shared.addChild(process.processIdentifier)
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process?.isRunning ?? false
        if running { process?.terminate() }
        lock.unlock()
        if running {
            // Escalate if the child ignores SIGTERM.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
                lock.lock(); defer { lock.unlock() }
                if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }
}

enum ProcessRunner {
    /// Where the captured output of child processes lives while they run.
    static var outputDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Squeeze7z-io", isDirectory: true)
    }

    /// Runs `executable` with stdin attached to /dev/null. Standard output and error go to temporary
    /// files, so neither pipe can fill up and block the child. Cancelling the calling task terminates
    /// the child and throws `OptimizerError.cancelled`.
    /// `onOutputTail`, when given, receives the last 2 KB of standard output about twice a second while the child
    /// runs, whenever it has grown (7zz's progress lines).
    static func run(executable: URL, arguments: [String], currentDirectory: URL? = nil,
                    environment: [String: String] = [:],
                    onOutputTail: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessOutput {
        if Task.isCancelled { throw OptimizerError.cancelled }

        let ioDir = Self.outputDirectory
        try? FileManager.default.createDirectory(at: ioDir, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let outURL = ioDir.appendingPathComponent("\(token).out")
        let errURL = ioDir.appendingPathComponent("\(token).err")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil),
              FileManager.default.createFile(atPath: errURL.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            throw OptimizerError.toolFailed(command: executable.lastPathComponent, exitCode: -1,
                                            stderr: "Cannot create temporary files for process output.")
        }
        defer {
            try? outHandle.close()
            try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        let poller: Task<Void, Never>? = onOutputTail.map { handler in
            Task.detached(priority: .utility) {
                var lastSize: UInt64 = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let reader = try? FileHandle(forReadingFrom: outURL) else { continue }
                    defer { try? reader.close() }
                    guard let size = try? reader.seekToEnd(), size > lastSize else { continue }
                    lastSize = size
                    try? reader.seek(toOffset: size > 2048 ? size - 2048 : 0)
                    if let tail = try? reader.readToEnd(), !tail.isEmpty { handler(tail) }
                }
            }
        }
        defer { poller?.cancel() }

        let canceller = ProcessCanceller()
        // The poller is stopped and awaited before returning: a late progress line must not reach the job after
        // the next phase has started.
        func stopPoller() async {
            poller?.cancel()
            await poller?.value
        }
        let exitCode: Int32
        do {
        exitCode = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                var env = ProcessInfo.processInfo.environment
                env["LC_ALL"] = "en_US.UTF-8"
                env["LANG"] = "en_US.UTF-8"
                for (k, v) in environment { env[k] = v }
                process.environment = env
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = outHandle
                process.standardError = errHandle
                process.terminationHandler = { p in
                    ActiveWork.shared.removeChild(p.processIdentifier)
                    let status = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
                    continuation.resume(returning: status)
                }
                do {
                    if try !canceller.launch(process) {
                        continuation.resume(throwing: OptimizerError.cancelled)
                    }
                } catch {
                    continuation.resume(throwing: OptimizerError.toolFailed(
                        command: executable.lastPathComponent, exitCode: -1, stderr: error.localizedDescription))
                }
            }
        } onCancel: {
            canceller.cancel()
        }
        } catch {
            await stopPoller()
            throw error
        }
        await stopPoller()

        if canceller.isCancelled || Task.isCancelled { throw OptimizerError.cancelled }
        let out = (try? Data(contentsOf: outURL)) ?? Data()
        let err = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessOutput(exitCode: exitCode, standardOutput: out, standardError: err)
    }
}
