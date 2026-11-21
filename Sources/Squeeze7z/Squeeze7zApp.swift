import SwiftUI
import AppKit

@main
struct Squeeze7zApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Squeeze7z", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1120, height: 600)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Squeeze7z") { AboutPanel.show(engine: model.engine) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Archives or Folders…") { model.showImporter = true }
                .keyboardShortcut("o")
                .disabled(model.engine == nil)
        }
        CommandMenu("Queue") {
            Button("Start") { model.start() }
                .keyboardShortcut("r")
                .disabled(!model.canStart)
            Button("Stop") { model.stop() }
                .keyboardShortcut(".")
                .disabled(!model.canStop)
            Divider()
            Button("Show Report") { model.showReport(ids: model.selection) }
                .keyboardShortcut("i")
                .disabled(model.selection.isEmpty)
            Button("Reveal in Finder") { model.reveal(ids: model.selection) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
            Button("Retry Selected") { model.retry(ids: model.selection) }
                .disabled(!model.canRetry(ids: model.selection))
            Divider()
            Button("Remove Selected") { model.remove(ids: model.selection) }
                .disabled(model.selection.isEmpty || model.reportJob != nil
                          || model.jobs(for: model.selection).allSatisfy { $0.status == .running })
            Button("Clear Finished") { model.clearFinished() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(!model.hasFinished)
        }
        CommandGroup(replacing: .help) {
            Button("7-Zip License") { AboutPanel.openLicense() }
                .disabled(AboutPanel.licenseURL() == nil)
            Button("About Squeeze7z") { AboutPanel.show(engine: model.engine) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The window of the `Window(id: "main")` scene (the Settings window can become main too).
    private var mainWindow: NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })
            ?? NSApp.windows.first(where: { $0.canBecomeMain })
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Needed when launched from `swift run`, where the process starts as a background tool.
        NSApp.setActivationPolicy(.regular)
        // See `handleOpenDocuments`. Installed here so that it is in place for the launch event too.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        DispatchQueue.main.async {
            self.mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    /// Archives or folders dropped on the Dock icon or opened with "Open With".
    ///
    /// This replaces AppKit's handler for the open-documents event. On the standard path SwiftUI
    /// answers the event by closing the main window to present its scene again, the window does not
    /// come back, and closing the last window quits the app: opening a file in the running app
    /// made it quit. With the main window in place the files go straight to the queue. Without
    /// one (the app is being launched to open them) the standard path runs: it creates the window
    /// and then calls `application(_:open:)`.
    @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        var urls: [URL] = []
        if let list = event.paramDescriptor(forKeyword: keyDirectObject) {
            if list.numberOfItems > 0 {
                for index in 1...list.numberOfItems {
                    if let url = list.atIndex(index)?.fileURLValue { urls.append(url) }
                }
            } else if let url = list.fileURLValue {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        if NSApp.windows.contains(where: { $0.identifier?.rawValue == "main" }) {
            application(NSApp, open: urls)
            NSApp.activate()
        } else {
            // NSApp.delegate is SwiftUI's delegate, which forwards to this one.
            NSApp.delegate?.application?(NSApp, open: urls)
        }
    }

    /// Adds the opened archives or folders to the queue.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.addItems(urls)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.hasRunningJobs else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while archives are being optimized?"
        alert.informativeText = "Closing the window quits Squeeze7z. Running jobs will be cancelled and their temporary files removed. Source archives are not touched."
        alert.addButton(withTitle: "Cancel Jobs and Quit")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.stop()
        Task { @MainActor in
            await model.waitUntilIdle()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Stands in for the main window's delegate so that closing the window while jobs run asks first, and
/// leaves the window where it is when the user chooses to keep running. Everything else goes to the
/// delegate that SwiftUI installed.
@MainActor
final class MainWindowGuard: NSObject, NSWindowDelegate {
    static let shared = MainWindowGuard()
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?

    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
           original.windowShouldClose?(sender) == false { return false }
        guard AppModel.shared.mayCloseMainWindow else {
            // The window stays open; the quit confirmation decides whether the app (and the window) goes.
            // Scheduled on the run loop, not the main dispatch queue: the terminate reply (.terminateLater) spins
            // a nested loop, and a main-queue block that runs it would starve every @MainActor task, the jobs'
            // completions included, so the app would never quit.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            return false
        }
        return true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }
}

/// Hands the hosting NSWindow of a SwiftUI view to `MainWindowGuard`.
struct WindowCloseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { MainWindowGuard.shared.install(on: window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { MainWindowGuard.shared.install(on: window) } }
    }
}
