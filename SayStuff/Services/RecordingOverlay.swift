import Cocoa
import SwiftUI

class RecordingOverlay {
    private var window: NSWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var viewModel = RecordingOverlayViewModel()
    private var hideWorkItem: DispatchWorkItem?

    // Window is bigger to give room for animation/borders
    private let windowWidth: CGFloat = 220
    private let windowHeight: CGFloat = 120

    func show(state: RecordingState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Cancel any pending hide
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil

            // Reset state (no animation, no transition)
            self.viewModel.isVisible = false
            self.viewModel.state = state
            self.viewModel.message = ""
            self.viewModel.audioLevel = 0.0
            self.viewModel.resetColors = true  // Signal to reset colors

            if self.window == nil {
                self.createWindow()
            }

            // Reposition window to current main screen (handles monitor changes)
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - (self.windowWidth / 2)
                let y = screenFrame.minY + (screenFrame.height * 0.10)
                self.window?.setFrameOrigin(NSPoint(x: x, y: y))
            }

            self.window?.orderFront(nil)

            // Let SwiftUI process the resetColors flag before animating in
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    self.viewModel.isVisible = true
                }
            }
        }
    }

    func showSuccess(wordCount: Int, duration: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.viewModel.state = .success

            // Calculate WPM (words per minute)
            let minutes = duration / 60.0
            let wpm = minutes > 0 ? Int(Double(wordCount) / minutes) : 0
            self.viewModel.message = "\(wpm) WPM"

            if self.window == nil {
                self.createWindow()
            }

            // Reposition window to current main screen (handles monitor changes)
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - (self.windowWidth / 2)
                let y = screenFrame.minY + (screenFrame.height * 0.10)
                self.window?.setFrameOrigin(NSPoint(x: x, y: y))
            }

            self.window?.orderFront(nil)
        }
    }

    func showError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.viewModel.state = .error
            self.viewModel.message = message

            if self.window == nil {
                self.createWindow()
            }

            // Reposition window to current main screen (handles monitor changes)
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - (self.windowWidth / 2)
                let y = screenFrame.minY + (screenFrame.height * 0.10)
                self.window?.setFrameOrigin(NSPoint(x: x, y: y))
            }

            self.window?.orderFront(nil)
        }
    }

    private func createWindow() {
        let view = RecordingOverlayView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.contentView = hosting
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Position at bottom center of screen (10% up from bottom)
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - (windowWidth / 2)
            let y = screenFrame.minY + (screenFrame.height * 0.10)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.window = window
        self.hostingView = hosting
    }

    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.audioLevel = level
        }
    }

    func update(state: RecordingState) {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.state = state
            self?.viewModel.message = ""
        }
    }

    func hide() {
        // Cancel any existing hide
        hideWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // Animate out
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                self.viewModel.isVisible = false
            }

            // Actually hide window after animation completes
            // Destroy window so it gets recreated on correct screen next time
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.window?.orderOut(nil)
                self.window = nil
                self.hostingView = nil
            }
        }

        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    func hideImmediately() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.orderOut(nil)
        }
    }
}

enum RecordingState {
    case recording
    case transcribing
    case success
    case error
}

class RecordingOverlayViewModel: ObservableObject {
    @Published var message: String = ""
    @Published var state: RecordingState = .recording
    @Published var audioLevel: Float = 0.0
    @Published var isVisible: Bool = false
    @Published var resetColors: Bool = false
}

struct RecordingOverlayView: View {
    @ObservedObject var viewModel: RecordingOverlayViewModel
    @State private var fromColor: Color = Color(red: 1.0, green: 0.1, blue: 0.1)
    @State private var toColor: Color = Color(red: 1.0, green: 0.1, blue: 0.1)
    @State private var lastState: RecordingState = .recording
    @State private var transitionStart: Date? = nil
    private let transitionDuration: Double = 0.5

    private let pillWidth: CGFloat = 140
    private let pillHeight: CGFloat = 56

    private func colorFor(_ state: RecordingState) -> Color {
        switch state {
        case .recording:
            return Color(red: 1.0, green: 0.1, blue: 0.1)
        case .transcribing:
            return Color.orange
        case .success:
            return Color.green
        case .error:
            return Color.red
        }
    }

    private func waveProgress(at date: Date) -> CGFloat {
        guard let start = transitionStart else { return 1.0 }
        let elapsed = date.timeIntervalSince(start)
        if elapsed >= transitionDuration {
            return 1.0
        }
        return CGFloat(elapsed / transitionDuration)
    }

