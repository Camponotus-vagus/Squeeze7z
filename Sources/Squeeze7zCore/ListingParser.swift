import Foundation

/// Parser for the output of `7zz l -slt`.
///
/// Layout of that output: banner, `--`, archive-level `key = value` lines, a `----------` separator,
/// then one block of `key = value` lines per entry, blocks separated by blank lines.
enum ListingParser {
    static func parse(_ text: String, archivePath: String, fallbackPhysicalSize: Int64) throws -> ArchiveListing {
        enum Section { case preamble, archive, entries }
        var section = Section.preamble
        var archiveProps: [String: String] = [:]
        var entries: [ArchiveEntry] = []
        var current: [String: String] = [:]

        func flush() {
            if let entry = makeEntry(current) { entries.append(entry) }
            current.removeAll(keepingCapacity: true)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> Substring in
            raw.hasSuffix("\r") ? raw.dropLast() : raw
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            // A multi-line value (an archive or entry comment) is printed as `Comment = `, `{`, the text, `}`.
            // Its lines are text, not listing structure: they must not start entries or set archive fields.
            if section != .preamble, let (_, value) = splitKeyValue(line), value.isEmpty,
               let end = closingBrace(in: lines, openingAt: index) {
                index = end + 1
                continue
            }
            switch section {
            case .preamble:
                if line == "--" { section = .archive }
                else if line == "----------" { section = .entries }
            case .archive:
                if line == "----------" { section = .entries }
                else if line == "--" { archiveProps.removeAll() }   // nested container (e.g. split volumes): keep the innermost layer
                else if line == "----" { continue }
                else if let (k, v) = splitKeyValue(line), archiveProps[k] == nil { archiveProps[k] = v }
            case .entries:
                if line.isEmpty { flush() }
                else if line == "----------" { continue }
                else if let (k, v) = splitKeyValue(line) {
                    if k == "Path", current["Path"] != nil { flush() }
                    current[k] = v
                }
            }
        }
        flush()

        guard let format = archiveProps["Type"], !format.isEmpty else {
            throw OptimizerError.notAnArchive((archivePath as NSString).lastPathComponent)
        }
        let physical = archiveProps["Physical Size"].flatMap { Int64($0) } ?? fallbackPhysicalSize
        let methods = archiveProps["Method"].flatMap { $0.isEmpty ? nil : $0 }
        let tail = archiveProps["Tail Size"].flatMap { Int64($0) } ?? 0
        let head = max(archiveProps["Offset"].flatMap { Int64($0) } ?? 0,
                       archiveProps["Embedded Stub Size"].flatMap { Int64($0) } ?? 0)
        return ArchiveListing(archivePath: archivePath, format: format, physicalSize: physical,
                              isSolid: archiveProps["Solid"] == "+", methods: methods, entries: entries,
                              tailBytes: max(tail, 0), headBytes: max(head, 0))
    }

    /// For a `{` at `lines[start]`: the index of the `}` that ends the block. That is the first `}` line
    /// followed by the end of the output, a blank line, a layer separator or another `key = value` line, so a
    /// comment that merely contains braces keeps its text together. Nil when there is no such block.
    static func closingBrace(in lines: [Substring], openingAt start: Int) -> Int? {
        guard start < lines.count, lines[start] == "{" else { return nil }
        var j = start + 1
        while j < lines.count {
            if lines[j] == "}" {
                let next = j + 1
                if next >= lines.count || lines[next].isEmpty || isSeparator(lines[next])
                    || splitKeyValue(lines[next]) != nil { return j }
            }
            j += 1
        }
        return nil
    }

    /// `--`, `----` and `----------` mark the layers of the listing.
    private static func isSeparator(_ line: Substring) -> Bool {
        !line.isEmpty && line.allSatisfy { $0 == "-" } && line.count >= 2
    }

    static func splitKeyValue(_ line: Substring) -> (String, String)? {
        if let range = line.range(of: " = ") {
            return (String(line[line.startIndex..<range.lowerBound]), String(line[range.upperBound...]))
        }
        if line.hasSuffix(" =") {
            return (String(line.dropLast(2)), "")
        }
        return nil
    }

