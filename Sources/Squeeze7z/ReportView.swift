import SwiftUI
import Squeeze7zCore

struct ReportView: View {
    let job: Job
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(job.url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 12)
                if let style = StatusStyle.finished(job.status) {
                    StatusBadge(style: style)
                } else {
                    StatusBadge(style: StatusStyle(title: "Running", systemImage: "arrow.triangle.2.circlepath",
                                                   color: .blue))
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = job.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let result = job.result {
                        SummarySection(job: job, result: result)
                        GroupsSection(result: result)
                        TrialsSection(result: result)
                    } else if job.status == .running {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Running: \(job.phase?.displayName ?? "starting")")
                        }
                    }
                    LogSection(lines: job.log)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 560, idealHeight: 640)
    }
}

private struct SummarySection: View {
    let job: Job
    let result: OptimizationResult

    var body: some View {
        GroupBox("Summary") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                row("Outcome", result.outcome == .optimized ? "Optimized" : "No gain (source untouched)")
                row("Source format", result.sourceFormat)
                row("Original", Fmt.bytes(result.originalBytes))
                row("Best archive", Fmt.bytes(result.optimizedBytes))
                if result.outcome == .optimized {
                    row("Saved", Fmt.saved(result.savedBytes, of: result.originalBytes))
                }
                row("Strategy", strategyTitle(result.strategy))
                row("Trials", "\(result.trialCount)")
                row("Duration", Fmt.duration(result.duration))
                if let output = result.outputURL {
                    GridRow {
                        Text("Output").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        HStack {
                            Text(output.path)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([output])
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    /// Anything else is the name of the whole-archive baseline that won.
    private func strategyTitle(_ strategy: String) -> String {
        switch strategy {
        case "per-group": "Per-group methods"
        case "hybrid": "Hybrid (one block per file family where smaller)"
        default: strategy
        }
    }
}

private struct GroupsSection: View {
    let result: OptimizationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File groups").font(.headline)
            if result.groups.isEmpty {
                Text("No per-group results (whole-archive strategy).").foregroundStyle(.secondary)
            } else {
                Table(result.groups) {
                    TableColumn("Group") { g in Text(g.uiTitle).fontWeight(.medium) }
                        .width(min: 80, ideal: 100)
                    TableColumn("Category") { g in Text(g.group.category.rawValue) }
                        .width(min: 70, ideal: 80)
                    TableColumn("Files") { g in Text("\(g.group.files.count)").monospacedDigit() }
                        .width(min: 40, ideal: 50)
                        .alignment(.trailing)
                    TableColumn("Size") { g in Text(Fmt.bytes(g.group.totalBytes)).monospacedDigit() }
                        .width(min: 70, ideal: 80)
                        .alignment(.trailing)
                    TableColumn("Winner") { g in
                        Text(g.winner.description).lineLimit(1).truncationMode(.tail).help(g.winner.description)
                    }
                    .width(min: 140, ideal: 180)
                    TableColumn("Best size") { g in
                        if let best = g.uiBestTrial {
                            Text(Fmt.bytes(best.compressedBytes) + (best.sampled ? " (sample)" : ""))
                                .monospacedDigit()
                        } else {
                            Text("-")
                        }
                    }
                    .width(min: 90, ideal: 110)
                    .alignment(.trailing)
                }
                .frame(height: min(max(CGFloat(result.groups.count) * 26 + 34, 100), 300))
            }
        }
    }
}

private struct TrialsSection: View {
    let result: OptimizationResult

    var body: some View {
        if !result.groups.isEmpty {
            DisclosureGroup("All trials (\(result.groups.reduce(0) { $0 + $1.trials.count }))") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.groups) { report in
                        DisclosureGroup("\(report.uiTitle) (\(report.trials.count))") {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                ForEach(Array(sorted(report).enumerated()), id: \.offset) { _, trial in
                                    GridRow {
                                        Image(systemName: trial.method == report.winner ? "star.fill" : "circle")
                                            .foregroundStyle(trial.method == report.winner ? .yellow : .clear)
                                        Text(trial.method.description)
                                            .font(.system(.callout, design: .monospaced))
                                            .lineLimit(1).truncationMode(.middle)
                                        Text(Fmt.bytes(trial.compressedBytes))
                                            .monospacedDigit()
                                            .gridColumnAlignment(.trailing)
                                        Text(String(format: "%.1fs", trial.seconds))
                                            .monospacedDigit().foregroundStyle(.secondary)
                                            .gridColumnAlignment(.trailing)
                                        Text(trial.sampled ? "sample" : "")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func sorted(_ report: GroupReport) -> [TrialResult] {
        report.trials.sorted { $0.compressedBytes < $1.compressedBytes }
    }
}

private struct LogSection: View {
    let lines: [String]

    var body: some View {
        DisclosureGroup("Log (\(lines.count) lines)") {
            ScrollView {
                Text(lines.isEmpty ? "No log output." : lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
