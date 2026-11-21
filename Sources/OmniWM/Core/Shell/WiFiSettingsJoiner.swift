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

    static func rowSecurity(in identifiers: Set<Data>, ssid: String, secured: Bool) -> RowSecurity {
        let row = "wifi-network-\(ssid)"
        guard identifiers.contains(Data("\(row)-signal".utf8)) else { return .unknown }
        return identifiers.contains(Data("\(row)-secure".utf8)) == secured ? .matches : .conflicts
    }

    struct RowChild: Equatable {
        var text: String?
        var identifier: String?
        var isLabel = false
        var isTarget = false
    }

    static func rowMarkers(in children: [RowChild], ssid: String) -> Set<Data>? {
        var markers: Set<Data>?
        var inTargetRow = false
        for child in children {
            if child.isLabel {
                inTargetRow = false
                guard let text = child.text, text.utf8.elementsEqual(ssid.utf8) else { continue }
                guard child.isTarget, markers == nil else { return nil }
                markers = []
                inTargetRow = true
            } else if inTargetRow, let identifier = child.identifier {
                markers?.insert(Data(identifier.utf8))
            }
        }
        return markers
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
            guard try Self.rowSecurity(in: search.recheck(label, app: app), ssid: ssid, secured: network.secured)
                == .matches
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
        private(set) var identifiers: Set<Data> = []
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
                identifiers.insert(Data(identifier.utf8))
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

        func recheck(_ label: AXUIElement, app: AXUIElement) throws -> Set<Data> {
            for window in try attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? [] {
                if try blocksInput(window) { throw SearchStop.abort }
                for child in try attribute(kAXChildrenAttribute, of: window) as? [AXUIElement] ?? []
                    where try blocksInput(child)
                {
                    throw SearchStop.abort
                }
            }
            guard let row = try AXUIElement.from(attribute(kAXParentAttribute, of: label)) else {
                throw SearchStop.abort
            }
            var children: [RowChild] = []
            for child in try attribute(kAXChildrenAttribute, of: row) as? [AXUIElement] ?? [] {
                switch try attribute(kAXRoleAttribute, of: child) as? String {
                case kAXStaticTextRole:
                    let text = try attribute(kAXValueAttribute, of: child) as? String
                    children.append(RowChild(text: text, isLabel: true, isTarget: CFEqual(child, label)))
                case kAXUnknownRole:
                    children.append(RowChild(identifier: try attribute(kAXIdentifierAttribute, of: child) as? String))
                default: continue
                }
            }
            guard let markers = WiFiSettingsJoiner.rowMarkers(in: children, ssid: ssid) else { throw SearchStop.abort }
            return markers
        }

        private func blocksInput(_ element: AXUIElement) throws -> Bool {
            if try attribute(kAXRoleAttribute, of: element) as? String == kAXSheetRole { return true }
            let subrole = try attribute(kAXSubroleAttribute, of: element) as? String
            return subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole
        }
    }
}
