import Foundation
import Testing
@testable import Squeeze7zCore

enum TestSupport {
    static func tool() throws -> SevenZipTool { try SevenZipTool.locate() }

    /// A fresh directory under the system temp dir.
    static func makeTempDir(_ label: String = "test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Squeeze7zTests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deterministic pseudo-random bytes (xorshift), so fixtures are reproducible.
    static func randomBytes(_ count: Int, seed: UInt64 = 42) -> Data {
        var state = seed | 1
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buf in
            for i in 0..<count {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                buf[i] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        return data
    }

    static func textBytes(_ words: Int, seed: UInt64 = 1) -> Data {
        let vocabulary = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "archive", "entropy",
                          "dictionary", "stream", "block", "header", "literal", "match", "window"]
        var state = seed | 1
        var out = ""
        for _ in 0..<words {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            out += vocabulary[Int(state % UInt64(vocabulary.count))] + " "
        }
        return Data(out.utf8)
    }

    /// 16-bit stereo PCM inside a minimal WAV container.
    static func wavBytes(frames: Int) -> Data {
        var pcm = Data()
        pcm.reserveCapacity(frames * 4)
        for i in 0..<frames {
            let l = Int16(8000 * sin(Double(i) / 20.0)), r = Int16(6000 * sin(Double(i) / 31.0))
            withUnsafeBytes(of: l.littleEndian) { pcm.append(contentsOf: $0) }
            withUnsafeBytes(of: r.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var header = Data("RIFF".utf8)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        le32(UInt32(pcm.count + 36)); header.append(contentsOf: "WAVEfmt ".utf8)
        le32(16); le16(1); le16(2); le32(44100); le32(176_400); le16(4); le16(16)
        header.append(contentsOf: "data".utf8); le32(UInt32(pcm.count))
        return header + pcm
    }

    /// 24-bit BMP with a smooth gradient.
    static func bmpBytes(width: Int, height: Int) -> Data {
        var pixels = Data()
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(contentsOf: [UInt8((x * 255 / width) & 255), UInt8((y * 255 / height) & 255),
                                           UInt8(((x + y) / 3) & 255)])
            }
        }
        var d = Data("BM".utf8)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        le32(UInt32(54 + pixels.count)); le32(0); le32(54)
        le32(40); le32(UInt32(width)); le32(UInt32(height)); le16(1); le16(24); le32(0); le32(UInt32(pixels.count))
        le32(2835); le32(2835); le32(0); le32(0)
        return d + pixels
    }

    /// The mixed tree used by the end-to-end tests: text, source, random, jpg-like, PCM, raw bitmap,
    /// a Mach-O copy of /bin/ls, an empty directory tree and a symlink.
    @discardableResult
    static func makeMixedTree(at root: URL) throws -> URL {
        let fm = FileManager.default
        func write(_ rel: String, _ data: Data) throws {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for i in 0..<4 { try write("docs/note\(i).txt", textBytes(12_000, seed: UInt64(i + 1))) }
        try write("src/main.py", Data(String(repeating: "def f(x):\n    return x * 2 + 1\n\n", count: 2500).utf8))
        try write("src/data.json",
                  Data(("{\"v\": [" + (0..<20_000).map { String(($0 * 7919) % 1000) }.joined(separator: ",") + "]}").utf8))
        try write("rand/blob.bin", randomBytes(200_000, seed: 5))
        try write("img/photo.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0]) + randomBytes(150_000, seed: 9))
        try write("audio/tone.wav", wavBytes(frames: 120_000))
        try write("img/pic.bmp", bmpBytes(width: 300, height: 200))
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: root.appendingPathComponent("tools_ls"))
        try fm.createDirectory(at: root.appendingPathComponent("empty/nested"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link_note").path,
                                  withDestinationPath: "docs/note0.txt")
        return root
    }

    /// Runs the vendored 7zz synchronously.
    @discardableResult
    static func run7zz(_ arguments: [String], in directory: URL? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = try tool().executableURL
        p.arguments = arguments
        p.currentDirectoryURL = directory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Creates an archive from the content of `tree` with the vendored 7zz.
    static func makeArchive(from tree: URL, at archive: URL, type: String, extra: [String] = []) throws {
        try? FileManager.default.removeItem(at: archive)
        let status = try run7zz(["a", "-t\(type)", "-y", "-bb0", "-bsp0", "-snl"] + extra + [archive.path, "."], in: tree)
        #expect(status == 0, "7zz failed to create the fixture archive")
    }

    static func extract(_ archive: URL, into dir: URL) throws {
        let status = try run7zz(["x", "-y", "-bb0", "-bsp0", "-snld20", "-o" + dir.path, archive.path])
        #expect(status == 0, "7zz failed to extract \(archive.lastPathComponent)")
    }

    /// Every path below `root`, relative, listed with `readdir` (FileManager hides `._` names).
    static func allPaths(_ root: URL, relative: String = "") throws -> [String] {
        var result: [String] = []
        let dir = relative.isEmpty ? root.path : root.path + "/" + relative
        for name in try TreeScanner.listDirectory(dir) {
            let rel = relative.isEmpty ? name : relative + "/" + name
            result.append(rel)
            var st = stat()
            if lstat(root.path + "/" + rel, &st) == 0, st.st_mode & S_IFMT == S_IFDIR {
                result += try allPaths(root, relative: rel)
            }
        }
        return result.sorted()
    }

    /// Relative path → "size:crc" for files, "link:target" for symlinks, "dir" for directories.
    static func fingerprint(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        for rel in try allPaths(root) {
            let path = root.appendingPathComponent(rel).path
            let attrs = try fm.attributesOfItem(atPath: path)
            switch attrs[.type] as? FileAttributeType {
            case .typeSymbolicLink: result[rel] = "link:" + (try fm.destinationOfSymbolicLink(atPath: path))
            case .typeDirectory: result[rel] = "dir"
            default:
                let crc = try CRC32.checksum(of: URL(fileURLWithPath: path))
                result[rel] = "\((attrs[.size] as? NSNumber)?.int64Value ?? -1):\(String(crc, radix: 16))"
            }
        }
        return result
    }

    /// Mode and modification time (whole seconds) of every directory below `root`.
    static func directoryMetadata(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for rel in try allPaths(root) {
            var st = stat()
            guard lstat(root.path + "/" + rel, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            result[rel] = String(st.st_mode & 0o7777, radix: 8) + "@\(st.st_mtimespec.tv_sec)"
        }
        return result
    }

    /// Runs a system tool synchronously and returns its exit status.
    @discardableResult
    static func runSystem(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = directory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
    }

    /// Size of `7zz a -mx9` over the tree, the reference the optimizer has to beat.
    static func referenceSize(of tree: URL, in dir: URL) throws -> Int64 {
        let ref = dir.appendingPathComponent("ref.7z")
        try makeArchive(from: tree, at: ref, type: "7z", extra: ["-mx=9"])
        return size(ref)
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [OptimizationEvent] = []
        func add(_ e: OptimizationEvent) { lock.lock(); items.append(e); lock.unlock() }
        var events: [OptimizationEvent] { lock.lock(); defer { lock.unlock() }; return items }
        var phases: [OptimizationPhase] { events.compactMap { if case .phase(let p) = $0 { p } else { nil } } }
        var logs: [String] { events.compactMap { if case .log(let s) = $0 { s } else { nil } } }
        var progress: [(Int, Int)] { events.compactMap { if case .trialProgress(let d, let t) = $0 { (d, t) } else { nil } } }
    }

    static func entries(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }
}
