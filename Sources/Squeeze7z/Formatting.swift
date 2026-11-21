import Foundation
import Squeeze7zCore

/// Small formatting helpers shared by the views.
enum Fmt {
    static func bytes(_ n: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // "0 bytes", never "Zero KB"
        return formatter.string(fromByteCount: n)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        if seconds < 10 && seconds > 0 { return String(format: "%.1fs", seconds) }
        return "\(s)s"
    }

    /// "about 12 min left", rounded the way a person would say it.
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 50 { return "under a minute left" }
        if minutes < 60 { return "about \(max(1, minutes)) min left" }
        let h = minutes / 60, m = (minutes % 60) / 5 * 5
        return m == 0 ? "about \(h) h left" : "about \(h) h \(m) min left"
    }

    /// "12.3 MB (24.5%)"
    static func saved(_ saved: Int64, of original: Int64) -> String {
        guard original > 0 else { return bytes(saved) }
        return "\(bytes(saved)) (\(percent(Double(saved) / Double(original))))"
    }
}

extension GroupReport {
    /// ".txt" for "ext:txt", "compressed (merged)" for "cat:compressed", "Text and source (family)" for
    /// "fam:text".
    var uiTitle: String {
        if group.id.hasPrefix("ext:") { return "." + group.id.dropFirst(4) }
        if group.id.hasPrefix("cat:") { return group.id.dropFirst(4) + " (merged)" }
        if group.id.hasPrefix("fam:") {
            let name = String(group.id.dropFirst(4))
            return (FileFamily(rawValue: name)?.displayName ?? name) + " (family)"
        }
        return group.id
    }

    /// The trial that produced the winning method, falling back to the smallest trial.
    var uiBestTrial: TrialResult? {
        trials.first(where: { $0.method == winner })
            ?? trials.min(by: { $0.compressedBytes < $1.compressedBytes })
    }
}
