// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices

extension MenuBarItemLocator {
    struct HostedItemEntry<Element> {
        let pid: pid_t
        let frame: CGRect
        let element: Element
    }

    static func hostedItems<Element>(_ entries: [HostedItemEntry<Element>], pid: pid_t) -> [HostedItemEntry<Element>] {
        entries.filter { $0.pid == pid && !$0.frame.isEmpty }.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func usesAXPress(for candidate: MenuBarItemActivationCandidate, hosted: Bool) -> Bool {
        candidate.useAXPress || hosted
    }

    static func fallback(
        for candidate: MenuBarItemActivationCandidate,
        frame: CGRect,
        hosted: Bool
    ) -> MenuBarItemActivation {
        hosted ? .unavailable : fallback(for: candidate, frame: frame)
    }

    @MainActor
    static func extrasChildren(
        pid: pid_t,
        environment: MenuExtractorEnvironment,
        deadline: MenuAXDeadline
    ) throws -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        let extrasValue: Any?
        do {
            extrasValue = try environment.readAttribute(
                app, "AXExtrasMenuBar" as CFString, deadline.remaining(at: environment.now())
            )
        } catch MenuExtractionError.ax(.noValue) {
            extrasValue = nil
        }
        guard let extrasValue, let extras = AXUIElement.from(extrasValue as CFTypeRef) else {
            guard let hosted = hostedItemElements(pid: pid), !hosted.isEmpty else {
                throw MenuExtractionError.invalidResponse
            }
            return hosted.map(\.element)
        }
        let childrenValue = try environment.readAttribute(
            extras, kAXChildrenAttribute as CFString, deadline.remaining(at: environment.now())
        )
        guard let children = childrenValue as? [AXUIElement] else {
            throw MenuExtractionError.invalidResponse
        }
        return children
    }

    private static func axChildren(
        _ element: AXUIElement,
        _ attribute: String = kAXChildrenAttribute
    ) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    static func hostedItemElements(pid: pid_t) -> [MenuBarItemElement]? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
            .first?.processIdentifier
        else { return nil }
        let agentElement = AXUIElementCreateApplication(agent)
        AXUIElementSetMessagingTimeout(agentElement, messagingTimeoutSeconds)
        defer { AXUIElementSetMessagingTimeout(agentElement, 0) }
        var entries: [HostedItemEntry<AXUIElement>] = []
        for window in axChildren(agentElement, kAXWindowsAttribute) {
            for group in axChildren(window) {
                for item in axChildren(group) {
                    var owner: pid_t = 0
                    guard AXUIElementGetPid(item, &owner) == .success, owner == pid,
                          let frame = frame(of: item) ?? frame(of: group)
                    else { continue }
                    entries.append(HostedItemEntry(pid: owner, frame: frame, element: item))
                }
            }
        }
        let items = hostedItems(entries, pid: pid)
        guard !items.isEmpty else { return nil }
        return items.map { MenuBarItemElement(element: $0.element, frame: $0.frame, hosted: true) }
    }
}