    private func borderGradient(progress: CGFloat) -> LinearGradient {
        if progress >= 0.99 {
            return LinearGradient(colors: [toColor, toColor], startPoint: .leading, endPoint: .trailing)
        }
        if progress <= 0.01 {
            return LinearGradient(colors: [fromColor, fromColor], startPoint: .leading, endPoint: .trailing)
        }

        // Softer gradient edge (0.15 blend zone)
        let edgeStart = max(0, progress - 0.08)
        let edgeEnd = min(1, progress + 0.08)

        return LinearGradient(
            stops: [
                .init(color: toColor, location: 0),
                .init(color: toColor, location: edgeStart),
                .init(color: fromColor, location: edgeEnd),
                .init(color: fromColor, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func glowColor(progress: CGFloat) -> Color {
        // Glow follows the wave - use same progress as border
        if progress >= 0.99 { return toColor }
        if progress <= 0.01 { return fromColor }
        // Blend colors based on progress (glow follows the wave exactly)
        return fromColor
    }

    var body: some View {
        TimelineView(.animation(paused: transitionStart == nil)) { timeline in
            let progress = waveProgress(at: timeline.date)

            ZStack {
                switch viewModel.state {
                case .recording:
                    WaveformContent(audioLevel: viewModel.audioLevel)
                case .transcribing:
                    LoadingContent()
                case .success:
                    ResultContent(message: viewModel.message, isError: false)
                case .error:
                    ResultContent(message: viewModel.message, isError: true)
                }
            }
            .padding(12)
            .frame(width: 140 + 24, height: 56 + 24)
            .background(
                ZStack {
                    // Base fill - very dark, nearly black
                    Capsule()
                        .fill(Color(white: 0.03))

                    // Strong inner shadow at top - key depth cue
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.black, Color.black.opacity(0.7), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .padding(4)

                    // Bottom reflection - subtle light bounce
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.clear, Color.clear, Color.white.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .padding(4)

                    // Soft inner vignette - subtle edge darkening
                    Capsule()
                        .strokeBorder(Color.black.opacity(0.5), lineWidth: 6)
                        .blur(radius: 10)

                    // Bright top rim light - makes border pop
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1.5
                        )

                    // Colored border - thicker for prominence
                    Capsule()
                        .strokeBorder(borderGradient(progress: progress), lineWidth: 3.5)
                }
                // Two glows - fromColor fading out, toColor fading in (synced to wave)
                .shadow(color: fromColor.opacity(0.5 * (1.0 - Double(progress))), radius: 3, x: 0, y: 0)
                .shadow(color: toColor.opacity(0.5 * Double(progress)), radius: 3, x: 0, y: 0)
                .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 3)
                .padding(12)
            )
            .frame(width: 220, height: 120)
        }
        .scaleEffect(viewModel.isVisible ? 1.0 : 0.7)
        .opacity(viewModel.isVisible ? 1.0 : 0.0)
        .onChange(of: viewModel.state) { newState in
            // If pill is hidden (fresh show), don't animate - just set colors directly
            if !viewModel.isVisible {
                let color = colorFor(newState)
                fromColor = color
                toColor = color
                lastState = newState
                transitionStart = nil
                return
            }

            // Otherwise do wave transition
            fromColor = colorFor(lastState)
            toColor = colorFor(newState)
            lastState = newState
            transitionStart = Date()

            // Clear transition after duration
            DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration + 0.05) {
                transitionStart = nil
            }
        }
        .onAppear {
            lastState = viewModel.state
            fromColor = colorFor(viewModel.state)
            toColor = colorFor(viewModel.state)
        }
        .onChange(of: viewModel.resetColors) { shouldReset in
            if shouldReset {
                let color = colorFor(viewModel.state)
                fromColor = color
                toColor = color
                lastState = viewModel.state
                transitionStart = nil
                viewModel.resetColors = false
            }
        }
    }
}

// Content views without backgrounds (they go inside the shared pill)

class WaveformAnimationState: ObservableObject {
    var displayLevel: CGFloat = 0
    var lastTime: TimeInterval = 0
    var decayStartTime: TimeInterval = 0
    var decayStartLevel: CGFloat = 0
    var isDecaying: Bool = false
}

struct WaveformContent: View {
    var audioLevel: Float
    @StateObject private var state = WaveformAnimationState()

    var body: some View {
        TimelineView(.animation) { (timeline: TimelineViewDefaultContext) in
            WaveformBars(
                audioLevel: audioLevel,
                state: state,
                currentTime: timeline.date.timeIntervalSinceReferenceDate
            )
        }
    }
}

struct WaveformBars: View {
    let audioLevel: Float
    let state: WaveformAnimationState
    let currentTime: TimeInterval

