import Cocoa
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?
    private var profileEditorWindow: NSWindow?
    private var transcriptionsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    // Services
    private var audioRecorder: AudioRecorder!
    private var whisperService: WhisperService!
    private var pasteService: PasteService!
    private var hotkeyManager: HotkeyManager!
    private var screenBorderOverlay: ScreenBorderOverlay!
    private var volumeAttenuator: VolumeAttenuator!
    private var updateManager: UpdateManager!
    private var transcriptionQueue: TranscriptionQueue!

    // State
    @Published var isRecording = false
    var isTranscribing = false  // Not @Published - menu bar doesn't need to observe this
    @Published var activeProfile: Profile?
    @Published var selectedLanguage: String = "en"

    private var transcriptionStore = TranscriptionStore.shared

    private var profileManager = ProfileManager.shared
    private var settingsManager = SettingsManager.shared
    private var settingsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize services
        audioRecorder = AudioRecorder()
        whisperService = WhisperService()
        pasteService = PasteService()
        hotkeyManager = HotkeyManager()
        screenBorderOverlay = ScreenBorderOverlay()
        volumeAttenuator = VolumeAttenuator()
        updateManager = UpdateManager()
        transcriptionQueue = TranscriptionQueue(pasteService: pasteService)

        // Set up transcription queue callbacks
        transcriptionQueue.onTranscriptionComplete = { [weak self] transcription in
            guard let self = self else { return }

            print("[SayStuff] Transcription: \(transcription)")

            self.transcriptionStore.add(transcription)

            if self.settingsManager.settings.playSounds {
                DispatchQueue.global(qos: .utility).async {
                    NSSound(named: "Glass")?.play()
                }
            }

            self.isTranscribing = false
            self.updateMenuBarIcon()
        }

        transcriptionQueue.onTranscriptionFailed = { [weak self] error in
            guard let self = self else { return }

            print("[SayStuff] Transcription failed: \(error)")
            self.isTranscribing = false
            self.updateMenuBarIcon()
        }

        // Set up menu bar
        setupMenuBar()

        // Register hotkey
        setupHotkey()

        // Re-register hotkey when settings change
        settingsCancellable = settingsManager.$settings
            .dropFirst() // Skip initial value
            .sink { [weak self] _ in
                self?.setupHotkey()
            }

        // Load active profile (restore saved selection or use first)
        if let savedId = UserDefaults.standard.string(forKey: "activeProfileId"),
           let savedUUID = UUID(uuidString: savedId),
           let savedProfile = profileManager.profiles.first(where: { $0.id == savedUUID }) {
            activeProfile = savedProfile
        } else {
            activeProfile = profileManager.profiles.first
        }

        // Load saved language
        if let savedLang = UserDefaults.standard.string(forKey: "selectedLanguage") {
            selectedLanguage = savedLang
        }

        showOnboardingIfNeeded()

        print("[SayStuff] Ready! Hold ⌥⌘V to record")
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Create a red waveform on a black squircle background
            let iconSize = NSSize(width: 22, height: 22)
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

            if let waveformImage = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SayStuff")?
                .withSymbolConfiguration(symbolConfig) {

                // First, create a red-tinted waveform
                let waveformSize = waveformImage.size
                let tintedWaveform = NSImage(size: waveformSize, flipped: false) { rect in
                    waveformImage.draw(in: rect)
                    NSColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1.0).setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }

                // Then compose it onto the black squircle
                let finalImage = NSImage(size: iconSize, flipped: false) { rect in
                    // Draw black squircle background
                    let squirclePath = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                    NSColor.black.setFill()
                    squirclePath.fill()

                    // Draw the red waveform centered
                    let waveformRect = NSRect(
                        x: (rect.width - waveformSize.width) / 2,
                        y: (rect.height - waveformSize.height) / 2,
                        width: waveformSize.width,
                        height: waveformSize.height
                    )
                    tintedWaveform.draw(in: waveformRect)

                    return true
                }
                finalImage.isTemplate = false
                button.image = finalImage
            }
        }

        // Create popover for menu
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 380)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                appDelegate: self,
                profileManager: profileManager
            )
        )

        // Use menu instead of popover action for proper click-outside behavior
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                closePopover()
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                startEventMonitor()
            }
        }
    }

    private func startEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func setupHotkey() {
        let settings = settingsManager.settings
        print("[SayStuff] Registering hotkey: \(settings.hotkeyModifiers) + keyCode:\(settings.hotkeyKeyCode) mode:\(settings.hotkeyMode)")

        hotkeyManager.register(
            modifiers: settings.hotkeyModifiers,
            keyCode: settings.hotkeyKeyCode,
            mode: settings.hotkeyMode,
            timeout: settings.toggleTimeout,
            onDown: { [weak self] in
                DispatchQueue.main.async {
                    self?.startRecording()
                }
            },
            onUp: { [weak self] in
                DispatchQueue.main.async {
                    self?.stopRecordingAndTranscribe()
                }
            }
        )
    }

    func startRecording() {
        guard !isRecording else { return }

        print("[SayStuff] Starting recording...")

        isRecording = true
        updateMenuBarIcon()

        // Show red screen border
        screenBorderOverlay.show()

        // Play start sound
        if settingsManager.settings.playSounds {
            NSSound(named: "Funk")?.play()
        }

        // Attenuate system audio
        if settingsManager.settings.attenuateAudio {
            volumeAttenuator.attenuate(to: settingsManager.settings.attenuationLevel)
        }

        do {
            try audioRecorder.startRecording()

            print("[SayStuff] Recording started")
        } catch {
            print("[SayStuff] Failed to start recording: \(error)")
            isRecording = false
            updateMenuBarIcon()
        }
    }

    func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        print("[SayStuff] Stopping recording...")

        isRecording = false
        isTranscribing = true
        updateMenuBarIcon()

        // Hide red screen border
        screenBorderOverlay.hide()

        // Restore system audio
        volumeAttenuator.restore()

        guard let audioURL = audioRecorder.stopRecording() else {
            print("[SayStuff] No audio captured")
            isTranscribing = false
            updateMenuBarIcon()
            return
        }

        print("[SayStuff] Audio saved, transcribing...")

        // Create the transcription task
        let task = Task<String, Error> {
            let profile = activeProfile ?? Profile.defaultEnglish
            return try await whisperService.transcribe(
                audioURL: audioURL,
                profile: profile,
                settings: settingsManager.settings
            )
        }

        // Enqueue transcription - queue handles paste and callbacks
        transcriptionQueue.enqueue(task: task)
    }

    private func updateMenuBarIcon() {
        // Keep icon static - don't change based on state
        // The red waveform is set once in setupMenuBar()
    }

    func selectProfile(_ profile: Profile) {
        activeProfile = profile
        UserDefaults.standard.set(profile.id.uuidString, forKey: "activeProfileId")

        // Sync language selector to profile's language
        selectedLanguage = profile.language
        UserDefaults.standard.set(profile.language, forKey: "selectedLanguage")
    }

    func selectLanguage(_ language: String) {
        selectedLanguage = language
        UserDefaults.standard.set(language, forKey: "selectedLanguage")

        // Update the active profile's language and save to disk
        if let currentProfile = activeProfile,
           let index = profileManager.profiles.firstIndex(where: { $0.id == currentProfile.id }) {
            profileManager.profiles[index].language = language
            profileManager.save()
            activeProfile = profileManager.profiles[index]
        }
    }

    func openTranscriptions() {
        popover.performClose(nil)

        let view = TranscriptionsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Recent Transcriptions"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        transcriptionsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        popover.performClose(nil)

        let settingsView = SettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SayStuff Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboardingIfNeeded() {
        guard !settingsManager.settings.hasCompletedOnboarding else { return }
        guard onboardingWindow == nil else { return }

        let view = OnboardingView(onComplete: { [weak self] in
            guard let self = self else { return }
            self.settingsManager.settings.hasCompletedOnboarding = true
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to SayStuff"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        onboardingWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openProfileEditor() {
        popover.performClose(nil)

        let editorView = ProfileEditorView(profileManager: profileManager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Profiles"
        window.contentView = NSHostingView(rootView: editorView)
        window.center()
        window.isReleasedWhenClosed = false
        profileEditorWindow = window

        profileEditorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkForUpdates() {
        updateManager.checkForUpdates()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
