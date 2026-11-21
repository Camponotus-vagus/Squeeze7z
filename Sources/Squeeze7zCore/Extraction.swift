import Foundation

extension SevenZipTool {
    /// Extracts `archive` into `directory` (created if needed). Symbolic links are restored with their
    /// exact stored targets: 7zz rewrites absolute link targets and refuses links that leave the
    /// extraction root, so those are re-created from the archive data afterwards.
    func extract(_ archive: URL, listing: ArchiveListing, to directory: URL,
                 progress: (@Sendable (ToolProgress) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hasLinks = listing.entries.contains { $0.isSymlink }
        var args = ["x"] + Self.quietSwitches + ["-spd", "-scsUTF-8", "-o" + directory.path]
        if hasLinks { args.append("-snld20") }
        // APFS and HFS+ images: 7zz would write each extended attribute as an extra file `name:attribute`
        // that the listing does not show. They are metadata, not content, and cannot go into a 7z.
        if Self.skipsAlternateStreams(listing) { args.append("-sns-") }
        args.append(archive.standardizedFileURL.path)
        try await runChecked(args, progress: progress)
        if hasLinks { try await restoreSymlinks(archive: archive, listing: listing, root: directory) }
    }

    /// True for file system images (inside a dmg), where extended attributes come out as separate files.
    static func skipsAlternateStreams(_ listing: ArchiveListing) -> Bool {
        ["apfs", "hfs"].contains(listing.format.lowercased())
    }

    private func restoreSymlinks(archive: URL, listing: ArchiveListing, root: URL) async throws {
        let fm = FileManager.default
        for entry in listing.entries where entry.isSymlink {
            // Entries are validated before extraction (`SourceChecks.ensureSafe`); this stays strict anyway,
            // because everything below deletes and creates files.
            let components = SourceChecks.canonicalPath(entry.path).split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains("..") else {
                throw OptimizerError.notAnArchive("\(entry.path) points outside the extraction folder")
            }
            let url = try SourceChecks.prepareLinkLocation(components: components, root: root)
            var buf = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(url.path, &buf, buf.count - 1)
            if n >= 0, Int64(n) == entry.size { continue }

            // Read the stored target (the entry data) from the archive.
            let listFile = root.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString).txt")
            try ListFile.write([entry.path], to: listFile)
            defer { try? fm.removeItem(at: listFile) }
            let out = try await runChecked(["x", "-so"] + Self.quietSwitches + ["-spd", "-scsUTF-8",
                                           archive.standardizedFileURL.path, "@" + listFile.path])
            guard Int64(out.standardOutput.count) == entry.size,
                  let target = String(data: out.standardOutput, encoding: .utf8), !target.isEmpty else {
                throw OptimizerError.verificationFailed("cannot restore the target of symbolic link \(entry.path)")
            }
            // Only a symlink or a regular file may be replaced, and only with unlink: never a directory tree.
            var st = stat()
            if lstat(url.path, &st) == 0 {
                let kind = st.st_mode & S_IFMT
                guard kind == S_IFLNK || kind == S_IFREG, unlink(url.path) == 0 else {
                    throw OptimizerError.verificationFailed("cannot replace \(entry.path) with a symbolic link")
                }
            }
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }
}

enum SourceChecks {
    /// The path as 7zz extracts it: no leading "/", no "." or empty components (`./a`, `d//b`, `/abs/x`).
    /// ".." is kept on purpose, so that an entry trying to leave the root fails the comparison.
    static func canonicalPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }.joined(separator: "/")
    }

    /// Normalized comparison key: canonical path, and APFS keeps names as stored while archives may use
    /// another Unicode form.
    static func key(_ path: String) -> String { canonicalPath(path).precomposedStringWithCanonicalMapping }

    /// Rejects archives that cannot be repacked safely or faithfully: entries that climb out of the
    /// extraction folder (`..`), device/FIFO/socket entries, and entries stored below a symlink.
    static func ensureSafe(_ listing: ArchiveListing) throws {
        for entry in listing.entries {
            if entry.path.split(separator: "/").contains("..") {
                throw OptimizerError.notAnArchive("\(entry.path) would be extracted outside the working folder")
            }
            if entry.isSpecialFile {
                throw OptimizerError.notAnArchive("contains device/FIFO/socket entries that 7z cannot store (\(entry.path))")
            }
        }
        try ensureSafeLinks(listing)
    }

    /// Resolves the location of a symlink below `root`, creating missing parent directories one by one
    /// and refusing any parent that is a symlink or not a directory. Returns the (not yet existing) link URL.
    static func prepareLinkLocation(components: [String], root: URL) throws -> URL {
        var current = root.standardizedFileURL.path
        for name in components.dropLast() {
            current += "/" + name
            var st = stat()
            if lstat(current, &st) != 0 {
                guard errno == ENOENT, mkdir(current, 0o755) == 0 else {
                    throw OptimizerError.verificationFailed("cannot create \(name) for a symbolic link")
                }
            } else if st.st_mode & S_IFMT != S_IFDIR {
                throw OptimizerError.notAnArchive("\(components.joined(separator: "/")) is stored below a symbolic link or a file")
            }
        }
        return URL(fileURLWithPath: current + "/" + components[components.count - 1])
    }

    /// Rejects archives that would write through a symlink (an entry below a symlink entry).
    static func ensureSafeLinks(_ listing: ArchiveListing) throws {
        let links = Set(listing.entries.filter(\.isSymlink).map { key($0.path) })
        guard !links.isEmpty else { return }
        for entry in listing.entries {
            let comps = key(entry.path).split(separator: "/").dropLast().map(String.init)
            var prefix = ""
            for c in comps {
                prefix = prefix.isEmpty ? c : prefix + "/" + c
                if links.contains(prefix) {
                    throw OptimizerError.notAnArchive("\(entry.path) is stored below the symbolic link \(prefix)")
                }
            }
        }
    }

    /// The extracted tree must match the source listing exactly (paths, sizes, CRC32). This catches
    /// duplicate names, case-insensitive collisions and any extraction problem before repacking.
    static func verifyExtraction(listing: ArchiveListing, snapshot: TreeSnapshot) throws {
        var expected: [String: ArchiveEntry] = [:]
        var hardLinks = Set<String>()
        for entry in listing.entries where !entry.isDirectory {
            let k = key(entry.path)
            if entry.isHardLink { hardLinks.insert(k); continue }
            if expected.updateValue(entry, forKey: k) != nil {
                throw OptimizerError.verificationFailed("the archive lists \(entry.path) more than once, or two names collide on this file system")
            }
        }
        var seen = Set<String>()
        for (path, info) in snapshot.files {
            let k = key(path)
            seen.insert(k)
            guard let entry = expected[k] else {
                if hardLinks.contains(k) { continue }
                throw OptimizerError.verificationFailed("unexpected extracted file \(path)")
            }
            if entry.size != info.size {
                throw OptimizerError.verificationFailed("size of \(path) differs after extraction (\(entry.size) vs \(info.size))")
            }
            if let crc = entry.crc, crc != info.crc {
                throw OptimizerError.verificationFailed("CRC of \(path) differs after extraction")
            }
        }
        for k in expected.keys where !seen.contains(k) {
            throw OptimizerError.verificationFailed("file \(expected[k]?.path ?? k) was not extracted")
        }
    }

    /// Compares a freshly built archive with the extracted tree.
    static func verifyArchive(listing: ArchiveListing, snapshot: TreeSnapshot) throws {
        var entries: [String: ArchiveEntry] = [:]
        var directories = Set<String>()
        for entry in listing.entries {
            let k = key(entry.path)
            if entry.isDirectory { directories.insert(k); continue }
            if entries.updateValue(entry, forKey: k) != nil {
                throw OptimizerError.verificationFailed("duplicate entry \(entry.path) in the new archive")
            }
        }
        for (path, info) in snapshot.files {
            guard let entry = entries[key(path)] else {
                throw OptimizerError.verificationFailed("\(path) is missing from the new archive")
            }
            if entry.size != info.size {
                throw OptimizerError.verificationFailed("size of \(path) differs (\(entry.size) vs \(info.size))")
            }
            let crc = entry.crc ?? (entry.size == 0 ? 0 : nil)
            if crc != info.crc {
                throw OptimizerError.verificationFailed("CRC of \(path) differs")
            }
        }
        let expectedKeys = Set(snapshot.files.keys.map(key))
        for k in entries.keys where !expectedKeys.contains(k) {
            throw OptimizerError.verificationFailed("unexpected entry \(entries[k]?.path ?? k) in the new archive")
        }
        for dir in Set(snapshot.directories.keys).union(snapshot.emptyDirectories) where !directories.contains(key(dir)) {
            throw OptimizerError.verificationFailed("directory \(dir) is missing from the new archive")
        }
    }
}
