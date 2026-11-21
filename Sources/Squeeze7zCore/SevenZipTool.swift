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

    /// Runs 7zz with the given arguments. The exit code is returned, not interpreted.
    func run(_ arguments: [String], currentDirectory: URL? = nil) async throws -> ProcessOutput {
        try await ProcessRunner.run(executable: executableURL, arguments: arguments, currentDirectory: currentDirectory)
    }

    /// Runs 7zz and converts failures to `OptimizerError`. `okCodes` lists accepted exit codes.
    @discardableResult
    func runChecked(_ arguments: [String], currentDirectory: URL? = nil,
                    okCodes: Set<Int32> = [0]) async throws -> ProcessOutput {
        let out = try await run(arguments, currentDirectory: currentDirectory)
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
