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
    var reader: AccessibilityReader?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // hide from Dock
        reader = AccessibilityReader()
        reader?.start()
    }
}
