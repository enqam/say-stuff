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

    // Services
    private var audioRecorder: AudioRecorder!
    private var whisperService: WhisperService!
    private var pasteService: PasteService!
    private var hotkeyManager: HotkeyManager!
    private var recordingOverlay: RecordingOverlay!
    private var updateManager: UpdateManager!

    // State
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var activeProfile: Profile?
    @Published var selectedLanguage: String = "en"

    private var transcriptionStore = TranscriptionStore.shared

    // Available languages for quick-switch
    let availableLanguages = [
        ("en", "EN", "English"),
        ("ru", "RU", "Русский"),
        ("auto", "AUTO", "Auto-detect")
    ]

    private var profileManager = ProfileManager.shared
    private var settingsManager = SettingsManager.shared
    private var recordingStartTime: Date?
    private var audioLevelCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var transcriptionTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize services
        audioRecorder = AudioRecorder()
        whisperService = WhisperService()
        pasteService = PasteService()
        hotkeyManager = HotkeyManager()
        recordingOverlay = RecordingOverlay()
        updateManager = UpdateManager()

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
        print("[SayStuff] Registering hotkey: \(settings.hotkeyModifiers) + \(settings.hotkeyKey)")

        hotkeyManager.register(
            modifiers: settings.hotkeyModifiers,
            key: settings.hotkeyKey,
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
        // Cancel any pending transcription from a previous quick release
        transcriptionTask?.cancel()
        transcriptionTask = nil

        guard !isRecording else { return }

        print("[SayStuff] Starting recording...")

        isRecording = true
        recordingStartTime = Date()
        updateMenuBarIcon()

        // Show waveform overlay
        recordingOverlay.show(state: .recording)

        // Play start sound
        if settingsManager.settings.playSounds {
            NSSound(named: "Funk")?.play()
        }

        do {
            try audioRecorder.startRecording()

            // Subscribe to audio level for reactive waveform
            audioLevelCancellable = audioRecorder.$audioLevel
                .sink { [weak self] level in
                    self?.recordingOverlay.updateAudioLevel(level)
                }

            print("[SayStuff] Recording started")
        } catch {
            print("[SayStuff] Failed to start recording: \(error)")
            recordingOverlay.showError("Mic error")
            recordingOverlay.hide()
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

        // Stop listening to audio levels
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        // Show loading overlay
        recordingOverlay.update(state: .transcribing)

        guard let audioURL = audioRecorder.stopRecording() else {
            print("[SayStuff] No audio captured")
            recordingOverlay.showError("No audio")
            recordingOverlay.hide()
            isTranscribing = false
            updateMenuBarIcon()
            return
        }

        print("[SayStuff] Audio saved, transcribing...")

        transcriptionTask = Task {
            do {
                let profile = activeProfile ?? Profile.defaultEnglish
                let transcription = try await whisperService.transcribe(
                    audioURL: audioURL,
                    profile: profile,
                    settings: settingsManager.settings
                )

                // Check if cancelled before updating UI
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    print("[SayStuff] Transcription: \(transcription)")

                    // Calculate stats
                    let wordCount = transcription.split(separator: " ").count
                    let duration = Date().timeIntervalSince(recordingStartTime ?? Date())

                    // Show success FIRST (so animation doesn't freeze)
                    recordingOverlay.showSuccess(wordCount: wordCount, duration: duration)
                    recordingOverlay.hide()

                    // Paste AFTER UI update
                    pasteService.pasteText(transcription)

                    // Save to disk
                    self.transcriptionStore.add(transcription)

                    // Play completion sound (off main thread)
                    if settingsManager.settings.playSounds {
                        DispatchQueue.global(qos: .utility).async {
                            NSSound(named: "Glass")?.play()
                        }
                    }

                    isTranscribing = false
                    updateMenuBarIcon()
                }
            } catch {
                print("[SayStuff] Transcription failed: \(error)")
                await MainActor.run {
                    recordingOverlay.showError("Transcription failed")
                    recordingOverlay.hide()
                    isTranscribing = false
                    updateMenuBarIcon()
                }
            }
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
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