    var body: some View {
        let target = CGFloat(audioLevel)
        let deltaTime: TimeInterval = state.lastTime == 0 ? 0 : currentTime - state.lastTime

        let newLevel: CGFloat = {
            // Rising or audio still present
            if target > state.displayLevel || target > 0.15 {
                state.isDecaying = false
                // Smooth attack
                return state.displayLevel + (target - state.displayLevel) * min(CGFloat(deltaTime) * 10.0, 1.0)
            } else {
                // Audio dropped - start decay with hold
                if !state.isDecaying {
                    state.isDecaying = true
                    state.decayStartTime = currentTime
                }
                let decayElapsed = currentTime - state.decayStartTime

                // Hold for 0.7s
                if decayElapsed < 0.7 {
                    return state.displayLevel
                } else {
                    // Ease-in decay: starts slow (1.0), accelerates to fast (8.0) over 1 second
                    let t = min((decayElapsed - 0.7) / 1.0, 1.0)
                    let decaySpeed = 1.0 + t * t * 7.0  // 1.0 → 8.0 with quadratic ease-in
                    return state.displayLevel + (target - state.displayLevel) * min(CGFloat(deltaTime * decaySpeed), 1.0)
                }
            }
        }()

        // GPU-accelerated waveform rendering (macOS 14+) with CPU fallback
        Group {
            if #available(macOS 14.0, *) {
                GPUWaveformBars(smoothedLevel: newLevel, time: currentTime)
            } else {
                CPUWaveformBars(smoothedLevel: newLevel, time: currentTime)
            }
        }
        .onChange(of: currentTime) { _ in
            state.displayLevel = newLevel
            state.lastTime = currentTime
        }
    }
}

/// GPU-accelerated waveform bars using Metal shader (macOS 14.0+)
/// Offloads all per-bar sine wave calculations to GPU
@available(macOS 14.0, *)
struct GPUWaveformBars: View {
    let smoothedLevel: CGFloat
    let time: TimeInterval

    var body: some View {
        Rectangle()
            .fill(.red)
            .frame(width: 140, height: 56)
            .colorEffect(
                ShaderLibrary.waveformBars(
                    .float(Float(time)),
                    .float(Float(smoothedLevel)),
                    .float2(140, 56)
                )
            )
    }
}

/// CPU fallback for macOS < 14.0
struct CPUWaveformBars: View {
    let smoothedLevel: CGFloat
    let time: TimeInterval

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<13, id: \.self) { index in
                WaveformBar(index: index, smoothedLevel: smoothedLevel, time: time, totalBars: 13)
            }
        }
    }
}

struct LoadingContent: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(spacing: 3) {
                ForEach(0..<13, id: \.self) { index in
                    LoadingBar(index: index, time: time, totalBars: 13)
                }
            }
        }
    }
}

struct ResultContent: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isError {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.red)
                Text(message)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                Text(message)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

struct WaveformPill: View {
    var audioLevel: Float
    @State private var smoothedLevel: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            HStack(spacing: 3) {
                ForEach(0..<13, id: \.self) { index in
                    WaveformBar(index: index, smoothedLevel: smoothedLevel, time: timeline.date.timeIntervalSinceReferenceDate, totalBars: 13)
                }
            }
        }
        .onChange(of: audioLevel) { newLevel in
            let newCG = CGFloat(newLevel)
            if newCG > smoothedLevel {
                withAnimation(.easeOut(duration: 0.05)) {
                    smoothedLevel = newCG
                }
            } else {
                withAnimation(.easeInOut(duration: 1.0)) {
                    smoothedLevel = newCG
                }
            }
        }
        .padding(12) // Room for shadow
        .frame(width: 140 + 24, height: 56 + 24)
        .background(
            ZStack {
                // Subtle outer glow
                Capsule()
                    .fill(Color(red: 1.0, green: 0.1, blue: 0.1).opacity(0.15))
                    .blur(radius: 4)
                    .padding(10)

                // Main pill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.15), Color(white: 0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        // Inner highlight
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.15), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .overlay(
                        // Border - bright vivid red
                        Capsule()
                            .strokeBorder(Color(red: 1.0, green: 0.1, blue: 0.1), lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
                    .padding(12)
            }
        )
    }
}

struct LoadingPill: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(spacing: 3) {
                ForEach(0..<13, id: \.self) { index in
                    LoadingBar(index: index, time: time, totalBars: 13)
                }
            }
        }
        .padding(12)
        .frame(width: 140 + 24, height: 56 + 24)
        .background(
            ZStack {
                // Subtle outer glow
                Capsule()
                    .fill(Color.orange.opacity(0.2))
                    .blur(radius: 5)
                    .padding(10)

                // Main pill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.15), Color(white: 0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.15), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.orange, lineWidth: 2.5)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
                    .padding(12)
            }
        )
    }
}

struct LoadingBar: View {
    let index: Int
    let time: TimeInterval
    let totalBars: Int

    private var shapeMultiplier: CGFloat {
        let distFromEdge = min(index, totalBars - 1 - index)
        return distFromEdge == 0 ? 0.4 : (distFromEdge == 1 ? 0.7 : 1.0)
    }

