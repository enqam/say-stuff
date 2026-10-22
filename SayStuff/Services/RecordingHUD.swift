import AppKit
import QuartzCore
import os

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
        static let gapAboveDock: CGFloat = 92
        /// Clear space around the pill inside its window. The glass draws its rim and outer
        /// refraction slightly outside its shape; a window cut flush to the pill clips them in
        /// straight lines that notch the edge where it starts to curve.
        static let margin: CGFloat = 12
        static let frameInterval: CFTimeInterval = 1.0 / 30
        static var barsWidth: CGFloat { CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap }
        static var pillWidth: CGFloat { padding * 2 + dotSize + dotGap + barsWidth }
    }

    private enum Mode { case hidden, recording, processing, message }
    private static let log = Logger(subsystem: "com.saystuff.app", category: "hud")

    private let panel: NSPanel
    private let pill = AppearanceAwareView()
    private weak var glassView: NSView?
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
    /// Where text is being typed (screen coordinates), looked up when recording starts.
    private var caret: NSPoint?
    private var caretLookup = 0
    private let morph = PasteMorph()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.pillWidth + Metrics.margin * 2,
                                height: Metrics.height + Metrics.margin * 2),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the glass draws its own edge; a window shadow outlines it in hard black
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
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true
        let pillFrame = container.bounds.insetBy(dx: Metrics.margin, dy: Metrics.margin)
        panel.contentView = container
        if #available(macOS 26.0, *) {
            // One glass view; the bars are plain layers inside it.
            let glass = LensGlassView(frame: pillFrame)
            glass.cornerRadius = Metrics.height / 2
            glass.style = .clear
            // Private variant 11 ("bubbles"): a clear refracting lens with no frost. Public
            // `.clear` blurs like frosted glass. Compared side by side with every variant on macOS 27.
            if glass.responds(to: NSSelectorFromString("set_variant:")) {
                glass.setValue(11, forKey: "_variant")
            }
            glassView = glass
            pill.frame = glass.bounds
            pill.autoresizingMask = [.width, .height]
            glass.contentView = pill
            pill.addRim()
            glass.autoresizingMask = [.width]
            container.addSubview(glass)
        } else {
            // Let AppKit resolve the fallback surface for Aqua or Dark Aqua.
            panel.appearance = nil
            if let layer = pill.layer {
                layer.cornerRadius = Metrics.height / 2
                layer.cornerCurve = .continuous
                layer.borderWidth = 0.5
            }
            pill.frame = pillFrame
            pill.autoresizingMask = [.width]
            container.addSubview(pill)
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
        #if DEBUG
        listenForDebugOutro()
        #endif
    }

    /// Apply the waveform and glass tint for the current appearance. CALayer
    /// stores CGColors, so it will not re-resolve a dynamic color by itself
    /// after the user switches Light/Dark mode.
    private func updateAppearanceColors() {
        let appearance = pill.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // White waveform in both modes: Light mode smokes the glass behind it.
        let foreground = NSColor.white
        let edge = NSColor.black.withAlphaComponent(0.28)
        pill.applyLook(isDark: isDark)

        appearance.performAsCurrentDrawingAppearance {
            bars.forEach {
                $0.backgroundColor = foreground.cgColor
                $0.borderColor = edge.cgColor
            }
            label.textColor = foreground
            icon.contentTintColor = foreground
        }

        if #available(macOS 26.0, *), let glass = glassView as? LensGlassView {
            // No tint: any tint frosts the lens.
            glass.tintColor = nil
            glass.isDark = isDark
            glass.applyLook()
        } else if let layer = pill.layer {
            appearance.performAsCurrentDrawingAppearance {
                layer.backgroundColor = (isDark
                    ? NSColor.white.withAlphaComponent(0.10)
                    : NSColor.black.withAlphaComponent(0.45)).cgColor  // white bars in both modes
                layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            }
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
        morph.cancel()
        mode = .recording
        locateCaret()
        smoothed = 0
        pendingPeak = 0
        history = history.map { _ in 0 }
        setWaveformVisible(true)
        layoutWaveform()
        stopShimmer()
        dot.backgroundColor = Theme.nsAccent.cgColor
        pulseDot()
        present()
        // Build the outro's glass once the pill is up, off the press-to-pill path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.mode == .recording, let frame = self.pillScreenFrame, let screen = self.panel.screen else { return }
            self.morph.prepare(at: frame, on: screen)
        }
    }

    /// The dot and bars as they're drawn right now (mid-shimmer), for the outro to carry.
    private func waveformCopy() -> CALayer? {
        guard let host = pill.layer, !barsLayer.isHidden else { return nil }
        let copy = CALayer()
        copy.bounds = host.bounds
        for source in [dot] + bars where !source.isHidden {
            let shown = source.presentation() ?? source
            let layer = CALayer()
            layer.frame = host.convert(shown.frame, from: source.superlayer)
            layer.backgroundColor = source.backgroundColor
            layer.cornerRadius = source.cornerRadius
            layer.borderWidth = source.borderWidth
            layer.borderColor = source.borderColor
            layer.opacity = shown.opacity
            copy.addSublayer(layer)
        }
        return copy
    }

    /// The glass pill's frame on screen.
    private var pillScreenFrame: NSRect? {
        guard let glass = glassView, let window = glass.window else { return nil }
        return window.convertToScreen(glass.convert(glass.bounds, to: nil))
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
        // The pill flies to the cursor while transcription runs, so the drop is already
        // there when the text and the done sound land.
        if let caret, let start = pillScreenFrame, let screen = panel.screen {
            morph.begin(from: start, toward: caret, content: waveformCopy(), on: screen)
            panel.orderOut(nil)
            stopShimmer()
            dot.removeAllAnimations()
        }
    }

    /// `action` makes the message clickable (e.g. undo).
    func flash(_ text: String, symbol: String? = nil, duration: TimeInterval = 1.8, action: (() -> Void)? = nil) {
        cancelHide()
        setAction(action)
        morph.cancel()
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

    /// `pasted`: the text just pasted, which the pill flows onto.
    func hide(pasted: String? = nil) {
        cancelHide()
        setAction(nil)
        guard mode != .hidden else { return }
        let wasProcessing = mode == .processing
        mode = .hidden
        if morph.isRunning {
            if let pasted { morph.land(pasted: pasted) } else { morph.dissolve() }
            return
        }
        // The pill flows only once there's text, so an empty result never sends it anywhere.
        if let pasted, wasProcessing, panel.isVisible, let start = pillScreenFrame, let screen = panel.screen {
            morph.begin(from: start, toward: caret, content: waveformCopy(), on: screen)
            morph.land(pasted: pasted)
            panel.orderOut(nil)
            stopShimmer()
            dot.removeAllAnimations()
            return
        }
        morph.cancel()
        fadeOut()
    }

    private func fadeOut() {
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
        frame.size = NSSize(width: width + Metrics.margin * 2, height: Metrics.height + Metrics.margin * 2)
        if panel.isVisible { frame.origin.x = center - frame.width / 2 }
        panel.setFrame(frame, display: false)
    }

    private func present() {
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                         y: Self.baseline(on: screen) - Metrics.margin))
        }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        if #available(macOS 26.0, *), let glass = glassView as? LensGlassView {
            // The glass builds its layers on first display, after this call returns.
            glass.applyLook()
            DispatchQueue.main.async { glass.applyLook() }
        }

        panel.alphaValue = 1
        guard let layer = panel.contentView?.layer else { return }
        // Intro: a squashed drop that springs out to full size. Render-server only, so the
        // pill is usable from the first frame.
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = Self.scale(layer, x: 0.82, y: 0.55)
        grow.toValue = CATransform3DIdentity
        grow.stiffness = 520
        grow.damping = 24
        grow.duration = grow.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1
        fade.duration = 0.05
        layer.add(grow, forKey: "intro")
        layer.add(fade, forKey: "introFade")
    }

    /// Scales about the layer's center whatever its anchor point (AppKit uses the corner).
    fileprivate static func scale(_ layer: CALayer, x: CGFloat, y: CGFloat) -> CATransform3D {
        let dx = (0.5 - layer.anchorPoint.x) * layer.bounds.width
        let dy = (0.5 - layer.anchorPoint.y) * layer.bounds.height
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, x, y, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }

    /// Looks up the text cursor off the main thread; Accessibility calls into other apps can block.
    private func locateCaret() {
        caretLookup += 1
        let lookup = caretLookup
        caret = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let point = CaretLocator.caretPoint()
            DispatchQueue.main.async {
                guard let self, self.caretLookup == lookup else { return }
                self.caret = point
            }
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
    /// A 1 pt rim traced on the exact capsule, brightest at the top and fading smoothly
    /// around the ends. Drawn here because the glass's own rim light jumps in brightness
    /// where the straight edges meet the curves.
    private let rim = CAGradientLayer()
    private let rimShape = CAShapeLayer()
    /// Smokes the glass in Light mode so white bars read on light backgrounds. A plain dark
    /// layer keeps the lens clear and refracting; the glass's own tint frosts it.
    private let shade = CAGradientLayer()
    /// Overrides the capsule's radius (the outro reshapes it into a rounded rect).
    var cornerRadius: CGFloat? { didSet { needsLayout = true } }
    /// Light mode's smoke, scaled (the outro clears it as it lands on text).
    var shadeOpacity: Float = 1 { didSet { shade.opacity = shadeOpacity } }

    func addRim() {
        guard let layer else { return }
        layer.insertSublayer(shade, at: 0)
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        rim.locations = [0, 0.5, 1]
        rim.startPoint = CGPoint(x: 0.5, y: 1)
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        rimShape.fillColor = nil
        rimShape.strokeColor = NSColor.white.cgColor
        rimShape.lineWidth = 1
        rim.mask = rimShape
        layer.addSublayer(rim)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard rim.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        rim.contentsScale = scale
        rimShape.contentsScale = scale
        rim.frame = bounds
        shade.frame = bounds
        let radius = min(cornerRadius ?? bounds.height / 2, bounds.height / 2, bounds.width / 2)
        shade.cornerRadius = radius
        let edge = bounds.insetBy(dx: rimShape.lineWidth / 2, dy: rimShape.lineWidth / 2)
        let edgeRadius = max(0, min(radius - rimShape.lineWidth / 2, edge.height / 2, edge.width / 2))
        rimShape.path = CGPath(roundedRect: edge, cornerWidth: edgeRadius, cornerHeight: edgeRadius, transform: nil)
        CATransaction.commit()
    }

    /// Dark mode keeps the glass clear with a brighter rim against the dark; Light mode
    /// smokes it.
    func applyLook(isDark: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.colors = (isDark ? [0.75, 0.45, 0.55] : [0.8, 0.45, 0.6]).map { NSColor(white: 1, alpha: $0).cgColor }
        // Lighter at the top, like light falling through it, so it reads as a lens with depth.
        shade.colors = (isDark ? [0, 0] : [0.06, 0.2]).map { NSColor(white: 0, alpha: $0).cgColor }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}


/// Finds the text cursor through Accessibility. Off the main thread only.
private enum CaretLocator {
    private static let log = Logger(subsystem: "com.saystuff.app", category: "caret")

    static func caretPoint() -> NSPoint? {
        // Chromium and Electron apps only build their accessibility tree when asked, and the
        // first query can take a few hundred ms. This runs while the user talks, so wait.
        if let app = NSWorkspace.shared.frontmostApplication {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.6)
        var focused: AnyObject?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            log.notice("No focused element (\(status.rawValue))")
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.6)
        let field = frame(of: element)

        var value: AnyObject?
        var selection = CFRange()
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID(),
           AXValueGetValue(value as! AXValue, .cfRange, &selection) {
            // The caret's own (empty) range often has no bounds; the character before it does.
            // Chromium can answer with the whole field instead; that doesn't count.
            let candidates = [(CFRange(location: selection.location, length: 0), false),
                              (CFRange(location: max(0, selection.location - 1), length: 1), true)]
            for (range, atEnd) in candidates {
                if let rect = bounds(of: range, in: element), rect.height < 60, rect != field {
                    log.notice("Caret from text bounds")
                    return point(x: atEnd ? rect.maxX : rect.minX, midY: rect.midY)
                }
            }
        }
        log.debug("Field \(role(of: element), privacy: .public): selection \(selection.location)+\(selection.length)")
        // Chromium answers range bounds only on the static text runs inside the field.
        if selection.location > 0, let rect = runBounds(of: NSRange(location: selection.location - 1, length: 1), in: element) {
            log.notice("Caret from a text run")
            return point(x: rect.maxX, midY: rect.midY)
        }
        // No cursor bounds: aim at the start of the field's first line.
        if let field, field.height < 400 {
            log.notice("Caret from the field frame")
            return point(x: field.minX + 14, midY: field.minY + min(field.height / 2, 14))
        }
        log.notice("No caret position")
        return nil
    }

    /// Where the just-pasted `text` sits (AppKit coordinates), checked against the field's
    /// contents so a paste the app hasn't processed yet doesn't count. Waits up to ~0.15 s
    /// for it to land.
    static func pastedTextFrame(_ text: String) -> NSRect? {
        let length = (text as NSString).length
        guard length > 0 else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        for attempt in 0..<6 {
            if attempt > 0 { usleep(25_000) }
            var focused: AnyObject?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.3)
            var value: AnyObject?
            var selection = CFRange()
            guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID(),
                  AXValueGetValue(value as! AXValue, .cfRange, &selection) else { return nil }
            let start = selection.location - length
            guard start >= 0 else { continue }
            var contents: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &contents) == .success,
               let contents = contents as? NSString {
                guard selection.location <= contents.length,
                      contents.substring(with: NSRange(location: start, length: length)) == text else { continue }
            }
            let field = frame(of: element)
            var rect = bounds(of: CFRange(location: start, length: length), in: element)
            if let found = rect, found == field || found.width < 1 { rect = nil }
            if rect == nil { rect = runBounds(of: NSRange(location: start, length: length), in: element) }
            guard let rect, rect.height <= 160 else {
                log.notice("Pasted text: no usable bounds")
                return nil
            }
            log.notice("Pasted text bounds after \(attempt) retries")
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        log.notice("Pasted text not found in the field")
        return nil
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.height > 0,
              rect.minX.isFinite, rect.minY.isFinite else { return nil }
        return rect
    }

    /// Bounds of `target` (in the field's text), from the field's static text runs: the union
    /// of the pieces in each run it covers. Runs are matched to the field's text in order; the
    /// walk is bounded so a huge field can't stall.
    private static func runBounds(of target: NSRange, in field: AXUIElement) -> CGRect? {
        let offset = NSMaxRange(target)
        var fieldValue: AnyObject?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &fieldValue) == .success,
              let text = fieldValue as? String else { return nil }
        let full = text as NSString
        guard offset <= full.length else { return nil }
        var cursor = 0
        var visited = 0
        var runs = 0, matched = 0, roles: [String: Int] = [:]
        var found: CGRect?
        var done = false
        defer {
            log.debug("Run search: offset \(offset) of \(full.length), visited \(visited), runs \(runs), matched \(matched), found \(found != nil), roles \(roles.description, privacy: .public)")
        }
        func search(_ node: AXUIElement, depth: Int) {
            guard !done, depth <= 8, visited < 400 else { return }
            visited += 1
            var role: AnyObject?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            roles[(role as? String) ?? "?", default: 0] += 1
            if (role as? String) == kAXStaticTextRole {
                runs += 1
                var runValue: AnyObject?
                guard AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &runValue) == .success,
                      let run = runValue as? String, !run.isEmpty else { return }
                let match = full.range(of: run, range: NSRange(location: cursor, length: full.length - cursor))
                guard match.location != NSNotFound else { return }
                matched += 1
                cursor = NSMaxRange(match)
                let piece = NSIntersectionRange(target, match)
                if piece.length > 0,
                   let rect = bounds(of: CFRange(location: piece.location - match.location, length: piece.length), in: node) {
                    found = found.map { $0.union(rect) } ?? rect
                }
                if cursor >= offset { done = true }
                return
            }
            var children: AnyObject?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                  let children = children as? [AXUIElement] else { return }
            for child in children where !done && cursor < offset { search(child, depth: depth + 1) }
        }
        search(field, depth: 0)
        return found
    }

    private static func role(of element: AXUIElement) -> String {
        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return role as? String ?? "?"
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.height > 0 else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    /// Accessibility uses top-left origin coordinates; AppKit uses bottom-left.
    private static func point(x: CGFloat, midY: CGFloat) -> NSPoint {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: x, y: top - midY)
    }
}

