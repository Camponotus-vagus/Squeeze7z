// Public API contract shared by the core engine, the CLI and the SwiftUI app.
// Implementation agents may ADD members but must not rename or remove the ones declared here.

import Foundation

// MARK: - Modes & settings

public enum OptimizationMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case fast, smart, normal, good, best, ultra, extreme, extreme2
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .fast: "Fast"
        case .smart: "Smart"
        case .normal: "Normal"
        case .good: "Good"
        case .best: "Best"
        case .ultra: "Ultra"
        case .extreme: "Extreme"
        case .extreme2: "Extreme 2"
        }
    }
}

public enum OutputMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Write `<name>_optimized.7z` next to the source (or in `outputDirectory`). Source untouched.
    case newFile
    /// Move the source to the Trash and put `<name>.7z` in its place.
    case replaceOriginal
    public var id: String { rawValue }
}

public struct OptimizerSettings: Codable, Sendable, Equatable {
    public var mode: OptimizationMode = .smart
    public var lzmaDictionaryMB: Int = 128
    public var ppmdMemoryMB: Int = 256
    /// LZMA "word size" (fast bytes, fb), 5...273.
    public var lzmaWordSize: Int = 64
    /// 0 = trials on full data; n = trials on a sample of at most n*5 MB per group.
    public var samplingLevel: Int = 0
    /// Skip PPMd for groups larger than this (MB). nil = no limit.
    public var noPPMdAboveMB: Int? = nil
    public var disablePPMd: Bool = false
    public var disableBZip2: Bool = false
    /// 0 = unlimited solid blocks (-ms=on).
    public var solidBlockSizeMB: Int = 0
    /// Archives processed at the same time (used by the app's queue).
    public var parallelJobs: Int = 2
    /// Trials run at the same time inside one archive.
    public var concurrentTrials: Int = 2
    /// 0 = let 7zz decide (-mmt=on).
    public var threadsPerTrial: Int = 0
    /// Forces -mmt=1 and concurrentTrials = 1.
    public var lowCPU: Bool = false
    public var outputMode: OutputMode = .newFile
    /// nil = same folder as the source.
    public var outputDirectory: URL? = nil
    /// Groups smaller than this are merged into their category group.
    public var minGroupBytes: Int = 64 * 1024
    public var keepTempFiles: Bool = false
    /// Allow the ARM64 and RISC-V branch filters for executables. They need 7-Zip 23 or later to extract
    /// (Archive Utility on macOS 26 reads them; p7zip 17 and 7-Zip before 23 do not). On by default; off keeps
    /// every archive readable by 7-Zip 9.20 at a cost on arm64 executables.
    public var allowModernFilters: Bool = true
    /// Also try one solid block per affinity family (text, executables, …) next to one block per extension,
    /// and keep whichever layout is smaller. Off = per-extension groups only.
    public var hybridGroups: Bool = true
    /// Keep the `__MACOSX` folder of AppleDouble files that Finder puts in zip files. Off = the folder is left
    /// out of the 7z: Archive Utility mistakes it for real content when it expands a 7z and replaces the files
    /// with their metadata stubs. Leaving it out drops the extended attributes it holds (Finder tags, comments,
    /// quarantine and provenance flags, resource forks).
    public var keepMacOSMetadata: Bool = false
    /// Fast and Smart modes: put already compressed files (jpg, mp4, zip, …) in their own block of independent
    /// LZMA2 chunks, so every core works on them. Off = one LZMA2 stream over the whole tree, as `7zz -mx9`.
    public var parallelMediaBlocks: Bool = true

    public init() {}