    private var sweepPos: Double {
        let cycleTime = time.truncatingRemainder(dividingBy: 2.0)
        return cycleTime < 1.0 ? cycleTime : 2.0 - cycleTime
    }

    var body: some View {
        let normalizedPos = Double(index) / Double(totalBars - 1)
        let distance = abs(normalizedPos - sweepPos)
        let intensity = exp(-distance * distance * 20) * 0.7 + 0.3

        let baseHeight: CGFloat = 6
        let maxHeight: CGFloat = 28
        let height = baseHeight + maxHeight * CGFloat(intensity) * shapeMultiplier

        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.orange)
            .frame(width: 5, height: height)
    }
}

struct ResultPill: View {
    let message: String
    let isError: Bool

    private var accentColor: Color {
        isError ? .red : .green
    }

    var body: some View {
        HStack(spacing: 8) {
            if isError {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.red)
                Text(message)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                Text(message)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(12)
        .frame(width: 140 + 24, height: 56 + 24)
        .background(
            ZStack {
                // Subtle outer glow
                Capsule()
                    .fill(accentColor.opacity(0.2))
                    .blur(radius: 5)
                    .padding(10)

                // Main pill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.15), Color(white: 0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.15), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(accentColor, lineWidth: 2.5)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
                    .padding(12)
            }
        )
    }
}

struct WaveformBar: View {
    let index: Int
    let smoothedLevel: CGFloat
    let time: TimeInterval
    let totalBars: Int

    // Center-biased shape with hard cap on edges
    private var shapeMultiplier: CGFloat {
        let distFromEdge = min(index, totalBars - 1 - index)

        // Edge bars hard capped
        if distFromEdge == 0 {
            return 0.3  // 30% for outermost
        }
        if distFromEdge == 1 {
            return 0.5  // 50% for second from edge
        }
        if distFromEdge == 2 {
            return 0.75  // 75% for third from edge
        }
        // Center bars
        return 1.0
    }

    var body: some View {
        let baseHeight: CGFloat = 6
        let maxHeight: CGFloat = 18  // Bumped up a bit

        // 3 overlapping waves with irrational-ish ratios - creates pseudo-random motion
        let f1: [Double] = [1.1, 1.3, 1.0, 1.4, 0.9, 1.35, 1.15, 1.45, 1.05, 1.25, 0.95, 1.2, 1.08]
        let f2: [Double] = [1.7, 2.1, 1.9, 2.3, 1.8, 2.2, 2.0, 2.4, 1.85, 2.15, 1.75, 2.05, 1.95]
        let f3: [Double] = [0.6, 0.8, 0.7, 0.85, 0.55, 0.75, 0.65, 0.9, 0.58, 0.72, 0.62, 0.78, 0.68]

        let p1 = Double(index) * 2.39
        let p2 = Double(index) * 1.47
        let p3 = Double(index) * 3.82

        // Combine 3 waves - creates complex, non-repeating pattern
        let wave1 = sin(time * f1[index % 13] + p1)
        let wave2 = sin(time * f2[index % 13] + p2)
        let wave3 = sin(time * f3[index % 13] + p3)

        // Combined wave ranges roughly -1 to 1 but with complex motion
        let combinedWave = (wave1 * 0.5 + wave2 * 0.3 + wave3 * 0.2)

        // IDLE: Flowing wave offset with smaller bars
        let idleOffset = sin(time * 0.8 * .pi * 2 + Double(index) * 0.25) * 6.0
        let idleHeight: CGFloat = 5.0

        // ACTIVE: Apply shapeMultiplier to EVERYTHING including chaos
        let audioBase = maxHeight * smoothedLevel
        let chaos = CGFloat(combinedWave) * 12.0 * smoothedLevel
        let activeHeight = (baseHeight + audioBase + chaos) * shapeMultiplier

        // Blend
        let blend = min(smoothedLevel * 3.0, 1.0)
        let height = max(baseHeight * 0.3, idleHeight * (1.0 - blend) + activeHeight * blend)
        let yOffset = idleOffset * (1.0 - Double(blend))

        RoundedRectangle(cornerRadius: 2)
            .fill(Color.red)
            .frame(width: 5, height: height)
            .offset(y: CGFloat(yOffset))
    }
}

#Preview {
    VStack(spacing: 20) {
        WaveformPill(audioLevel: 0.2)
            .frame(width: 140, height: 56)
        WaveformPill(audioLevel: 0.8)
            .frame(width: 140, height: 56)
        LoadingPill()
            .frame(width: 140, height: 56)
        ResultPill(message: "156 WPM", isError: false)
            .frame(width: 140, height: 56)
    }
    .padding(40)
    .background(Color.gray.opacity(0.3))
}
