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

// Serialises a dictionary as a single JSON line and appends to the log.
// All capture events use this so downstream tooling gets consistent structure.
func logJSON(_ entry: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys),
          let line = String(data: data, encoding: .utf8) else { return }
    log(line)
}

// Writes a full-content payload to the current session's turn file for the classifier LLM.
// Routes to /tmp/palah-sessions/<session_id>/turn-NNN.ndjson using the session_id already
// present in the entry. Returns a payload_id UUID embedded in the compact palah.log entry.
@discardableResult
func logPayload(_ entry: [String: Any]) -> String {
    let id        = UUID().uuidString
    var full      = entry
    full["payload_id"] = id

    let sessionId = entry["session_id"] as? String ?? ""
    let app       = entry["app"]        as? String ?? "unknown"
    let path: String
    if !sessionId.isEmpty {
        path = sessions.payloadPath(sessionId: sessionId, app: app)
    } else {
        // Fallback: no session_id (should not happen after AX/browser wiring)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let slug = SessionManager.slug(for: app)
        let dir  = "\(sessionBaseDir)/\(slug)"
        sessions.ensureDir(dir)
        path = "\(dir)/ax-\(fmt.string(from: Date())).ndjson"
    }

    guard let data = try? JSONSerialization.data(withJSONObject: full, options: .sortedKeys),
          let line = String(data: data, encoding: .utf8) else { return id }
    let bytes = (line + "\n").data(using: .utf8)!
    if FileManager.default.fileExists(atPath: path),
       let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile(); fh.write(bytes); fh.closeFile()
    } else {
        try? bytes.write(to: URL(fileURLWithPath: path))
    }
    return id
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

// MARK: - AI Tool Domain List
// Single source of truth — mirrors extensions/chrome-extension/manifest.json host_permissions.
// Add new AI tool domains here AND in the extension manifest to keep both in sync.

let aiToolDomains: Set<String> = [
    "chatgpt.com",
    "claude.ai",
    "gemini.google.com",
    "perplexity.ai",
    "www.perplexity.ai",
    "grok.com",
    "x.com",
    "deepseek.com",
    "chat.deepseek.com",
    "copilot.microsoft.com",
    "www.bing.com",
    "meta.ai",
    "poe.com",
    "you.com",
    "character.ai",
    "mistral.ai",
    "chat.mistral.ai",
    "huggingface.co",
]

// MARK: - Safari
// Uses WebKit's native AX tree — no special activation or extra permissions needed.
// URL-gated via kAXURLAttribute on the AXWebArea element: only reads text when the
// current page hostname is in aiToolDomains. Mirrors Chrome extension domain scoping.

struct SafariInterceptor: PromptInterceptor {
    let name = "Safari"

    func canHandle(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        return id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview"
    }

    func read(from app: NSRunningApplication) -> (text: String?, role: String) {
        let appEl = axAppElement(for: app)

        var winObj: AnyObject?
        let searchRoot: AXUIElement
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winObj) == .success,
           let win = winObj { searchRoot = win as! AXUIElement }
        else { searchRoot = appEl }

        guard let webArea = findWebArea(in: searchRoot, depth: 0),
              let host = webAreaHost(webArea),
              aiToolDomains.contains(host) else { return (nil, "") }

        // Read directly from the prompt input element rather than the focused element.
        // This lets us detect the field clearing immediately after submit, even when
        // focus has moved to the response area (AXGroup) or send button (AXButton).
        if let inputEl = findEditableTextArea(in: webArea) {
            return (textFrom(inputEl), "AXTextArea")
        }

        return (nil, "")
    }

    // Searches the web area for the first editable AXTextArea — the prompt input.
    // AI tool pages typically have one editable text area: the prompt input.
    private func findEditableTextArea(in el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }
        var roleObj: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleObj)
        if (roleObj as? String) == "AXTextArea" {
            var enabled: AnyObject?
            // kAXEnabledAttribute filters out read-only text areas
            if AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &enabled) == .success,
               (enabled as? Bool) == true { return el }
        }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let childList = children as? [AXUIElement] else { return nil }
        for child in childList {
            if let found = findEditableTextArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    // Reads kAXURLAttribute from an AXWebArea element.
    private func webAreaHost(_ webArea: AXUIElement) -> String? {
        var obj: AnyObject?
        guard AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &obj) == .success,
              let obj else { return nil }
        let urlStr: String?
        if let url = obj as? URL         { urlStr = url.absoluteString }
        else if let url = obj as? NSURL  { urlStr = url.absoluteString }
        else                             { urlStr = obj as? String }
        guard let urlStr, let host = URLComponents(string: urlStr)?.host else { return nil }
        return host
    }

    private func findWebArea(in el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 8 else { return nil }
        var roleObj: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleObj)
        if (roleObj as? String) == "AXWebArea" { return el }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let childList = children as? [AXUIElement] else { return nil }
        for child in childList {
            if let found = findWebArea(in: child, depth: depth + 1) { return found }
        }
        return nil
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
    "com.anthropic.claudefordesktop",   // Claude Desktop (Electron)
    "com.openai.chat",                   // ChatGPT Desktop (Electron)
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
    "notion.id",                         // Notion (native, no AXManualAccessibility needed)
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
// AX roles that represent editable text inputs. Only these update lastText.
// Responses and containers (AXGroup, AXScrollArea, AXStaticText) are excluded.
private let textInputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

