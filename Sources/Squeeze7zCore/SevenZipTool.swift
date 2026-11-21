import Foundation

/// Thin wrapper around the 7-Zip console binary (`7zz`).
public struct SevenZipTool: Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Switches that keep 7zz non-interactive and quiet.
    static let quietSwitches = ["-y", "-bb0", "-bsp0"]

    // MARK: Locating the binary

    /// Resolution order: `SQUEEZE7Z_7ZZ`, the app bundle resource, `<repo>/Vendor/7zip/7zz`, Homebrew.
    public static func locate() throws -> SevenZipTool {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["SQUEEZE7Z_7ZZ"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil) {
            candidates.append(bundled)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("7zz"))
        }
        // This file lives at <repo>/Sources/Squeeze7zCore/SevenZipTool.swift. Left out of the app bundle build
        // (scripts/build-app.sh defines SQUEEZE7Z_APP_BUNDLE), which would otherwise carry the build machine's path.
        #if !SQUEEZE7Z_APP_BUNDLE
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("Vendor/7zip/7zz"))
        #endif
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/7zz"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/7zz"))
        for url in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
               fm.isExecutableFile(atPath: url.path) {
                return SevenZipTool(executableURL: url)
            }
        }
        throw OptimizerError.sevenZipNotFound
    }

    // MARK: Version

    public var version: String {
        get async throws {
            let out = try await run([])
            let banner = out.outputText.split(separator: "\n").first { $0.contains("7-Zip") } ?? ""
            let token = banner.split(separator: " ").first { t in
                t.first?.isNumber == true && t.contains(".")
            }
            guard let token else {
                throw OptimizerError.toolFailed(command: "7zz", exitCode: out.exitCode,
                                                stderr: "Cannot read the 7-Zip version banner.")
            }
            return String(token)
        }
    }

    // MARK: Running

    /// Runs 7zz with the given arguments. The exit code is returned, not interpreted. With `progress`, 7zz prints
    /// its progress (`-bsp1` instead of `-bsp0`) and the latest line is handed over about twice a second.
    func run(_ arguments: [String], currentDirectory: URL? = nil,
             progress: (@Sendable (ToolProgress) -> Void)? = nil) async throws -> ProcessOutput {
        guard let progress else {
            return try await ProcessRunner.run(executable: executableURL, arguments: arguments,
                                               currentDirectory: currentDirectory)
        }
        let args = arguments.map { $0 == "-bsp0" ? "-bsp1" : $0 }
        var out = try await ProcessRunner.run(executable: executableURL, arguments: args,
                                              currentDirectory: currentDirectory) { tail in
            if let line = Self.parseProgress(tail) { progress(line) }
        }
        out.hadProgress = true
        return out
    }

    /// Runs 7zz and converts failures to `OptimizerError`. `okCodes` lists accepted exit codes.
    @discardableResult
    func runChecked(_ arguments: [String], currentDirectory: URL? = nil, okCodes: Set<Int32> = [0],
                    progress: (@Sendable (ToolProgress) -> Void)? = nil) async throws -> ProcessOutput {
        let out = try await run(arguments, currentDirectory: currentDirectory, progress: progress)
        if okCodes.contains(out.exitCode) { return out }
        throw Self.error(for: out, arguments: arguments)
    }

    static func error(for out: ProcessOutput, arguments: [String]) -> OptimizerError {
        if looksEncrypted(out) { return .encrypted }
        if out.exitCode == 255 { return .cancelled }
        let verb = arguments.first ?? ""
        let target = arguments.last(where: { !$0.hasPrefix("-") && !$0.hasPrefix("@") })
            .map { " " + ($0 as NSString).lastPathComponent } ?? ""
        return .toolFailed(command: "7zz \(verb)\(target)", exitCode: out.exitCode, stderr: out.diagnostics)
    }

    static func looksEncrypted(_ out: ProcessOutput) -> Bool {
        let text = (out.errorText + "\n" + out.outputText).lowercased()
        return text.contains("wrong password") || text.contains("cannot open encrypted archive")
            || text.contains("can not open encrypted archive") || text.contains("enter password")
    }

    // MARK: Progress

    /// The latest progress line in a tail of 7zz's `-bsp1` output: "  42% 1234 + dir/name.jpg". The lines redraw
    /// themselves with backspaces; the last complete one wins. Nil when the tail holds none.
    static func parseProgress(_ tail: Data) -> ToolProgress? {
        let text = String(decoding: tail, as: UTF8.self)
        let segments = text.split(whereSeparator: { $0 == "\u{8}" || $0 == "\r" || $0 == "\n" })
        for segment in segments.reversed() {
            let line = segment.trimmingCharacters(in: .whitespaces)
            guard let match = line.wholeMatch(of: /(\d{1,3})%(?:\s+(\d+))?(?:\s+[+=U-]\s+(.+))?/),
                  let percent = Int(match.1), percent <= 100 else { continue }
            return ToolProgress(percent: percent, files: match.2.flatMap { Int($0) },
                                currentFile: match.3.map(String.init))
        }
        return nil
    }

    // MARK: Listing

    public func list(_ archive: URL) async throws -> ArchiveListing {
        let path = archive.standardizedFileURL.path
        // -spd: the archive name is a literal path, "*" and "?" in it are not wildcards.
        let out = try await run(["l", "-slt"] + Self.quietSwitches + ["-spd", path])
        if out.exitCode != 0 && out.exitCode != 1 {
            if Self.looksEncrypted(out) { throw OptimizerError.encrypted }
            if out.exitCode == 255 { throw OptimizerError.cancelled }
            let text = (out.errorText + out.outputText).lowercased()
            if text.contains("as archive") || text.contains("is not archive") || text.contains("unsupported archive") {
                throw OptimizerError.notAnArchive(archive.lastPathComponent)
            }
            throw Self.error(for: out, arguments: ["l", path])
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        return try ListingParser.parse(out.outputText, archivePath: path, fallbackPhysicalSize: size)
    }
}
