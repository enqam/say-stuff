import Cocoa
import SwiftUI

class RecordingOverlay {
    private var window: NSWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var viewModel = RecordingOverlayViewModel()

    // Window is bigger to give room for animation/borders
    private let windowWidth: CGFloat = 180
    private let windowHeight: CGFloat = 80

    func show(state: RecordingState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Reset state immediately WITHOUT animation
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.viewModel.state = state
                self.viewModel.message = ""
                self.viewModel.audioLevel = 0.0
            }

            if self.window == nil {
                self.createWindow()
            }
            self.window?.orderFront(nil)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.window?.orderOut(nil)
        }
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
}

struct RecordingOverlayView: View {
    @ObservedObject var viewModel: RecordingOverlayViewModel

    private let pillWidth: CGFloat = 140
    private let pillHeight: CGFloat = 56

    var body: some View {
        ZStack {
            switch viewModel.state {
            case .recording:
                WaveformPill(audioLevel: viewModel.audioLevel)
                    .transition(.opacity)
            case .transcribing:
                LoadingPill()
                    .transition(.opacity)
            case .success:
                ResultPill(message: viewModel.message, isError: false)
                    .transition(.opacity)
            case .error:
                ResultPill(message: viewModel.message, isError: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
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
                withAnimation(.easeOut(duration: 0.6)) {
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

    private var shapeMultiplier: CGFloat {
        let distFromEdge = min(index, totalBars - 1 - index)
        if distFromEdge == 0 {
            return 0.4  // Outermost bars
        } else if distFromEdge == 1 {
            return 0.7  // Second from edge
        } else {
            return 1.0  // Center bars
        }
    }

    var body: some View {
        let baseHeight: CGFloat = 8
        let maxHeight: CGFloat = 30  // Reduced to ensure margin from edges

        // Per-bar amplitude multipliers - tighter range for more consistency
        let amplitudes: [Double] = [0.75, 0.85, 0.8, 0.95, 0.85, 0.9, 0.8, 0.95, 0.85, 0.9, 0.8, 0.85, 0.75]
        let amplitude = amplitudes[index % amplitudes.count]

        // Continuous phase for smooth wave
        let phase = Double(index) * 0.9

        // IDLE: Smooth continuous traveling wave - more pronounced valleys
        let idleWave = sin(time * 2.5 + phase) * 0.5 + 0.5
        let idleHeight = baseHeight * 0.5 + 6.0 * CGFloat(idleWave) * shapeMultiplier

        // ACTIVE: Gentler variation for more consistent look
        let activeSpeed = 1.0 + Double(index % 5) * 0.15
        let activeWave = sin(time * activeSpeed + phase * 1.5) * 0.5 + 0.5
        let activeHeight = baseHeight + maxHeight * CGFloat(amplitude) * CGFloat(0.7 + activeWave * 0.3) * shapeMultiplier

        // Blend between idle and active based on audio level
        let height = idleHeight + (activeHeight - idleHeight) * smoothedLevel

        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.red)
            .frame(width: 5, height: height)
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
