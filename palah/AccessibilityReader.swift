//
//  AccessibilityReader.swift
//  Palah
//
//  Created by Gopakumar N on 03/06/26.
//

import Cocoa
import ApplicationServices

// MARK: - Logging

private let logPath = "/tmp/palah.log"

private func log(_ message: String) {
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

// MARK: - PromptInterceptor Protocol
//
// To add support for a new app or browser:
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

private func windows(of appEl: AXUIElement) -> [AXUIElement] {
    var w: AnyObject?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &w) == .success,
          let list = w as? [AXUIElement] else { return [] }
    return list
}

// Reads text from an AX element.
// Tries: kAXValueAttribute → kAXSelectedTextAttribute → child traversal.
// Child traversal handles browser contenteditable divs (ChatGPT, Gemini, Claude.ai, etc.)
// which use ProseMirror/Quill and store text in nested AXStaticText children.
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

// Searches app → windows for a focused element with text.
// The window-level search is what exposes browser contenteditable elements.
private func readFromAXTree(appEl: AXUIElement) -> (text: String?, role: String) {
    var bestRole = ""
    for target in ([appEl] + windows(of: appEl)) {
        guard let el = focusedElement(in: target) else { continue }
        let r = role(of: el)
        if !r.isEmpty { bestRole = r }
        if let text = textFrom(el) { return (text, r) }
    }
    return (nil, bestRole)
}

// Searches for an element with kAXFocusedAttribute = true by walking the AX tree.
// Used as a fallback when kAXFocusedUIElementAttribute doesn't work (e.g. Firefox/Gecko).
// Skips container roles (Window, Application, ScrollArea) which are "focused" in the
// sense of being active, not in the sense of receiving text input.
// maxNodes caps traversal cost — ~200 nodes is typically enough to find a focused field.
private let containerRoles: Set<String> = ["AXWindow", "AXApplication", "AXSheet", "AXScrollArea", "AXSplitGroup"]

private func findFocusedByAttribute(in el: AXUIElement, remaining: inout Int, maxDepth: Int) -> AXUIElement? {
    guard remaining > 0, maxDepth > 0 else { return nil }
    remaining -= 1

    var roleObj: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleObj)
    let elRole = roleObj as? String ?? ""

    if !containerRoles.contains(elRole) {
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(el, kAXFocusedAttribute as CFString, &focused) == .success,
           (focused as? Bool) == true { return el }
    }

    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
          let childList = children as? [AXUIElement] else { return nil }

    for child in childList {
        if let found = findFocusedByAttribute(in: child, remaining: &remaining, maxDepth: maxDepth - 1) {
            return found
        }
    }
    return nil
}

// MARK: - Chromium Browsers
// Covers: Chrome, Brave, Microsoft Edge, Arc, Vivaldi
// Requires AXManualAccessibility = true to activate Chrome's AX tree.
// Uses window-level focused element + child traversal for contenteditable (ChatGPT, Gemini, etc.)

private let chromiumBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.canary",
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "company.thebrowser.Browser",       // Arc
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
]

struct ChromiumInterceptor: PromptInterceptor {
    let name = "Chromium"

    // Backs off after a permission denial; retries after 30 seconds in case user grants it.
    static var jsBlockedUntil: Date = .distantPast

    func canHandle(_ app: NSRunningApplication) -> Bool {
        chromiumBundleIDs.contains(app.bundleIdentifier ?? "")
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, true as CFTypeRef)

        // AX works for native Chrome elements (URL bar, find bar, etc.)
        var bestRole = ""
        for target in ([appEl] + windows(of: appEl)) {
            guard let el = focusedElement(in: target) else { continue }
            let r = role(of: el)
            if !r.isEmpty { bestRole = r }
            if let text = textFrom(el) { return (text, r) }
        }

        // AX can't reach web contenteditable (ChatGPT, Gemini, Claude.ai, etc.)
        // Fall back to JavaScript via AppleScript.
        // Requires: System Settings → Privacy & Security → Automation → Palah → Google Chrome ✓
        guard Date() > ChromiumInterceptor.jsBlockedUntil else { return (nil, bestRole) }

        if let text = readViaJS(appName: app.localizedName ?? "Google Chrome") {
            return (text, "web-input")
        }

        return (nil, bestRole)
    }

    private func readViaJS(appName: String) -> String? {
        let js = "document.activeElement.isContentEditable ? document.activeElement.innerText.trim() : ''"
        let src = "tell application \"\(appName)\" to execute active tab of front window javascript \"\(js)\""
        var err: NSDictionary?
        let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let e = err {
            let code = (e[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 {
                ChromiumInterceptor.jsBlockedUntil = Date().addingTimeInterval(30)
                log("[js] Automation permission denied — grant it in System Settings → Privacy & Security → Automation → Palah → Google Chrome (will retry in 30s)")
            } else {
                log("[js] error \(code): \(e[NSAppleScript.errorBriefMessage] ?? "unknown")")
            }
            return nil
        }
        let raw = result?.stringValue ?? ""
        log("[js] raw result: '\(raw)'")
        guard !raw.isEmpty else { return nil }
        return raw
    }
}

// MARK: - Safari
// Uses WebKit's native AX tree; standard queries work without special activation.

struct SafariInterceptor: PromptInterceptor {
    let name = "Safari"

    func canHandle(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        return id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview"
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        readFromAXTree(appEl: axAppElement(for: app))
    }
}

// MARK: - Firefox
// Firefox on macOS Sequoia does not expose its Gecko web content via the standard
// macOS Accessibility API. The AX tree is limited to window frame elements only,
// regardless of accessibility.force_disabled setting or AXObserver registration.
//
// Phase 2 fix: Firefox WebExtension that sends prompt text to a local Palah HTTP endpoint.
// This is the standard approach used by enterprise browser security tools for Firefox.

struct FirefoxInterceptor: PromptInterceptor {
    let name = "Firefox"

    func canHandle(_ app: NSRunningApplication) -> Bool {
        (app.bundleIdentifier ?? "").hasPrefix("org.mozilla")
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        // Firefox web content is not accessible via macOS AX API on Sequoia.
        // Interceptor placeholder — will be replaced by WebExtension in Phase 2.
        return (nil, "")
    }
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
// Catches anything not handled above: legal/medical/finance AI tools, Slack AI, etc.
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

// MARK: - AccessibilityReader

class AccessibilityReader {
    // Registry — evaluated top-to-bottom, first match wins.
    // GenericAXInterceptor must stay last.
    private let interceptors: [PromptInterceptor] = [
        ChromiumInterceptor(),
        SafariInterceptor(),
        FirefoxInterceptor(),
        VSCodeFamilyInterceptor(),
        NativeAIAppInterceptor(),
        GenericAXInterceptor(),
    ]

    private var lastText = ""
    private var lastAppName = ""
    private var lastRole = ""
    private var timer: Timer?

    func start() {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        log("[\(timestamp())] Palah started — watching for AI prompts")

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
        }

        if !role.isEmpty, role != lastRole {
            log("[\(timestamp())]   field: \(role)")
            lastRole = role
        }

        let captured = text ?? ""
        guard captured != lastText else { return }
        lastText = captured
        if !captured.isEmpty {
            log("[\(timestamp())]   captured: \(captured)")
        }
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
