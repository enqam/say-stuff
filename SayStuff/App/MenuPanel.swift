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
