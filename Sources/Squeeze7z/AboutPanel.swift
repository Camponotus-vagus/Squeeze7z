import AppKit
import Foundation
import Squeeze7zCore

@MainActor
enum AboutPanel {
    static func show(engine: SevenZipTool?) {
        Task { @MainActor in
            let version = engine == nil ? nil : try? await engine?.version
            NSApplication.shared.orderFrontStandardAboutPanel(options: [
                .applicationName: "Squeeze7z",
                .applicationVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
                .version: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev",
                .credits: credits(sevenZipVersion: version ?? nil),
            ])
            NSApplication.shared.activate()
        }
    }

    private static func credits(sevenZipVersion: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let engineLine = sevenZipVersion.map { "Engine: \($0)\n" } ?? ""
        let text = """
        Repacks archives into standard 7z, choosing the best compression method for each file type, and keeps the result only if it is smaller.
        The idea is inspired by Ultra7z Archive Optimizer. Squeeze7z is an independent implementation and shares no code or branding with it.
        \(engineLine)7-Zip Copyright (C) 1999-2026 Igor Pavlov. 7-Zip is distributed under the GNU LGPL, with the unRAR restriction: the unRAR code may not be used to re-create the RAR compression algorithm.
        """
        let result = NSMutableAttributedString(string: text, attributes: base)
        let range = (text as NSString).range(of: "7-Zip Copyright (C) 1999-2026 Igor Pavlov")
        if range.location != NSNotFound {
            result.addAttribute(.link, value: URL(string: "https://www.7-zip.org")!, range: range)
        }
        return result
    }

    /// Opens the bundled 7-Zip license text (or the vendored copy when running from a checkout).
    static func openLicense() {
        if let url = licenseURL() { NSWorkspace.shared.open(url) }
    }

    static func licenseURL() -> URL? {
        let fm = FileManager.default
        for name in ["License", "7-Zip License", "7zip-License"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "txt") { return url }
        }
        // Running from the SwiftPM checkout: Sources/Squeeze7z/AboutPanel.swift -> repo root.
        #if SQUEEZE7Z_APP_BUNDLE
        return nil
        #else
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendored = root.appendingPathComponent("Vendor/7zip/License.txt")
        return fm.fileExists(atPath: vendored.path) ? vendored : nil
        #endif
    }
}
