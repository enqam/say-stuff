import Cocoa

/// Lightweight red border around the screen during recording.
/// Dynamically adapts to screen contours using macOS APIs:
/// - MacBook with notch: rounded top corners + notch cutout
/// - External monitor: simple rectangle
class ScreenBorderOverlay {
    private var window: NSWindow?
    private let borderWidth: CGFloat = 4.0
    private let borderColor = NSColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1.0)

    func show() {
        guard window == nil else { return }

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Create border view with screen-specific contours
        let borderView = ScreenContourBorderView(frame: NSRect(origin: .zero, size: screenFrame.size))
        borderView.borderWidth = borderWidth
        borderView.borderColor = borderColor
        borderView.configureForScreen(screen)
        window.contentView = borderView

        window.setFrame(screenFrame, display: true)
        window.orderFront(nil)

        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

/// View that draws a border following the actual screen contours
private class ScreenContourBorderView: NSView {
    var borderWidth: CGFloat = 4.0
    var borderColor: NSColor = .red

    // Notch geometry (calculated from NSScreen APIs)
    private var hasNotch: Bool = false
    private var notchLeftX: CGFloat = 0      // Where notch starts (from left)
    private var notchRightX: CGFloat = 0     // Where notch ends (from left)
    private var notchHeight: CGFloat = 0     // How deep the notch goes
    private var topCornerRadius: CGFloat = 0 // Radius for top corners

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configure the border based on actual screen properties
    func configureForScreen(_ screen: NSScreen) {
        if #available(macOS 12.0, *) {
            // Check if this screen has a notch
            let safeTop = screen.safeAreaInsets.top
            if safeTop > 0,
               let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea {
                // This screen has a notch - calculate its exact geometry
                hasNotch = true

                // Convert from screen coordinates to view coordinates
                // auxiliaryTopLeftArea.maxX is where the notch starts
                // auxiliaryTopRightArea.minX is where the notch ends
                let screenFrame = screen.frame

                // The auxiliary areas are in screen coordinates, we need relative positions
                notchLeftX = leftArea.maxX - screenFrame.minX
                notchRightX = rightArea.minX - screenFrame.minX
                notchHeight = safeTop

                // Top corner radius - approximately matches the notch corner curve
                // The notch corners are about 8-10 points radius, screen corners slightly larger
                topCornerRadius = safeTop / 2.5
            } else {
                // No notch (external monitor or older Mac)
                hasNotch = false
            }
        } else {
            // Pre-macOS 12 - assume no notch
            hasNotch = false
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let inset = borderWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)

        let path: NSBezierPath

        if hasNotch {
            path = createNotchedPath(in: rect)
        } else {
            // Simple rectangle for external monitors
            path = NSBezierPath(rect: rect)
        }

        path.lineWidth = borderWidth
        borderColor.setStroke()
        path.stroke()
    }

    private func createNotchedPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let r = topCornerRadius

        // Notch corner radius (slightly smaller than screen corners)
        let nr = r * 0.8

        // Start at bottom-left (no rounding on bottom)
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))

        // Bottom edge
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))

        // Right edge up to top-right corner
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))

        // Top-right corner
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: 0,
            endAngle: 90,
            clockwise: false
        )

        // Top edge to notch (right side)
        path.line(to: NSPoint(x: notchRightX + nr, y: rect.maxY))

        // Notch: curve down into notch (right side)
        path.appendArc(
            withCenter: NSPoint(x: notchRightX + nr, y: rect.maxY - nr),
            radius: nr,
            startAngle: 90,
            endAngle: 180,
            clockwise: false
        )

        // Notch: right edge going down
        path.line(to: NSPoint(x: notchRightX, y: rect.maxY - notchHeight + nr))

        // Notch: bottom-right corner
        path.appendArc(
            withCenter: NSPoint(x: notchRightX - nr, y: rect.maxY - notchHeight + nr),
            radius: nr,
            startAngle: 0,
            endAngle: -90,
            clockwise: true
        )

        // Notch: bottom edge
        path.line(to: NSPoint(x: notchLeftX + nr, y: rect.maxY - notchHeight))

        // Notch: bottom-left corner
        path.appendArc(
            withCenter: NSPoint(x: notchLeftX + nr, y: rect.maxY - notchHeight + nr),
            radius: nr,
            startAngle: -90,
            endAngle: 180,
            clockwise: true
        )

        // Notch: left edge going up
        path.line(to: NSPoint(x: notchLeftX, y: rect.maxY - nr))

        // Notch: curve back to top edge (left side)
        path.appendArc(
            withCenter: NSPoint(x: notchLeftX - nr, y: rect.maxY - nr),
            radius: nr,
            startAngle: 0,
            endAngle: 90,
            clockwise: false
        )

        // Top edge to top-left corner
        path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))

        // Top-left corner
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: 90,
            endAngle: 180,
            clockwise: false
        )

        // Left edge back to start
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))

        path.close()
        return path
    }
}
