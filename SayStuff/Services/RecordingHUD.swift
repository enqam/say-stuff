import AppKit
import QuartzCore

/// Small floating pill at the bottom of the screen: live waveform while recording,
/// a shimmer while transcribing, and short status messages.
///
/// Pure AppKit + Core Animation. The waveform is ~15 plain CALayers whose heights are set at
/// most 30×/s; the render server interpolates between updates, so there's no drawing code
/// and no per-frame view work.
final class RecordingHUD {
    private enum Metrics {
        static let height: CGFloat = 36
        static let barCount = 15
        static let barWidth: CGFloat = 3
        static let barGap: CGFloat = 3
        static let minBar: CGFloat = 3
        static let maxBar: CGFloat = 20
        static let dotSize: CGFloat = 7
        static let padding: CGFloat = 14
        static let dotGap: CGFloat = 10
        static let gapAboveDock: CGFloat = 80
        static let frameInterval: CFTimeInterval = 1.0 / 30
        static var barsWidth: CGFloat { CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap }
        static var pillWidth: CGFloat { padding * 2 + dotSize + dotGap + barsWidth }
    }

    private enum Mode { case hidden, recording, processing, message }

    private let panel: NSPanel
    private let pill = AppearanceAwareView()
    private let dot = CALayer()
    private let barsLayer = CALayer()
    private var bars: [CALayer] = []
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    private var mode: Mode = .hidden
    private var history = [CGFloat](repeating: 0, count: Metrics.barCount / 2 + 1)  // [0] = newest, drawn in the center
    private var smoothed: CGFloat = 0
    private var pendingPeak: CGFloat = 0
    private var lastFrame: CFTimeInterval = 0
    private var hideWork: DispatchWorkItem?
    private var messageAction: (() -> Void)?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.pillWidth, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Keep the HUD tied to the user's current macOS appearance. The custom
        // view calls back when AppKit changes its effective appearance, including
        // while this non-activating panel is already visible.
        pill.onAppearanceChange = { [weak self] in
            self?.updateAppearanceColors()
        }

