// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices

actor WiFiSettingsJoiner {
    private static let shared = WiFiSettingsJoiner()
    private static let settingsBundle = "com.apple.systempreferences"
    private static let handoffSeconds: TimeInterval = 8
    private static let retryInterval = Duration.milliseconds(200)
    private static let messagingTimeout: Float = 0.2
    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.wifi.settings", qos: .userInitiated)
    private let connectTitle = Bundle(path: "/System/Library/PrivateFrameworks/WiFiSettingsKit.framework")?
        .localizedString(forKey: "Connect", value: "Connect", table: nil) ?? "Connect"

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    @MainActor
    static func join(_ network: ShellWiFiNetwork) async -> String? {
        let failure = String(localized: "Join this network in Wi-Fi Settings")
        guard let url = ShellSettingsPane.wifi.url, NSWorkspace.shared.open(url) else { return failure }
        guard AXIsProcessTrusted(),
              let bytes = ShellWiFiNetwork.ssidData(id: network.id),
              network.ssid.utf8.elementsEqual(bytes)
        else { return failure }

        let deadline = ProcessInfo.processInfo.systemUptime + handoffSeconds
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundle)
                .first(where: { !$0.isTerminated })
            {
                switch await shared.attempt(pid: app.processIdentifier, network: network, deadline: deadline) {
                case .dispatched: return nil
                case .blocked: return failure
                case .waiting: break
                }
            }
            do { try await Task.sleep(for: retryInterval) }
            catch { return failure }
        }
        return failure
    }

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

    enum RowSecurity: Equatable {
        case unknown, matches, conflicts
    }

    static func rowSecurity(in identifiers: Set<String>, ssid: String, secured: Bool) -> RowSecurity {
        let row = "wifi-network-\(ssid)"
        guard identifiers.contains("\(row)-signal") else { return .unknown }
        return identifiers.contains("\(row)-secure") == secured ? .matches : .conflicts
    }

    private enum Attempt {
        case waiting, dispatched, blocked
    }

    private func attempt(pid: pid_t, network: ShellWiFiNetwork, deadline: TimeInterval) -> Attempt {
        let ssid = network.ssid
        let app = AXUIElementCreateApplication(pid)
        do {
            let search = SSIDSearch(ssid: ssid, deadline: deadline)
            let windows = try search.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []
            for window in windows { try search.visit(window, depth: 0) }
            guard let label = search.match else { return .waiting }
            switch Self.rowSecurity(in: search.identifiers, ssid: ssid, secured: network.secured) {
            case .unknown: return .waiting
            case .conflicts: return .blocked
            case .matches: break
            }
            guard let value = try search.attribute(kAXValueAttribute, of: label) as? String,
                  value.utf8.elementsEqual(ssid.utf8)
            else { return .waiting }
            var names: CFArray?
            guard AXUIElementCopyActionNames(label, &names) == .success,
                  let actions = names as? [String],
                  let action = Self.connectAction(in: actions, title: connectTitle)
            else { return .blocked }
            try search.requireTimeLeft()
            return AXUIElementPerformAction(label, action as CFString) == .success ? .dispatched : .blocked
        } catch SearchStop.retry {
            return .waiting
        } catch {
            return .blocked
        }
    }

    private enum SearchStop: Error {
        case retry, abort
    }

    private final class SSIDSearch {
        static let maxDepth = 30
        static let nodeBudget = 2000

        let ssid: String
        let deadline: TimeInterval
        private(set) var match: AXUIElement?
        private(set) var identifiers: Set<String> = []
        private var nodesLeft = nodeBudget

        init(ssid: String, deadline: TimeInterval) {
            self.ssid = ssid
            self.deadline = deadline
        }

        func requireTimeLeft() throws {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw SearchStop.abort }
        }

        func attribute(_ name: String, of element: AXUIElement) throws -> CFTypeRef? {
            try requireTimeLeft()
            AXUIElementSetMessagingTimeout(element, WiFiSettingsJoiner.messagingTimeout)
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
            case .success: return value
            case .noValue,
                 .attributeUnsupported: return nil
            case .invalidUIElement,
                 .cannotComplete: throw SearchStop.retry
            default: throw SearchStop.abort
            }
        }

        func visit(_ element: AXUIElement, depth: Int) throws {
            guard depth < Self.maxDepth, nodesLeft > 0 else { throw SearchStop.abort }
            nodesLeft -= 1
            let role = try attribute(kAXRoleAttribute, of: element) as? String
            if role == kAXSheetRole { throw SearchStop.abort }
            if role == kAXWindowRole,
               let subrole = try attribute(kAXSubroleAttribute, of: element) as? String,
               subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole
            { throw SearchStop.abort }
            if role == kAXTextFieldRole || role == kAXTextAreaRole { return }
            if role == kAXUnknownRole, let identifier = try attribute(kAXIdentifierAttribute, of: element) as? String {
                identifiers.insert(identifier)
            }
            if role == kAXStaticTextRole,
               let value = try attribute(kAXValueAttribute, of: element) as? String,
               value.utf8.elementsEqual(ssid.utf8)
            {
                guard match == nil else { throw SearchStop.abort }
                match = element
            }
            for child in try attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [] {
                try visit(child, depth: depth + 1)
            }
        }
    }
}
