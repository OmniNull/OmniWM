// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices

struct NativeMenuBarOverflow: Equatable, Sendable {
    struct Tree<Element> {
        let menuBars: () -> [Element]
        let children: (Element) -> [Element]
        let identifier: (Element) -> String?
        let frame: (Element) -> CGRect?
    }

    static let expandedIndicator = "menu-bar-overflow-indicator-expanded"

    var itemFrames: [CGRect] = []

    init(itemFrames: [CGRect] = []) {
        self.itemFrames = itemFrames
    }

    init<Element>(_ tree: Tree<Element>) {
        for menuBar in tree.menuBars() {
            let children = tree.children(menuBar)
            guard children.contains(where: { tree.identifier($0) == Self.expandedIndicator }) else { continue }
            itemFrames += children.compactMap(tree.frame).filter { !$0.isEmpty }
        }
    }

    func covers(_ frame: CGRect) -> Bool {
        itemFrames.contains { $0.intersects(frame) }
    }
}

@MainActor
final class NativeMenuBarOverflowWatcher {
    nonisolated static let agentBundleID = "com.apple.MenuBarAgent"
    private static let queue = DispatchQueue(label: "com.barut.OmniWM.nativeMenuBarOverflow", qos: .userInitiated)

    var overflow = NativeMenuBarOverflow()
    var onChange: (() -> Void)?
    private var agent: NSRunningApplication?
    private var observer: AXObserver?
    private var searched = false
    private var reads = 0

    isolated deinit {
        stop()
    }

    func setActive(_ active: Bool) {
        guard active else { return stop() }
        if !searched || agent?.isTerminated == true {
            observeAgent()
        }
    }

    private func stop() {
        removeObserver()
        agent = nil
        searched = false
        reads &+= 1
        overflow = NativeMenuBarOverflow()
    }

    private func removeObserver() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    private func observeAgent() {
        removeObserver()
        reads &+= 1
        let previous = agent
        agent = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first
        searched = agent != nil || previous == nil
        guard let pid = agent?.processIdentifier else { return publish(NativeMenuBarOverflow()) }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let watcher = Unmanaged<NativeMenuBarOverflowWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.read() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created,
              AXObserverAddNotification(
                  created,
                  AXUIElementCreateApplication(pid),
                  kAXLayoutChangedNotification as CFString,
                  Unmanaged.passUnretained(self).toOpaque()
              ) == .success
        else { return publish(NativeMenuBarOverflow()) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        read()
    }

    private func read() {
        guard let pid = agent?.processIdentifier else { return }
        reads &+= 1
        let read = reads
        Self.queue.async { [weak self] in
            let overflow = NativeMenuBarOverflow(.live(pid: pid))
            Task { @MainActor [weak self] in
                guard let self, reads == read else { return }
                publish(overflow)
            }
        }
    }

    private func publish(_ next: NativeMenuBarOverflow) {
        guard overflow != next else { return }
        overflow = next
        onChange?()
    }
}

extension NativeMenuBarOverflow.Tree where Element == AXUIElement {
    static func live(pid: pid_t) -> Self {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, MenuBarItemLocator.messagingTimeoutSeconds)
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value
        }
        return Self(
            menuBars: { value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] },
            children: { value($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] },
            identifier: { value($0, kAXIdentifierAttribute) as? String },
            frame: { MenuBarItemLocator.frame(of: $0) }
        )
    }
}
