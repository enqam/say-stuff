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

    var isShown: Bool { panel.isVisible }

    init<Content: View>(@ViewBuilder content: (_ resize: @escaping (CGFloat) -> Void) -> Content) {
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

        var resize: (CGFloat) -> Void = { _ in }
        host = NSHostingView(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(content({ resize($0) }))
        panel.contentView = host
        resize = { [weak self] height in self?.setHeight(height) }
    }

    func toggle(from button: NSStatusBarButton) {
        isShown ? close() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
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

/// Small notice under the status item ("Added “Cerebras” to Dictionary · Undo").
/// Separate from the recording pill so it's visible after the pill is gone.
@MainActor
final class StatusBanner {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    func show(_ message: String, symbol: String, actionTitle: String? = nil, below button: NSStatusBarButton?,
              duration: TimeInterval = 5, action: (() -> Void)? = nil) {
        hideWork?.cancel()
        let host = NSHostingView(rootView: BannerView(message: message, symbol: symbol, actionTitle: actionTitle) { [weak self] in
            action?()
            self?.hide()
        })
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)

        if let button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            var x = anchor.midX - size.width / 2
            if let visible = window.screen?.visibleFrame {
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            }
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
                                                 Task { @MainActor in self?.panel.orderOut(nil) }
                                             })
    }
}

private struct BannerView: View {
    let message: String
    let symbol: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, actionTitle == nil ? 14 : 7)
        .padding(.vertical, 7)
        .glassSurface(Capsule())
    }
}