    /// Tolerant decoding: a key that is missing (settings saved by an older version) keeps its default.
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ current: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? current
        }
        mode = try value(.mode, mode)
        lzmaDictionaryMB = try value(.lzmaDictionaryMB, lzmaDictionaryMB)
        ppmdMemoryMB = try value(.ppmdMemoryMB, ppmdMemoryMB)
        lzmaWordSize = try value(.lzmaWordSize, lzmaWordSize)
        samplingLevel = try value(.samplingLevel, samplingLevel)
        noPPMdAboveMB = try c.decodeIfPresent(Int.self, forKey: .noPPMdAboveMB)
        disablePPMd = try value(.disablePPMd, disablePPMd)
        disableBZip2 = try value(.disableBZip2, disableBZip2)
        solidBlockSizeMB = try value(.solidBlockSizeMB, solidBlockSizeMB)
        parallelJobs = try value(.parallelJobs, parallelJobs)
        concurrentTrials = try value(.concurrentTrials, concurrentTrials)
        threadsPerTrial = try value(.threadsPerTrial, threadsPerTrial)
        lowCPU = try value(.lowCPU, lowCPU)
        outputMode = try value(.outputMode, outputMode)
        outputDirectory = try c.decodeIfPresent(URL.self, forKey: .outputDirectory)
        minGroupBytes = try value(.minGroupBytes, minGroupBytes)
        keepTempFiles = try value(.keepTempFiles, keepTempFiles)
        allowModernFilters = try value(.allowModernFilters, allowModernFilters)
        hybridGroups = try value(.hybridGroups, hybridGroups)
        keepMacOSMetadata = try value(.keepMacOSMetadata, keepMacOSMetadata)
        parallelMediaBlocks = try value(.parallelMediaBlocks, parallelMediaBlocks)
    }
}

extension ExecutableArchitecture {
    /// ARM64 (7-Zip 23) and RISC-V (7-Zip 24) filters cannot be read by older 7-Zip versions.
    public var requiresModernSevenZip: Bool { self == .arm64 || self == .riscv }
}

// MARK: - File classification

public enum FileCategory: String, Codable, Sendable, CaseIterable {
    case text          // txt, html, xml, json, csv, source code, svg, rtf, log, md …
    case binary        // generic data, db, doc (old office), pdf (partially), dat …
    case executable    // Mach-O, PE (exe/dll/sys), ELF, so, dylib, o, a
    case imageRaw      // bmp, tga, tif/tiff (uncompressed), pnm, raw camera, psd
    case audioRaw      // wav, aif/aiff, au, raw pcm
    case compressed    // jpg, png, gif, webp, heic, mp3, aac, ogg, flac, mp4, mov, mkv, zip, 7z, rar, gz, xz, docx, xlsx, pdf …
    case misc          // anything else / unknown extension
}

public struct ArchiveEntry: Sendable, Hashable, Codable {
    public var path: String          // relative path inside the archive, "/" separated
    public var size: Int64
    public var packedSize: Int64?
    public var crc: UInt32?
    public var isDirectory: Bool
    public var isEncrypted: Bool
    public var isSymlink: Bool
    public var method: String?
    public var modified: Date?
    /// Hard links (tar) report size 0 in listings but are extracted as full files.
    public var isHardLink: Bool = false
    /// FIFO, character/block device or socket: 7z cannot store these, 7zz extracts them as empty files.
    public var isSpecialFile: Bool = false
    /// Unix permission bits (including setuid, setgid and sticky) when the listing shows them.
    public var unixMode: UInt16?

    public init(path: String, size: Int64, packedSize: Int64? = nil, crc: UInt32? = nil,
                isDirectory: Bool = false, isEncrypted: Bool = false, isSymlink: Bool = false,
                method: String? = nil, modified: Date? = nil) {
        self.path = path; self.size = size; self.packedSize = packedSize; self.crc = crc
        self.isDirectory = isDirectory; self.isEncrypted = isEncrypted; self.isSymlink = isSymlink
        self.method = method; self.modified = modified
    }
}

