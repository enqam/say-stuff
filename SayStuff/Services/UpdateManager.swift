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
        // Only start the updater when user explicitly requests
        if !updaterController.updater.sessionInProgress {
            updaterController.updater.checkForUpdates()
        }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}
