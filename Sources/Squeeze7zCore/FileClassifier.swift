import Foundation

/// CPU architectures for which 7-Zip has a branch-converter filter.
public enum ExecutableArchitecture: String, Codable, Sendable, CaseIterable, Hashable {
    case x86, arm64, arm, armThumb, powerPC, sparc, ia64, riscv
}

public enum FileClassifier {
    /// Lowercased extension → category. Unknown extensions map to `.misc`.
    public static func category(forExtension ext: String) -> FileCategory {
        var e = ext.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        return table[e] ?? .misc
    }

    /// The grouping key of a path: lowercased text after the last dot of the file name, or "" if there is
    /// none. Names such as ".gitignore" or "Notes. Final copy" have no extension.
    public static func extensionKey(forPath path: String) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        var trimmed = Substring(name)
        while trimmed.hasPrefix(".") { trimmed = trimmed.dropFirst() }
        guard let dot = trimmed.lastIndex(of: ".") else { return "" }
        let ext = trimmed[trimmed.index(after: dot)...]
        if ext.isEmpty || ext.count > 12 || ext.contains(" ") { return "" }
        return ext.lowercased()
    }

    // MARK: Tables

    private static let table: [String: FileCategory] = {
        var t: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ list: String) {
            for e in list.split(whereSeparator: { $0 == " " || $0 == "\n" }) { t[String(e)] = category }
        }
        add(.text, """
        txt text md markdown mdx rst adoc asciidoc org log csv tsv json jsonl ndjson json5 geojson xml html htm xhtml shtml
        css scss sass less styl js mjs cjs jsx ts tsx map svg rtf tex bib ltx sty cls bst ini cfg conf config yml yaml toml
        properties plist sh bash zsh fish ksh csh bat cmd ps1 psm1 py pyw pyi rb rake gemspec pl pm php phtml java kt kts
        scala groovy gradle c h cc cpp cxx hpp hxx hh inl ipp m mm swift go rs cs vb vbs fs fsx lua r jl sql asm s dart
        erl hrl ex exs hs lhs ml mli clj cljs cljc edn elm vue svelte astro cmake make mk dockerfile gitignore
        gitattributes editorconfig env srt vtt ass ssa sub ics vcf eml mbox dtd xsd xsl xslt wsdl rss atom opml gpx kml
        csproj vbproj fsproj sln vcxproj props targets xaml resx nfo diff patch po pot sgml tpl j2 jinja hbs ejs pug haml
        proto thrift graphql gql tf tfvars hcl nix cu cuh cl glsl hlsl vert frag wgsl obj mtl gcode scad dot gv mmd puml
        ipynb bas pas pp dpr f f90 f95 for cob cbl lisp lsp el scm rkt tcl awk sed vim pro qml ui qrc pri lock cabal
        sbt pom bzl bazel gn gni ninja rmd qmd m4 in ac am lds
        """)
        add(.binary, """
        dat data bin db sqlite sqlite3 db3 mdb accdb doc xls ppt pps vsd pub msg pdf dbf idx ndx pak wad iso img vhd
        vmdk vdi qcow2 sav ttf otf eot ico cur icns class pyc pyo wasm swf fla dwg mo pcap pcapng npy h5 hdf5 hdf nc
        mat parquet pickle pkl rdata rda sas7bdat dta spss tfrecord safetensors ckpt pt pth onnx gguf mlmodel tflite
        bundle lnk jks keystore p12 pfx der crt cer pem key gpg pgp asc kdbx stl 3mf fbx blend dae 3ds max ma mb ai
        eps ps indd xcf sketch fig lit chm hlp cnt tlb rc res resources store cache idb ldb
        """)
        add(.executable, "exe dll sys drv ocx scr cpl efi so dylib o a lib ko elf node pyd rlib mach")
        add(.imageRaw, """
        bmp dib tga icb vda vst tif tiff pnm pbm pgm ppm pam pfm xbm xpm psd psb raw arw cr2 nef nrw orf rw2 raf dng
        pef srw x3f 3fr iiq erf mef mos mrw kdc dcr sr2 srf rwl fff hdr exr dds fits fit pcx sgi rgb ras sun
        """)
        add(.audioRaw, "wav wave aif aiff aifc au snd pcm caf w64 bwf sd2 voc 8svx s16 u8 l16 s24 s32 f32 f64")
        add(.compressed, """
        jpg jpeg jpe jfif png gif webp heic heif avif jxl jp2 j2k jpx apng mp3 aac m4a m4b ogg oga opus wma flac ape wv
        tta mp4 m4v mov mkv webm avi wmv flv mpg mpeg mpe m2ts mts 3gp 3g2 vob ogv zip zipx 7z rar gz tgz bz2 tbz tbz2
        xz txz zst tzst lz lzma lz4 z cab arj lzh lha jar war ear apk ipa aar docx xlsx pptx docm xlsm pptm odt ods odp
        odg epub cbz cbr cb7 xpi crx pkg dmg woff woff2 br sz bz sit sitx ace alz egg vsdx msix appx nupkg whl deb rpm
        snap xar wim swm esd msi cpio ogx mka spx m4p
        """)
        return t
    }()

    // MARK: Content sniffing

    enum Sniff: Equatable {
        case executable(Set<ExecutableArchitecture>)
        case compressed
        case text
        case other
    }

    /// Classifies a file by its first bytes (up to a few KiB are enough).
    static func sniff(_ prefix: [UInt8]) -> Sniff {
        if let archs = ExecutableSniffer.architectures(inHeader: prefix) { return .executable(archs) }
        if isCompressedMagic(prefix) { return .compressed }
        if looksLikeText(prefix) { return .text }
        return .other
    }

    private static func hasPrefix(_ bytes: [UInt8], _ magic: [UInt8]) -> Bool {
        bytes.count >= magic.count && bytes[0..<magic.count].elementsEqual(magic)
    }

    static func isCompressedMagic(_ b: [UInt8]) -> Bool {
        hasPrefix(b, [0x50, 0x4B, 0x03, 0x04]) ||             // zip
            hasPrefix(b, [0x1F, 0x8B]) ||                      // gzip
            hasPrefix(b, [0x42, 0x5A, 0x68]) ||                // bzip2
            hasPrefix(b, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) || // xz
            hasPrefix(b, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) || // 7z
            hasPrefix(b, [0x28, 0xB5, 0x2F, 0xFD]) ||          // zstd
            hasPrefix(b, [0x52, 0x61, 0x72, 0x21]) ||          // rar
            hasPrefix(b, [0xFF, 0xD8, 0xFF]) ||                // jpeg
            hasPrefix(b, [0x89, 0x50, 0x4E, 0x47]) ||          // png
            hasPrefix(b, [0x47, 0x49, 0x46, 0x38]) ||          // gif
            hasPrefix(b, [0x4F, 0x67, 0x67, 0x53]) ||          // ogg
            hasPrefix(b, [0x49, 0x44, 0x33]) ||                // mp3 with ID3
            hasPrefix(b, [0x1A, 0x45, 0xDF, 0xA3]) ||          // matroska / webm
            hasPrefix(b, [0x66, 0x4C, 0x61, 0x43]) ||          // flac
            (b.count >= 12 && hasPrefix(b, [0x52, 0x49, 0x46, 0x46]) && Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50]) ||
            (b.count >= 12 && Array(b[4..<8]) == [0x66, 0x74, 0x79, 0x70])   // ISO base media (mp4, heic, mov)
    }

    static func looksLikeText(_ b: [UInt8]) -> Bool {
        if b.isEmpty { return false }
        var control = 0, high = 0
        for byte in b {
            if byte == 0 { return false }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0C && byte != 0x1B { control += 1 }
            if byte >= 0x80 { high += 1 }
        }
        if control * 100 > b.count { return false }   // more than 1 % control characters
        if high == 0 { return true }
        // Accept valid UTF-8, tolerating a sequence cut off at the end of the prefix.
        for cut in 0...min(3, b.count - 1) {
            if String(validating: b[0..<(b.count - cut)], as: UTF8.self) != nil { return true }
        }
        return high * 100 < b.count * 30                // Latin-1 style text
    }
}