    static func makeEntry(_ dict: [String: String]) -> ArchiveEntry? {
        // Single-stream formats such as .tbz2 can list their one entry without a Path.
        guard dict["Path"] != nil || dict["Size"] != nil || dict["Attributes"] != nil else { return nil }
        var path = dict["Path"] ?? ""
        if path.isEmpty && dict["Path"] != nil { return nil }
        // tar and file system images (APFS, HFS+) carry the Unix mode in `Mode`, other formats in `Attributes`.
        let attrs = parseAttributes((dict["Attributes"] ?? "") + " " + (dict["Mode"] ?? ""))
        var isDirectory = attrs.isDirectory || dict["Folder"] == "+"
        if path.hasSuffix("/") && path.count > 1 { path.removeLast(); isDirectory = true }
        let hardLink = !(dict["Hard Link"] ?? "").isEmpty
        let symlinkKey = !(dict["Symbolic Link"] ?? "").isEmpty
        var entry = ArchiveEntry(
            path: path,
            size: dict["Size"].flatMap { Int64($0) } ?? 0,
            packedSize: dict["Packed Size"].flatMap { Int64($0) },
            crc: dict["CRC"].flatMap { $0.isEmpty ? nil : UInt32($0, radix: 16) },
            isDirectory: isDirectory,
            isEncrypted: dict["Encrypted"] == "+",
            isSymlink: (attrs.isSymlink || symlinkKey) && !isDirectory,
            method: dict["Method"].flatMap { $0.isEmpty ? nil : $0 },
            modified: dict["Modified"].flatMap { parseDate($0) })
        entry.isHardLink = hardLink
        entry.unixMode = unixPermissions(dict["Attributes"] ?? "") ?? unixPermissions(dict["Mode"] ?? "")
        // tar listings carry the Unix mode in `Mode`, other formats in `Attributes`.
        entry.isSpecialFile = !isDirectory && !entry.isSymlink
            && (hasSpecialMode(dict["Attributes"] ?? "") || hasSpecialMode(dict["Mode"] ?? ""))
        return entry
    }

    /// `Attributes` is either DOS letters ("A", "D", "....A"), a Unix mode ("-rw-r--r--"), or both
    /// separated by a space ("D drwxr-xr-x").
    static func parseAttributes(_ s: String) -> (isDirectory: Bool, isSymlink: Bool) {
        var dir = false, link = false
        for token in s.split(separator: " ") {
            if isUnixMode(token) {
                if token.first == "d" { dir = true }
                if token.first == "l" { link = true }
            } else if token.contains("D") {
                dir = true
            }
        }
        return (dir, link)
    }

    /// Permission bits (with setuid, setgid and sticky) of the Unix mode string in `s`, if there is one.
    static func unixPermissions(_ s: String) -> UInt16? {
        guard let token = s.split(separator: " ").first(where: { isUnixMode($0) }) else { return nil }
        let c = Array(token.dropFirst())
        var bits: UInt16 = 0
        for (i, ch) in c.enumerated() where i < 9 {
            let shift = UInt16(8 - i)
            switch ch {
            case "r", "w", "x", "s", "t": bits |= 1 << shift   // "S" and "T": special bit without execute
            default: break
            }
        }
        if c.count == 9 {
            if c[2] == "s" || c[2] == "S" { bits |= 0o4000 }
            if c[5] == "s" || c[5] == "S" { bits |= 0o2000 }
            if c[8] == "t" || c[8] == "T" { bits |= 0o1000 }
        }
        return bits
    }

    /// True when a Unix mode string describes a FIFO (p), character device (c), block device (b) or socket (s).
    static func hasSpecialMode(_ s: String) -> Bool {
        s.split(separator: " ").contains { isUnixMode($0) && "cbps".contains($0.first!) }
    }

    private static func isUnixMode(_ t: Substring) -> Bool {
        guard t.count == 10, let first = t.first, "-dlcbpsDL?".contains(first) else { return false }
        return t.dropFirst().allSatisfy { "rwxsStT-".contains($0) }
    }

    /// "2026-11-20 14:40:44.8257743" (local time) → Date.
    static func parseDate(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "T" })
        guard parts.count >= 2 else { return nil }
        let ymd = parts[0].split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3 else { return nil }
        let hmsParts = parts[1].split(separator: ".", maxSplits: 1)
        let hms = hmsParts[0].split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3 else { return nil }
        var t = tm()
        t.tm_year = Int32(ymd[0] - 1900)
        t.tm_mon = Int32(ymd[1] - 1)
        t.tm_mday = Int32(ymd[2])
        t.tm_hour = Int32(hms[0])
        t.tm_min = Int32(hms[1])
        t.tm_sec = Int32(hms[2])
        t.tm_isdst = -1
        let seconds = mktime(&t)
        guard seconds != -1 else { return nil }
        var fraction = 0.0
        if hmsParts.count == 2, let f = Double("0." + hmsParts[1]) { fraction = f }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + fraction)
    }
}
