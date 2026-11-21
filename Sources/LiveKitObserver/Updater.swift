import ObserverCore
import Sparkle
import SwiftUI

/// Checks the GitHub Releases appcast for new versions and installs them. Settings come from Config/Info.plist:
/// it checks daily and installs updates in the background when the app quits.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    private init() {
        guard NSClassFromString("XCTestCase") == nil else { controller = nil; return }
        // Builds without a Sparkle key (local ./build.sh before setup) would fail every check, so they skip it.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if let key, !key.isEmpty, key != "SPARKLE_PUBLIC_KEY_NOT_SET" {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

/// The "Check for Updates…" item in the app menu.
struct CheckForUpdatesCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.isAvailable)
        }
    }
}
