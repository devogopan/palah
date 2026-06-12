//
//  AccessibilityReader.swift
//  Palah
//
//  Created by Gopakumar N on 03/06/26.
//
//  Handles prompt interception for native macOS apps and IDE AI plugins via the
//  Accessibility API. Browser-based AI tools (ChatGPT, Gemini, Claude.ai, etc.)
//  are handled by the Palah Chrome extension (palah-extension/).

import Cocoa
import ApplicationServices

// MARK: - Logging

let logPath = "/tmp/palah.log"

func log(_ message: String) {
    print(message)
    let line = message + "\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: logPath),
       let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: logPath))
    }
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - PromptInterceptor Protocol
//
// To add support for a new native app:
//   1. Create a struct conforming to PromptInterceptor
//   2. Implement canHandle() — return true for the relevant bundle IDs
//   3. Implement read() — return (text, role) for the focused element
//   4. Register it in AccessibilityReader.interceptors before GenericAXInterceptor

protocol PromptInterceptor {
    var name: String { get }
    func canHandle(_ app: NSRunningApplication) -> Bool
    func read(from app: NSRunningApplication) -> (text: String?, role: String)
}

// MARK: - Shared AX Helpers

private func axAppElement(for app: NSRunningApplication) -> AXUIElement {
    AXUIElementCreateApplication(app.processIdentifier)
}

private func focusedElement(in target: AXUIElement) -> AXUIElement? {
    var el: AnyObject?
    guard AXUIElementCopyAttributeValue(target, kAXFocusedUIElementAttribute as CFString, &el) == .success,
          let element = el else { return nil }
    return (element as! AXUIElement)
}

private func role(of el: AXUIElement) -> String {
    var r: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
    return r as? String ?? ""
}

// Reads text from an AX element.
// Tries kAXValueAttribute → kAXSelectedTextAttribute → child traversal.
// Child traversal handles editors that store text in nested AXStaticText children
// (e.g. VS Code chat panels using ProseMirror-style rendering).
private func textFrom(_ el: AXUIElement, depth: Int = 0) -> String? {
    var value: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
       let text = value as? String, !text.isEmpty { return text }

    var selected: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selected) == .success,
       let text = selected as? String, !text.isEmpty { return text }

    guard depth < 5 else { return nil }
    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
          let childList = children as? [AXUIElement] else { return nil }

    let parts = childList.compactMap { textFrom($0, depth: depth + 1) }
    let joined = parts.joined(separator: "\n")
    return joined.isEmpty ? nil : joined
}

// MARK: - VS Code Family (AI coding assistants)
// Covers: VS Code (Claude, Copilot, Cursor Chat), Cursor, Windsurf, Zed
// All are Electron-based; chat panels expose text via AXTextArea.

private let vscodeFamilyBundleIDs: Set<String> = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.todesktop.230313mzl4w4u92",    // Cursor
    "com.exafunction.windsurf",          // Windsurf
    "dev.zed.zed",                       // Zed
]

struct VSCodeFamilyInterceptor: PromptInterceptor {
    let name = "VSCode Family"

    func canHandle(_ app: NSRunningApplication) -> Bool {
        vscodeFamilyBundleIDs.contains(app.bundleIdentifier ?? "")
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, true as CFTypeRef)
        guard let el = focusedElement(in: appEl) else { return (nil, "") }
        return (textFrom(el), role(of: el))
    }
}

// MARK: - Native AI Apps
// Covers: Claude Desktop, ChatGPT Desktop, Notion AI, etc.
// Add new native AI apps here by extending the bundle ID list.

private let nativeAIAppBundleIDs: Set<String> = [
    "com.anthropic.claudefordesktop",   // Claude Desktop
    "com.openai.chat",                   // ChatGPT Desktop
    "notion.id",                         // Notion
]

struct NativeAIAppInterceptor: PromptInterceptor {
    let name = "Native AI"

    func canHandle(_ app: NSRunningApplication) -> Bool {
        nativeAIAppBundleIDs.contains(app.bundleIdentifier ?? "")
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)
        guard let el = focusedElement(in: appEl) else { return (nil, "") }
        return (textFrom(el), role(of: el))
    }
}

// MARK: - Generic AX Fallback
// Catches anything not handled above: specialist AI tools, Slack AI, legal/medical AI apps, etc.
// This always returns true so it must be last in the registry.

struct GenericAXInterceptor: PromptInterceptor {
    let name = "Generic"

    func canHandle(_ app: NSRunningApplication) -> Bool { true }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)
        guard let el = focusedElement(in: appEl) else { return (nil, "") }
        return (textFrom(el), role(of: el))
    }
}

// MARK: - Helpers

// Returns true for empty strings and VS Code-style hint/placeholder text.
// These appear after a submit: "Queue another message…", "⌘ Esc to focus…", etc.
private func isPlaceholder(_ text: String) -> Bool {
    text.isEmpty || text.hasSuffix("…") || text.contains("⌘")
}

// MARK: - AccessibilityReader

class AccessibilityReader {
    // Registry — evaluated top-to-bottom, first match wins.
    // GenericAXInterceptor must stay last.
    private let interceptors: [PromptInterceptor] = [
        VSCodeFamilyInterceptor(),
        NativeAIAppInterceptor(),
        GenericAXInterceptor(),
    ]

    private var lastText = ""
    private var lastCaptured = ""   // last text we actually logged (dedup)
    private var lastAppName = ""
    private var lastRole = ""
    private var timer: Timer?

    func start() {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        log("[\(timestamp())] Palah started — watching native AI apps and IDE plugins")

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard AXIsProcessTrusted() else {
                log("[\(timestamp())] waiting for Accessibility permission...")
                return
            }
            self.tick()
        }
    }

    private func tick() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appName = app.localizedName ?? "unknown"

        let interceptor = interceptors.first { $0.canHandle(app) }!
        let (text, role) = interceptor.read(from: app)

        if appName != lastAppName {
            log("[\(timestamp())] → \(appName)  [\(interceptor.name)]")
            lastAppName = appName
            lastRole = ""
            lastText = ""
        }

        if !role.isEmpty, role != lastRole {
            log("[\(timestamp())]   field: \(role)")
            lastRole = role
        }

        let captured = text ?? ""

        // Submit detection: field transitions from real user text to empty or placeholder text.
        // VS Code replaces typed text with hint text (ending in … or containing ⌘) on submit.
        if !isPlaceholder(lastText) && isPlaceholder(captured) && lastText != lastCaptured {
            log("[\(timestamp())] [submit] \(appName)")
            log("[\(timestamp())]   \(lastText.prefix(300))")
            lastCaptured = lastText
        }

        lastText = captured
    }

}
