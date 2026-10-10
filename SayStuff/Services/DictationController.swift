import AppKit
import Combine
import AVFoundation
import Carbon.HIToolbox

/// Owns the record → transcribe → paste loop and everything the user sees/hears while it runs.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case processing
    }

    @Published private(set) var phase: Phase = .idle
    /// Set when the dictation shortcut couldn't be registered (usually taken by another app).
    @Published private(set) var hotkeyError: String?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    private let settingsManager = SettingsManager.shared
    private var settings: AppSettings { settingsManager.settings }

    private let recorder = AudioRecorder()
    private let hud = RecordingHUD()
    private let border = ScreenBorderOverlay()
    private let attenuator = VolumeAttenuator()
    private let hotkeys = HotkeyManager()
    private let pasteService = PasteService()
    private let whisper = WhisperService()
    private let sounds = SoundPlayer()

    private var pendingJobs = 0
    private var pasteChain: Task<Void, Never>?
    private var autoStopTimer: Timer?
    private var hotkeysSuspended = false
    private var cancellables = Set<AnyCancellable>()

    /// Recordings shorter than this (after silence trimming) are accidental taps.
    private let minimumDuration: TimeInterval = 0.3

    private init() {
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.push(level: level) }
        }
        hotkeys.onEvent = { [weak self] id, isPress in
            self?.handleHotkey(id, isPress: isPress)
        }
    }

    func start() {
        settingsManager.$settings
            .map(\.hotkey)
            .removeDuplicates()
            .sink { [weak self] combo in self?.registerDictationHotkey(combo) }
            .store(in: &cancellables)
    }

    func shutdown() {
        recorder.cancel()
        attenuator.restoreImmediately()
    }

    /// Lets the shortcut recorder capture the current combo without triggering dictation.
    func setHotkeysSuspended(_ suspended: Bool) {
        hotkeysSuspended = suspended
    }

    // MARK: - Hotkeys

    private func registerDictationHotkey(_ combo: KeyCombo) {
        let ok = hotkeys.register(.dictation, keyCode: combo.keyCode, modifiers: combo.carbonModifiers)
        hotkeyError = ok ? nil : "\(combo.displayString) is already used by another app. Pick a different shortcut."
    }

    private func handleHotkey(_ id: HotkeyManager.ID, isPress: Bool) {
        guard !hotkeysSuspended else { return }
        switch (id, isPress) {
        case (.cancel, true):
            cancel()
        case (.dictation, true):
            if settings.hotkeyMode == .toggle, isRecording {
                finish()
            } else {
                begin()
            }
        case (.dictation, false):
            if settings.hotkeyMode == .hold { finish() }
        default:
            break
        }
    }

    // MARK: - Recording

    func begin() {
        guard !isRecording else { return }
        phase = .recording(since: Date())

        hud.showRecording()
        if settings.showScreenBorder { border.show() }
        let soundLength = sounds.play(settings.feedbackSound)
        if settings.attenuateAudio {
            attenuator.attenuate(to: settings.attenuationLevel, after: soundLength)
        }
        hotkeys.register(.cancel, keyCode: UInt16(kVK_Escape), modifiers: 0)

        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: settings.toggleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }

        recorder.start(deviceUID: settings.selectedAudioDeviceUID) { [weak self] error in
            guard let self, let error else { return }
            print("[Dictation] Failed to start recording: \(error)")
            self.endRecordingUI(playSound: false)
            self.settle()
            self.hud.flash(error.localizedDescription, symbol: "mic.slash")
        }
    }

    func finish() {
        guard isRecording else { return }
        endRecordingUI(playSound: true)
        pendingJobs += 1
        phase = .processing
        hud.showProcessing()

        recorder.stop { [weak self] recording in
            guard let self else { return }
            guard let recording, recording.containsSpeech, recording.duration >= self.minimumDuration else {
                if let recording { try? FileManager.default.removeItem(at: recording.url) }
                self.pendingJobs -= 1
                self.settle()
                self.notify("No speech detected", symbol: "waveform.slash", duration: 1.4)
                return
            }
            self.transcribeAndPaste(recording)
        }
    }

    func cancel() {
        guard isRecording else { return }
        recorder.cancel()
        endRecordingUI(playSound: false)
        settle()
        hud.flash("Cancelled", symbol: "xmark", duration: 1)
    }

    private func endRecordingUI(playSound: Bool) {
        phase = .idle
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        hotkeys.unregister(.cancel)
        border.hide()
        let sound = playSound ? settings.feedbackSound : ""
        // Play the stop sound once volume is back up so it sounds the same as the start sound.
        attenuator.restore { [weak self] in self?.sounds.play(sound) }
    }

    // MARK: - Pipeline

    private func transcribeAndPaste(_ recording: Recording) {
        let request = WhisperService.Request(
            audioURL: recording.url,
            whisperPath: settingsManager.whisperBinaryPath,
            modelPath: settingsManager.modelPath,
            language: settings.language,
            vocabulary: DictionaryStore.shared.vocabularyPrompt
        )
        let whisper = self.whisper
        // Transcriptions run concurrently, but results are pasted in the order they were spoken.
        let transcription = Task.detached(priority: .userInitiated) { try await whisper.transcribe(request) }
        let previous = pasteChain

        pasteChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.pendingJobs -= 1
                self.settle()
            }
            do {
                let text = self.finalize(try await transcription.value)
                guard !text.isEmpty else {
                    self.notify("No speech detected", symbol: "waveform.slash", duration: 1.4)
                    return
                }
                TranscriptionStore.shared.add(text.trimmingCharacters(in: .whitespaces))
                if self.pasteService.paste(text) == .copiedOnly {
                    self.notify("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: 2.4)
                } else if self.pendingJobs <= 1, !self.isRecording {
                    self.hud.hide()
                }
            } catch {
                print("[Dictation] Transcription failed: \(error)")
                self.notify(error.localizedDescription, symbol: "exclamationmark.triangle", duration: 2.6)
            }
        }
    }

    private func finalize(_ transcript: String) -> String {
        var text = DictionaryStore.shared.apply(to: transcript)
        // Output profiles (LLM formatting) plug in here.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.addTrailingSpace, !text.isEmpty { text += " " }
        return text
    }

    /// Status messages never cover the live waveform of a newer recording.
    private func notify(_ text: String, symbol: String, duration: TimeInterval) {
        guard !isRecording else { return }
        hud.flash(text, symbol: symbol, duration: duration)
    }

    /// Recomputes the phase after a recording or job ends.
    private func settle() {
        guard !isRecording else { return }
        phase = pendingJobs > 0 ? .processing : .idle
    }
}

/// Plays the start/stop sound. Sounds are cached so playback starts instantly.
final class SoundPlayer {
    static let choices = ["Funk", "Pop", "Tink", "Purr", "Bottle", "Morse", "Glass", "Hero"]

    private var cache: [String: NSSound] = [:]

    /// Plays `name` (empty = silent) and returns how long it lasts.
    @discardableResult
    func play(_ name: String) -> TimeInterval {
        guard !name.isEmpty else { return 0 }
        let sound: NSSound?
        if let cached = cache[name] {
            sound = cached
        } else {
            sound = NSSound(named: NSSound.Name(name))
            cache[name] = sound
        }
        guard let sound else { return 0 }
        sound.stop()
        sound.play()
        return min(sound.duration, 0.5)
    }
}
