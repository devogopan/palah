//
//  palahApp.swift
//  Palah
//
//  Created by Gopakumar N on 03/06/26.
//

import SwiftUI
import ApplicationServices

@main
struct PalahApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }  // no window, no dock icon
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var reader:  AccessibilityReader?
    var server:  PromptServer?
    var ocWatcher: OpenClawWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // hide from Dock
        server = PromptServer()
        server?.start()
        reader = AccessibilityReader()
        reader?.start()
        ocWatcher = OpenClawWatcher()
        ocWatcher?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ocWatcher?.stop()
    }
}
