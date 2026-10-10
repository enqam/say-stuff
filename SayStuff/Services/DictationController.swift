import AppKit
import Combine
import AVFoundation
import Carbon.HIToolbox

/// Owns the record → transcribe → format → paste loop and everything the user sees/hears while it runs.
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
    private let sounds = SoundPlayer()

    private var pendingJobs = 0
    private var pasteChain: Task<Void, Never>?
    private var autoStopTimer: Timer?
    private var hotkeysSuspended = false
    private var volumeRestoreStarted: Date?
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

        // Keep the local model loaded while the local engine is selected.
        settingsManager.$settings
            .map { [$0.engine.rawValue, $0.modelSize.rawValue, $0.whisperPath, $0.modelDirectory] }
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLocalServer() }
            .store(in: &cancellables)
    }

    private func updateLocalServer() {
        let cli = settingsManager.whisperBinaryPath
        let model = settingsManager.modelPath
        if settings.engine == .local {
            Task { await WhisperServer.shared.prewarm(cliPath: cli, model: model) }
        } else {
            Task { await WhisperServer.shared.stop() }  // started again on demand if the cloud falls back
        }
    }

    func shutdown() {
        recorder.cancel()
        attenuator.restoreImmediately()
        WhisperServer.terminateNow()
    }

    /// Lets the shortcut recorder capture the current combo without triggering dictation.
    func setHotkeysSuspended(_ suspended: Bool) {
        hotkeysSuspended = suspended
    }

    // MARK: - Hotkeys

    private func registerDictationHotkey(_ combo: KeyCombo) {
        let ok = hotkeys.register(.dictation, keyCode: combo.keyCode, modifiers: combo.carbonModifiers)
        hotkeyError = ok ? nil : "\(combo.displayString) is taken by another app. Pick a different shortcut."
    }

    private func handleHotkey(_ id: HotkeyManager.ID, isPress: Bool) {
        guard !hotkeysSuspended else { return }
        switch (id, isPress) {
        case (.dictation, true):
            if settings.hotkeyMode == .toggle, isRecording {
                finish()
            } else {
                begin()
            }
        case (.dictation, false):
            if settings.hotkeyMode == .hold { finish() }
        }
    }

    // MARK: - Recording

    func begin() {
        guard !isRecording else { return }
        phase = .recording(since: Date())

        hud.showRecording()
        if settings.showScreenBorder { border.show() }
        let soundLength = settings.playSounds ? sounds.play(SoundPlayer.start) : 0
        if settings.attenuateAudio {
            // Duck after the start sound so it plays at full volume.
            attenuator.attenuate(to: settings.attenuationLevel, after: soundLength)
        }
        warmUpConnections()

        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: settings.toggleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }

        recorder.start(deviceUID: settings.selectedAudioDeviceUID) { [weak self] error in
            guard let self, let error else { return }
            print("[Dictation] Failed to start recording: \(error)")
            self.endRecordingUI()
            self.settle()
            self.hud.flash(error.localizedDescription, symbol: "mic.slash")
        }
    }

    func finish() {
        guard isRecording else { return }
        endRecordingUI()
        let stoppedAt = Date()
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
            self.transcribeAndPaste(recording, stoppedAt: stoppedAt)
        }
    }

    private func endRecordingUI() {
        phase = .idle
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        border.hide()
        volumeRestoreStarted = Date()
        attenuator.restore()
    }

    /// Opens TLS connections while the user is still talking, so the requests start hot.
    private func warmUpConnections() {
        let keys = APIKeys.shared
        if settings.engine == .cloud, settings.cloudProvider == .fal, keys.hasKey(.fal) {
            CloudSession.preconnect(URL(string: "https://rest.fal.ai/")!)
            CloudSession.preconnect(URL(string: "https://fal.run/")!)
        }
        let usesGroq = settings.engine == .cloud && settings.cloudProvider == .groq
        if usesGroq || settings.activeProfileID != nil, keys.hasKey(.groq) {
            CloudSession.preconnect(URL(string: "https://api.groq.com/")!)
        }
    }

    // MARK: - Pipeline

    private struct Job {
        let recording: Recording
        let engine: TranscriptionEngine
        let cloudProvider: CloudProvider
        let stoppedAt: Date
        let language: String
        let candidates: [String]
        let falKey: String?
        let groqKey: String?
        let profile: Profile?
        let vocabulary: String?
        let fixWords: (String) -> String
        let local: WhisperService.Request
        let localAvailable: Bool
    }

    private struct Outcome {
        let text: String
        let note: String?
        let usage: [UsageRecord]
        let source: String
    }

    private func transcribeAndPaste(_ recording: Recording, stoppedAt: Date) {
        let keys = APIKeys.shared
        let job = Job(
            recording: recording,
            engine: settings.engine,
            cloudProvider: settings.cloudProvider,
            stoppedAt: stoppedAt,
            language: settings.language,
            candidates: settings.candidateLanguages,
            falKey: keys.key(.fal),
            groqKey: keys.key(.groq),
            profile: ProfileStore.shared.profile(id: settings.activeProfileID),
            vocabulary: DictionaryStore.shared.vocabularyPrompt,
            fixWords: DictionaryStore.shared.replacer(),
            local: WhisperService.Request(
                audioURL: recording.url,
                whisperPath: settingsManager.whisperBinaryPath,
                modelPath: settingsManager.modelPath,
                candidates: settings.candidateLanguages,
                vocabulary: DictionaryStore.shared.vocabularyPrompt
            ),
            localAvailable: settingsManager.isModelDownloaded(settings.modelSize)
        )

        // Jobs run concurrently, but results are pasted in the order they were spoken.
        let work = Task.detached(priority: .userInitiated) { try await Self.run(job) }
        let previous = pasteChain

        pasteChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.pendingJobs -= 1
                self.settle()
            }
            do {
                let outcome = try await work.value
                outcome.usage.forEach(UsageLedger.shared.add)
                let text = self.finalize(outcome.text)
                guard !text.isEmpty else {
                    self.notify(outcome.note ?? "No speech detected",
                                symbol: outcome.note == nil ? "waveform.slash" : "exclamationmark.triangle",
                                duration: outcome.note == nil ? 1.4 : 2.6)
                    return
                }
                let latency = Date().timeIntervalSince(job.stoppedAt)
                print("[Dictation] \(outcome.source): \(String(format: "%.2f", latency))s from stop to paste")
                TranscriptionStore.shared.add(text.trimmingCharacters(in: .whitespaces), source: outcome.source, seconds: latency)
                if self.pasteService.paste(text) == .copiedOnly {
                    self.notify("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: 2.4)
                } else if let note = outcome.note {
                    self.notify(note, symbol: "info.circle", duration: 2.4)
                } else if self.pendingJobs <= 1, !self.isRecording {
                    self.hud.hide()
                }
                self.playDoneSound()
            } catch {
                print("[Dictation] Failed: \(error)")
                self.notify(error.localizedDescription, symbol: "exclamationmark.triangle", duration: 2.6)
            }
        }
    }

    nonisolated private static func run(_ job: Job) async throws -> Outcome {
        var notes: [String] = []
        var usage: [UsageRecord] = []
        var text: String

        func transcribeLocally() async throws -> String {
            try await WhisperService().transcribe(job.local)
        }

        var source = "Local"
        if job.engine == .cloud {
            let provider = job.cloudProvider
            let key = provider == .groq ? job.groqKey : job.falKey
            do {
                guard let key else { throw CloudError.missingKey(provider.keyProvider) }
                switch provider {
                case .groq:
                    let result = try await GroqTranscriber().transcribe(
                        audioURL: job.recording.url, candidates: job.candidates, prompt: job.vocabulary, key: key)
                    text = WhisperService.clean(result.text)
                    usage.append(UsageRecord(service: .transcription, provider: "Groq whisper-large-v3-turbo",
                                             quantity: job.recording.duration,
                                             costUSD: GroqTranscriber.cost(audioSeconds: job.recording.duration,
                                                                           requests: result.requests)))
                    source = "Groq"
                case .fal:
                    let result = try await FalTranscriber().transcribe(audioURL: job.recording.url, language: job.candidates.count == 1 ? job.candidates[0] : "auto", key: key)
                    text = WhisperService.clean(result.text)
                    let (cost, isEstimate) = await FalPricing.shared.cost(
                        audioSeconds: job.recording.duration, requestSeconds: result.requestSeconds, key: key)
                    usage.append(UsageRecord(service: .transcription, provider: "fal.ai Wizper v3",
                                             quantity: job.recording.duration, costUSD: cost, isEstimate: isEstimate))
                    source = "fal.ai"
                }
                try? FileManager.default.removeItem(at: job.recording.url)
            } catch {
                if let failure = error as? FalBilledFailure, let key {
                    let (cost, isEstimate) = await FalPricing.shared.cost(
                        audioSeconds: job.recording.duration, requestSeconds: failure.requestSeconds, key: key)
                    usage.append(UsageRecord(service: .transcription, provider: "fal.ai Wizper v3 (failed)",
                                             quantity: job.recording.duration, costUSD: cost, isEstimate: isEstimate))
                }
                guard job.localAvailable else {
                    // Keep the spend record even though there's nothing to paste.
                    return Outcome(text: "", note: error.localizedDescription, usage: usage, source: provider.displayName)
                }
                print("[Dictation] Cloud transcription failed, using local: \(error)")
                if case CloudError.missingKey = error {
                    notes.append("Add a \(provider.keyProvider.displayName) key to use Cloud")
                } else {
                    notes.append("Cloud unavailable — transcribed on this Mac")
                }
                text = try await transcribeLocally()
            }
        } else {
            text = try await transcribeLocally()
        }

        text = job.fixWords(text)

        if let profile = job.profile, !text.isEmpty {
            if let key = job.groqKey {
                do {
                    let result = try await GroqFormatter().format(text, profile: profile, vocabulary: job.vocabulary, key: key)
                    text = job.fixWords(result.text)
                    usage.append(UsageRecord(service: .formatting, provider: "Groq gpt-oss-20b",
                                             quantity: Double(result.promptTokens + result.completionTokens),
                                             costUSD: result.cost))
                } catch {
                    print("[Dictation] Formatting failed: \(error)")
                    notes.append("\(profile.name) formatting failed — pasted as spoken")
                }
            } else {
                notes.append("Add a Groq key to use \(profile.name)")
            }
        }

        return Outcome(text: text, note: notes.first, usage: usage, source: source)
    }

    private func finalize(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.addTrailingSpace, !text.isEmpty, !text.contains("\n") else { return text }
        return text + " "
    }

    /// The done sound waits for the volume fade-up so it plays at full volume.
    private func playDoneSound() {
        guard settings.playSounds else { return }
        let elapsed = volumeRestoreStarted.map { Date().timeIntervalSince($0) } ?? 1
        let wait = max(0, VolumeAttenuator.fadeUpDuration + 0.02 - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.sounds.play(SoundPlayer.done)
        }
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

/// Start and done sounds. Cached so playback starts instantly.
final class SoundPlayer {
    static let start = "Funk"
    static let done = "Glass"

    private var cache: [String: NSSound] = [:]

    /// Plays `name` and returns how long it lasts (capped).
    @discardableResult
    func play(_ name: String) -> TimeInterval {
        let sound = cache[name] ?? NSSound(named: NSSound.Name(name))
        cache[name] = sound
        guard let sound else { return 0 }
        sound.stop()
        sound.play()
        return min(sound.duration, 0.5)
    }
}