/// Outro. When transcription starts the pill flows to the text cursor and waits there as a
/// small glass drop, so the moment the text lands it only has to spread over it: it
/// stretches over exactly the pasted text like a skin, clears to an outline and fades.
/// Without text bounds it pours into the cursor after the text instead. If the cursor is
/// unknown the pill stays put until the paste and flows from there.
///
/// The glass can't be animated on the render server (its shape layers rebuild on layout), so
/// a display link steps springs and reshapes a copy of the pill each frame. The link pauses
/// while the drop waits, and the copy is built while you talk so its first frame is ready.
/// Retargeting keeps each spring's velocity, so a late answer bends the motion, never jerks it.
private final class PasteMorph: NSObject {
    /// After landing: fade once settled, or at the latest this long after the paste.
    private static let settle: CFTimeInterval = 0.06
    private static let fadeLength: CFTimeInterval = 0.12
    private static let latestFade: CFTimeInterval = 0.2
    /// The drop that waits at the cursor.
    private static let dropSize = NSSize(width: 30, height: 22)
    private static let trace = Logger(subsystem: "com.saystuff.app", category: "morph")

    private lazy var overlay: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = NSView()
        root.wantsLayer = true
        panel.contentView = root
        holder.wantsLayer = true
        holder.layer?.mask = edgeMask
        interiorFill.backgroundColor = NSColor.black.cgColor
        outside.fillColor = NSColor.black.cgColor
        outside.fillRule = .evenOdd
        edgeMask.addSublayer(outside)
        edgeMask.addSublayer(interiorFill)
        edgeMask.addSublayer(edgeRing)
        blob.autoresizingMask = [.width, .height]
        holder.addSubview(blob)
        root.addSubview(holder)
        return panel
    }()

    /// Clips the glass to its edge: solid across the bezel, then easing to clear so the text
    /// inside reads as if nothing were over it. The edge is one small image, rendered once
    /// per target and stretched nine-slice, so reshaping costs nothing per frame. While it
    /// travels a solid fill covers the middle: it leaves the HUD as the pill and lands as an outline.
    private let holder = NSView()
    private let edgeMask = CALayer()
    private let edgeRing = CALayer()
    private let interiorFill = CALayer()
    /// Everything outside the shape stays unmasked. The glass redraws its shape a frame after
    /// a resize, so while it shrinks it briefly extends past the new bounds; a mask cut at
    /// the bounds sliced its rounded end off in a straight line (seen frame by frame).
    private let outside = CAShapeLayer()
    private static let bezel: CGFloat = 4.5
    private static let feather: CGFloat = 7
    private var ringRadius: CGFloat = -1

    private let face = AppearanceAwareView()
    private lazy var blob: NSView = {
        face.wantsLayer = true
        if #available(macOS 26.0, *) {
            let glass = LensGlassView()
            glass.style = .clear
            if glass.responds(to: NSSelectorFromString("set_variant:")) {
                glass.setValue(11, forKey: "_variant")
            }
            face.autoresizingMask = [.width, .height]
            glass.contentView = face
            face.addRim()
            face.onAppearanceChange = { [weak glass, weak face] in
                guard let glass, let face else { return }
                let isDark = face.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                glass.isDark = isDark
                glass.applyLook()
                face.applyLook(isDark: isDark)
            }
            glass.wantsLayer = true
            return glass
        }
        face.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.5).cgColor
        return face
    }()

    /// One damped spring per component: center x, center y, width, height.
    private struct Spring {
        var value: CGFloat, velocity: CGFloat = 0, target: CGFloat
        var omega: CGFloat, zeta: CGFloat
        mutating func step(_ dt: CGFloat) {
            let force = -omega * omega * (value - target) - 2 * zeta * omega * velocity
            velocity += force * dt
            value += velocity * dt
        }
        var settled: Bool { abs(value - target) < 0.5 && abs(velocity) < 20 }
    }

    private var generation = 0
    private var link: CADisplayLink?
    private var began: CFTimeInterval = 0, lastTick: CFTimeInterval = 0
    /// Set once the text is pasted; landing clears the middle and then fades.
    private var landedAt: CFTimeInterval?
    private var fadeFrom: CFTimeInterval?
    private var springs: [Spring] = []
    private var targetRadius: CGFloat = 0
    private var screenFrame = NSRect.zero
    private(set) var isRunning = false
    /// Eased blends, stepped each frame so nothing switches at once: how far it has left the
    /// HUD (tint easing off), and how far it has opened into an outline on the text.
    private var flight: CGFloat = 0, openness: CGFloat = 0
    /// The pill's dot and bars as they were at the hand-off; they shrink with it and fade.
    private var content: CALayer?
    private var contentSize = CGSize.zero

    /// Builds the copy at the pill's place, invisible, so its glass is ready to take over.
    func prepare(at pill: NSRect, on screen: NSScreen) {
        guard !isRunning else { return }
        screenFrame = screen.frame
        reset(to: pill)
        overlay.alphaValue = 0
        overlay.orderFrontRegardless()
    }

    /// Takes over from the pill (`start`, screen coordinates) and flows to `caret`, or waits
    /// in the pill's place without one. The caller hides the pill in the same turn.
    func begin(from start: NSRect, toward caret: NSPoint?, content: CALayer?, on screen: NSScreen) {
        generation += 1
        isRunning = true
        screenFrame = screen.frame
        reset(to: start)
        if let content {
            content.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            contentSize = content.bounds.size
            face.layer?.addSublayer(content)
            self.content = content
            apply()
        }
        if let caret {
            // Room for the text around the cursor too, so the window rarely grows mid-flight:
            // a resize moves the window and its contents on different frames (a sideways jump).
            let around = NSRect(x: caret.x - 600, y: caret.y - 250, width: 1200, height: 500)
            overlay.setFrame(overlay.frame.union(Self.padded(around, on: screenFrame)), display: false)
            aim(at: NSRect(x: caret.x - Self.dropSize.width / 2, y: caret.y - Self.dropSize.height / 2,
                           width: Self.dropSize.width, height: Self.dropSize.height), padded: false)
        }
        overlay.alphaValue = 1
        overlay.orderFrontRegardless()
        startLink()
    }

    /// The text is in: find it and spread over it.
    func land(pasted text: String) {
        guard isRunning else { return }
        let run = generation
        landedAt = CACurrentMediaTime()
        // Head for the cursor at landing speed until the text's bounds arrive.
        for index in springs.indices {
            springs[index].omega = index < 2 ? 40 : 32
            springs[index].zeta = index < 2 ? 0.85 : 0.7
        }
        startLink()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let target = CaretLocator.pastedTextFrame(text) ?? CaretLocator.caretPoint().map(Self.sliver)
            DispatchQueue.main.async {
                guard let self, self.generation == run else { return }
                if let target { self.aim(at: target, padded: true) } else { self.fadeFrom = CACurrentMediaTime() }
                self.startLink()
            }
        }
    }

    #if DEBUG
    /// Lands on a known rect without Accessibility, `delay` after the paste (like the lookup).
    func debugLand(on target: NSRect, after delay: TimeInterval) {
        guard isRunning else { return }
        landedAt = CACurrentMediaTime()
        startLink()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.aim(at: target, padded: true)
            self?.startLink()
        }
    }
    #endif

    /// Nothing was pasted: fade where it is.
    func dissolve() {
        guard isRunning else { cancel(); return }
        if fadeFrom == nil { fadeFrom = CACurrentMediaTime() }
        startLink()
    }

    func cancel() {
        generation += 1
        stop()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        isRunning = false
        overlay.orderOut(nil)
    }

    private func reset(to rect: NSRect) {
        overlay.setFrame(Self.padded(rect, on: screenFrame), display: false)
        springs = [
            Spring(value: rect.midX, target: rect.midX, omega: 30, zeta: 0.85),
            Spring(value: rect.midY, target: rect.midY, omega: 30, zeta: 0.85),
            Spring(value: rect.width, target: rect.width, omega: 24, zeta: 0.7),
            Spring(value: rect.height, target: rect.height, omega: 24, zeta: 0.7),
        ]
        targetRadius = rect.height / 2
        landedAt = nil
        fadeFrom = nil
        flight = 0
        openness = 0
        content?.removeFromSuperlayer()
        content = nil
        began = CACurrentMediaTime()
        if #available(macOS 26.0, *), blob is LensGlassView { face.onAppearanceChange?() }
        blob.alphaValue = 1
        apply()
    }

    private func startLink() {
        if link == nil {
            let link = blob.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
        lastTick = CACurrentMediaTime()
    }

    /// A thin upright capsule the size of a text cursor.
    private static func sliver(at point: NSPoint) -> NSRect {
        NSRect(x: point.x - 3, y: point.y - 10, width: 6, height: 20)
    }

    /// The overlay covers only where the shape moves (plus room for overshoot), not the screen.
    private static func padded(_ rect: NSRect, on screen: NSRect) -> NSRect {
        rect.insetBy(dx: -40, dy: -40).intersection(screen).integral
    }

    /// `padded`: room around text for the bezel and its fade, so they sit outside the letters.
    private func aim(at target: NSRect, padded: Bool) {
        // The fade ends where the text starts, so no letter sits under the glass.
        let pad = padded ? Self.bezel + Self.feather : 0
        let rect = target.insetBy(dx: -pad, dy: -pad)
        let goals = [rect.midX, rect.midY, rect.width, rect.height]
        for index in springs.indices { springs[index].target = goals[index] }
        targetRadius = padded ? min(12, rect.height / 2, rect.width / 2) : rect.height / 2
        // Toward the cursor it arrives in ~0.2 s, about one local transcription, so the drop
        // is waiting when the text lands. Landing is quick.
        for index in springs.indices {
            springs[index].omega = padded ? (index < 2 ? 40 : 32) : (index < 2 ? 22 : 20)
            springs[index].zeta = padded ? (index < 2 ? 0.85 : 0.7) : 1
        }
        let area = overlay.frame.union(Self.padded(rect, on: screenFrame))
        if area != overlay.frame { overlay.setFrame(area, display: false) }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(1.0 / 30, max(0, now - lastTick))
        lastTick = now
        let substeps = 4
        for _ in 0..<substeps {
            for index in springs.indices { springs[index].step(CGFloat(dt) / CGFloat(substeps)) }
        }
        let distance = hypot(springs[0].target - springs[0].value, springs[1].target - springs[1].value)
        let openGoal: CGFloat = landedAt == nil ? 0 : 1 - min(1, distance / 40)
        openness += (openGoal - openness) * (1 - exp(-CGFloat(dt) / 0.05))
        flight += (1 - flight) * (1 - exp(-CGFloat(dt) / 0.1))
        let settled = springs.allSatisfy(\.settled) && abs(openGoal - openness) < 0.01
        if let landedAt, fadeFrom == nil,
           now - landedAt > Self.latestFade || (now - landedAt > Self.settle && settled) {
            fadeFrom = now
        }
        if let fadeFrom {
            let fade = min(1, (now - fadeFrom) / Self.fadeLength)
            guard fade < 1 else { stop(); return }
            blob.alphaValue = 1 - fade * fade * (3 - 2 * fade)
        }
        apply()
        #if DEBUG
        Self.trace.notice("""
            frame t=\(Int((now - self.began) * 1000))ms x=\(Int(self.springs[0].value)) y=\(Int(self.springs[1].value)) \
            w=\(Int(self.springs[2].value)) h=\(Int(self.springs[3].value)) tx=\(Int(self.springs[0].target)) \
            ty=\(Int(self.springs[1].target)) landed=\(self.landedAt.map { Int((now - $0) * 1000) } ?? -1) \
            alpha=\(String(format: "%.2f", self.blob.alphaValue), privacy: .public) win=\(Int(self.overlay.frame.minX)),\(Int(self.overlay.frame.minY)),\(Int(self.overlay.frame.width))
            """)
        #endif
        // Waiting at the cursor: nothing moves, so stop the frames until the paste.
        if settled, landedAt == nil, fadeFrom == nil { link.isPaused = true }
    }

    private func apply() {
        let size = NSSize(width: max(2, springs[2].value), height: max(2, springs[3].value))
        let rect = NSRect(x: springs[0].value - size.width / 2, y: springs[1].value - size.height / 2,
                          width: size.width, height: size.height)
        // Solid and round while travelling or waiting; once landing, the middle clears and the
        // corners take the target's shape as it closes in.
        let travel = 1 - openness
        let radius = min(max(targetRadius, size.height / 2 * travel), size.height / 2, size.width / 2)
        // Light mode's smoke eases off in flight so the drop stays clear glass. On the outline
        // a trace of it stays, faintly tinting the edge (the mask feathers it toward the middle).
        let airborne = 1 - 0.65 * flight
        let smoke = airborne + (0.3 - airborne) * openness
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blob.frame = CGRect(origin: .zero, size: size)
        if #available(macOS 26.0, *), let glass = blob as? LensGlassView {
            glass.cornerRadius = radius
        } else {
            face.layer?.cornerRadius = radius
        }
        face.cornerRadius = radius
        face.shadeOpacity = Float(smoke)
        // The pill's strong lens flips the text it crosses, which strobes as it moves over
        // lines (measured frame by frame), so it calms down as it leaves the HUD.
        if #available(macOS 26.0, *), let glass = blob as? LensGlassView { glass.subtlety = max(openness, min(1, flight * 3)) }
        if let content {
            // The dot and bars stay centered, shrink with the shape and fade early on.
            let scale = min(1, size.width / max(1, contentSize.width), size.height / max(1, contentSize.height))
            content.position = CGPoint(x: size.width / 2, y: size.height / 2)
            content.transform = CATransform3DMakeScale(scale, scale, 1)
            let t = min(1, max(0, (CACurrentMediaTime() - began) / 0.16))
            content.opacity = Float(1 - t * t * (3 - 2 * t))
            if t >= 1 { content.removeFromSuperlayer(); self.content = nil }
        }
        holder.frame = rect.offsetBy(dx: -overlay.frame.minX, dy: -overlay.frame.minY)
        layoutMask(size: size, radius: radius, interior: travel)
        blob.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }

    private func layoutMask(size: NSSize, radius: CGFloat, interior: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        edgeMask.frame = bounds
        let around = CGMutablePath()
        around.addRect(bounds.insetBy(dx: -60, dy: -60))
        around.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
        outside.path = around
        interiorFill.frame = bounds
        interiorFill.cornerRadius = radius
        interiorFill.opacity = Float(interior)
        // The ring image is drawn for the landing shape; in flight the solid middle hides it.
        let scale = overlay.backingScaleFactor
        if ringRadius != targetRadius, let image = Self.edgeImage(radius: targetRadius, scale: scale) {
            ringRadius = targetRadius
            edgeRing.contents = image.image
            edgeRing.contentsScale = scale
            let side = image.side, edge = image.edge
            edgeRing.contentsCenter = CGRect(x: edge / side, y: edge / side, width: 1 / side, height: 1 / side)
        }
        edgeRing.frame = bounds
    }

    /// A rounded-rect edge as alpha: opaque for `bezel` points in, then a smooth falloff over
    /// `feather` points, measured as true distance from the curved edge.
    private static func edgeImage(radius: CGFloat, scale: CGFloat) -> (image: CGImage, side: CGFloat, edge: CGFloat)? {
        let edge = ceil(max(radius, bezel + feather)) + 1
        let side = edge * 2 + 1
        let pixels = Int(side * scale)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let half = side / 2
        for y in 0..<pixels {
            for x in 0..<pixels {
                // Signed distance to the rounded rect (negative inside), in points.
                let px = abs((CGFloat(x) + 0.5) / scale - half) - (half - radius)
                let py = abs((CGFloat(y) + 0.5) / scale - half) - (half - radius)
                let outside = hypot(max(px, 0), max(py, 0)) + min(max(px, py), 0) - radius
                let t = min(1, max(0, (-outside - bezel) / feather))
                let alpha = 1 - t * t * (3 - 2 * t)
                data[(y * pixels + x) * 4 + 3] = UInt8(alpha * 255)
            }
        }
        guard let image = context.makeImage() else { return nil }
        return (image, side, edge)
    }
}

