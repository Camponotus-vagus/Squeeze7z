import Foundation

/// Table-driven CRC-32 (IEEE 802.3, the variant used by 7z, zip and gzip), slicing-by-8.
public struct CRC32: Sendable {
    private static let tables: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            t[i] = c
        }
        for i in 0..<256 {
            for k in 1..<8 {
                let prev = t[(k - 1) * 256 + i]
                t[k * 256 + i] = (prev >> 8) ^ t[Int(prev & 0xFF)]
            }
        }
        return t
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    /// The checksum of everything fed so far.
    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        var crc = state
        var p = base
        var n = buffer.count
        Self.tables.withUnsafeBufferPointer { t in
            while n >= 8 {
                let a = UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)) ^ crc
                let b = UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                crc = t[7 * 256 + Int(a & 0xFF)] ^ t[6 * 256 + Int((a >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((a >> 16) & 0xFF)] ^ t[4 * 256 + Int(a >> 24)]
                    ^ t[3 * 256 + Int(b & 0xFF)] ^ t[2 * 256 + Int((b >> 8) & 0xFF)]
                    ^ t[1 * 256 + Int((b >> 16) & 0xFF)] ^ t[Int(b >> 24)]
                p += 8
                n -= 8
            }
            while n > 0 {
                crc = t[Int((crc ^ UInt32(p.load(as: UInt8.self))) & 0xFF)] ^ (crc >> 8)
                p += 1
                n -= 1
            }
        }
        state = crc
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.value
    }

    public static func checksum(of url: URL) throws -> UInt32 {
        try checksum(of: url, checkCancellation: nil)
    }

    /// Streaming checksum of a file. `checkCancellation` is called between chunks and may throw to abort.
    static func checksum(of url: URL, checkCancellation: (() throws -> Void)?) throws -> UInt32 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { close(fd) }
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var crc = CRC32()
        var counter = 0
        while true {
            let n = read(fd, buffer.baseAddress, chunk)
            if n < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            if n == 0 { break }
            crc.update(UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            counter += 1
            if counter % 16 == 0 { try checkCancellation?() }
        }
        return crc.value
    }

    /// CRC of a symbolic link: 7-Zip stores the target path bytes as the entry data.
    static func checksumOfLinkTarget(at url: URL) throws -> (crc: UInt32, size: Int64) {
        var buf = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(url.path, &buf, buf.count - 1)
        guard n >= 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let data = Data(buf[0..<n])
        return (checksum(data), Int64(n))
    }
}