// Known placeholder strings across major AI tools. Add new ones as discovered.
private let knownPlaceholders: Set<String> = [
    "Ask anything",           // ChatGPT
    "Message ChatGPT",        // ChatGPT
    "Reply to Claude...",     // Claude.ai
    "Enter a prompt here",    // Gemini
    "Message Gemini",         // Gemini
    "Ask Perplexity",         // Perplexity
]

private func isPlaceholder(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty || t.hasSuffix("…") || t.contains("⌘") || knownPlaceholders.contains(t)
}

// MARK: - AccessibilityReader

class AccessibilityReader {
    // Registry — evaluated top-to-bottom, first match wins.
    // GenericAXInterceptor must stay last.
    private let interceptors: [PromptInterceptor] = [
        VSCodeFamilyInterceptor(),
        SafariInterceptor(),
        NativeAIAppInterceptor(),
        GenericAXInterceptor(),
    ]

    private var lastText = ""
    private var lastCaptured = ""   // last text we actually logged (dedup)
    private var lastAppName = ""
    private var lastRole = ""
    private var lastInputRole = ""  // role when user was last actively typing
    private var wasInInput = false  // was previous tick focused on a text input role?
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
            lastInputRole = ""
            lastText = ""
            wasInInput = false
        }

        if !role.isEmpty, role != lastRole {
            log("[\(timestamp())]   field: \(role)")
            lastRole = role
        }

        let captured = text ?? ""
        let inInput  = textInputRoles.contains(role)

        // Require at least 3 chars to avoid false submits from backspace (e.g. "l", "lo").
        let hadContent = !isPlaceholder(lastText)
                      && lastText != lastCaptured
                      && lastText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3

        // Submit detection — two patterns:
        // A) Field clears while still focused (VS Code chat, ChatGPT web)
        // B) Focus leaves the input entirely (Claude Desktop: AXTextArea → AXButton → AXWebArea)
        if hadContent {
            let fieldCleared = inInput  && isPlaceholder(captured)
            let leftInput    = !inInput && wasInInput
            if fieldCleared || leftInput {
                let text  = lastText
                let words = text.split(separator: " ").count
                // Datetime pseudo-session: each AX capture gets a unique session (no app-provided ID).
                // Prefixed "ax-" so AX sessions are visually distinct from hook-based UUID sessions
                // in the same app folder (e.g. cursor/ax-20260629-143200 vs cursor/35c770d6-...).
                let tsFmt = DateFormatter(); tsFmt.dateFormat = "yyyyMMdd-HHmmss"
                let pseudoSessionId = "ax-\(tsFmt.string(from: Date()))"
                // FUTURE: For Safari (and Chrome when not using the extension), enrich the session
                // with file attachment metadata by walking the AX tree for file-upload UI elements
                // (e.g. AXButton with label containing "attach" or "upload", AXStaticText with
                // filenames). Currently attachments are always empty for AX-captured sessions.
                sessions.openSession(sessionId: pseudoSessionId, app: appName, meta: [
                    "source": "ax", "interceptor": interceptor.name,
                ])
                sessions.advanceTurn(sessionId: pseudoSessionId, app: appName)
                let pid = logPayload([
                    "ts":         timestamp(),
                    "event":      "submit",
                    "source":     "ax",
                    "app":        appName,
                    "session_id": pseudoSessionId,
                    "words":      words,
                    "text":       text,
                ])
                sessions.recordPrompt(sessionId: pseudoSessionId, words: words,
                                      model: "", payloadId: pid)
                logJSON([
                    "ts":          timestamp(),
                    "event":       "submit",
                    "source":      "ax",
                    "app":         appName,
                    "session_id":  pseudoSessionId,
                    "interceptor": interceptor.name,
                    "role":        lastInputRole,
                    "words":       words,
                    "preview":     String(text.prefix(120)),
                ])
                lastCaptured = text
            }
        }

        // Only update lastText when focused on an input — freeze it while in response area
        // so the prompt survives until we can detect the submit.
        if inInput {
            lastText = captured
            lastInputRole = role
        }
        wasInInput = inInput
    }

}