/// The bubbles glass, tuned. Its private layers: "@0" refracts the backdrop through the
/// `glassBackground` filter, "@2" is a dark outer ring and "@3" bright bands along the top
/// and bottom. Those bands are hidden: they come from two lights, and wherever the lights
/// point the rim jumps in brightness somewhere (measured across spreads, angles and
/// amounts), so the pill draws its own rim instead. Each mode leans on the opposite of its
/// background: a lighter ring in Dark mode, a full dark ring and an inner shadow in Light mode.
///
/// Sharpness: the backdrop is sampled at half resolution and the shape layers render at 1x,
/// which the lens magnifies into streaks and a stepped rim. Both go to the screen's scale,
/// and a 0.5 pt blur on the sample smooths magnified grain without frosting the glass.
/// AppKit rebuilds these layers, so this runs after every layout and whenever the HUD appears.
@available(macOS 26.0, *)
private final class LensGlassView: NSGlassEffectView {
    var isDark = false
    /// 0 is the pill; 1 the moving drop and outro outline: a light edge refraction kept
    /// within its bezel (strong refraction flips the text it crosses), and in Light mode a
    /// softer ring and no inner shadow. In between it blends, so
    /// the pill turns into the outline without a jump.
    var subtlety: CGFloat = 0

    override func layout() {
        super.layout()
        applyLook()
    }

