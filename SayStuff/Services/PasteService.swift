import Cocoa
import Carbon.HIToolbox
import ApplicationServices

class PasteService {
    private let pasteboard = NSPasteboard.general
    private let hasShownAccessibilityWarningKey = "HasShownAccessibilityPasteWarning"

    func pasteText(_ text: String) {
        // If we don't have Accessibility access, we can't simulate Cmd+V.
        // Fall back to copying the text so the user can paste manually.
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            showAccessibilityWarningOnce()
            return
        }

        // Save current clipboard
        let savedItems = savePasteboard()

        // Set new text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure pasteboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            // Simulate Cmd+V
            self?.simulatePaste()

            // Restore clipboard after paste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.restorePasteboard(savedItems)
            }
        }
    }

    private func savePasteboard() -> [NSPasteboardItem] {
        var items: [NSPasteboardItem] = []

        for item in pasteboard.pasteboardItems ?? [] {
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            items.append(newItem)
        }

        return items
    }

    private func restorePasteboard(_ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private func simulatePaste() {
        // Create Cmd+V key event
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func showAccessibilityWarningOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: hasShownAccessibilityWarningKey) else { return }
        defaults.set(true, forKey: hasShownAccessibilityWarningKey)

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Enable Accessibility to paste automatically"
            alert.informativeText = """
SayStuff copied the transcription to your clipboard.

To auto‑paste into the active app, enable Accessibility for SayStuff in System Settings → Privacy & Security → Accessibility.
"""
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
