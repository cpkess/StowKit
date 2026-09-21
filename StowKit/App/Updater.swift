import Foundation
import Observation
import Sparkle

/// Sparkle, fed by the appcast attached to the latest GitHub release. Only signed builds carry a
/// feed and key (Config/StowKitCloud-Info.plist), so an ad-hoc contributor build never tries to
/// replace itself with an official one.
@MainActor @Observable final class Updater {
    static var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
            && NSClassFromString("XCTestCase") == nil
    }
    private(set) var canCheck = false
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = Self.isConfigured ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }
    var isAvailable: Bool { controller != nil }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }
}
