import SwiftUI
import AppKit
import Squeeze7zCore

/// The Settings window: three toolbar tabs, each one a grouped form.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Compression", systemImage: "archivebox") {
                CompressionSettings()
            }
            Tab("Performance", systemImage: "gauge.with.dots.needle.67percent") {
                PerformanceSettings()
            }
        }
        .frame(width: 580)
    }
}

/// Where results go, the safety net and the reset.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    private let updates = Updates.shared
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Result", selection: $model.settings.outputMode) {
                    Text("New file (_optimized.7z)").tag(OutputMode.newFile)
                    Text("Replace original (move to Trash)").tag(OutputMode.replaceOriginal)
                }
                LabeledContent("Output folder") {
                    HStack {
                        Text(model.settings.outputDirectory?.path ?? "Same folder as the source")
                            .foregroundStyle(model.settings.outputDirectory == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.head)
                        Button("Choose…") { chooseOutputFolder() }
                        if model.settings.outputDirectory != nil {
                            Button("Reset") { model.settings.outputDirectory = nil }
                        }
                    }
                }
                .disabled(model.settings.outputMode == .replaceOriginal)
            } header: {
                Text("Output")
            } footer: {
                if model.settings.outputMode == .replaceOriginal {
                    Label("The source archive is moved to the Trash only after the new archive has been verified. Folders are not replaced.",
                          systemImage: "info.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                Picker("When adding a folder", selection: $model.folderAction) {
                    Text("Compress the folder").tag(FolderAction.compress)
                    Text("Optimize the archives inside it").tag(FolderAction.scanArchives)
                }
            } header: {
                Text("Folders")
            } footer: {
                Text(model.folderAction == .compress
                     ? "A folder becomes one 7z named after it, next to the folder or in the output folder. The folder itself is never moved to the Trash."
                     : "Folders are searched recursively for archives; files ending in _optimized.7z are skipped.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Safety") {
                Toggle("Verify result (test + file-by-file CRC comparison)", isOn: .constant(true))
                    .disabled(true)
                Toggle("Keep temporary files (debugging)", isOn: $model.settings.keepTempFiles)
            }

            if updates.isAvailable {
                Section("Updates") {
                    @Bindable var updates = updates
                    Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                    LabeledContent("Squeeze7z \(Self.version)") {
                        Button("Check Now") { updates.checkForUpdates() }
                    }
                }
            }

            Section {
                LabeledContent("All settings") {
                    Button("Reset to Defaults") { model.settings = OptimizerSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: updates.isAvailable ? 540 : 440)
        .animation(.smooth(duration: 0.25), value: model.settings.outputMode)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where optimized archives are written."
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.outputDirectory = url
        }
    }
}

/// Mode, codec parameters and the methods that may be tried.
struct CompressionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Mode", selection: $model.settings.mode) {
                    ForEach(OptimizationMode.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text(modeHint(model.settings.mode))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Parameters") {
                StepperRow(title: "LZMA dictionary",
                           valueText: "\(model.settings.lzmaDictionaryMB) MB",
                           value: $model.settings.lzmaDictionaryMB, range: 16...1536, step: 16)
                StepperRow(title: "PPMd memory",
                           valueText: "\(model.settings.ppmdMemoryMB) MB",
                           value: $model.settings.ppmdMemoryMB, range: 16...2048, step: 16)
                StepperRow(title: "LZMA word size",
                           valueText: "\(model.settings.lzmaWordSize)",
                           value: $model.settings.lzmaWordSize, range: 32...273, step: 1)
                Picker("Sampling level", selection: $model.settings.samplingLevel) {
                    Text("0 (trials on full data)").tag(0)
                    ForEach(1...6, id: \.self) { n in Text("\(n) (sample up to \(n * 5) MB per group)").tag(n) }
                }
                StepperRow(title: "Solid block size",
                           valueText: model.settings.solidBlockSizeMB == 0 ? "Unlimited" : "\(model.settings.solidBlockSizeMB) MB",
                           value: $model.settings.solidBlockSizeMB, range: 0...4096, step: 16)
                StepperRow(title: "Merge groups smaller than",
                           valueText: "\(model.settings.minGroupBytes / 1024) KiB",
                           value: minGroupKiB, range: 0...16384, step: 16)
                Toggle("Hybrid groups (one solid block per file family when smaller)",
                       isOn: $model.settings.hybridGroups)
                Toggle("Keep __MACOSX metadata folders from zip files",
                       isOn: $model.settings.keepMacOSMetadata)
                    .help("Archive Utility expands this folder over the real files of a 7z. Off leaves it out, with the Finder tags and other extended attributes it holds.")
            }

            Section("Method filters") {
                Toggle("Disable PPMd", isOn: $model.settings.disablePPMd)
                Toggle("Disable BZip2", isOn: $model.settings.disableBZip2)
                Toggle("Skip PPMd for large groups", isOn: ppmdLimitEnabled)
                    .disabled(model.settings.disablePPMd)
                if model.settings.noPPMdAboveMB != nil && !model.settings.disablePPMd {
                    StepperRow(title: "No PPMd above",
                               valueText: "\(model.settings.noPPMdAboveMB ?? 256) MB",
                               value: ppmdLimitValue, range: 1...16384, step: 16)
                }
                Toggle("Use ARM64/RISC-V filters for executables",
                       isOn: $model.settings.allowModernFilters)
                    .help("On: smaller archives of arm64 programs, readable by Archive Utility and 7-Zip 23 or later. Off: readable by older 7-Zip and p7zip, at a cost on arm64 executables.")
                Toggle("Compress photos, videos and zips on all cores",
                       isOn: $model.settings.parallelMediaBlocks)
                    .help("Fast and Smart modes: already compressed files go in their own block, split into chunks that every core works on. Several times faster on folders of photos and videos, a few KB larger at most. Off: one stream, as 7-Zip at its maximum preset.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 690)
    }

    private var minGroupKiB: Binding<Int> {
        Binding(get: { model.settings.minGroupBytes / 1024 },
                set: { model.settings.minGroupBytes = $0 * 1024 })
    }

    private var ppmdLimitEnabled: Binding<Bool> {
        Binding(get: { model.settings.noPPMdAboveMB != nil },
                set: { model.settings.noPPMdAboveMB = $0 ? (model.settings.noPPMdAboveMB ?? 256) : nil })
    }

    private var ppmdLimitValue: Binding<Int> {
        Binding(get: { model.settings.noPPMdAboveMB ?? 256 },
                set: { model.settings.noPPMdAboveMB = $0 })
    }

    private func modeHint(_ mode: OptimizationMode) -> String {
        switch mode {
        case .fast: "Whole archive with one LZMA2 pass. No per-group trials."
        case .smart: "About 7-Zip -mx9 speed and size, plus PPMd for the text files when there are enough of them. No trials."
        case .normal: "LZMA2 and PPMd per file group."
        case .good: "Adds LZMA, delta and executable filters, whole-archive baseline."
        case .best: "Adds more PPMd orders, BZip2 and LZMA variants."
        case .ultra: "Adds wider delta, Deflate64 and match-finder variants."
        case .extreme: "Adds LZMA parameter sweeps for binary data."
        case .extreme2: "Exhaustive sweeps. Very slow."
        }
    }
}

/// How much of the machine a run may use.
struct PerformanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                StepperRow(title: "Parallel jobs",
                           valueText: "\(model.settings.parallelJobs)",
                           value: $model.settings.parallelJobs, range: 1...6, step: 1)
                StepperRow(title: "Concurrent trials per archive",
                           valueText: "\(model.settings.lowCPU ? 1 : model.settings.concurrentTrials)",
                           value: $model.settings.concurrentTrials, range: 1...8, step: 1)
                    .disabled(model.settings.lowCPU)
                StepperRow(title: "Threads per trial",
                           valueText: model.settings.lowCPU ? "1" : (model.settings.threadsPerTrial == 0 ? "Automatic" : "\(model.settings.threadsPerTrial)"),
                           value: $model.settings.threadsPerTrial, range: 0...64, step: 1)
                    .disabled(model.settings.lowCPU)
                Toggle("Low CPU usage", isOn: $model.settings.lowCPU)
            } footer: {
                Text(memoryHint(model.settings))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(height: 270)
    }

    private func memoryHint(_ s: OptimizerSettings) -> String {
        let trials = s.lowCPU ? 1 : s.concurrentTrials
        // LZMA with bt4 needs roughly 11.5x the dictionary size per compressor.
        let peakMB = Double(s.lzmaDictionaryMB) * 11.5 * Double(trials) * Double(s.parallelJobs)
        let peak = Int64(peakMB * 1_048_576)
        let installed = Int64(ProcessInfo.processInfo.physicalMemory)
        let text = "Worst-case LZMA memory: about \(Fmt.bytes(peak)) (dictionary × concurrent trials × parallel jobs). This Mac has \(Fmt.bytes(installed))."
        return peak > installed / 2 ? text + " Consider lowering the dictionary or parallelism." : text
    }
}

private struct StepperRow: View {
    let title: String
    let valueText: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
                Stepper(title, value: $value, in: range, step: step).labelsHidden()
            }
        }
    }
}