    func applyLook() {
        guard let layer else { return }
        let s = max(0, min(1, subtlety))
        let ring: Float = isDark ? 0.6 : Float(1 - 0.55 * s)
        let scale = window?.backingScaleFactor ?? 2
        var backdrop: [String: Any] = ["inputBlurRadius": 0.5, "inputBlurOpacity0": 1]
        // No backdrop key light: it lights a fixed-depth band that doesn't fit the round
        // ends and leaves bright (Dark) or black (Light) crescents there.
        if !isDark {
            backdrop.merge(["inputShadowAmount": 6, "inputShadowHeight": 8, "inputShadowOpacity": 0.25 * (1 - s)]) { $1 }
        }
        do {
            // From the glass's own values (-50 over 20 pt inside, 10 outside, read from the
            // glassBackground filter on macOS 27) down to a light edge.
            backdrop.merge(["inputInnerRefractionAmount": -50 + 44 * s, "inputInnerRefractionHeight": 20 - 14 * s,
                            "inputOuterRefractionAmount": 10 - 10 * s]) { $1 }
        }
        var stack = [layer]
        while let next = stack.popLast() {
            let kind = NSStringFromClass(type(of: next))
            if kind == "CASDFElementLayer" {
                // The glass shape defaults to continuous corners, which on a full capsule
                // leave a shoulder where the straight edge meets the curve.
                next.cornerCurve = .circular
            } else if kind == "CABackdropLayer" {
                if (next.value(forKey: "scale") as? NSNumber)?.doubleValue != 1 { next.setValue(1.0, forKey: "scale") }
            } else if (kind.contains("SDF") || kind.contains("Portal")), next.contentsScale != scale {
                next.contentsScale = scale
            }
            switch next.name {
            case "@3": if !next.isHidden { next.isHidden = true }
            case "@2": if next.opacity != ring { next.opacity = ring }
            case "@0" where next.filters?.isEmpty == false:
                // Only what changed: each write replaces the filter, and rewriting it every
                // frame while the outro reshapes made the lens drop out on alternate frames.
                for (key, value) in backdrop {
                    let path = "filters.glassBackground.\(key)"
                    if let current = next.value(forKeyPath: path) as? NSNumber, let wanted = value as? NSNumber,
                       abs(current.doubleValue - wanted.doubleValue) < 0.001 { continue }
                    next.setValue(value, forKeyPath: path)
                }
            default: break
            }
            stack.append(contentsOf: next.sublayers ?? [])
        }
    }
}

#if DEBUG
extension RecordingHUD {
    /// Replays the outro against a fixed caret and text rect (screen coordinates), for
    /// recording it frame by frame: `defaults`-free, triggered by a distributed notification.
    func debugOutro(caret point: NSPoint, text: NSRect, transcribe: TimeInterval, lookup: TimeInterval) {
        showRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.caretLookup += 1
            self.caret = point
            self.showProcessing()
            DispatchQueue.main.asyncAfter(deadline: .now() + transcribe) {
                self.mode = .hidden
                self.morph.debugLand(on: text, after: lookup)
            }
        }
    }

    func listenForDebugOutro() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.saystuff.debugOutro"),
                                                            object: nil, queue: .main) { [weak self] note in
            let v = (note.object as? String ?? "").split(separator: ",").compactMap { Double($0) }
            guard v.count == 8 else { return }
            self?.debugOutro(caret: NSPoint(x: v[0], y: v[1]), text: NSRect(x: v[2], y: v[3], width: v[4], height: v[5]),
                             transcribe: v[6], lookup: v[7])
        }
    }

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
