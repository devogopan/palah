//
//  PromptServer.swift
//  Palah
//
//  Local HTTP server that receives prompt captures from the Chrome extension.
//  Listens on localhost:45678 — no TLS needed for loopback-only traffic.

import Foundation
import Network

class PromptServer {
    private var listener: NWListener?

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: 45678)
        } catch {
            log("[\(timestamp())] PromptServer: failed to bind port 45678 — \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                log("[\(timestamp())] PromptServer: listening on localhost:45678")
            }
        }
        listener?.start(queue: .global(qos: .background))
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .background))
        accumulate(conn: conn, buf: Data())
    }

    private func accumulate(conn: NWConnection, buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, _ in
            guard let self else { return }
            var buf = buf
            if let chunk { buf.append(chunk) }
            guard let raw = String(data: buf, encoding: .utf8) else { return }

            // Wait until headers are fully received
            guard let sepRange = raw.range(of: "\r\n\r\n") else {
                if !isComplete { self.accumulate(conn: conn, buf: buf) }
                return
            }

            let headers = String(raw[..<sepRange.lowerBound])
            let body    = String(raw[sepRange.upperBound...])

            // Check Content-Length to ensure body is complete
            var contentLength = 0
            for line in headers.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    let val = lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    contentLength = Int(val) ?? 0
                }
            }

            if body.utf8.count < contentLength && !isComplete {
                self.accumulate(conn: conn, buf: buf)
                return
            }

            let firstLine = headers.components(separatedBy: "\r\n").first ?? ""
            self.processRequest(firstLine: firstLine, body: body, conn: conn)
        }
    }

    // MARK: - Request processing

    private func processRequest(firstLine: String, body: String, conn: NWConnection) {
        let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type\r\n"

        let parts  = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : ""
        let path   = parts.count > 1 ? parts[1] : "/"

        if method == "OPTIONS" {
            respond("HTTP/1.1 204 No Content\r\n\(cors)\r\n", to: conn)
            return
        }

        if method == "GET" && path == "/health" {
            let payload = "{\"status\":\"ok\",\"server\":\"palah\",\"port\":45678}\n"
            respond("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n\(cors)\r\n\(payload)", to: conn)
            return
        }

        // POST /prompt — from Chrome extension
        if method == "POST",
           let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["type"] as? String) == "PROMPT_CAPTURED" {

            if (json["event_type"] as? String) == "ai_response" {
                // AI response: write to the existing turn file, no new session
                logAIResponse(json)
                respond("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\(cors)\r\n{}", to: conn)
            } else {
                // User prompt: create session+turn, return context for correlation
                let (sessionId, turn) = logCapture(json)
                let payload = "{\"session_id\":\"\(sessionId)\",\"turn\":\(turn)}\n"
                respond(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n\(cors)\r\n\(payload)",
                    to: conn
                )
            }
            return
        }

        // POST /hooks/cursor — from Cursor hooks (command type via shell script)
        if method == "POST" && path.hasPrefix("/hooks/cursor") {
            handleCursorHook(body: body, conn: conn, cors: cors)
            return
        }

        // POST /hooks/claude — from Claude Code hooks (http type, direct POST)
        if method == "POST" && path.hasPrefix("/hooks/claude") {
            handleClaudeCodeHook(body: body, conn: conn, cors: cors)
            return
        }

        respond("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\(cors)\r\n", to: conn)
    }

    private func respond(_ response: String, to conn: NWConnection) {
        conn.send(content: response.data(using: .utf8),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Cursor Hooks

    private func handleCursorHook(body: String, conn: NWConnection, cors: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            respondAllow(cors: cors, to: conn)
            return
        }

        // Common base fields present in all Cursor hook payloads (docs: cursor.com/docs/hooks#reference)
        let eventName     = json["hook_event_name"] as? String ?? detectCursorEvent(json)
        let sessionId     = json["conversation_id"] as? String
                         ?? json["session_id"]       as? String ?? ""
        let cursorVersion = json["cursor_version"]  as? String ?? "unknown"
        let model         = json["model"]           as? String ?? ""
        let userEmail     = json["user_email"]      as? String ?? ""
        let ts            = timestamp()

        // Base fields included in every log entry
        var base: [String: Any] = [
            "ts": ts, "source": "cursor_hook", "app": "Cursor",
            "session_id": sessionId, "cursor_version": cursorVersion,
        ]
        if !model.isEmpty     { base["model"]      = model }
        if !userEmail.isEmpty { base["user_email"] = userEmail }

        switch eventName {

        // ── Prompt ───────────────────────────────────────────────────────────

        case "beforeSubmitPrompt":
            sessions.openSession(sessionId: sessionId, app: "Cursor", meta: [
                "cursor_version": cursorVersion, "model": model, "user_email": userEmail,
            ])
            sessions.advanceTurn(sessionId: sessionId, app: "Cursor")
            let prompt = json["prompt"] as? String ?? ""
            let words  = prompt.split(separator: " ").count
            let pid    = logPayload(base.merging(["event": "submit", "words": words, "text": prompt]) { $1 })
            sessions.recordPrompt(sessionId: sessionId, words: words, model: model, payloadId: pid)
            logJSON(base.merging(["event": "submit", "words": words, "preview": String(prompt.prefix(120))]) { $1 })

        // ── Tool calls ───────────────────────────────────────────────────────

        case "preToolUse":
            var entry = base.merging([
                "event": "tool_pre",
                "tool":  json["tool_name"] as? String ?? "",
                "cwd":   json["cwd"]       as? String ?? "",
            ]) { $1 }
            if let input = json["tool_input"] {
                let inputStr: String
                if let s = input as? String {
                    inputStr = s
                } else if let d = try? JSONSerialization.data(withJSONObject: input),
                          let s = String(data: d, encoding: .utf8) { inputStr = s } else { inputStr = "" }
                if inputStr.count > 300 {
                    var payloadEntry = entry
                    payloadEntry["tool_input"] = input
                    entry["input_preview"] = String(inputStr.prefix(120))
                    entry["input_chars"]   = inputStr.count
                    entry["payload_id"]    = logPayload(payloadEntry)
                } else {
                    entry["input"] = input
                }
            }
            logJSON(entry)
            respondAllow(cors: cors, to: conn)
            return

        case "postToolUse":
            let toolName  = json["tool_name"] as? String ?? ""
            let durationMs = json["duration"] as? Int    ?? 0
            var entry = base.merging([
                "event": "tool_post", "tool": toolName, "duration_ms": durationMs,
            ]) { $1 }
            if let out = json["tool_output"] {
                var payloadEntry = entry; payloadEntry["tool_output"] = out
                let pid = logPayload(payloadEntry)
                let preview: String
                if let s = out as? String { preview = String(s.prefix(120)) }
                else if let d = try? JSONSerialization.data(withJSONObject: out),
                        let s = String(data: d, encoding: .utf8) { preview = String(s.prefix(120)) }
                else { preview = String("\(out)".prefix(120)) }
                entry["output_preview"] = preview
                entry["payload_id"]     = pid
                sessions.recordToolUse(sessionId: sessionId, tool: toolName,
                                       durationMs: durationMs, effort: "", payloadId: pid)
            }
            logJSON(entry)

        case "postToolUseFailure":
            logJSON(base.merging([
                "event": "tool_fail",
                "tool":  json["tool_name"] as? String ?? "",
                "error": json["error"]     as? String ?? "",
            ]) { $1 })

        // ── File access ──────────────────────────────────────────────────────

        case "beforeReadFile":
            let content = json["content"] as? String ?? ""
            var entry = base.merging([
                "event":           "file_read",
                "file":            json["file_path"] as? String ?? "",
                "content_chars":   content.count,
                "content_preview": String(content.prefix(120)),
            ]) { $1 }
            var payloadEntry = entry
            payloadEntry["content"] = content
            entry["payload_id"] = logPayload(payloadEntry)
            logJSON(entry)
            respondAllow(cors: cors, to: conn)
            return

        case "afterFileEdit":
            let editsStr: String
            if let e = json["edits"],
               let d = try? JSONSerialization.data(withJSONObject: e),
               let s = String(data: d, encoding: .utf8) { editsStr = s } else { editsStr = "" }
            var entry = base.merging([
                "event":         "file_edit",
                "file":          json["file_path"] as? String ?? "",
                "edits_chars":   editsStr.count,
                "edits_preview": String(editsStr.prefix(120)),
            ]) { $1 }
            var payloadEntry = entry
            if let e = json["edits"] { payloadEntry["edits"] = e }
            entry["payload_id"] = logPayload(payloadEntry)
            logJSON(entry)

        case "beforeTabFileRead":
            let content = json["content"] as? String ?? ""
            var entry = base.merging([
                "event":         "tab_file_read",
                "file":          json["file_path"] as? String ?? "",
                "content_chars": content.count,
            ]) { $1 }
            var payloadEntry = entry
            payloadEntry["content"] = content
            entry["payload_id"] = logPayload(payloadEntry)
            logJSON(entry)
            respondAllow(cors: cors, to: conn)
            return

        // ── Shell ────────────────────────────────────────────────────────────

        case "beforeShellExecution":
            let cmd = json["command"] as? String ?? ""
            logJSON(base.merging([
                "event":       "shell_pre",
                "cmd_preview": String(cmd.prefix(200)),
                "cwd":         json["cwd"] as? String ?? "",
            ]) { $1 })
            respondAllow(cors: cors, to: conn)
            return

        case "afterShellExecution":
            let output = json["output"] as? String ?? ""
            var entry = base.merging([
                "event":          "shell_post",
                "cmd_preview":    String((json["command"] as? String ?? "").prefix(200)),
                "output_preview": String(output.prefix(120)),
                "duration_ms":    json["duration"] as? Int  ?? 0,
                "sandbox":        json["sandbox"]  as? Bool ?? false,
            ]) { $1 }
            var payloadEntry = entry
            payloadEntry["output"] = output
            entry["payload_id"] = logPayload(payloadEntry)
            logJSON(entry)

        // ── MCP ──────────────────────────────────────────────────────────────

        case "beforeMCPExecution":
            var entry = base.merging(["event": "mcp_pre"]) { $1 }
            if let s = json["server_name"] as? String { entry["mcp_server"] = s }
            if let t = json["tool_name"]   as? String { entry["tool"]       = t }
            if let input = json["tool_input"] {
                let inputStr: String
                if let s = input as? String { inputStr = s }
                else if let d = try? JSONSerialization.data(withJSONObject: input),
                        let s = String(data: d, encoding: .utf8) { inputStr = s } else { inputStr = "" }
                if inputStr.count > 300 {
                    var payloadEntry = entry; payloadEntry["tool_input"] = input
                    entry["input_preview"] = String(inputStr.prefix(120))
                    entry["input_chars"]   = inputStr.count
                    entry["payload_id"]    = logPayload(payloadEntry)
                } else {
                    entry["input"] = input
                }
            }
            logJSON(entry)
            respondAllow(cors: cors, to: conn)
            return

        case "afterMCPExecution":
            var entry = base.merging(["event": "mcp_post"]) { $1 }
            if let s = json["server_name"] as? String { entry["mcp_server"] = s }
            if let t = json["tool_name"]   as? String { entry["tool"]       = t }
            if let out = json["tool_output"] {
                var payloadEntry = entry; payloadEntry["tool_output"] = out
                let preview: String
                if let s = out as? String { preview = String(s.prefix(120)) }
                else if let d = try? JSONSerialization.data(withJSONObject: out),
                        let s = String(data: d, encoding: .utf8) { preview = String(s.prefix(120)) }
                else { preview = String("\(out)".prefix(120)) }
                entry["output_preview"] = preview
                entry["payload_id"]     = logPayload(payloadEntry)
            }
            logJSON(entry)

        // ── Subagents ────────────────────────────────────────────────────────

        case "subagentStart":
            let task = json["task"] as? String ?? ""
            logJSON(base.merging([
                "event":          "subagent_start",
                "subagent_id":    json["subagent_id"]    as? String ?? "",
                "subagent_type":  json["subagent_type"]  as? String ?? "",
                "subagent_model": json["subagent_model"] as? String ?? "",
                "task_preview":   String(task.prefix(120)),
                "is_parallel":    json["is_parallel_worker"] as? Bool ?? false,
            ]) { $1 })
            respondAllow(cors: cors, to: conn)
            return

        // ── Response ─────────────────────────────────────────────────────────

        case "afterAgentResponse":
            let text = json["text"] as? String ?? ""
            var entry = base.merging([
                "event":          "agent_response",
                "response_words": text.split(separator: " ").count,
                "text":           text,
            ]) { $1 }
            let pid = logPayload(entry)
            entry.removeValue(forKey: "text")
            entry["response_preview"] = String(text.prefix(120))
            entry["payload_id"]       = pid
            logJSON(entry)

        // ── Session lifecycle ─────────────────────────────────────────────────

        case "sessionStart":
            logJSON(base.merging([
                "event":          "session_start",
                "session_source": json["source"] as? String ?? "",
            ]) { $1 })

        case "stop":
            sessions.closeSession(sessionId: sessionId)
            logJSON(base.merging([
                "event":      "session_end",
                "status":     json["status"]     as? String ?? "",
                "loop_count": json["loop_count"] as? Int    ?? 0,
            ]) { $1 })

        case "workspaceOpen":
            logJSON(base.merging(["event": "workspace_open"]) { $1 })

        default:
            logJSON(base.merging([
                "event":      "cursor_hook",
                "hook_event": eventName,
            ]) { $1 })
        }

        respond("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\(cors)\r\n{}", to: conn)
    }

    private func respondAllow(cors: String, to conn: NWConnection) {
        let payload = "{\"permission\":\"allow\"}\n"
        respond(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n\(cors)\r\n\(payload)",
            to: conn
        )
    }

    // Fallback event detection from payload fields for older Cursor versions
    // that may not include hook_event_name in the payload.
    private func detectCursorEvent(_ json: [String: Any]) -> String {
        if json["prompt"]      != nil && json["tool_name"] == nil && json["command"] == nil { return "beforeSubmitPrompt" }
        if json["subagent_id"] != nil                                                       { return "subagentStart" }
        if json["tool_name"]   != nil && json["tool_output"] == nil && json["error"] == nil { return "preToolUse" }
        if json["tool_name"]   != nil && json["tool_output"] != nil                         { return "postToolUse" }
        if json["tool_name"]   != nil && json["error"]       != nil                         { return "postToolUseFailure" }
        if json["command"]     != nil && json["output"]      == nil                         { return "beforeShellExecution" }
        if json["command"]     != nil && json["output"]      != nil                         { return "afterShellExecution" }
        if json["file_path"]   != nil && json["edits"]       != nil                         { return "afterFileEdit" }
        if json["file_path"]   != nil && json["attachments"] != nil                         { return "beforeReadFile" }
        if json["file_path"]   != nil && json["content"]     != nil                         { return "beforeTabFileRead" }
        if json["text"]        != nil                                                        { return "afterAgentResponse" }
        if json["loop_count"]  != nil                                                        { return "stop" }
        if json["source"]      != nil                                                        { return "sessionStart" }
        return "unknown"
    }

    // MARK: - Claude Code Hooks

    private func handleClaudeCodeHook(body: String, conn: NWConnection, cors: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            respondClaudeAllow(cors: cors, to: conn); return
        }

        // Common base fields present in all Claude Code hook payloads
        let eventName = json["hook_event_name"] as? String ?? ""
        let sessionId = json["session_id"]      as? String ?? ""
        let cwd       = json["cwd"]             as? String ?? ""
        let agentType = json["agent_type"]      as? String ?? ""
        let ts        = timestamp()

        var base: [String: Any] = [
            "ts": ts, "source": "claude_hook", "app": "ClaudeCode",
            "session_id": sessionId, "cwd": cwd,
        ]
        if !agentType.isEmpty { base["agent_type"] = agentType }

        switch eventName {

        // ── Prompt ───────────────────────────────────────────────────────────

        case "UserPromptSubmit":
            let promptModel = json["model"] as? String ?? ""
            sessions.openSession(sessionId: sessionId, app: "ClaudeCode", meta: [
                "cwd": cwd, "model": promptModel,
            ])
            sessions.advanceTurn(sessionId: sessionId, app: "ClaudeCode")
            let prompt = json["prompt"] as? String ?? ""
            let words  = prompt.split(separator: " ").count
            let pid    = logPayload(base.merging(["event": "submit", "words": words, "text": prompt]) { $1 })
            sessions.recordPrompt(sessionId: sessionId, words: words, model: promptModel, payloadId: pid)
            logJSON(base.merging(["event": "submit", "words": words, "preview": String(prompt.prefix(120))]) { $1 })
            // BLOCKING (set hooks async:false in settings.json to enable):
            // let deny = "{\"decision\":\"block\",\"reason\":\"Prompt blocked by Palah policy\"}"
            // respondClaudeJSON(deny, cors: cors, to: conn); return

        // ── Tool calls ───────────────────────────────────────────────────────

        case "PreToolUse":
            let toolName = json["tool_name"] as? String ?? ""
            var entry = base.merging(["event": "tool_pre", "tool": toolName]) { $1 }
            if let input = json["tool_input"] {
                let inputStr: String
                if let s = input as? String {
                    inputStr = s
                } else if let d = try? JSONSerialization.data(withJSONObject: input),
                          let s = String(data: d, encoding: .utf8) { inputStr = s } else { inputStr = "" }
                if inputStr.count > 300 {
                    var payloadEntry = entry
                    payloadEntry["tool_input"] = input
                    entry["input_preview"] = String(inputStr.prefix(120))
                    entry["input_chars"]   = inputStr.count
                    entry["payload_id"]    = logPayload(payloadEntry)
                } else {
                    entry["input"] = input
                }
            }
            logJSON(entry)
            // BLOCKING (e.g., block dangerous git/shell commands):
            // if toolName == "Bash",
            //    let cmd = (json["tool_input"] as? [String: Any])?["command"] as? String {
            //     let blocked = ["git push --force", "curl | bash", "rm -rf /"]
            //     if blocked.contains(where: { cmd.contains($0) }) {
            //         let deny = """
            //         {"hookSpecificOutput":{"hookEventName":"PreToolUse",
            //          "permissionDecision":"deny",
            //          "permissionDecisionReason":"Blocked by Palah: policy violation"}}
            //         """
            //         respondClaudeJSON(deny, cors: cors, to: conn); return
            //     }
            // }

        case "PostToolUse":
            let toolName   = json["tool_name"]   as? String ?? ""
            let durationMs = json["duration_ms"] as? Int    ?? 0
            let effort     = json["effort"]      as? String ?? ""
            var entry = base.merging(["event": "tool_post", "tool": toolName, "duration_ms": durationMs]) { $1 }
            if let out = json["tool_response"] {
                var payloadEntry = entry; payloadEntry["tool_response"] = out
                let pid = logPayload(payloadEntry)
                let preview: String
                if let s = out as? String { preview = String(s.prefix(120)) }
                else if let data = try? JSONSerialization.data(withJSONObject: out),
                        let s = String(data: data, encoding: .utf8) { preview = String(s.prefix(120)) }
                else { preview = String("\(out)".prefix(120)) }
                entry["output_preview"] = preview
                entry["payload_id"]     = pid
                sessions.recordToolUse(sessionId: sessionId, tool: toolName,
                                       durationMs: durationMs, effort: effort, payloadId: pid)
            }
            logJSON(entry)

        case "PostToolUseFailure":
            logJSON(base.merging([
                "event": "tool_fail",
                "tool":  json["tool_name"] as? String ?? "",
                "error": json["error"]     as? String ?? "",
            ]) { $1 })

        // ── Subagents ────────────────────────────────────────────────────────

        case "SubagentStart":
            logJSON(base.merging([
                "event":      "subagent_start",
                "agent_type": json["agent_type"] as? String ?? "",
                "agent_id":   json["agent_id"]   as? String ?? "",
            ]) { $1 })
            // BLOCKING (deny subagent spawning):
            // let deny = "{\"decision\":\"block\",\"reason\":\"Subagents not permitted by policy\"}"
            // respondClaudeJSON(deny, cors: cors, to: conn); return

        case "SubagentStop":
            logJSON(base.merging([
                "event":      "subagent_stop",
                "agent_type": json["agent_type"] as? String ?? "",
                "agent_id":   json["agent_id"]   as? String ?? "",
            ]) { $1 })

        // ── Session lifecycle ─────────────────────────────────────────────────

        case "SessionStart":
            logJSON(base.merging([
                "event":  "session_start",
                "source": json["source"] as? String ?? "",
                "model":  json["model"]  as? String ?? "",
            ]) { $1 })

        case "SessionEnd", "Stop":
            sessions.closeSession(sessionId: sessionId)
            logJSON(base.merging(["event": "session_end"]) { $1 })

        // ── Observability ─────────────────────────────────────────────────────

        case "Notification":
            let msg = json["message"] as? String ?? ""
            logJSON(base.merging(["event": "notification", "message": String(msg.prefix(200))]) { $1 })

        case "FileChanged":
            logJSON(base.merging(["event": "file_changed", "file": json["file_path"] as? String ?? ""]) { $1 })

        case "PreCompact":
            logJSON(base.merging(["event": "pre_compact"]) { $1 })
            // BLOCKING (prevent context compaction):
            // let deny = "{\"decision\":\"block\",\"reason\":\"Compaction blocked by Palah\"}"
            // respondClaudeJSON(deny, cors: cors, to: conn); return

        default:
            logJSON(base.merging(["event": "claude_hook", "hook_event": eventName]) { $1 })
        }

        respondClaudeAllow(cors: cors, to: conn)
    }

    // Empty {} = proceed in Claude Code HTTP hooks
    private func respondClaudeAllow(cors: String, to conn: NWConnection) {
        respond("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\(cors)\r\n{}", to: conn)
    }

    // Used for block responses — uncomment respondClaudeJSON calls above to enable
    // private func respondClaudeJSON(_ payload: String, cors: String, to conn: NWConnection) {
    //     respond("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n\(cors)\r\n\(payload)", to: conn)
    // }

    // MARK: - Structured logging

    @discardableResult
    private func logCapture(_ json: [String: Any]) -> (sessionId: String, turn: Int) {
        let source = json["source"] as? String ?? ""
        let text   = json["text"]   as? String ?? ""
        let url    = json["url"]    as? String ?? ""
        let app: String
        switch source {
        case "node_options", "openclaw_session":
            app = json["app"] as? String ?? "unknown"
        default:
            app = "chrome-\(json["tool"] as? String ?? "browser")"
        }

        // Session ID: use the caller-provided ID when available (OpenClaw, node_options),
        // otherwise generate a datetime-based pseudo-ID for browser extension captures.
        let sessionId: String
        if let provided = json["session_id"] as? String, !provided.isEmpty,
           source == "openclaw_session" || source == "node_options" {
            sessionId = provided
        } else {
            let tsFmt = DateFormatter(); tsFmt.dateFormat = "yyyyMMdd-HHmmss"
            sessionId = tsFmt.string(from: Date())
        }

        var meta: [String: Any] = ["source": source, "url": url]
        switch source {
        case "node_options":
            meta["model"]    = json["model"]    ?? ""
            meta["endpoint"] = json["endpoint"] ?? ""
        case "openclaw_session":
            meta["model"]    = json["model"]    ?? ""
        default:
            break
        }
        sessions.openSession(sessionId: sessionId, app: app, meta: meta)
        sessions.advanceTurn(sessionId: sessionId, app: app)

        let words = json["words"] as? Int ?? text.split(separator: " ").count
        var base: [String: Any] = [
            "ts":         timestamp(),
            "event":      "submit",
            "source":     source,
            "app":        app,
            "session_id": sessionId,
            "url":        url,
            "words":      words,
        ]
        switch source {
        case "node_options":
            base["pid"]      = json["pid"]
            base["model"]    = json["model"]
            base["msgCount"] = json["messageCount"]
            base["endpoint"] = json["endpoint"]
        case "openclaw_session":
            base["model"]    = json["model"]
        default:
            break
        }

        var payloadEntry = base
        payloadEntry["text"]          = text
        payloadEntry["attachments"]   = json["attachments"] ?? []
        payloadEntry["input_tokens"]  = json["input_tokens"]  ?? NSNull()
        payloadEntry["output_tokens"] = json["output_tokens"] ?? NSNull()
        let pid = logPayload(payloadEntry)
        sessions.recordPrompt(sessionId: sessionId, words: words,
                              model: json["model"] as? String ?? "", payloadId: pid)

        var logEntry = base; logEntry["preview"] = String(text.prefix(120))
        logJSON(logEntry)

        return (sessionId, sessions.currentTurn(sessionId: sessionId))
    }

    // Writes an AI response to the same turn file as the originating prompt.
    // session_id and turn are echoed back by Palah when the prompt was captured,
    // stored in the extension, and returned here with the response event.
    private func logAIResponse(_ json: [String: Any]) {
        let sessionId    = json["session_id"]   as? String ?? ""
        let source       = json["source"]       as? String ?? ""
        let text         = json["text"]         as? String ?? ""
        let words        = json["words"]        as? Int    ?? text.split(separator: " ").count
        let inputTokens  = json["input_tokens"] ?? NSNull()
        let outputTokens = json["output_tokens"] ?? NSNull()

        let app: String
        let eventSource: String
        switch source {
        case "openclaw_session":
            app = json["app"] as? String ?? "openclaw"
            eventSource = "openclaw_session:response"
        case "node_options":
            app = json["app"] as? String ?? "node"
            eventSource = "node_options:response"
        default:
            app = "chrome-\(json["tool"] as? String ?? "browser")"
            eventSource = "extension:response"
        }

        var entry: [String: Any] = [
            "ts":            timestamp(),
            "event":         "ai_response",
            "source":        eventSource,
            "app":           app,
            "session_id":    sessionId,
            "url":           json["url"] as? String ?? "",
            "words":         words,
            "input_tokens":  inputTokens,
            "output_tokens": outputTokens,
        ]

        var payloadEntry = entry
        payloadEntry["text"] = text
        let pid = logPayload(payloadEntry)
        entry["preview"]    = String(text.prefix(120))
        entry["payload_id"] = pid
        logJSON(entry)
    }
}