        pill.wantsLayer = true
        if #available(macOS 26.0, *) {
            // One glass view; the bars are plain layers inside it.
            let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: Metrics.pillWidth, height: Metrics.height))
            glass.cornerRadius = Metrics.height / 2
            glass.style = .clear  // the clearest glass AppKit offers: refraction, no frost, no tint
            pill.frame = glass.bounds
            pill.autoresizingMask = [.width, .height]
            glass.contentView = pill
            panel.contentView = glass
        } else {
            // Let AppKit resolve the fallback surface for Aqua or Dark Aqua.
            // The old forced dark appearance made the pill look like a white
            // sticker when the rest of the desktop was in Light mode.
            panel.appearance = nil
            if let layer = pill.layer {
                layer.cornerRadius = Metrics.height / 2
                layer.cornerCurve = .continuous
                layer.borderWidth = 0.5
            }
            panel.contentView = pill
        }

        dot.backgroundColor = Theme.nsAccent.cgColor
        dot.cornerRadius = Metrics.dotSize / 2
        pill.layer?.addSublayer(dot)

        pill.layer?.addSublayer(barsLayer)
        for _ in 0..<Metrics.barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = Metrics.barWidth / 2
            // A hairline edge instead of a tint or shadow keeps white bars readable on bright
            // backgrounds without frosting the glass (borders don't need an offscreen pass).
            bar.borderWidth = 0.5
            bar.borderColor = NSColor(white: 0, alpha: 0.28).cgColor
            barsLayer.addSublayer(bar)
            bars.append(bar)
        }

        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.isHidden = true
        pill.addSubview(label)

        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.isHidden = true
        pill.addSubview(icon)

        layoutWaveform()
        pill.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        updateAppearanceColors()
    }

    /// Resolve semantic AppKit colors for the current appearance and push them
    /// into the layers. CALayer stores CGColors, so it will not re-resolve a
    /// dynamic NSColor by itself after the user switches Light/Dark mode.
    private func updateAppearanceColors() {
        let appearance = pill.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let foreground = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.86)
        let edge = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.28)

        appearance.performAsCurrentDrawingAppearance {
            bars.forEach {
                $0.backgroundColor = foreground.cgColor
                $0.borderColor = edge.cgColor
            }
            label.textColor = isDark ? .white : .black
            icon.contentTintColor = isDark ? .white : .black
        }

        guard #unavailable(macOS 26.0), let layer = pill.layer else { return }
        appearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
            layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        }
    }

    @objc private func clicked() {
        guard mode == .message, let action = messageAction else { return }
        messageAction = nil
        action()
        hide()
    }

    /// Only clickable messages take the mouse; otherwise clicks pass through to the app below.
    private func setAction(_ action: (() -> Void)?) {
        messageAction = action
        panel.ignoresMouseEvents = action == nil
    }

    // MARK: - Public (main thread)

    func showRecording() {
        cancelHide()
        setAction(nil)
        mode = .recording
        smoothed = 0
        pendingPeak = 0
        history = history.map { _ in 0 }
        setWaveformVisible(true)
        layoutWaveform()
        stopShimmer()
        dot.backgroundColor = Theme.nsAccent.cgColor
        pulseDot()
        present()
    }

    /// Feed a 0...1 loudness value. Cheap to call for every audio buffer.
    func push(level: Float) {
        guard mode == .recording else { return }
        pendingPeak = max(pendingPeak, CGFloat(level))
        let now = CACurrentMediaTime()
        guard now - lastFrame >= Metrics.frameInterval else { return }
        lastFrame = now

        let target = pendingPeak
        pendingPeak = 0
        // Fast attack, slower release reads as "alive" without jitter.
        smoothed += (target - smoothed) * (target > smoothed ? 0.7 : 0.25)
        history.removeLast()
        history.insert(smoothed, at: 0)

        CATransaction.begin()
        CATransaction.setAnimationDuration(Metrics.frameInterval * 1.5)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let center = Metrics.barCount / 2
        for (index, bar) in bars.enumerated() {
            let distance = abs(index - center)
            let envelope = 1 - CGFloat(distance) / CGFloat(center + 1) * 0.5
            setHeight(bar, Metrics.minBar + (Metrics.maxBar - Metrics.minBar) * history[distance] * envelope)
        }
        CATransaction.commit()
    }

    func showProcessing() {
        cancelHide()
        setAction(nil)
        guard mode != .processing else { return }
        mode = .processing
        setWaveformVisible(true)
        layoutWaveform()
        dot.removeAllAnimations()
        dot.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        bars.forEach { setHeight($0, Metrics.minBar + 1) }
        CATransaction.commit()
        startShimmer()
        present()
    }

    /// `action` makes the message clickable (e.g. undo).
    func flash(_ text: String, symbol: String? = nil, duration: TimeInterval = 1.8, action: (() -> Void)? = nil) {
        cancelHide()
        setAction(action)
        mode = .message
        stopShimmer()
        dot.removeAllAnimations()
        setWaveformVisible(false)

        label.stringValue = text
        label.sizeToFit()
        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.image = image
        icon.isHidden = image == nil
        label.isHidden = false

        let iconWidth: CGFloat = image == nil ? 0 : 16 + 7
        let width = Metrics.padding * 2 + iconWidth + ceil(label.frame.width)
        let pillWidth = max(width, Metrics.height * 2)
        resize(width: pillWidth)
        let originX = (pillWidth - iconWidth - label.frame.width) / 2
        icon.frame = NSRect(x: originX, y: (Metrics.height - 16) / 2, width: 16, height: 16)
        label.frame.origin = NSPoint(x: originX + iconWidth, y: (Metrics.height - label.frame.height) / 2)

        present()
        scheduleHide(after: duration)
    }

    func hide() {
        cancelHide()
        setAction(nil)
        guard mode != .hidden else { return }
        mode = .hidden
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.mode == .hidden else { return }
            self.panel.orderOut(nil)
            self.stopShimmer()
            self.dot.removeAllAnimations()
        })
    }

    // MARK: - Layout

    private func layoutWaveform() {
        resize(width: Metrics.pillWidth)
        let midY = Metrics.height / 2
        dot.frame = CGRect(x: Metrics.padding, y: midY - Metrics.dotSize / 2, width: Metrics.dotSize, height: Metrics.dotSize)
        barsLayer.frame = CGRect(x: Metrics.padding + Metrics.dotSize + Metrics.dotGap, y: 0, width: Metrics.barsWidth, height: Metrics.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Metrics.barWidth, height: Metrics.minBar)
            bar.position = CGPoint(x: CGFloat(index) * (Metrics.barWidth + Metrics.barGap) + Metrics.barWidth / 2, y: midY)
        }
        CATransaction.commit()
    }

    private func setWaveformVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.isHidden = !visible
        barsLayer.isHidden = !visible
        CATransaction.commit()
        label.isHidden = visible
        icon.isHidden = visible || icon.image == nil
    }

    private func setHeight(_ bar: CALayer, _ height: CGFloat) {
        bar.bounds.size.height = height
    }

    private func resize(width: CGFloat) {
        var frame = panel.frame
        let center = frame.midX
        frame.size = NSSize(width: width, height: Metrics.height)
        if panel.isVisible { frame.origin.x = center - width / 2 }
        panel.setFrame(frame, display: false)
    }

    private func present() {
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: Self.baseline(on: screen)))
        }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()

        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -6
        rise.toValue = 0
        rise.duration = 0.2
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pill.layer?.add(rise, forKey: "rise")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Just above a visible Dock; with an auto-hiding Dock, low near the screen edge.
    private static func baseline(on screen: NSScreen) -> CGFloat {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        return screen.frame.minY + (reserved > 8 ? reserved : 0) + Metrics.gapAboveDock
    }

    // MARK: - Animations (run on the render server)

    private func pulseDot() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
    }

    private func startShimmer() {
        let now = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            let wave = CABasicAnimation(keyPath: "bounds.size.height")
            wave.fromValue = Metrics.minBar + 1
            wave.toValue = Metrics.minBar + 9
            wave.duration = 0.42
            wave.autoreverses = true
            wave.repeatCount = .infinity
            wave.beginTime = now + Double(index) * 0.055
            wave.fillMode = .backwards
            wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(wave, forKey: "shimmer")
        }
    }

    private func stopShimmer() {
        bars.forEach { $0.removeAnimation(forKey: "shimmer") }
    }

    private func scheduleHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }
}

/// The HUD's layers store resolved CGColors, so give the content view a small
/// appearance-change hook and refresh those colors when AppKit re-resolves it.
private final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

#if DEBUG
extension RecordingHUD {
    /// Puts the waveform in a fixed state for snapshots (levels from the center outwards).
    func debugShowRecording(levels: [CGFloat]) {
        showRecording()
        dot.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = Metrics.barCount / 2
        for (index, bar) in bars.enumerated() {
            let distance = abs(index - center)
            let level = distance < levels.count ? levels[distance] : 0
            setHeight(bar, Metrics.minBar + (Metrics.maxBar - Metrics.minBar) * level)
        }
        CATransaction.commit()
    }

    func debugRender(to url: URL) {
        guard let layer = pill.layer else { return }
        let scale: CGFloat = 2
        let size = pill.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        if !label.isHidden {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            if !icon.isHidden, let image = icon.image {
                let tinted = NSImage(size: icon.frame.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor.white.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: icon.frame)
            }
            (label.stringValue as NSString).draw(at: label.frame.origin, withAttributes: [
                .font: label.font as Any,
                .foregroundColor: NSColor.white,
            ])
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
