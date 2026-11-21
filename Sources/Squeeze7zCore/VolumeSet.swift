import Foundation

/// Knows about archive extensions and multi-volume naming schemes.
enum VolumeSet {
    static let singleStreamExtensions: Set<String> = ["gz", "bz2", "xz", "zst", "z", "lzma", "lz4", "lz"]
    static let tarCompoundExtensions: Set<String> = ["tgz", "tbz", "tbz2", "txz", "tzst", "taz", "tz"]

    static let archiveExtensions: Set<String> = [
        "7z", "zip", "zipx", "rar", "cab", "gz", "bz2", "xz", "zst", "tar", "tgz", "tbz", "tbz2", "txz", "tzst",
        "taz", "tz", "iso", "arj", "lzh", "lha", "z", "chm", "cpio", "rpm", "deb", "wim", "swm", "esd", "dmg",
        "lzma", "lz4", "jar", "apk", "cbz", "cbr", "cb7",
    ]

    /// Formats that are plain containers of files. The others in `archiveExtensions` are functional
    /// artifacts (an app, a package, a disk image, a comic book): repacking them loses what makes them work.
    static let functionalContainerExtensions: Set<String> = [
        "jar", "apk", "cbz", "cbr", "cb7", "dmg", "iso", "deb", "rpm", "chm", "wim", "swm", "esd",
    ]

    /// `name.ext.001` → (prefix "name.ext", width 3); only for numeric suffixes of 3+ digits.
    private static func numericVolume(_ name: String) -> (prefix: String, number: Int, width: Int)? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let suffix = name[name.index(after: dot)...]
        guard suffix.count >= 3, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
        return (String(name[..<dot]), n, suffix.count)
    }

    /// `name.part01.rar` → (prefix "name", number 1, width 2).
    private static func partVolume(_ name: String) -> (prefix: String, number: Int, width: Int)? {
        let lower = name.lowercased()
        guard lower.hasSuffix(".rar") else { return nil }
        let stem = String(name.dropLast(4))
        guard let range = stem.lowercased().range(of: ".part", options: .backwards) else { return nil }
        let digits = stem[range.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let n = Int(digits) else { return nil }
        return (String(stem[..<range.lowerBound]), n, digits.count)
    }

    static func isSupported(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if let v = numericVolume(name) { return v.number == 1 }
        if let p = partVolume(name) { return p.number == 1 }
        let ext = url.pathExtension.lowercased()
        return archiveExtensions.contains(ext)
    }

    /// True for a functional container (jar, apk, cbz, dmg, iso, deb, …): it can be repacked when the user
    /// asks for it explicitly, but must never be picked up by a folder scan or replaced by the result.
    static func isFunctionalContainer(_ url: URL) -> Bool {
        functionalContainerExtensions.contains(url.pathExtension.lowercased())
    }

    /// Supported and a plain archive: what a folder scan may queue.
    static func isPlainArchive(_ url: URL) -> Bool { isSupported(url) && !isFunctionalContainer(url) }

    /// All volumes of the archive whose first volume is `url`, including `url`, in order.
    static func volumes(of url: URL) -> [URL] {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        var result = [url]
        func exists(_ n: String) -> URL? {
            let u = dir.appendingPathComponent(n)
            return fm.fileExists(atPath: u.path) ? u : nil
        }
        if let v = numericVolume(name) {
            var i = v.number + 1
            while let u = exists(v.prefix + "." + String(format: "%0\(v.width)d", i)) { result.append(u); i += 1 }
            return result
        }
        if let p = partVolume(name) {
            var i = p.number + 1
            let ext = String(name.suffix(4))
            while let u = exists(p.prefix + ".part" + String(format: "%0\(p.width)d", i) + ext) { result.append(u); i += 1 }
            return result
        }
        let ext = url.pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension
        if ext == "zip" {
            var parts: [URL] = []
            var i = 1
            while let u = exists(stem + "." + (name.hasSuffix(".ZIP") ? "Z" : "z") + String(format: "%02d", i)) { parts.append(u); i += 1 }
            return parts + [url]
        }
        if ext == "rar" {
            var i = 0
            while let u = exists(stem + "." + (name.hasSuffix(".RAR") ? "R" : "r") + String(format: "%02d", i)) { result.append(u); i += 1 }
        }
        return result
    }

    /// File name without archive extension and volume suffix. A tar inside a single-stream compressor
    /// also loses its ".tar".
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        if let v = numericVolume(name) {
            let inner = URL(fileURLWithPath: v.prefix)
            return stripArchiveExtension(inner.lastPathComponent)
        }
        if let p = partVolume(name) { return p.prefix }
        return stripArchiveExtension(name)
    }

    private static func stripArchiveExtension(_ name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        guard !ext.isEmpty, archiveExtensions.contains(ext) else { return name }
        var stem = ns.deletingPathExtension
        if singleStreamExtensions.contains(ext), stem.lowercased().hasSuffix(".tar") { stem = String(stem.dropLast(4)) }
        return stem.isEmpty ? name : stem
    }
}
