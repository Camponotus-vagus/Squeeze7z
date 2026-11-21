import AppKit
import Foundation
import SwiftUI
import Testing
import Squeeze7zCore
@testable import Squeeze7z

/// Renders the main views offscreen into PNG files, to look at layouts without driving the app.
/// Runs only when SQUEEZE7Z_SNAPSHOT_DIR names the output folder:
///
///     SQUEEZE7Z_SNAPSHOT_DIR=/tmp/shots swift test --filter ViewSnapshotTests
///
/// The window server composites Liquid Glass, so glass surfaces come out flat here; texts, sizes,
/// colours and both appearances are faithful.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SQUEEZE7Z_SNAPSHOT_DIR"] != nil), .serialized)
struct ViewSnapshotTests {
    private var outputDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SQUEEZE7Z_SNAPSHOT_DIR"] ?? NSTemporaryDirectory(),
            isDirectory: true)
    }

    private func snapshot(_ view: some View, size: CGSize, name: String) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            // Let SwiftUI finish its first update passes (tables and forms fill in asynchronously).
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            window.close()
        }
    }

    private func sampleResult(for url: URL, outcome: OptimizationOutcome) -> OptimizationResult {
        let text = FileGroup(id: "ext:txt", category: .text, extensions: ["txt"], files: ["a.txt", "b.txt"],
                             totalBytes: 9_400_000)
        let code = FileGroup(id: "fam:text", category: .text, extensions: ["swift", "h"], files: ["x.swift", "y.h"],
                             totalBytes: 21_000_000)
        let ppmd = MethodSpec(coders: ["PPMd:o=8:mem=256m"])
        let lzma = MethodSpec(coders: ["LZMA2:d=64m:fb=273"])
        let trials = [TrialResult(method: ppmd, compressedBytes: 1_900_000, seconds: 1.4, sampled: false),
                      TrialResult(method: lzma, compressedBytes: 2_300_000, seconds: 2.1, sampled: true)]
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return OptimizationResult(
            sourceURL: url, outputURL: outcome == .optimized ? url.deletingPathExtension().appendingPathExtension("7z") : nil,
            sourceFormat: "zip", originalBytes: 48_300_000, optimizedBytes: outcome == .optimized ? 31_200_000 : 48_900_000,
            outcome: outcome,
            groups: [GroupReport(group: text, trials: trials, winner: ppmd),
                     GroupReport(group: code, trials: trials, winner: lzma)],
            strategy: "hybrid", trialCount: 42, startedAt: start, finishedAt: start.addingTimeInterval(95))
    }

    /// One job in every state the table can show.
    private func populatedModel() -> AppModel {
        let model = AppModel()
        let base = URL(fileURLWithPath: "/Users/someone/Archives", isDirectory: true)
        func job(_ name: String, bytes: Int64) -> Job { Job(url: base.appendingPathComponent(name), originalBytes: bytes) }

        let queued = job("field-notes.zip", bytes: 12_400_000)
        let running = job("specimens-2026.7z", bytes: 310_000_000)
        running.begin()
        running.phase = .trials
        running.trialsDone = 17
        running.trialsTotal = 42
        let starting = job("scans.tar.gz", bytes: 88_000_000)
        starting.begin()
        let done = job("manuscript-backup.rar", bytes: 48_300_000)
        done.status = .done
        done.result = sampleResult(for: done.url, outcome: .optimized)
        let noGain = job("photos-already-small.zip", bytes: 48_300_000)
        noGain.status = .noGain
        noGain.result = sampleResult(for: noGain.url, outcome: .noGain)
        let failed = job("broken-download.zip", bytes: 2_000_000)
        failed.status = .failed
        failed.errorMessage = "The archive is damaged: unexpected end of data"
        let cancelled = job("old-project.iso", bytes: 700_000_000)
        cancelled.status = .cancelled
        model.jobs = [queued, running, starting, done, noGain, failed, cancelled]
        return model
    }

    @Test func mainWindowStates() throws {
        let size = CGSize(width: 1120, height: 600)
        let empty = AppModel()
        empty.backupWarningDismissed = false
        try snapshot(ContentView().environment(empty), size: size, name: "main-empty-banner")

        let populated = populatedModel()
        populated.backupWarningDismissed = true
        populated.showTransientNotice("Skipped 3 items that are not archives.", seconds: 30)
        try snapshot(ContentView().environment(populated), size: size, name: "main-queue")
    }

    @Test func floatingElements() throws {
        let model = populatedModel()
        try snapshot(VStack(spacing: 20) {
            BackupBanner()
            DropOverlay(showsLabel: true).frame(height: 160)
            BottomBar()
        }
        .padding()
        .environment(model), size: CGSize(width: 1000, height: 420), name: "floating")
    }

    /// The opaque stand-in for glass (Reduce Transparency), with and without Increase Contrast.
    @Test func floatingElementsWithReducedTransparency() throws {
        func panel(_ text: String, tint: Color?, contrast: Bool) -> some View {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(FloatingGlassSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: tint,
                                               reduceTransparency: true, increasedContrast: contrast))
        }
        let badges = HStack {
            ForEach([JobStatus.queued, .done, .noGain, .failed, .cancelled], id: \.self) { status in
                if let style = StatusStyle.finished(status) { StatusBadge(style: style) }
            }
        }
        try snapshot(VStack(spacing: 16) {
            panel("Keep backups; verify results", tint: .yellow, contrast: false)
            panel("Keep backups; verify results", tint: .yellow, contrast: true)
            panel("Queue 3 · Optimized 2 session", tint: nil, contrast: false)
            panel("Drop to add to the queue", tint: .accentColor, contrast: true)
            badges
        }
        .padding(24), size: CGSize(width: 700, height: 340), name: "floating-reduced-transparency")
    }

    @Test func report() throws {
        let model = populatedModel()
        let done = try #require(model.jobs.first { $0.status == .done })
        done.appendLog("Phase: Inspecting")
        done.appendLog("Phase: Trials")
        try snapshot(ReportView(job: done), size: CGSize(width: 860, height: 640), name: "report-done")
        let failed = try #require(model.jobs.first { $0.status == .failed })
        try snapshot(ReportView(job: failed), size: CGSize(width: 860, height: 640), name: "report-failed")
    }

    @Test func settings() throws {
        let model = AppModel()
        try snapshot(SettingsView().environment(model), size: CGSize(width: 580, height: 440), name: "settings-tabs")
        try snapshot(GeneralSettings().environment(model), size: CGSize(width: 580, height: 350), name: "settings-general")
        try snapshot(CompressionSettings().environment(model), size: CGSize(width: 580, height: 690),
                     name: "settings-compression")
        try snapshot(PerformanceSettings().environment(model), size: CGSize(width: 580, height: 270),
                     name: "settings-performance")
    }
}
