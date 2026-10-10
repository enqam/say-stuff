#if DEBUG
import AppKit
import SwiftUI

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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var jobs: [Job] = [Job(name: "popover", size: nil) { AnyView(MenuBarView()) }]
        for pane in SettingsPane.allCases {
            jobs.append(Job(name: "settings-\(pane.rawValue)", size: NSSize(width: 720, height: 560)) {
                SettingsRouter.shared.pane = pane
                return AnyView(SettingsView())
            })
        }
        for step in 0..<3 {
            jobs.append(Job(name: "onboarding-\(step + 1)", size: NSSize(width: 480, height: 460)) {
                AnyView(OnboardingView(initialStep: step) {})
            })
        }

        var queue: [(Job, NSAppearance.Name)] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for job in jobs { queue.append((job, appearance)) }
        }
        renderNext(queue, into: directory)
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
