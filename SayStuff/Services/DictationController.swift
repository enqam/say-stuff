import AppKit
import Combine
import AVFoundation
import Carbon.HIToolbox
import os

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
    private var parakeetRecording: Task<Void, Never>?
    /// Transcribes the current recording while it's spoken (Whisper streaming).
    private var whisperStream: WhisperStream?
    private var autoStopTimer: Timer?
    private var hotkeysSuspended = false
    private var cancellables = Set<AnyCancellable>()
    /// Mics connected at the last device change; nil until the first one, so launch isn't a plug-in.
    private var connectedMicrophoneUIDs: Set<String>?
    #if DEBUG
    /// A replayed dictation: transcribes this instead of the mic, and pastes and saves nothing.
    fileprivate var debugRecording: Recording?
    fileprivate var debugDry = false
    #endif

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
        RecordingArchive.prune()
        _ = DictionaryStore.shared
        #if DEBUG
        listenForDebugDictation()
        #endif
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

        // Devices settle over a few hundred ms after a plug-in.
        AudioDeviceManager.shared.$inputDevices
            .combineLatest(settingsManager.$settings.map { [$0.selectedAudioDeviceUID, $0.selectedAudioDeviceName] }.removeDuplicates())
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] devices, _ in self?.followMicrophone(devices) }
            .store(in: &cancellables)
    }

    /// Keeps the chosen mic pointed at its current UID (USB UIDs change with the port), switches
    /// to a remembered mic when it's plugged in or when the active one goes away, and readies the
    /// capture session for whichever mic the next recording will use.
    private func followMicrophone(_ devices: [AudioDevice]) {
        let previous = connectedMicrophoneUIDs
        connectedMicrophoneUIDs = Set(devices.map(\.uid))
        func connected(_ mic: RememberedMicrophone) -> AudioDevice? {
            devices.first { $0.uid == mic.uid } ?? devices.first { $0.matches(uid: mic.uid, name: mic.name) }
        }
        let remembered = settings.rememberedMicrophones
        let pluggedIn = previous.flatMap { previous in
            remembered.lazy.compactMap(connected).first { !previous.contains($0.uid) }
        }
        let active = settings.selectedAudioDeviceUID.flatMap {
            connected(RememberedMicrophone(uid: $0, name: settings.selectedAudioDeviceName))
        }
        if let device = pluggedIn ?? active ?? remembered.lazy.compactMap(connected).first,
           device.uid != settings.selectedAudioDeviceUID || device.name != settings.selectedAudioDeviceName {
            settingsManager.settings.selectMicrophone(device)
            return  // the settings change runs this again
        }
        recorder.prepare(preferredUID: settings.selectedAudioDeviceUID, preferredName: settings.selectedAudioDeviceName)
    }

    /// Prepare the selected model at launch and after engine settings change.
    private func updateLocalServer() {
        let model = settingsManager.modelPath
        let cli = settingsManager.whisperBinaryPath
        let idle = settings.modelIdleMinutes * 60
        let usesWhisper = settings.engine == .local && settings.modelSize.isWhisper
        let usesParakeet = settings.engine == .local && settings.modelSize.isParakeet
        let parakeetModel = settings.modelSize
        Task {
            await WhisperServer.shared.setIdleTimeout(idle)
            await ParakeetService.shared.setIdleTimeout(idle)
            // Only the selected local model stays in memory; others load again on demand.
            if usesWhisper {
                await WhisperServer.shared.stopUnless(model: model)
                await WhisperServer.shared.prewarm(cliPath: cli, model: model)
            } else {
                await WhisperServer.shared.stop()
            }
            if usesParakeet {
                await ParakeetService.shared.prewarm(parakeetModel)
            } else {
                await ParakeetService.shared.unload()
            }
        }
    }

    func shutdown() {
        recorder.cancel()
        releaseParakeetRecording()
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
        let trace = LatencyTrace()
        trace.mark("start.pressed")
        let stream = settings.engine == .local && settings.modelSize.isWhisper && settings.streamWhisper
            ? WhisperStream(whisperPath: settingsManager.whisperBinaryPath, model: settingsManager.modelPath,
                            candidates: language.map { [$0] } ?? settings.candidateLanguages,
                            vocabulary: DictionaryStore.shared.vocabularyPrompt)
            : nil
        whisperStream = stream
        // Start the microphone before synchronous UI and sound work on the main thread.
        recorder.start(preferredUID: settings.selectedAudioDeviceUID, preferredName: settings.selectedAudioDeviceName,
                       onChunk: stream.map { stream in { stream.append($0) } }, trace: trace) { [weak self] error in
            trace.mark("start.mainCallback")
            guard let self, let error else { return }
            print("[Dictation] Failed to start recording: \(error)")
            self.endRecordingUI(nextPhase: self.pendingJobs > 0 ? .processing : .idle)
            self.settle()
            self.hud.flash(error.localizedDescription, symbol: "mic.slash")
        }
        corrections.cancel()
        recordingLanguage = language
        phase = .recording(since: Date())

        hud.showRecording()
        if settings.showScreenBorder { border.show() }
        let soundLength = settings.playSounds ? sounds.play(SoundPlayer.start) : 0
        if settings.playSounds { sounds.wakeOutput() }
        if settings.attenuateAudio {
            // Start ducking just after the start sound's attack; its tail can dip with the music.
            attenuator.attenuate(to: settings.attenuationLevel, after: min(soundLength, 0.12))
        }
        warmUpConnections()
        if settings.engine == .local {
            // Load the model while the user talks; usually ready before they stop.
            if settings.modelSize.isParakeet {
                let model = settings.modelSize
                parakeetRecording = Task.detached(priority: .userInitiated) { await ParakeetService.shared.beginRecording(model) }
            } else {
                let cli = settingsManager.whisperBinaryPath, model = settingsManager.modelPath
                Task.detached(priority: .userInitiated) { await WhisperServer.shared.prewarm(cliPath: cli, model: model) }
            }
        }

        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: settings.toggleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }

        trace.mark("start.uiReady")
    }

    func finish() {
        guard isRecording else { return }
        let trace = LatencyTrace()
        trace.mark("stop.pressed")
        let forcedLanguage = recordingLanguage
        var startedAt: Date?
        if case .recording(let since) = phase { startedAt = since }
        // Where the text is going; the stats keep pace per app.
        let app = NSWorkspace.shared.frontmostApplication
        let target = Target(name: app?.localizedName, bundleID: app?.bundleIdentifier)
        let stream = whisperStream
        whisperStream = nil
        let stoppedAt = Date()
        pendingJobs += 1
        // Transition directly to processing: a transient idle phase would reset the
        // status icon before the capture callback or paste could reach the main thread.
        endRecordingUI(nextPhase: .processing)
        trace.mark("stop.uiEnded")
        hud.showProcessing()

        recorder.stop(trace: trace) { [weak self] recording in
            guard let self else { return }
            var recording = recording
            #if DEBUG
            if let replay = self.debugRecording { recording = replay; self.debugRecording = nil }
            #endif
            guard let recording, recording.containsSpeech, recording.duration >= self.minimumDuration else {
                stream?.cancel()
                if let recording {
                    RecordingArchive.note(recording.garbled ? "[garbled audio]" : "[not speech, skipped]", for: recording.url)
                }
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
            self.transcribeAndPaste(recording, stream: stream, stoppedAt: stoppedAt,
                                    recordingSeconds: startedAt.map { stoppedAt.timeIntervalSince($0) } ?? recording.duration,
                                    target: target, forcedLanguage: forcedLanguage, trace: trace)
        }
    }

    private struct Target {
        let name: String?
        let bundleID: String?
    }

    private func releaseParakeetRecording() {
        guard let reservation = parakeetRecording else { return }
        parakeetRecording = nil
        Task {
            await reservation.value
            await ParakeetService.shared.endRecording()
        }
    }

    private func endRecordingUI(nextPhase: Phase) {
        releaseParakeetRecording()
        whisperStream?.cancel()
        whisperStream = nil
        phase = nextPhase
        recordingLanguage = nil
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        border.hide()
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
        let stream: WhisperStream?
        /// Whether a text field is focused, checked while transcription runs.
        let focus: Task<TextFocus.State, Never>
        let engine: TranscriptionEngine
        let cloudProvider: CloudProvider
        let stoppedAt: Date
        let language: String
        let candidates: [String]
        let falKey: String?
        let groqKey: String?
        let profile: Profile?
        let vocabulary: String?
        let fixWords: @Sendable (String) async -> String
        let removeFillers: Bool
        let local: WhisperService.Request
        let localModel: WhisperModel
        let localAvailable: Bool
    }

    private struct Outcome {
        let text: String
        /// The transcript as the engine returned it, before any cleanup.
        var spoken = ""
        let note: String?
        let usage: [UsageRecord]
        let source: String
        var metric: DictationMetric
    }

    private func transcribeAndPaste(_ recording: Recording, stream: WhisperStream?, stoppedAt: Date,
                                    recordingSeconds: Double, target: Target,
                                    forcedLanguage: String?, trace: LatencyTrace) {
        trace.mark("job.setupStarted")
        let keys = APIKeys.shared
        let candidates = forcedLanguage.map { [$0] } ?? settings.candidateLanguages
        let job = Job(
            trace: trace,
            recording: recording,
            stream: stream,
            focus: Task.detached(priority: .userInitiated) { TextFocus.state() },
            engine: settings.engine,
            cloudProvider: settings.cloudProvider,
            stoppedAt: stoppedAt,
            language: settings.language,
            candidates: candidates,
            falKey: keys.key(.fal),
            groqKey: keys.key(.groq),
            profile: ProfileStore.shared.profile(id: settings.activeProfileID),
            vocabulary: DictionaryStore.shared.vocabularyPrompt,
            fixWords: DictionaryStore.shared.replacer,
            removeFillers: settings.removeFillers,
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
                trace.mark("job.settled")
            }
            #if DEBUG
            let dry = self.debugDry
            self.debugDry = false
            #else
            let dry = false
            #endif
            do {
                var outcome = try await work.value
                trace.mark("job.resultOnMain")
                outcome.usage.forEach(UsageLedger.shared.add)
                defer {
                    outcome.metric.totalSeconds = Date().timeIntervalSince(job.stoppedAt)
                    trace.mark("job.finished")
                    if !dry { Telemetry.shared.record(outcome.metric) }
                }
                let text = self.finalize(outcome.text)
                #if DEBUG
                if dry { Logger(subsystem: "com.saystuff.app", category: "debug").notice("Dry run text: \(text, privacy: .public)") }
                #endif
                if !dry { RecordingArchive.note(text.isEmpty ? "[no text]" : text, for: job.recording.url) }
                if !text.isEmpty, !dry {
                    Self.recordSpeech(outcome, recording: job.recording, recordingSeconds: recordingSeconds,
                                      target: target, candidates: job.candidates, profile: job.profile?.name)
                }
                guard !text.isEmpty else {
                    self.notify(outcome.note ?? "No speech detected",
                                symbol: outcome.note == nil ? "waveform.slash" : "exclamationmark.triangle",
                                duration: outcome.note == nil ? 1.4 : 2.6)
                    return
                }
                // Nowhere to type: paste as soon as a field is clicked; after a few seconds
                // leave it on the clipboard instead.
                if !dry, await job.focus.value == .none {
                    self.notify("Click a text field to paste", symbol: "cursorarrow.click", duration: Self.focusWait)
                    if await !Self.waitForTextField() {
                        self.pasteService.copy(text)
                        TranscriptionStore.shared.add(text.trimmingCharacters(in: .whitespaces), source: outcome.source,
                                                      seconds: Date().timeIntervalSince(job.stoppedAt))
                        self.notify("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: 2.4)
                        return
                    }
                }
                let latency = Date().timeIntervalSince(job.stoppedAt)
                print("[Dictation] \(outcome.source): \(String(format: "%.2f", latency))s from stop to paste")
                // Paste first; saving history writes to disk.
                // Not sure a field had focus: keep the text on the clipboard so ⌘V recovers a miss.
                let pasted = dry ? .pasted
                    : self.pasteService.paste(text, keepOnClipboard: await job.focus.value != .text, trace: trace)
                if !dry { self.playDoneSound() }
                trace.mark("paste.soundStarted")
                // The outro starts with the paste, before anything else.
                let flows = pasted == .pasted && outcome.note == nil && self.pendingJobs <= 1 && !self.isRecording
                if flows { self.hud.hide(pasted: text) }
                trace.mark("outro.started")
                // Saving history and attaching the correction watcher (Accessibility calls into
                // the target app, then a callback per edit) ran on the main thread during the
                // outro's first frames and froze it for 30-170 ms; they wait until it has landed.
                let learn = pasted != .copiedOnly && self.settings.learnCorrections
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.outroLength) {
                    guard !dry else { return }
                    TranscriptionStore.shared.add(text.trimmingCharacters(in: .whitespaces), source: outcome.source, seconds: latency)
                    trace.mark("history.finished")
                    if learn {
                        self.corrections.watch(pasted: text, vocabulary: DictionaryStore.shared.entries.map(\.term))
                    }
                }
                if pasted == .copiedOnly {
                    self.notify("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: 2.4)
                } else {
                    if let note = outcome.note {
                        self.notify(note, symbol: "info.circle", duration: 2.4)
                    } else if !flows, self.pendingJobs <= 1, !self.isRecording {
                        self.hud.hide()
                    }
                }
            } catch {
                print("[Dictation] Failed: \(error)")
                RecordingArchive.note("[failed: \(error.localizedDescription)]", for: job.recording.url)
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
            if job.localModel.isParakeet {
                let forced = job.candidates.count == 1 ? job.candidates[0] : nil
                let result = try await ParakeetService.shared.transcribe(
                    job.recording.url, samples: job.recording.samples, model: job.localModel,
                    forcedLanguage: forced, trace: job.trace)
                metric.coldStart = result.coldStart
                return WhisperService.clean(result.text)
            }
            if let stream = job.stream {
                // Most of the dictation is already transcribed; only the part after the last pause is left.
                let recording = job.recording
                do {
                    let result = try await stream.finish(
                        tail: recording.tailHasSpeech || recording.streamedSamples == 0 ? recording.tail : nil)
                    if !result.text.isEmpty {
                        metric.setup += " · Stream"
                        metric.retriedLanguage = result.retriedLanguage
                        return result.text
                    }
                } catch {
                    print("[Dictation] Streaming failed, transcribing the whole recording: \(error)")
                }
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
        let spoken = text
        if job.removeFillers { text = TextCleanup.removeDisfluencies(text) }
        text = await job.fixWords(text)

        if let profile = job.profile, !text.isEmpty {
            let formatStart = Date()
            defer { metric.formatSeconds = Date().timeIntervalSince(formatStart) }
            if let key = job.groqKey {
                do {
                    let result = try await GroqFormatter().format(text, profile: profile, vocabulary: job.vocabulary, key: key)
                    if GroqFormatter.looksLikeRewrite(result.text, of: text) {
                        text = await job.fixWords(result.text)
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
        return Outcome(text: text, spoken: spoken, note: notes.first, usage: usage, source: source, metric: metric)
    }

    private static func recordSpeech(_ outcome: Outcome, recording: Recording, recordingSeconds: Double,
                                      target: Target, candidates: [String], profile: String?) {
        let spoken = outcome.spoken
        let words = SpeechStats.wordCount(spoken)
        guard words > 0 else { return }
        let fillers = max(0, words - SpeechStats.wordCount(TextCleanup.removeDisfluencies(spoken)))
        SpeechStats.shared.record(SpeechSample(
            words: words, fillers: fillers, timing: recording.speech, recordingSeconds: recordingSeconds,
            language: SpeechStats.language(of: spoken, candidates: candidates),
            app: target.name, appBundleID: target.bundleID,
            setup: outcome.metric.setup, profile: profile))
    }

    private func finalize(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.addTrailingSpace, !text.isEmpty, !text.contains("\n") else { return text }
        return text + " "
    }

    private static let focusWait: TimeInterval = 10
    /// How long the pasted-text outro runs: flight, landing and fade.
    private static let outroLength: TimeInterval = 0.5

    /// Polls for a focused text field for up to `focusWait` seconds.
    private static func waitForTextField() async -> Bool {
        let deadline = Date().addingTimeInterval(focusWait)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if await Task.detached(priority: .userInitiated, operation: { TextFocus.state() }).value != .none {
                return true
            }
        }
        return false
    }

    /// Plays as the text lands. The volume fade-up front-loads, so it's mostly back by now.
    private func playDoneSound() {
        guard settings.playSounds else { return }
        sounds.play(SoundPlayer.done)
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
        // Past the done sound's tail, and soon enough that a follow-up starts instantly.
        if pendingJobs == 0 { sounds.sleepOutput(after: 20) }
    }
}

/// Start and done sounds. Cached so playback starts instantly.
final class SoundPlayer {
    static let start = "Funk"
    static let done = "Glass"

    private var cache: [String: NSSound] = [:]
    /// `NSSound.play()` blocks until the output device starts. A wedged device
    /// (e.g. mid Bluetooth switch) would otherwise freeze the main thread.
    private let queue = DispatchQueue(label: "com.saystuff.sounds", qos: .userInteractive)

    /// Plays `name` and returns how long it lasts (capped).
    @discardableResult
    func play(_ name: String) -> TimeInterval {
        let sound = cache[name] ?? NSSound(named: NSSound.Name(name))
        cache[name] = sound
        guard let sound else { return 0 }
        queue.async {
            sound.stop()
            sound.play()
        }
        return min(sound.duration, 0.5)
    }

    // MARK: Keeping Bluetooth output awake

    /// Bluetooth headphones stop their audio stream when nothing plays; the next sound waits
    /// for it to restart. Measured with AirPods Pro on macOS 27: ~400 ms to restart, then
    /// 160 ms of output latency, versus 8 ms to start on a running stream. So while a
    /// dictation is under way a silent output keeps the stream up, and stops a while after.
    private var keepAwake: AVAudioEngine?
    private var sleepWork: DispatchWorkItem?
    private let keepAwakeQueue = DispatchQueue(label: "com.saystuff.sounds.awake", qos: .userInitiated)

    /// Keeps the output awake until `sleep(after:)`. No-op unless the output is Bluetooth.
    func wakeOutput() {
        sleepWork?.cancel()
        sleepWork = nil
        keepAwakeQueue.async { [self] in
            guard keepAwake == nil, Self.outputIsBluetooth() else { return }
            let engine = AVAudioEngine()
            let silence = AVAudioSourceNode { _, _, _, buffers in
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return noErr
            }
            engine.attach(silence)
            engine.connect(silence, to: engine.mainMixerNode, format: nil)
            do {
                try engine.start()
                keepAwake = engine
            } catch {
                print("[Sounds] Couldn't keep output awake: \(error)")
            }
        }
    }

    /// Lets the output sleep again after `delay` (time for the last sound to finish, and for
    /// a quick follow-up dictation to start instantly).
    func sleepOutput(after delay: TimeInterval) {
        sleepWork?.cancel()
        let work = DispatchWorkItem { [self] in
            keepAwakeQueue.async { [self] in
                keepAwake?.stop()
                keepAwake = nil
            }
        }
        sleepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func outputIsBluetooth() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

#if DEBUG
extension DictationController {
    /// Replays a dictation of a speech file (16 kHz mono) through the real recorder, HUD and
    /// engine, pasting and saving nothing: `com.saystuff.debugDictate` with
    /// "path,seconds,x,y,w,h", the last four where the text "lands" (screen coordinates).
    func listenForDebugDictation() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.saystuff.debugDictate"),
                                                            object: nil, queue: .main) { note in
            let parts = (note.object as? String ?? "").split(separator: ",").map(String.init)
            let numbers = parts.dropFirst().compactMap(Double.init)
            guard parts.count == 6, numbers.count == 5, let recording = Self.debugLoad(URL(fileURLWithPath: parts[0])) else { return }
            let text = NSRect(x: numbers[1], y: numbers[2], width: numbers[3], height: numbers[4])
            Task { @MainActor in
                DictationController.shared.debugDictate(recording, seconds: numbers[0], text: text)
            }
        }
    }

    private func debugDictate(_ recording: Recording, seconds: TimeInterval, text: NSRect) {
        guard !isRecording else { return }
        begin()
        hud.debugTarget = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            self.debugRecording = recording
            self.debugDry = true
            self.finish()
        }
    }

    nonisolated private static func debugLoad(_ url: URL) -> Recording? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate == 16_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return Recording(url: url, duration: Double(samples.count) / 16_000, containsSpeech: true, samples: samples)
    }
}
#endif