public struct ArchiveListing: Sendable, Codable {
    public var archivePath: String
    public var format: String         // "7z", "zip", "Rar5", … as reported by 7zz "Type ="
    public var physicalSize: Int64
    public var isSolid: Bool
    public var methods: String?
    public var entries: [ArchiveEntry]
    /// Bytes that follow the end of the archive (`Tail Size`); 7zz does not list or extract them.
    public var tailBytes: Int64 = 0
    /// Bytes before the archive proper (`Offset` / `Embedded Stub Size`, e.g. an SFX stub).
    public var headBytes: Int64 = 0
    public init(archivePath: String, format: String, physicalSize: Int64, isSolid: Bool,
                methods: String?, entries: [ArchiveEntry], tailBytes: Int64 = 0, headBytes: Int64 = 0) {
        self.archivePath = archivePath; self.format = format; self.physicalSize = physicalSize
        self.isSolid = isSolid; self.methods = methods; self.entries = entries
        self.tailBytes = tailBytes; self.headBytes = headBytes
    }
}

public struct FileGroup: Sendable, Identifiable, Codable {
    /// e.g. "ext:txt" or "cat:compressed"
    public var id: String
    public var category: FileCategory
    public var extensions: [String]
    /// Paths relative to the extraction root.
    public var files: [String]
    public var totalBytes: Int64
    /// CPU architectures found in executable files of this group, most voluminous first.
    /// Empty when unknown or when the group is not executable. Drives the choice of branch filters.
    public var executableArchitectures: [ExecutableArchitecture] = []
    public init(id: String, category: FileCategory, extensions: [String], files: [String], totalBytes: Int64) {
        self.id = id; self.category = category; self.extensions = extensions; self.files = files; self.totalBytes = totalBytes
    }
}

// MARK: - Methods

/// One 7z coder chain (e.g. Delta:4 + LZMA) plus archive-level switches, rendered to 7zz args.
public struct MethodSpec: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Coders in order, each a 7zz method string such as "LZMA:d=128m:fb=273" or "Delta:4".
    public var coders: [String]
    /// Extra switches such as "-mb0s0:1" (BCJ2 bonds) or "-mqs=on".
    public var extraArgs: [String]
    public init(coders: [String], extraArgs: [String] = []) {
        self.coders = coders; self.extraArgs = extraArgs
    }
    /// Human readable, e.g. "Delta:4 + LZMA:d=128m:fb=64".
    public var description: String {
        coders.joined(separator: " + ") + (extraArgs.contains(MethodSpec.sortByTypeSwitch) ? " [sorted by type]" : "")
    }
    /// 7zz switch that orders the files of a solid block by extension before name (default: by name).
    public static let sortByTypeSwitch = "-mqs=on"
    /// `-m0=…`, `-m1=…`, … followed by `extraArgs`. Solid/thread/header switches are added by the caller.
    public var arguments: [String] {
        coders.enumerated().map { "-m\($0.offset)=\($0.element)" } + extraArgs
    }
    public static let copy = MethodSpec(coders: ["Copy"])
}

public struct TrialResult: Sendable, Codable, Hashable {
    public var method: MethodSpec
    public var compressedBytes: Int64
    public var seconds: Double
    public var sampled: Bool
    public init(method: MethodSpec, compressedBytes: Int64, seconds: Double, sampled: Bool) {
        self.method = method; self.compressedBytes = compressedBytes; self.seconds = seconds; self.sampled = sampled
    }
}

public struct GroupReport: Sendable, Codable, Identifiable {
    public var id: String { group.id }
    public var group: FileGroup
    public var trials: [TrialResult]
    public var winner: MethodSpec
    public init(group: FileGroup, trials: [TrialResult], winner: MethodSpec) {
        self.group = group; self.trials = trials; self.winner = winner
    }
}

