//
//  SafariWebExtensionHandler.swift
//  Shared (Extension)
//
//  Receives native messages from background.js (browser.runtime.sendNativeMessage)
//  and forwards them to the Palah macOS agent at localhost:45678 via URLSession.
//
//  WHY URLSession (not JS fetch):
//  content.js runs in an HTTPS page (chatgpt.com, claude.ai, etc.). Safari enforces
//  mixed-content policy and blocks HTTP fetch from HTTPS pages — even to localhost.
//  Native Swift URLSession is NOT subject to this restriction, so the relay goes:
//    content.js → sendMessage → background.js → sendNativeMessage → here → URLSession
//
//  WHAT MUST BE IN PLACE (all three, or the chain silently breaks):
//    1. "nativeMessaging" in the Safari manifest permissions   ← was missing originally
//    2. com.apple.security.network.client entitlement
//    3. NSAppTransportSecurity localhost exception (Info.plist)
//
//  HOW TO RESUME (after code-signing with Apple Developer identity):
//    log stream --predicate 'subsystem == "com.devogopan.palah.safari"' --info
//    "PALAH: beginRequest invoked"  → sendNativeMessage reached this handler
//    "PALAH: POST ok, status 200"   → full relay working; check /tmp/palah-sessions

import SafariServices
import os.log

private let palahLog = OSLog(subsystem: "com.devogopan.palah.safari", category: "bridge")

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        os_log(.default, log: palahLog, "PALAH: beginRequest invoked")

        let request = context.inputItems.first as? NSExtensionItem
        let message: Any?
        if #available(iOS 15.0, macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

#if os(macOS)
        guard let msgDict = message as? [String: Any],
              let body = try? JSONSerialization.data(withJSONObject: msgDict),
              let url  = URL(string: "http://localhost:45678/prompt") else {
            os_log(.error, log: palahLog, "PALAH: message decode failed")
            complete(context: context, response: ["ok": false])
            return
        }

        os_log(.default, log: palahLog, "PALAH: POSTing %d bytes to localhost:45678", body.count)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            if let error = error {
                os_log(.error, log: palahLog, "PALAH: POST failed: %{public}@", error.localizedDescription)
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                os_log(.default, log: palahLog, "PALAH: POST ok, status %d", code)
            }
            var resp: [String: Any] = ["ok": true]
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                resp = json
            }
            self?.complete(context: context, response: resp)
        }.resume()
#else
        complete(context: context, response: ["ok": false])
#endif
    }

    private func complete(context: NSExtensionContext, response: [String: Any]) {
        let item = NSExtensionItem()
        if #available(iOS 15.0, macOS 11.0, *) {
            item.userInfo = [SFExtensionMessageKey: response]
        } else {
            item.userInfo = ["message": response]
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
