//
//  AccessibilityReader.swift
//  Palah
//
//  Created by Gopakumar N on 03/06/26.
//

import Cocoa
import ApplicationServices

private let logPath = "/tmp/palah.log"

private func log(_ message: String) {
    print(message)
    let line = message + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: logPath),
       let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

class AccessibilityReader {
    private var lastText = ""
    private var timer: Timer?

    func start() {
        log("Palah started")
        // Show the permission prompt once — user grants it in System Settings
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            guard AXIsProcessTrusted() else {
                log("[waiting] Accessibility permission not yet granted")
                return
            }

            let text = self.focusedElementValue() ?? ""
            guard text != self.lastText else { return }
            self.lastText = text
            if !text.isEmpty {
                log("--- Captured ---\n\(text)\n")
            }
        }
    }

    private func focusedElementValue() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            log("[debug] no frontmost app")
            return nil
        }

        log("[debug] frontmost app: \(frontApp.localizedName ?? "unknown") (pid: \(frontApp.processIdentifier))")

        let appEl = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Force-enable accessibility tree for Chromium-based browsers (Chrome, Edge, Brave)
        // Chrome disables its AX tree by default; this is a no-op for other apps
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, true as CFTypeRef)

        var focusedEl: AnyObject?
        let elResult = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedEl)
        guard elResult == .success, let el = focusedEl else {
            log("[debug] no focused element — AXError: \(elResult.rawValue)")
            return nil
        }

        var role: AnyObject?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &role)
        log("[debug] role: \(role as? String ?? "unknown")")

        // Try standard value attribute
        var value: AnyObject?
        if AXUIElementCopyAttributeValue(el as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String, !text.isEmpty {
            return text
        }

        // Fallback: selected text (works for some contenteditable elements)
        var selected: AnyObject?
        if AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let text = selected as? String, !text.isEmpty {
            log("[debug] captured via selectedText fallback")
            return text
        }

        log("[debug] no value from this element")
        return nil
    }
}
