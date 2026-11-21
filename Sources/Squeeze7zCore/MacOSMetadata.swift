import Foundation

/// The `__MACOSX` folder that Finder's Compress command and `ditto -k --sequesterRsrc` put in zip files.
///
/// It holds one AppleDouble file (`._name`) per file with extended attributes or a resource fork. Archive
/// Utility reads it back into attributes when it expands a zip, but a 7z has no such convention: 7-Zip
/// extracts it as an ordinary folder, and Archive Utility (macOS 26) maps `__MACOSX/<dir>` onto `<dir>` when
/// it expands a 7z, so the real files come out replaced by 163-byte AppleDouble stubs, without any error.
enum MacOSMetadata {
    static let folderName = "__MACOSX"
    /// First four bytes of every AppleDouble file.
    static let appleDoubleMagic: [UInt8] = [0x00, 0x05, 0x16, 0x07]

    /// Removes a top-level `__MACOSX` folder from the extracted tree and from the snapshot, if every file in
    /// it is an AppleDouble file. Returns the number of AppleDouble files removed (0 = nothing done).
    static func strip(root: URL, snapshot: inout TreeSnapshot) throws -> Int {
        let prefix = folderName + "/"
        let inside = snapshot.files.filter { $0.key.hasPrefix(prefix) }
        guard !inside.isEmpty, snapshot.files[folderName] == nil else { return 0 }
        for (path, info) in inside {
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix("._"), !info.isSymlink, info.size >= 4,
                  isAppleDouble(root.appendingPathComponent(path)) else { return 0 }
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(folderName, isDirectory: true))
        snapshot.files = snapshot.files.filter { !$0.key.hasPrefix(prefix) }
        snapshot.directories = snapshot.directories.filter { $0.key != folderName && !$0.key.hasPrefix(prefix) }
        snapshot.emptyDirectories.removeAll { $0 == folderName || $0.hasPrefix(prefix) }
        return inside.count
    }

    static func isAppleDouble(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4) else { return false }
        return Array(head) == appleDoubleMagic
    }
}
