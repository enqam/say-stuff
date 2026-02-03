import AppKit
import Foundation
import Sparkle

class UpdateManager: NSObject, ObservableObject {
    private var updaterController: SPUStandardUpdaterController!

    override init() {
        super.init()
        // Initialize Sparkle updater - don't start automatically
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard let feedURL = updaterController.updater.feedURL, !feedURL.absoluteString.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't configured"
            alert.informativeText = "Check the GitHub Releases page for new versions."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Only start the updater when user explicitly requests
        if !updaterController.updater.sessionInProgress {
            updaterController.updater.checkForUpdates()
        }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}