/// Outcome of comparing one family as a single solid block with the same files split by extension.
public struct FamilyReport: Sendable, Codable, Identifiable {
    /// "fam:<name>", the id of the family group in `OptimizationResult.groups` when it was kept as one block.
    public var id: String
    public var family: FileFamily
    /// Ids of the extension groups that make up the family.
    public var groupIDs: [String]
    public var totalBytes: Int64
    /// Estimated packed size as one block (best trial scaled to the full data) and split by extension.
    public var blockBytes: Int64
    public var splitBytes: Int64
    /// True when the family is stored as one block in the hybrid layout.
    public var useBlock: Bool
    /// Best method found for the block.
    public var winner: MethodSpec?
    public var trialCount: Int
    public init(id: String, family: FileFamily, groupIDs: [String], totalBytes: Int64, blockBytes: Int64,
                splitBytes: Int64, useBlock: Bool, winner: MethodSpec?, trialCount: Int) {
        self.id = id; self.family = family; self.groupIDs = groupIDs; self.totalBytes = totalBytes
        self.blockBytes = blockBytes; self.splitBytes = splitBytes; self.useBlock = useBlock
        self.winner = winner; self.trialCount = trialCount
    }
}

// MARK: - Progress & results

public enum OptimizationPhase: String, Sendable, Codable {
    case inspecting, extracting, grouping, trials, assembling, baseline, verifying, finishing
    public var displayName: String {
        switch self {
        case .inspecting: "Inspecting"
        case .extracting: "Extracting"
        case .grouping: "Grouping"
        case .trials: "Trials"
        case .assembling: "Assembling"
        case .baseline: "Baseline"
        case .verifying: "Verifying"
        case .finishing: "Finishing"
        }
    }
}

public enum OptimizationEvent: Sendable {
    case phase(OptimizationPhase)
    /// Trials completed / planned for the whole archive.
    case trialProgress(done: Int, total: Int)
    /// Free-form log line (shown in the report / console).
    case log(String)
    /// Progress inside the current long step (extraction, compression, verification), about twice a second.
    case stepProgress(StepProgress)
}

/// One progress line of a running 7zz: percent of its work, files done, the file it is on.
struct ToolProgress: Sendable, Equatable {
    var percent: Int
    var files: Int?
    var currentFile: String?
}

/// Where a job is inside one long step, for a live status line.
public struct StepProgress: Sendable, Equatable {
    public enum Step: String, Sendable, Equatable {
        case extracting, compressing, compressingMedia, verifying

        public var displayName: String {
            switch self {
            case .extracting: "Extracting"
            case .compressing: "Compressing"
            case .compressingMedia: "Compressing media"
            case .verifying: "Verifying"
            }
        }
    }

    public var step: Step
    /// 0...1 of this step.
    public var fraction: Double
    public var filesDone: Int?
    public var filesTotal: Int?
    /// Path inside the archive or folder, as 7zz prints it.
    public var currentFile: String?
    /// Share saved so far while compressing (0.03 = 3%), estimated from what has been written; nil when unknown.
    public var estimatedSaving: Double?

    public init(step: Step, fraction: Double, filesDone: Int? = nil, filesTotal: Int? = nil,
                currentFile: String? = nil, estimatedSaving: Double? = nil) {
        self.step = step; self.fraction = fraction; self.filesDone = filesDone; self.filesTotal = filesTotal
        self.currentFile = currentFile; self.estimatedSaving = estimatedSaving
    }
}

public enum OptimizationOutcome: String, Sendable, Codable {
    /// A smaller archive was written to `outputURL`.
    case optimized
    /// Result was not smaller; nothing written, source untouched.
    case noGain
}

