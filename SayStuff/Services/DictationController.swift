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
    /// Per-language shortcut problems, keyed by language code.
    @Published private(set) var languageHotkeyErrors: [String: String] = [:]
    /// Set when the current recording was started with a language shortcut.
    @Published private(set) var recordingLanguage: String?

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
    private let corrections = CorrectionWatcher()

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
        corrections.onLearn = { [weak self] term, heard in
            self?.learn(term: term, heardAs: heard)
        }
        corrections.onTextChanged = { AppDelegate.shared?.hideDictionaryNotice() }
    }

    func start() {
        settingsManager.$settings
            .map(\.hotkey)
            .removeDuplicates()
            .sink { [weak self] combo in self?.registerDictationHotkey(combo) }
            .store(in: &cancellables)

        settingsManager.$settings
            .map(Self.languageShortcuts)
            .removeDuplicates()
            .sink { [weak self] shortcuts in self?.registerLanguageHotkeys(shortcuts) }
            .store(in: &cancellables)

        settingsManager.$settings
            .map { [$0.engine.rawValue, $0.modelSize.rawValue, $0.whisperPath, $0.modelDirectory, "\($0.modelIdleMinutes)"] }
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLocalServer() }
            .store(in: &cancellables)
    }

    /// The local model is loaded on demand; settings changes only unload it when it no longer fits.
    private func updateLocalServer() {
        let model = settingsManager.modelPath
        let idle = settings.modelIdleMinutes * 60
        let usesWhisper = settings.engine == .local && settings.modelSize.isWhisper
        let usesParakeet = settings.engine == .local && settings.modelSize == .parakeet
        Task {
            await WhisperServer.shared.setIdleTimeout(idle)
            await ParakeetService.shared.setIdleTimeout(idle)
            // Only the selected local model stays in memory; others load again on demand.
            if usesWhisper {
                await WhisperServer.shared.stopUnless(model: model)
            } else {
                await WhisperServer.shared.stop()
            }
            if !usesParakeet { await ParakeetService.shared.unload() }
        }
    }

    func shutdown() {
        recorder.cancel()
        attenuator.restoreImmediately()
        // whisper-server's watchdog stops it once this process exits.
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

    private var languageHotkeyIDs: [HotkeyManager.ID: String] = [:]

    private struct LanguageShortcut: Equatable {
        let code: String
        let combo: KeyCombo
    }

    private static func languageShortcuts(_ settings: AppSettings) -> [LanguageShortcut] {
        settings.spokenLanguages.compactMap { code in
            settings.languageHotkeys[code].map { LanguageShortcut(code: code, combo: $0) }
        }
    }

    private func registerLanguageHotkeys(_ shortcuts: [LanguageShortcut]) {
        languageHotkeyIDs.keys.forEach(hotkeys.unregister)
        languageHotkeyIDs = [:]
        var errors: [String: String] = [:]
        var taken = [settings.hotkey]
        for (index, shortcut) in shortcuts.enumerated() {
            let code = shortcut.code, combo = shortcut.combo
            if taken.contains(where: { $0.sameKeys(as: combo) }) {
                errors[code] = "\(combo.displayString) is already used by another SayStuff shortcut."
                continue
            }
            let id = HotkeyManager.ID.language(index)
            if hotkeys.register(id, keyCode: combo.keyCode, modifiers: combo.carbonModifiers) {
                languageHotkeyIDs[id] = code
                taken.append(combo)
            } else {
                errors[code] = "\(combo.displayString) is taken by another app."
            }
        }
        languageHotkeyErrors = errors
    }

    private func handleHotkey(_ id: HotkeyManager.ID, isPress: Bool) {
        guard !hotkeysSuspended else { return }
        let language = languageHotkeyIDs[id]
        guard id == .dictation || language != nil else { return }
        if isPress {
            // Any SayStuff shortcut stops a toggle recording, whichever one started it.
            if settings.hotkeyMode == .toggle, isRecording {
                finish()
            } else {
                begin(language: language)
            }
        } else if settings.hotkeyMode == .hold {
            finish()
        }
    }

    // MARK: - Recording

    /// `language` forces one language for this recording (a language shortcut); nil uses the settings.
    func begin(language: String? = nil) {
        guard !isRecording else { return }
        corrections.cancel()
        recordingLanguage = language
        phase = .recording(since: Date())

        hud.showRecording()
        if settings.showScreenBorder { border.show() }
        let soundLength = settings.playSounds ? sounds.play(SoundPlayer.start) : 0
        if settings.attenuateAudio {
            // Duck after the start sound so it plays at full volume.
            attenuator.attenuate(to: settings.attenuationLevel, after: soundLength)
        }
        warmUpConnections()
        if settings.engine == .local {
            // Load the model while the user talks; usually ready before they stop.
            if settings.modelSize == .parakeet {
                Task.detached(priority: .userInitiated) { await ParakeetService.shared.prewarm() }
            } else {
                let cli = settingsManager.whisperBinaryPath, model = settingsManager.modelPath
                Task.detached(priority: .userInitiated) { await WhisperServer.shared.prewarm(cliPath: cli, model: model) }
            }
        }

        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: settings.toggleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }

        recorder.start(deviceUID: settings.selectedAudioDeviceUID) { [weak self] error in
            guard let self, let error else { return }
            print("[Dictation] Failed to start recording: \(error)")
            self.endRecordingUI(nextPhase: self.pendingJobs > 0 ? .processing : .idle)
            self.settle()
            self.hud.flash(error.localizedDescription, symbol: "mic.slash")
        }
    }

    func finish() {
        guard isRecording else { return }
        let trace = LatencyTrace()
        trace.mark("stop.pressed")
        let forcedLanguage = recordingLanguage
        let stoppedAt = Date()
        pendingJobs += 1
        // Transition directly to processing: a transient idle phase would reset the
        // status icon before the capture callback or paste could reach the main thread.
        endRecordingUI(nextPhase: .processing)
        trace.mark("stop.uiEnded")
        hud.showProcessing()

        recorder.stop(trace: trace) { [weak self] recording in
            guard let self else { return }
            guard let recording, recording.containsSpeech, recording.duration >= self.minimumDuration else {
                if let recording { try? FileManager.default.removeItem(at: recording.url) }
                self.pendingJobs -= 1
                self.settle()
                if recording?.garbled == true {
                    // Reconnect next time; a stale USB session is the usual cause.
                    self.recorder.resetSession()
                    self.notify("Mic sent garbled audio — reconnecting", symbol: "exclamationmark.triangle", duration: 2.6)
                } else {
                    self.notify("No speech detected", symbol: "waveform.slash", duration: 1.4)
                }
                return
            }
            self.transcribeAndPaste(recording, stoppedAt: stoppedAt, forcedLanguage: forcedLanguage, trace: trace)
        }
    }

    private func endRecordingUI(nextPhase: Phase) {
        phase = nextPhase
        recordingLanguage = nil
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
        let trace: LatencyTrace
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
        let localModel: WhisperModel
        let localAvailable: Bool
    }

    private struct Outcome {
        let text: String
        let note: String?
        let usage: [UsageRecord]
        let source: String
        var metric: DictationMetric
    }

    private func transcribeAndPaste(_ recording: Recording, stoppedAt: Date, forcedLanguage: String?, trace: LatencyTrace) {
        trace.mark("job.setupStarted")
        let keys = APIKeys.shared
        let candidates = forcedLanguage.map { [$0] } ?? settings.candidateLanguages
        let job = Job(
            trace: trace,
            recording: recording,
            engine: settings.engine,
            cloudProvider: settings.cloudProvider,
            stoppedAt: stoppedAt,
            language: settings.language,
            candidates: candidates,
            falKey: keys.key(.fal),
            groqKey: keys.key(.groq),
            profile: ProfileStore.shared.profile(id: settings.activeProfileID),
            vocabulary: DictionaryStore.shared.vocabularyPrompt,
            fixWords: DictionaryStore.shared.replacer(),
            local: WhisperService.Request(
                audioURL: recording.url,
                whisperPath: settingsManager.whisperBinaryPath,
                modelPath: settingsManager.modelPath,
                candidates: candidates,
                vocabulary: DictionaryStore.shared.vocabularyPrompt
            ),
            localModel: settings.modelSize,
            localAvailable: settingsManager.isModelDownloaded(settings.modelSize)
        )

        trace.mark("job.setupFinished")

        // Jobs run concurrently, but results are pasted in the order they were spoken.
        let work = Task.detached(priority: .userInitiated) { try await Self.run(job) }
        let previous = pasteChain

        pasteChain = Task { [weak self] in
            await previous?.value
            trace.mark("job.previousPasteFinished")
            guard let self else { return }
            defer {
                self.pendingJobs -= 1
                self.settle()
            }
            do {
                var outcome = try await work.value
                trace.mark("job.resultOnMain")
                outcome.usage.forEach(UsageLedger.shared.add)
                defer {
                    outcome.metric.totalSeconds = Date().timeIntervalSince(job.stoppedAt)
                    trace.mark("job.finished")
                    Telemetry.shared.record(outcome.metric)
                }
                let text = self.finalize(outcome.text)
                guard !text.isEmpty else {
                    self.notify(outcome.note ?? "No speech detected",
                                symbol: outcome.note == nil ? "waveform.slash" : "exclamationmark.triangle",
                                duration: outcome.note == nil ? 1.4 : 2.6)
                    return
                }
                let latency = Date().timeIntervalSince(job.stoppedAt)
                print("[Dictation] \(outcome.source): \(String(format: "%.2f", latency))s from stop to paste")
                trace.mark("history.started")
                TranscriptionStore.shared.add(text.trimmingCharacters(in: .whitespaces), source: outcome.source, seconds: latency)
                trace.mark("history.finished")
                if self.pasteService.paste(text, trace: trace) == .copiedOnly {
                    self.notify("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: 2.4)
                } else {
                    if self.settings.learnCorrections { self.corrections.watch(pasted: text) }
                    if let note = outcome.note {
                        self.notify(note, symbol: "info.circle", duration: 2.4)
                    } else if self.pendingJobs <= 1, !self.isRecording {
                        self.hud.hide()
                    }
                }
                self.playDoneSound()
            } catch {
                print("[Dictation] Failed: \(error)")
                self.notify(error.localizedDescription, symbol: "exclamationmark.triangle", duration: 2.6)
            }
        }
    }

    nonisolated private static func run(_ job: Job) async throws -> Outcome {
        job.trace.mark("job.workerStarted")
        var notes: [String] = []
        var usage: [UsageRecord] = []
        var text: String
        var metric = DictationMetric(
            setup: "Local · \(job.localModel.shortName)",
            languageMode: job.candidates.count == 1 ? job.candidates[0] : "auto",
            audioSeconds: job.recording.duration,
            transcribeSeconds: 0
        )
        let transcribeStart = Date()

        func transcribeLocally() async throws -> String {
            if job.localModel == .parakeet {
                defer { try? FileManager.default.removeItem(at: job.recording.url) }
                let forced = job.candidates.count == 1 ? job.candidates[0] : nil
                let result = try await ParakeetService.shared.transcribe(job.recording.url, forcedLanguage: forced)
                metric.coldStart = result.coldStart
                return WhisperService.clean(result.text)
            }
            let result = try await WhisperService().transcribe(job.local)
            metric.coldStart = result.coldStart
            metric.retriedLanguage = result.retriedLanguage
            return result.text
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
                    metric.setup = "Groq"
                    metric.retriedLanguage = result.requests > 1
                case .fal:
                    let result = try await FalTranscriber().transcribe(audioURL: job.recording.url, language: job.candidates.count == 1 ? job.candidates[0] : "auto", key: key)
                    text = WhisperService.clean(result.text)
                    let (cost, isEstimate) = await FalPricing.shared.cost(
                        audioSeconds: job.recording.duration, requestSeconds: result.requestSeconds, key: key)
                    usage.append(UsageRecord(service: .transcription, provider: "fal.ai Wizper v3",
                                             quantity: job.recording.duration, costUSD: cost, isEstimate: isEstimate))
                    source = "fal.ai"
                    metric.setup = "fal.ai"
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
                    metric.setup = provider.displayName
                    metric.transcribeSeconds = Date().timeIntervalSince(transcribeStart)
                    return Outcome(text: "", note: error.localizedDescription, usage: usage, source: provider.displayName, metric: metric)
                }
                print("[Dictation] Cloud transcription failed, using local: \(error)")
                if case CloudError.missingKey = error {
                    notes.append("Add a \(provider.keyProvider.displayName) key to use Cloud")
                } else {
                    notes.append("Cloud unavailable — transcribed on this Mac")
                }
                metric.fellBack = true
                text = try await transcribeLocally()
            }
        } else {
            text = try await transcribeLocally()
        }

        metric.transcribeSeconds = Date().timeIntervalSince(transcribeStart)
        job.trace.mark("job.transcriptionFinished")
        text = job.fixWords(text)

        if let profile = job.profile, !text.isEmpty {
            let formatStart = Date()
            defer { metric.formatSeconds = Date().timeIntervalSince(formatStart) }
            if let key = job.groqKey {
                do {
                    let result = try await GroqFormatter().format(text, profile: profile, vocabulary: job.vocabulary, key: key)
                    if GroqFormatter.looksLikeRewrite(result.text, of: text) {
                        text = job.fixWords(result.text)
                    } else {
                        print("[Dictation] Formatter answered instead of rewriting; pasting as spoken: \(result.text)")
                        notes.append("\(profile.name) changed too much — pasted as spoken")
                    }
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

        job.trace.mark("job.workerFinished")
        return Outcome(text: text, note: notes.first, usage: usage, source: source, metric: metric)
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

    private func learn(term: String, heardAs heard: String) {
        let dictionary = DictionaryStore.shared
        let existing = dictionary.entries.first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
        guard existing?.heardAs.contains(where: { $0.caseInsensitiveCompare(heard) == .orderedSame }) != true else { return }
        let existed = existing != nil
        dictionary.add(term: term, heardAs: [heard], learned: true)
        print("[Dictation] Learned \(term) (heard \(heard))")
        AppDelegate.shared.showDictionaryNotice(term: term, heardAs: heard,
                                                  near: corrections.correctionAnchor,
                                                  highlight: corrections.correctedWordFrame,
                                                  field: corrections.textFieldFrame) {
            dictionary.forget(term: term, heardAs: heard, removeTerm: !existed)
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
