import AppKit
import SwiftUI

/// Borderless panel that drops down from the status item. Unlike NSPopover it doesn't
/// activate SayStuff, so the app you were typing in stays frontmost.
@MainActor
final class MenuPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let panel: Panel
    private let host: NSHostingView<AnyView>
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private weak var anchor: NSStatusBarButton?
    private let makeContent: (@escaping (CGFloat) -> Void, CGFloat) -> AnyView

    var isShown: Bool { panel.isVisible }

    init<Content: View>(@ViewBuilder content: @escaping (_ resize: @escaping (CGFloat) -> Void, _ maximumHeight: CGFloat) -> Content) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: MenuBarView.width, height: 400),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        makeContent = { resize, maximumHeight in AnyView(content(resize, maximumHeight)) }
        host = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = host
        host.rootView = makeContent({ [weak self] height in self?.setHeight(height) }, 720)
    }

    func toggle(from button: NSStatusBarButton) {
        isShown ? close() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        let availableHeight = max(160, (button.window?.screen?.visibleFrame.height ?? 800) - 14)
        host.rootView = makeContent({ [weak self] height in self?.setHeight(height) }, availableHeight)
        let size = host.fittingSize
        panel.setContentSize(NSSize(width: MenuBarView.width, height: size.height))
        position()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.close()
                return nil
            }
            return event
        }
    }

    func close() {
        guard isShown else { return }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.panel.orderOut(nil) }
        })
    }

    private func setHeight(_ height: CGFloat) {
        guard height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height  // keep the top edge pinned under the menu bar
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func position() {
        guard let button = anchor, let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        var x = buttonFrame.midX - panel.frame.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - 6))
    }
}

/// Contextual learning feedback anchored to the corrected text, separate from the recording HUD.
@MainActor
final class StatusBanner {
    private let panel: NSPanel
    private let bracketPanel: NSPanel
    private var hideWork: DispatchWorkItem?
    private var dismissalMonitor: Any?
    private var generation = UUID()

    init() {
        panel = Self.makePanel()
        bracketPanel = Self.makePanel()
        bracketPanel.ignoresMouseEvents = true
        bracketPanel.hasShadow = false
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    func show(term: String, heardAs heard: String, near word: NSRect?, highlight: NSRect?, field: NSRect?,
              duration: TimeInterval = 6, undo: @escaping () -> Void) {
        hideWork?.cancel()
        if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
        dismissalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        generation = UUID()
        let host = NSHostingView(rootView: DictionaryNoticeView(term: term, heardAs: heard) { [weak self] in
            undo()
            self?.hide()
        })
        panel.contentView = host
        let anchor = word ?? field ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let fitting = host.fittingSize
        let size = NSSize(width: min(fitting.width, visible.width - 24), height: fitting.height)
        panel.setContentSize(size)
        panel.setFrame(Self.noticeFrame(size: size, near: anchor, within: visible), display: false)

        if let highlight, highlight.intersects(visible) {
            bracketPanel.contentView = NSHostingView(rootView: CorrectionBracket().stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).padding(1))
            bracketPanel.setFrame(highlight.insetBy(dx: -4, dy: -3), display: false)
            bracketPanel.alphaValue = 1
            bracketPanel.orderFrontRegardless()
        } else {
            bracketPanel.orderOut(nil)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Prefer directly below the word; flip above it at the bottom of the screen.
    static func noticeFrame(size: NSSize, near anchor: NSRect, within visible: NSRect) -> NSRect {
        let gap: CGFloat = 8
        let margin: CGFloat = 12
        let x = min(max(anchor.minX - 4, visible.minX + margin), visible.maxX - size.width - margin)
        let below = anchor.minY - gap - size.height
        let y = below >= visible.minY + margin ? below : anchor.maxY + gap
        return NSRect(x: x, y: min(max(y, visible.minY + margin), visible.maxY - size.height - margin),
                      width: size.width, height: size.height)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
        dismissalMonitor = nil
        guard panel.isVisible || bracketPanel.isVisible else { return }
        let expected = generation
        NSAnimationContext.runAnimationGroup({
            $0.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 0
            bracketPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                self.panel.orderOut(nil)
                self.bracketPanel.orderOut(nil)
            }
        })
    }
}

/// Two small brackets identify the corrected word without covering its letters.
private struct CorrectionBracket: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(6, rect.width / 3)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        return path
    }
}

private struct DictionaryNoticeView: View {
    let term: String
    let heardAs: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(heardAs).foregroundStyle(Theme.textSecondary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text(term).fontWeight(.semibold)
                }
                .font(.system(size: 12.5))
                .lineLimit(1)
                Text("Added to Dictionary")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Button("Undo", action: undo)
                .buttonStyle(PillButtonStyle())
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 8)
        .glassSurface(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Added \(term) to Dictionary, heard as \(heardAs)")
    }
}
