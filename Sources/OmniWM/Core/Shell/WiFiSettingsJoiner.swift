// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices

actor WiFiSettingsJoiner {
    private static let shared = WiFiSettingsJoiner()
    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.wifi.settings", qos: .userInitiated)
    private let connectTitle = Bundle(path: "/System/Library/PrivateFrameworks/WiFiSettingsKit.framework")?
        .localizedString(forKey: "Connect", value: "Connect", table: nil) ?? "Connect"

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    // This is a handoff, not an association result. Once dispatched, macOS owns all credential UI.
    @MainActor
    static func join(_ network: ShellWiFiNetwork) async -> String? {
        let failure = String(localized: "Join this network in Wi-Fi Settings")
        guard let url = ShellSettingsPane.wifi.url, NSWorkspace.shared.open(url) else { return failure }
        guard AXIsProcessTrusted(),
              let bytes = ShellWiFiNetwork.ssidData(id: network.id),
              network.ssid.utf8.elementsEqual(bytes)
        else { return failure }

        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first(where: { !$0.isTerminated })
            {
                switch await shared.attempt(pid: app.processIdentifier, ssid: network.ssid, deadline: deadline) {
                case .dispatched: return nil
                case .blocked: return failure
                case .waiting: break
                }
            }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return failure }
        }
        return failure
    }

    // Custom AX action names are opaque strings. Pass the returned string back unchanged, not "AXConnect".
    static func connectAction(in actions: [String], title: String) -> String? {
        var match: String?
        for action in actions {
            let name = action.prefix { $0 != "\n" }
            guard name == "Name:\(title)" || name == "Name:Connect" else { continue }
            guard match == nil else { return nil }
            match = action
        }
        return match
    }

    private enum Attempt {
        case waiting, dispatched, blocked
    }

    private func attempt(pid: pid_t, ssid: String, deadline: TimeInterval) -> Attempt {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        do {
            let session = Session(ssid: ssid, deadline: deadline)
            let windows = try session.copy(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            for window in windows { try session.visit(window, depth: 0) }
            guard let target = session.target else { return .waiting }
            // The list can refresh while we traverse it. Recheck both identity and action immediately before dispatch.
            guard let value = try session.copy(target, kAXValueAttribute) as? String,
                  value.utf8.elementsEqual(ssid.utf8)
            else { return .waiting }
            var names: CFArray?
            guard AXUIElementCopyActionNames(target, &names) == .success,
                  let actions = names as? [String],
                  let action = Self.connectAction(in: actions, title: connectTitle)
            else { return .blocked }
            try session.check()
            // Never retry an action: an AX timeout can mean the request was delivered.
            return AXUIElementPerformAction(target, action as CFString) == .success ? .dispatched : .blocked
        } catch Failure.unavailable {
            return .waiting
        } catch {
            return .blocked
        }
    }

    private enum Failure: Error {
        case unavailable, blocked
    }

    private final class Session {
        let ssid: String
        let deadline: TimeInterval
        var target: AXUIElement?
        var remaining = 2000

        init(ssid: String, deadline: TimeInterval) {
            self.ssid = ssid
            self.deadline = deadline
        }

        func check() throws {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.blocked }
        }

        func copy(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
            try check()
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
            case .success: return value
            case .noValue,
                 .attributeUnsupported: return nil
            case .invalidUIElement,
                 .cannotComplete: throw Failure.unavailable
            default: throw Failure.blocked
            }
        }

        func visit(_ element: AXUIElement, depth: Int) throws {
            guard depth < 30, remaining > 0 else { throw Failure.blocked }
            remaining -= 1
            let role = try copy(element, kAXRoleAttribute) as? String
            // Do not inspect an existing dialog, or read/traverse any editable credential fields.
            if role == kAXSheetRole { throw Failure.blocked }
            if role == kAXWindowRole,
               let subrole = try copy(element, kAXSubroleAttribute) as? String,
               subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole
            { throw Failure.blocked }
            if role == kAXTextFieldRole || role == kAXTextAreaRole { return }
            if role == kAXStaticTextRole,
               let value = try copy(element, kAXValueAttribute) as? String,
               value.utf8.elementsEqual(ssid.utf8)
            {
                guard target == nil else { throw Failure.blocked }
                target = element
            }
            for child in try copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                try visit(child, depth: depth + 1)
            }
        }
    }
}
