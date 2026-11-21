import Foundation
import Squeeze7zCore

// squeeze7z-cli: command-line front end of the Squeeze7z engine.

let usage = """
Usage:
  squeeze7z-cli optimize [options] FILE_OR_FOLDER...
  squeeze7z-cli inspect FILE

A folder given to optimize is compressed into FOLDER_NAME.7z next to it (or in --out). It is never trashed,
whatever --replace says.

Options for optimize:
  --mode M          fast | smart | normal | good | best | ultra | extreme | extreme2   (default: smart)
  --sampling N      0...6, trials on samples of N*5 MB per group              (default: 0)
  --out DIR         write results into DIR instead of next to the source
  --replace         move the source to the Trash and put NAME.7z in its place
  --json            print results as JSON on stdout
  --dict MB         LZMA dictionary size in MB                                (default: 128)
  --ppmd-mem MB     PPMd memory in MB                                         (default: 256)
  --word-size N     LZMA fast bytes, 5...273                                  (default: 64)
  --solid MB        solid block size in MB, 0 = unlimited                     (default: 0)
  --trials N        trials in parallel                                        (default: 2)
  --threads N       7zz threads per trial, 0 = automatic                      (default: 0)
  --no-ppmd         never try PPMd
  --no-bzip2        never try BZip2
  --no-ppmd-above MB  skip PPMd for groups larger than MB
  --no-hybrid       never store a family of related extensions as one solid block
  --keep-macosx     keep the __MACOSX folder of zip files made by Finder (left out by default)
  --no-modern-filters  leave out the ARM64 and RISC-V filters, so 7-Zip before 23 can extract the result
  --modern-filters  accepted for compatibility: the ARM64 and RISC-V filters are on by default
  --single-stream   fast/smart: no parallel block for jpg, mp4, zip…; one LZMA2 stream as 7zz -mx9
  --low-cpu         one thread, one trial at a time
  --keep-temp       keep the temporary directory for debugging
  --quiet           no progress output on stderr
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func err(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    let p = String(repeating: " ", count: max(0, width - s.count))
    return right ? p + s : s + p
}

struct Options {
    var settings = OptimizerSettings()
    var json = false
    var quiet = false
    var files: [String] = []
}

func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("Missing value for \(flag)") }
        return args[i]
    }
    func intValue(_ flag: String) -> Int {
        guard let n = Int(value(flag)) else { fail("Invalid number for \(flag)") }
        return n
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--mode":
            guard let m = OptimizationMode(rawValue: value(a).lowercased()) else {
                fail("Unknown mode. Use one of: " + OptimizationMode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            o.settings.mode = m
        case "--sampling": o.settings.samplingLevel = min(max(intValue(a), 0), 6)
        case "--out": o.settings.outputDirectory = URL(fileURLWithPath: value(a), isDirectory: true)
        case "--replace": o.settings.outputMode = .replaceOriginal
        case "--json": o.json = true
        case "--dict": o.settings.lzmaDictionaryMB = intValue(a)
        case "--ppmd-mem": o.settings.ppmdMemoryMB = intValue(a)
        case "--word-size": o.settings.lzmaWordSize = intValue(a)
        case "--solid": o.settings.solidBlockSizeMB = intValue(a)
        case "--trials": o.settings.concurrentTrials = max(1, intValue(a))
        case "--threads": o.settings.threadsPerTrial = max(0, intValue(a))
        case "--no-ppmd": o.settings.disablePPMd = true
        case "--no-bzip2": o.settings.disableBZip2 = true
        case "--no-ppmd-above": o.settings.noPPMdAboveMB = intValue(a)
        case "--no-hybrid": o.settings.hybridGroups = false
        case "--keep-macosx": o.settings.keepMacOSMetadata = true
        case "--modern-filters": o.settings.allowModernFilters = true
        case "--no-modern-filters": o.settings.allowModernFilters = false
        case "--single-stream": o.settings.parallelMediaBlocks = false
        case "--low-cpu": o.settings.lowCPU = true
        case "--keep-temp": o.settings.keepTempFiles = true
        case "--quiet": o.quiet = true
        case "-h", "--help": print(usage); exit(0)
        default:
            if a.hasPrefix("--") { fail("Unknown option \(a)\n\n\(usage)") }
            o.files.append(a)
        }
        i += 1
    }
    return o
}

func printReport(_ r: OptimizationResult) {
    print("\(r.sourceURL.lastPathComponent)  [\(r.sourceFormat)]")
    let idW = max(8, r.groups.map { $0.group.id.count }.max() ?? 8)
    print("  " + pad("group", idW) + "  " + pad("category", 10) + pad("files", 7, right: true) + pad("size", 11, right: true)
          + pad("trials", 8, right: true) + "  winner")
    for g in r.groups {
        let winnerTrial = g.trials.first { $0.method == g.winner }
        let packed = winnerTrial.map { " -> \(bytes($0.compressedBytes))" + ($0.sampled ? " (sample)" : "") } ?? ""
        print("  " + pad(g.group.id, idW) + "  " + pad(g.group.category.rawValue, 10)
              + pad(String(g.group.files.count), 7, right: true) + pad(bytes(g.group.totalBytes), 11, right: true)
              + pad(String(g.trials.count), 8, right: true) + "  \(g.winner)\(packed)")
    }
    let pct = r.originalBytes > 0 ? Double(r.originalBytes - r.optimizedBytes) / Double(r.originalBytes) * 100 : 0
    if !r.families.isEmpty {
        print("  families (one block vs split by extension, estimated):")
        for f in r.families {
            let layout = f.useBlock ? "one block" : "split by extension"
            let block = f.blockBytes == Int64.max ? "-" : bytes(f.blockBytes)
            print("    " + pad(f.id, 16) + pad(String(f.groupIDs.count) + " groups", 11) + pad(bytes(f.totalBytes), 11, right: true)
                  + "  block " + pad(block, 9, right: true) + "  split " + pad(bytes(f.splitBytes), 9, right: true) + "  -> \(layout)")
        }
    }
    print("  strategy: \(r.strategy), trials: \(r.trialCount), time: \(String(format: "%.1f", r.duration)) s")
    switch r.outcome {
    case .optimized:
        print("  original \(bytes(r.originalBytes)) -> optimized \(bytes(r.optimizedBytes)), saved \(bytes(r.savedBytes)) (\(String(format: "%.2f", pct)) %)")
        if let out = r.outputURL { print("  output: \(out.path)") }
    case .noGain:
        print("  no gain: best result \(bytes(r.optimizedBytes)) vs original \(bytes(r.originalBytes)); nothing written")
    }
}

func runOptimize(_ args: [String]) async -> Int32 {
    let o = parseOptions(args)
    guard !o.files.isEmpty else { fail("No input files or folders.\n\n\(usage)") }
    let tool: SevenZipTool
    do { tool = try SevenZipTool.locate() } catch { fail(error.localizedDescription) }
    let optimizer = ArchiveOptimizer(tool: tool, settings: o.settings)
    optimizer.sweepStaleTemporaryFiles()
    let quiet = o.quiet || o.json
    var status: Int32 = 0
    var results: [OptimizationResult] = []
    for path in o.files {
        let url = URL(fileURLWithPath: path)
        if !quiet { err("== \(url.lastPathComponent)") }
        do {
            let result = try await optimizer.optimize(url) { event in
                if quiet { return }
                switch event {
                case .phase(let p): err("[\(p.displayName)]")
                case .trialProgress(let d, let t): if d == t || d % 10 == 0 { err("  trial \(d)/\(t)") }
                case .log(let s): err("  \(s)")
                }
            }
            results.append(result)
            if !o.json { printReport(result) }
        } catch {
            err("\(url.lastPathComponent): \(error.localizedDescription)")
            status = 1
        }
    }
    if o.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(results) { print(String(decoding: data, as: UTF8.self)) }
    }
    return status
}

func runInspect(_ args: [String]) async -> Int32 {
    guard args.count == 1 else { fail("inspect takes exactly one file.\n\n\(usage)") }
    let tool: SevenZipTool
    do { tool = try SevenZipTool.locate() } catch { fail(error.localizedDescription) }
    let url = URL(fileURLWithPath: args[0])
    if ArchiveOptimizer.isFolder(url) {
        err("\(url.lastPathComponent) is a folder: inspect reads archives. Use optimize to compress the folder.")
        return 1
    }
    do {
        let listing = try await tool.list(url)
        print("\(url.lastPathComponent): \(listing.format), \(bytes(listing.physicalSize)), solid: \(listing.isSolid ? "yes" : "no"), methods: \(listing.methods ?? "-")")
        let files = listing.entries.filter { !$0.isDirectory }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        print("\(files.count) files, \(listing.entries.count - files.count) directories, \(bytes(total)) unpacked")
        print("")
        for e in listing.entries {
            let kind = e.isDirectory ? "d" : (e.isSymlink ? "l" : "-")
            let crc = e.crc.map { String(format: "%08X", $0) } ?? "        "
            print("\(kind) \(pad(String(e.size), 12, right: true)) \(crc)  \(e.path)")
        }
        // Grouping preview by extension and category.
        var perExt: [String: (Int, Int64)] = [:]
        for e in files {
            let ext = FileClassifier.extensionKey(forPath: e.path)
            let old = perExt[ext] ?? (0, 0)
            perExt[ext] = (old.0 + 1, old.1 + e.size)
        }
        print("\nBy extension:")
        for (ext, v) in perExt.sorted(by: { $0.value.1 > $1.value.1 }) {
            let cat = FileClassifier.category(forExtension: ext)
            print("  \(pad(ext.isEmpty ? "(none)" : ext, 12)) \(pad(cat.rawValue, 11)) \(pad(String(v.0), 7, right: true)) files \(pad(bytes(v.1), 11, right: true))")
        }
        return 0
    } catch {
        err(error.localizedDescription)
        return 1
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(2) }

/// Remembers which termination signal arrived, for the exit status.
final class SignalRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0
    func set(_ signal: Int32) { lock.lock(); if value == 0 { value = signal }; lock.unlock() }
    var received: Int32 { lock.lock(); defer { lock.unlock() }; return value }
}

let signalRecord = SignalRecord()
let work = Task { () -> Int32 in
    switch command {
    case "optimize": return await runOptimize(Array(arguments.dropFirst()))
    case "inspect": return await runInspect(Array(arguments.dropFirst()))
    case "-h", "--help", "help": print(usage); return 0
    default: fail("Unknown command \(command)\n\n\(usage)")
    }
}

// Ctrl-C, `kill` and a closing terminal all cancel the run, so the 7zz children are stopped and the
// temporary folder is removed before exiting. A second signal gives up waiting and exits at once
// (the exit hook still kills the children and removes the temporary folder).
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        if signalRecord.received != 0 { exit(128 + sig) }
        signalRecord.set(sig)
        work.cancel()
    }
    source.resume()
    signalSources.append(source)
}
let status = await work.value
if signalRecord.received != 0 { exit(128 + signalRecord.received) }
exit(status)
