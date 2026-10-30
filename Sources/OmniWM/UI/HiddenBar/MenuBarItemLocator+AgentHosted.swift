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

    struct HostedTree<Element> {
        let windows: () -> [Element]
        let children: (Element) -> [Element]
        let owner: (Element) -> pid_t?
        let frame: (Element) -> CGRect?
    }

    final class HostedItemIndex {
        private let walk: () -> [HostedItemEntry<AXUIElement>]?
        private var itemsByPID: [pid_t: [MenuBarItemElement]]?

        init(walk: @escaping () -> [HostedItemEntry<AXUIElement>]?) {
            self.walk = walk
        }

        convenience init(expired: @escaping () -> Bool) {
            self.init { liveHostedTree().flatMap { hostedEntries($0, expired: expired) } }
        }

        convenience init() {
            self.init(expired: expiry(after: hostedWalkBudget))
        }

        func items(for pid: pid_t) -> [MenuBarItemElement]? {
            if itemsByPID == nil {
                let entries = walk() ?? []
                itemsByPID = Dictionary(grouping: entries, by: \.pid).mapValues { owned in
                    hostedItems(owned, pid: owned[0].pid).map {
                        MenuBarItemElement(element: $0.element, frame: $0.frame, hosted: true)
                    }
                }
            }
            guard let items = itemsByPID?[pid], !items.isEmpty else { return nil }
            return items
        }
    }

    private static let hostedWalkBudget: Duration = .milliseconds(250)

    static func expiry(
        after budget: Duration,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) -> () -> Bool {
        var deadline: ContinuousClock.Instant?
        return {
            let current = now()
            let end = deadline ?? current.advanced(by: budget)
            deadline = end
            return current >= end
        }
    }

    static func hostedItems<Element>(_ entries: [HostedItemEntry<Element>], pid: pid_t) -> [HostedItemEntry<Element>] {
        entries.filter { $0.pid == pid && !$0.frame.isEmpty }.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func hostedEntries<Element>(
        _ tree: HostedTree<Element>,
        expired: () -> Bool
    ) -> [HostedItemEntry<Element>]? {
        var entries: [HostedItemEntry<Element>] = []
        if expired() { return nil }
        for window in tree.windows() {
            if expired() { return nil }
            for group in tree.children(window) {
                if expired() { return nil }
                for item in tree.children(group) {
                    if expired() { return nil }
                    guard let owner = tree.owner(item), let frame = tree.frame(item) else { continue }
                    entries.append(HostedItemEntry(pid: owner, frame: frame, element: item))
                }
            }
        }
        return entries
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
            let index = HostedItemIndex(expired: { (try? deadline.remaining(at: environment.now())) == nil })
            guard let hosted = index.items(for: pid) else {
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

    private static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        return element
    }

    private static func axChildren(
        _ element: AXUIElement,
        _ attribute: String = kAXChildrenAttribute
    ) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bounded(element), attribute as CFString, &ref) == .success
        else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func liveHostedTree() -> HostedTree<AXUIElement>? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
            .first?.processIdentifier
        else { return nil }
        let root = AXUIElementCreateApplication(agent)
        return HostedTree(
            windows: { axChildren(root, kAXWindowsAttribute) },
            children: { axChildren($0) },
            owner: { element in
                var owner: pid_t = 0
                return AXUIElementGetPid(element, &owner) == .success ? owner : nil
            },
            frame: { frame(of: bounded($0)) }
        )
    }
}
