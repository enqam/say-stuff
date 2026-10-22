import Cocoa
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var menuPanel: MenuPanel!
    private let banner = StatusBanner()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let dictation = DictationController.shared
    private var cancellables = Set<AnyCancellable>()
    private var statusIconShowsRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        #if DEBUG
        if let directory = UISnapshots.outputDirectory {
            UISnapshots.run(to: directory)
            return
        }
        #endif
        setupStatusItem()
        dictation.start()

        dictation.$phase
            .sink { [weak self] phase in self?.updateStatusIcon(for: phase) }
            .store(in: &cancellables)

        if !SettingsManager.shared.settings.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard statusItem != nil else { return }
        dictation.shutdown()
    }

    // Launching the app again (Finder, Raycast) while it's running opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = idleIcon
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menuPanel = MenuPanel { resize, maximumHeight in
            MenuBarView(onHeightChange: resize, maximumHeight: maximumHeight)
        }
    }

    private let idleIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SayStuff")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = true
        return image
    }()

    /// Drawn red rather than tinted: the menu bar can render a tinted template image monochrome.
    private let activeIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SayStuff, dictating")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed])))
        image?.isTemplate = false
        return image
    }()

    private func updateStatusIcon(for phase: DictationController.Phase) {
        guard let button = statusItem.button else { return }
        switch phase {
        case .idle:
            guard statusIconShowsRecording else { return }
            statusIconShowsRecording = false
            button.image = idleIcon
        case .recording:
            guard !statusIconShowsRecording else { return }
            statusIconShowsRecording = true
            button.image = activeIcon
        case .processing:
            // Updating the status-item scene can synchronously wait on the graphics
            // server. Stay red from recording until the result has been pasted;
            // the HUD shows processing without delaying the main-thread handoffs.
            break
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        menuPanel.toggle(from: button)
    }

    // MARK: - Windows

    func openSettings(_ pane: SettingsPane? = nil) {
        menuPanel.close()
        if let pane { SettingsRouter.shared.pane = pane }

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "SayStuff"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentViewController = NSHostingController(rootView: SettingsView())
            window.setContentSize(NSSize(width: 640, height: 640))
            window.minSize = NSSize(width: 620, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("SettingsWindow")
            settingsWindow = window
        }
        present(settingsWindow)
    }

    func showOnboarding() {
        menuPanel.close()
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in
                SettingsManager.shared.settings.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
            })
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    /// Menu bar apps stay out of the Dock, except while one of their windows is open
    /// so it can be found with ⌘-Tab.
    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing == onboardingWindow { onboardingWindow = nil }
        let othersOpen = [settingsWindow, onboardingWindow].contains { window in
            guard let window, window != closing else { return false }
            return window.isVisible
        }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }

    /// Keep correction feedback beside the edited text without taking keyboard focus.
    func showDictionaryNotice(term: String, heardAs heard: String, near anchor: NSRect?,
                              highlight: NSRect?, field: NSRect?, undo: @escaping () -> Void) {
        banner.show(term: term, heardAs: heard, near: anchor, highlight: highlight, field: field, undo: undo)
    }

    func hideDictionaryNotice() { banner.hide() }
}
