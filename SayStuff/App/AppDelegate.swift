import Cocoa
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?
    private var profileEditorWindow: NSWindow?

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

    private var profileManager = ProfileManager.shared
    private var settingsManager = SettingsManager.shared
    private var recordingStartTime: Date?
    private var audioLevelCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?

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

        // Load active profile
        activeProfile = profileManager.profiles.first

        print("[SayStuff] Ready! Hold ⌥⌘V to record")
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "SayStuff")
        }

        // Create popover for menu
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 300)
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

        Task {
            do {
                let profile = activeProfile ?? Profile.defaultEnglish
                let transcription = try await whisperService.transcribe(
                    audioURL: audioURL,
                    profile: profile,
                    settings: settingsManager.settings
                )

                await MainActor.run {
                    print("[SayStuff] Transcription: \(transcription)")

                    pasteService.pasteText(transcription)

                    // Calculate stats
                    let wordCount = transcription.split(separator: " ").count
                    let duration = Date().timeIntervalSince(recordingStartTime ?? Date())

                    // Show success
                    recordingOverlay.showSuccess(wordCount: wordCount, duration: duration)
                    recordingOverlay.hide()

                    // Play completion sound
                    if settingsManager.settings.playSounds {
                        NSSound(named: "Glass")?.play()
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
        guard let button = statusItem.button else { return }

        if isRecording {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
        } else if isTranscribing {
            button.image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "Transcribing")
            button.contentTintColor = .systemOrange
        } else {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "SayStuff")
            button.contentTintColor = nil
        }
    }

    func selectProfile(_ profile: Profile) {
        activeProfile = profile
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
