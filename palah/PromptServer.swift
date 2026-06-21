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

        // POST /prompt — from Chrome extension or BASE_URL relay clients
        if method == "POST",
           let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["type"] as? String) == "PROMPT_CAPTURED" {
            logCapture(json)
        }

        respond("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\(cors)\r\n", to: conn)
    }

    private func respond(_ response: String, to conn: NWConnection) {
        conn.send(content: response.data(using: .utf8),
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Structured logging

    private func logCapture(_ json: [String: Any]) {
        let source = json["source"] as? String ?? ""
        let text   = json["text"]   as? String ?? ""
        let url    = json["url"]    as? String ?? ""

        var entry: [String: Any] = [
            "ts":      timestamp(),
            "event":   "submit",
            "url":     url,
            "words":   json["words"] as? Int ?? text.split(separator: " ").count,
            "preview": String(text.prefix(120)),
        ]

        if source == "node_options" {
            // From NODE_OPTIONS preload — richer metadata available
            entry["source"]   = "node_options"
            entry["app"]      = json["app"]          as? String ?? "unknown"
            entry["pid"]      = json["pid"]
            entry["model"]    = json["model"]
            entry["msgCount"] = json["messageCount"]
            entry["endpoint"] = json["endpoint"]
        } else {
            // From Chrome extension
            entry["source"] = "extension:\(source)"
            entry["app"]    = json["tool"] as? String ?? "unknown"
        }

        logJSON(entry)
    }
}
