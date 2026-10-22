import AppKit
import SwiftUI

enum UISnapshotMode {
    static var isActive = false
}

#if DEBUG

/// Read-only fixtures exercise the overflow cases without changing the user's saved settings or history.
struct MenuSnapshotFixture {
    var settings = AppSettings()
    var profiles = Profile.builtIns
    var models = WhisperModel.allCases
    var devices = [
        AudioDevice(id: 1, name: "iPhone Microphone", uid: "snapshot-iphone"),
        AudioDevice(id: 2, name: "Comica_VM40 TX", uid: "snapshot-comica"),
        AudioDevice(id: 3, name: "MacBook Pro Microphone", uid: "snapshot-mac"),
    ]
    var recent = [
        RecentTranscription(text: "First, fix the login page, then add dark mode and update the changelog."),
        RecentTranscription(text: "The meeting has moved to Thursday at three."),
        RecentTranscription(text: "Cerebras is in the dictionary now."),
    ]
}

/// Renders every UI surface to PNGs (light + dark) and quits, for design review.
/// Doesn't register hotkeys or a status item, so it can run next to a live copy.
///
///     SAYSTUFF_SNAPSHOT_DIR=/tmp/saystuff-shots .../SayStuff.app/Contents/MacOS/SayStuff
@MainActor
enum UISnapshots {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["SAYSTUFF_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private struct Job {
        let name: String
        let size: NSSize?
        let make: () -> AnyView
    }

    static func run(to directory: URL) {
        UISnapshotMode.isActive = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var local = MenuSnapshotFixture()
        local.settings.language = "en"
        local.settings.modelSize = .parakeet
        local.settings.selectedAudioDeviceUID = "snapshot-comica"
        var cloud = local
        cloud.settings.engine = .cloud
        var preview = local
        preview.settings.activeProfileID = Profile.promptID
        var stress = local
        stress.settings.spokenLanguages = allSupportedLanguages.filter { $0.code != "auto" }.map(\.code)
        stress.profiles += (0..<7).map { index in
            var profile = Profile.newCustom()
            profile.name = "A very long custom profile name \(index + 1)"
            return profile
        }
        stress.devices += (0..<8).map { index in
            AudioDevice(id: UInt32(index + 10), name: "An exceptionally long external microphone device name \(index + 1)", uid: "snapshot-long-\(index)")
        }
        var jobs: [Job] = [
            Job(name: "popover", size: nil) { AnyView(MenuBarView()) },
            Job(name: "menu-local", size: nil) { AnyView(MenuBarView(snapshot: local)) },
            Job(name: "menu-cloud", size: nil) { AnyView(MenuBarView(snapshot: cloud)) },
            Job(name: "menu-preview", size: nil) { AnyView(MenuBarView(initiallyShowsPreview: true, snapshot: preview)) },
            Job(name: "menu-long-names", size: nil) { AnyView(MenuBarView(maximumHeight: 1600, snapshot: stress)) },
            Job(name: "menu-overflow", size: nil) { AnyView(MenuBarView(maximumHeight: 500, snapshot: stress)) },
        ]
        for pane in SettingsPane.allCases {
            jobs.append(Job(name: "settings-\(pane.rawValue)", size: NSSize(width: 640, height: 900)) {
                SettingsRouter.shared.pane = pane
                return AnyView(SettingsView())
            })
        }
        jobs.append(Job(name: "history-speaking", size: nil) {
            AnyView(SpeakingCard(stats: SpeechStats(fixture: speechFixture())).frame(width: 600).padding(20))
        })
        for step in 0..<3 {
            jobs.append(Job(name: "onboarding-\(step + 1)", size: NSSize(width: 500, height: 500)) {
                AnyView(OnboardingView(initialStep: step) {})
            })
        }

        var queue: [(Job, NSAppearance.Name)] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for job in jobs { queue.append((job, appearance)) }
        }
        renderNext(queue, into: directory)
    }

    private static func speechFixture() -> [SpeechSample] {
        var generator = SystemRandomNumberGenerator()
        let apps = [("Messages", "com.apple.MobileSMS"), ("T3 Code", "com.t3.code"), ("Notes", "com.apple.Notes")]
        return (0..<120).map { index in
            let span = Double.random(in: 2...25, using: &generator)
            let russian = index % 4 == 0
            let rate = (russian ? 2.3 : 2.7) + Double(index % 30) / 60 + Double.random(in: -0.3...0.3, using: &generator)
            let pauses = Int(span / 5)
            let app = apps[index % apps.count]
            return SpeechSample(
                date: Date().addingTimeInterval(-Double(index) * 21_600),
                words: Int(span * rate), fillers: Int.random(in: 0...2, using: &generator),
                timing: SpeechTiming(spanSeconds: span, voicedSeconds: span * 0.72, pauses: pauses,
                                     pauseSeconds: Double(pauses) * 0.8, longestPauseSeconds: pauses > 0 ? 1.2 : 0),
                recordingSeconds: span + 0.8, language: russian ? "ru" : "en",
                app: app.0, appBundleID: app.1, setup: "Local · Parakeet Ultra", profile: nil)
        }
    }

    private static func renderNext(_ queue: [(Job, NSAppearance.Name)], into directory: URL) {
        guard let (job, appearanceName) = queue.first else {
            renderHUD(into: directory)
            NSApp.terminate(nil)
            return
        }

        let appearance = NSAppearance(named: appearanceName)
        let host = NSHostingView(rootView: job.make().background(Color(nsColor: .windowBackgroundColor)))
        let size = job.size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderFrontRegardless()

        // Give SwiftUI a few run loop turns to lay out (NavigationSplitView needs more than one).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            host.layoutSubtreeIfNeeded()
            if job.size == nil { window.setContentSize(host.fittingSize) }
            host.layoutSubtreeIfNeeded()
            let suffix = appearanceName == .darkAqua ? "dark" : "light"
            write(host, to: directory.appendingPathComponent("\(job.name)-\(suffix).png"), appearance: appearance)
            window.orderOut(nil)
            renderNext(Array(queue.dropFirst()), into: directory)
        }
    }

    private static func write(_ view: NSView, to url: URL, appearance: NSAppearance?) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        let draw = { view.cacheDisplay(in: view.bounds, to: rep) }
        if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func renderHUD(into directory: URL) {
        let hud = RecordingHUD()
        let states: [(String, (RecordingHUD) -> Void)] = [
            ("hud-recording", { $0.debugShowRecording(levels: [0.15, 0.55, 0.9, 0.7, 0.4, 0.75, 0.3, 0.1]) }),
            ("hud-processing", { $0.showProcessing() }),
            ("hud-message", { $0.flash("No speech detected", symbol: "waveform.slash") }),
        ]
        for (name, apply) in states {
            apply(hud)
            hud.debugRender(to: directory.appendingPathComponent("\(name).png"))
        }
        hud.hide()
    }
}
#endif