/// Detects executable files and their CPU architecture from the file header.
public enum ExecutableSniffer {
    /// Returns nil when `header` is not an executable. An empty set means "executable, no known filter".
    public static func architectures(inHeader h: [UInt8]) -> Set<ExecutableArchitecture>? {
        guard h.count >= 4 else { return nil }
        func be32(_ o: Int) -> UInt32 {
            guard o + 4 <= h.count else { return 0 }
            return UInt32(h[o]) << 24 | UInt32(h[o + 1]) << 16 | UInt32(h[o + 2]) << 8 | UInt32(h[o + 3])
        }
        func le32(_ o: Int) -> UInt32 {
            guard o + 4 <= h.count else { return 0 }
            return UInt32(h[o + 3]) << 24 | UInt32(h[o + 2]) << 16 | UInt32(h[o + 1]) << 8 | UInt32(h[o])
        }
        func le16(_ o: Int) -> UInt16 {
            guard o + 2 <= h.count else { return 0 }
            return UInt16(h[o + 1]) << 8 | UInt16(h[o])
        }

        // Mach-O thin, little endian (0xFEEDFACE / 0xFEEDFACF) and big endian.
        let magicBE = be32(0)
        if magicBE == 0xCEFA_EDFE || magicBE == 0xCFFA_EDFE {
            return machOArch(le32(4)).map { [$0] } ?? []
        }
        if magicBE == 0xFEED_FACE || magicBE == 0xFEED_FACF {
            return machOArch(be32(4)).map { [$0] } ?? []
        }
        // Mach-O universal (fat). Java class files share 0xCAFEBABE, but their next field is >= 45.
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {
            let count = Int(be32(4))
            guard count >= 1, count <= 16 else { return nil }
            let stride = magicBE == 0xCAFE_BABE ? 20 : 32
            var result = Set<ExecutableArchitecture>()
            for i in 0..<count {
                let off = 8 + i * stride
                if off + 4 > h.count { break }
                if let a = machOArch(be32(off)) { result.insert(a) }
            }
            return result
        }
        // ELF
        if h[0] == 0x7F, h[1] == 0x45, h[2] == 0x4C, h[3] == 0x46, h.count >= 20 {
            let littleEndian = h[5] != 2
            let machine = littleEndian ? UInt16(h[19]) << 8 | UInt16(h[18]) : UInt16(h[18]) << 8 | UInt16(h[19])
            switch machine {
            case 3, 62: return [.x86]
            case 40: return [.arm]
            case 183: return [.arm64]
            case 20, 21: return [.powerPC]
            case 2, 43: return [.sparc]
            case 50: return [.ia64]
            case 243: return [.riscv]
            default: return []
            }
        }
        // PE / DOS "MZ"
        if h[0] == 0x4D, h[1] == 0x5A {
            let peOffset = Int(le32(0x3C))
            if h.count >= 0x40, peOffset >= 0x40, peOffset + 6 <= h.count,
               h[peOffset] == 0x50, h[peOffset + 1] == 0x45, h[peOffset + 2] == 0, h[peOffset + 3] == 0 {
                switch le16(peOffset + 4) {
                case 0x014C, 0x8664: return [.x86]
                case 0x01C0: return [.arm]
                case 0x01C2, 0x01C4: return [.armThumb]
                case 0xAA64, 0xA641: return [.arm64]
                case 0x0200: return [.ia64]
                case 0x01F0, 0x01F1: return [.powerPC]
                case 0x5032, 0x5064: return [.riscv]
                default: return []
                }
            }
            return [.x86]
        }
        return nil
    }

    private static func machOArch(_ cpuType: UInt32) -> ExecutableArchitecture? {
        switch cpuType {
        case 7, 0x0100_0007: return .x86
        case 12: return .arm
        case 0x0100_000C, 0x0200_000C: return .arm64
        case 18, 0x0100_0012: return .powerPC
        default: return nil
        }
    }

    /// Reads the first 4 KiB of `url` and detects the architectures. nil when not an executable.
    static func architectures(of url: URL) -> Set<ExecutableArchitecture>? {
        guard let prefix = readPrefix(of: url, count: 4096) else { return nil }
        return architectures(inHeader: prefix)
    }

    static func readPrefix(of url: URL, count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: count) else { return nil }
        return [UInt8](data)
    }
}