public struct OptimizationResult: Sendable, Codable {
    public var sourceURL: URL
    public var outputURL: URL?
    public var sourceFormat: String
    public var originalBytes: Int64
    /// Size of the best archive produced (even when not kept).
    public var optimizedBytes: Int64
    public var outcome: OptimizationOutcome
    public var groups: [GroupReport]
    /// "per-group", "hybrid" (one solid block per family where that was smaller) or the name of the winning
    /// whole-archive baseline.
    public var strategy: String
    public var trialCount: Int
    public var startedAt: Date
    public var finishedAt: Date
    /// Families that were evaluated as one block against a split by extension (empty when none had two groups
    /// or hybrid groups are off). `groups` holds the layout of the winning archive: a "fam:<name>" entry for
    /// each family kept as one block, the extension groups otherwise.
    public var families: [FamilyReport] = []
    public var savedBytes: Int64 { outcome == .optimized ? originalBytes - optimizedBytes : 0 }
    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    public init(sourceURL: URL, outputURL: URL?, sourceFormat: String, originalBytes: Int64,
                optimizedBytes: Int64, outcome: OptimizationOutcome, groups: [GroupReport],
                strategy: String, trialCount: Int, startedAt: Date, finishedAt: Date,
                families: [FamilyReport] = []) {
        self.sourceURL = sourceURL; self.outputURL = outputURL; self.sourceFormat = sourceFormat
        self.originalBytes = originalBytes; self.optimizedBytes = optimizedBytes; self.outcome = outcome
        self.groups = groups; self.strategy = strategy; self.trialCount = trialCount
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.families = families
    }
}

public enum OptimizerError: Error, Sendable, LocalizedError, Equatable {
    case sevenZipNotFound
    case notAnArchive(String)
    case encrypted
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case toolFailed(command: String, exitCode: Int32, stderr: String)
    case verificationFailed(String)
    case cancelled
    /// A file or folder of the unpacked archive cannot be read (permissions); nothing was changed.
    case unreadable(String)
    /// The optimized archive is complete but could not be moved into place; it is kept at the given path.
    case outputKept(path: String, reason: String)
    /// A folder cannot be compressed as it is (name collisions, output inside the folder, unwritable destination,
    /// staging failure). Nothing was changed.
    case folderProblem(String)

    public var errorDescription: String? {
        switch self {
        case .sevenZipNotFound: "The 7zz engine was not found."
        case .notAnArchive(let s): "Not a supported archive: \(s)"
        case .encrypted: "Password-protected archives are not supported."
        case .insufficientDiskSpace(let n, let a):
            "Not enough free disk space (need \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)), available \(ByteCountFormatter.string(fromByteCount: a, countStyle: .file)))."
        case .toolFailed(let c, let code, let err): "7zz failed (\(code)) running \(c): \(err)"
        case .verificationFailed(let s): "Verification failed: \(s)"
        case .cancelled: "Cancelled."
        case .unreadable(let s):
            "Cannot read \(s). It has no read permission, so it cannot be repacked safely."
        case .folderProblem(let s): s
        case .outputKept(let path, let reason):
            "The optimized archive was kept at \(path) because the original could not be replaced cleanly: \(reason)"
        }
    }
}

// MARK: - Entry points (implemented in other files of Squeeze7zCore)
//
// public struct SevenZipTool: Sendable {
//     public let executableURL: URL
//     public init(executableURL: URL)
//     public static func locate() throws -> SevenZipTool          // resolution order: SevenZipTool.locate()
//     public var version: String { get async throws }
//     public func list(_ archive: URL) async throws -> ArchiveListing
// }
//
// public struct ArchiveOptimizer: Sendable {
//     public init(tool: SevenZipTool, settings: OptimizerSettings)
//     /// Cooperative cancellation: cancelling the calling Task must terminate child 7zz processes
//     /// and throw OptimizerError.cancelled. Temp files are always removed.
//     public func optimize(_ source: URL,
//                          progress: @escaping @Sendable (OptimizationEvent) -> Void) async throws -> OptimizationResult
//     public static func isSupportedArchive(_ url: URL) -> Bool   // by extension (+ volume patterns)
//     public static let supportedExtensions: Set<String>
// }
//
// public enum FileClassifier { public static func category(forExtension: String) -> FileCategory }
// public enum CandidateGenerator {
//     public static func candidates(for group: FileGroup, settings: OptimizerSettings,
//                                   isSingleExtensionArchive: Bool) -> [MethodSpec]
// }
// public struct CRC32 { public static func checksum(of url: URL) throws -> UInt32; public static func checksum(_ data: Data) -> UInt32 }
