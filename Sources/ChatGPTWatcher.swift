import AppKit
import ApplicationServices

/// Notices work in the ChatGPT app (which also hosts Codex), including ChatGPT Work tasks that
/// run in the cloud and leave no local log. While a reply is being produced the open chat shows a
/// "処理中" status (and a "停止" button); both disappear when it finishes.
///
/// Only element roles and short accessibility descriptions are read — never chat titles, message
/// text or values — and nothing is stored. It needs the Accessibility permission, and only sees the
/// chat currently open in the app.
enum ChatGPTWatcher {
    enum State: Equatable {
        case off              // the setting is off
        case notRunning       // the ChatGPT app is not open
        case needsPermission  // Accessibility permission has not been granted
        case idle
        case busy
    }

    static let bundleID = "com.openai.codex"
    /// Descriptions of the live status region while a reply is in progress.
    private static let statusWords = ["処理中", "Processing"]
    /// The stop button shown while a reply is streaming.
    private static let stopWords: Set<String> = ["停止", "Stop", "Stop generating"]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// One look at the app. Safe to call off the main thread.
    static func check() -> State {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return .notRunning }
        guard AXIsProcessTrusted() else { return .needsPermission }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)

        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray
        var pending: [AXUIElement] = [root]
        var index = 0
        while index < pending.count, index < 6000 {
            let element = pending[index]
            index += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [AnyObject], list.count == 4 else { continue }
            let role = list[0] as? String ?? ""
            // The menu bar holds hundreds of items and never the status; skip it entirely.
            if role == kAXMenuBarRole { continue }
            let subrole = list[1] as? String ?? ""
            let description = list[2] as? String ?? ""
            if subrole == "AXApplicationStatus", statusWords.contains(where: description.contains) { return .busy }
            if role == kAXButtonRole, stopWords.contains(description) { return .busy }
            if let children = list[3] as? [AXUIElement] { pending.append(contentsOf: children) }
        }
        return .idle
    }
}
