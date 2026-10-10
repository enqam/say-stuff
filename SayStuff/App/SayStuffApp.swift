import SwiftUI

@main
struct SayStuffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Windows are managed by AppDelegate; a menu bar app still needs one scene.
        Settings {
            EmptyView()
        }
    }
}
