import Foundation
import Observation
import Sparkle

/// Software updates through Sparkle: the appcast named by `SUFeedURL` in Info.plist, archives verified with the
/// EdDSA key `SUPublicEDKey`. Off when the app does not run from a bundle that names a feed (`swift run`, tests).
@MainActor @Observable
final class Updates {
    static let shared = Updates()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    /// Whether this copy of the app can update itself.
    var isAvailable: Bool { controller != nil }

    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`, so SwiftUI sees changes.
    var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private init() {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "SUFeedURL") is String,
              bundle.object(forInfoDictionaryKey: "SUPublicEDKey") is String else {
            controller = nil
            automaticallyChecks = false
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
