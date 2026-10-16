// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices

struct HiddenBarMenuRow: Equatable, Sendable {
    let id: String
    let title: String
    let enabled: Bool
    let mark: String?
    let shortcut: String?
    let submenu: Bool
    let separator: Bool
}

struct HiddenBarMenuPage: Equatable, Sendable {
    let title: String?
    let rows: [HiddenBarMenuRow]
    let backID: String?
}

@MainActor
final class HiddenBarMenuSession {
    enum OpenResult: Equatable {
        case menu
        case noMenu
        case unavailable
    }

    enum SelectionResult: Equatable {
        case updated
        case performed
        case unavailable
        case ignored
    }

    enum RevealDisposition: Equatable {
        case conceal
        case nativeFallback
    }

    private struct Level {
        let root: AXUIElement
        let title: String?
    }

    private let environment: MenuExtractorEnvironment
    private let reader: MenuAXReader
    private let ownerIsCurrent: (MenuBarAppCandidate) -> Bool
    private let elementPID: (AXUIElement) -> pid_t?
    private let press: @MainActor (AXUIElement) -> AXError
    private var owner: MenuBarAppCandidate?
    private var levels: [Level] = []
    private var actions: [String: MenuItemSnapshot] = [:]
    private var acquisition: Task<Void, Never>?
    private var generation = 0
    private var releaseReveal: ((RevealDisposition) -> Void)?
    private(set) var page: HiddenBarMenuPage?

    var bundleID: String? {
        owner?.bundleID
    }

    init(
        environment: MenuExtractorEnvironment = .live,
        ownerIsCurrent: @escaping (MenuBarAppCandidate) -> Bool = { owner in
            guard let app = NSRunningApplication(processIdentifier: owner.pid) else { return false }
            return !app.isTerminated && app.bundleIdentifier == owner.bundleID
        },
        elementPID: @escaping (AXUIElement) -> pid_t? = { element in
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success ? pid : nil
        },
        press: @escaping @MainActor (AXUIElement) -> AXError = { element in
            (try? MenuAXReader.withMessagingTimeout(on: element, timeout: 0.25) {
                performAXAction(element, kAXPressAction as CFString, noteKey: "hiddenBarMenuPressFailed")
            }) ?? .cannotComplete
        }
    ) {
        self.environment = environment
        reader = MenuAXReader(environment: environment, submenuTimeout: 0.25)
        self.ownerIsCurrent = ownerIsCurrent
        self.elementPID = elementPID
        self.press = press
    }

    struct Target {
        let key: MenuBarItemKey
        let ownerPID: pid_t
        let cachedItems: [ResolvedMenuBarItem]?
    }

    func acquire(
        target: Target,
        resolve: @escaping () async -> [ResolvedMenuBarItem]?,
        onResolve: @escaping ([ResolvedMenuBarItem]) -> Void = { _ in },
        release: @escaping (RevealDisposition) -> Void,
        onOpen: @escaping (OpenResult) -> Void
    ) {
        let key = target.key
        let ownerPID = target.ownerPID
        let cachedItems = target.cachedItems
        close()
        let owner = MenuBarAppCandidate(bundleID: key.bundleID, pid: ownerPID)
        self.owner = owner
        releaseReveal = release
        let generation = self.generation
        acquisition = Task { [weak self] in
            let freshItems = await resolve()
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            acquisition = nil
            let ownerCurrent = ownerIsCurrent(owner)
            guard ownerCurrent, let freshItems, !freshItems.isEmpty,
                  freshItems.allSatisfy({ $0.pid == ownerPID && $0.key.bundleID == key.bundleID })
            else {
                Log.hiddenBar
                    .error(
                        "Menu item resolution failed for \(key.bundleID), PID \(ownerPID), owner current \(ownerCurrent), item count \(freshItems?.count ?? -1)"
                    )
                close()
                onOpen(.unavailable)
                return
            }
            onResolve(freshItems)
            guard !Task.isCancelled, generation == self.generation else { return }
            let freshTarget: ResolvedMenuBarItem? = if let cachedItems {
                HiddenBarActivationPolicy.activationTarget(
                    for: key, cachedItems: cachedItems, cachedIcons: [:],
                    freshItems: freshItems, freshIcons: [:]
                )
            } else if key.ordinal == 0, freshItems.count == 1 {
                freshItems.first
            } else {
                nil
            }
            guard let freshTarget, freshTarget.pid == ownerPID, freshTarget.key.bundleID == key.bundleID else {
                Log.hiddenBar
                    .error(
                        "Could not identify selected item for \(key.bundleID) among \(freshItems.count) resolved items"
                    )
                close()
                onOpen(.unavailable)
                return
            }
            let result = open(target: freshTarget, cachedItems: freshItems)
            if result != .menu { close(disposition: result == .noMenu ? .nativeFallback : .conceal) }
            onOpen(result)
        }
    }

    func open(target: ResolvedMenuBarItem, cachedItems: [ResolvedMenuBarItem]) -> OpenResult {
        clearMenu()
        let owner = MenuBarAppCandidate(bundleID: target.key.bundleID, pid: target.pid)
        guard ownerIsCurrent(owner) else { return .unavailable }
        do {
            guard let element = try MenuBarItemLocator.menuTarget(
                matching: target, cachedItems: cachedItems, environment: environment
            ), elementPID(element) == target.pid else {
                Log.hiddenBar.error("AX menu item identity changed for \(owner.bundleID)")
                return .unavailable
            }
            guard let root = try menuRoot(of: element) else { return .noMenu }
            self.owner = owner
            levels = [Level(root: root, title: nil)]
            try loadPage()
            return .menu
        } catch {
            Log.hiddenBar.error("Menu extraction failed for \(owner.bundleID): \(error)")
            close()
            return .unavailable
        }
    }

    func select(id: String) -> SelectionResult {
        guard let owner, let page else { return .ignored }
        guard id == page.backID || actions[id] != nil else { return .ignored }
        guard ownerIsCurrent(owner) else {
            close()
            return .unavailable
        }
        do {
            if id == page.backID {
                levels.removeLast()
                try loadPage()
                return .updated
            }
            guard let snapshot = actions[id], elementPID(snapshot.element) == owner.pid else {
                close()
                return .unavailable
            }
            guard try isEnabledMenuItem(snapshot.element) else { return .ignored }
            guard ownerIsCurrent(owner) else {
                close()
                return .unavailable
            }
            if let root = snapshot.submenuRoot {
                levels.append(Level(root: root, title: snapshot.attributes["AXTitle"] as? String))
                try loadPage()
                return .updated
            }
            let result = press(snapshot.element)
            close()
            return result == .success ? .performed : .unavailable
        } catch {
            close()
            return .unavailable
        }
    }

    func close(disposition: RevealDisposition = .conceal) {
        generation += 1
        acquisition?.cancel()
        acquisition = nil
        clearMenu()
        let release = releaseReveal
        releaseReveal = nil
        release?(disposition)
    }

    private func clearMenu() {
        page = nil
        actions.removeAll()
        levels.removeAll()
        owner = nil
    }

    private func menuRoot(of element: AXUIElement) throws -> AXUIElement? {
        let deadline = MenuAXDeadline(start: environment.now(), timeout: 0.25)
        let value: Any?
        do {
            value = try environment.readAttribute(
                element, kAXChildrenAttribute as CFString, deadline.remaining(at: environment.now())
            )
        } catch MenuExtractionError.ax(.attributeUnsupported), MenuExtractionError.ax(.noValue) {
            return nil
        }
        guard let value else { return nil }
        guard let children = value as? [AXUIElement] else { throw MenuExtractionError.invalidResponse }
        var menu: AXUIElement?
        for child in children {
            let role = try environment.readAttribute(
                child, kAXRoleAttribute as CFString, deadline.remaining(at: environment.now())
            )
            guard let role = role as? String else { throw MenuExtractionError.invalidResponse }
            if role == kAXMenuRole as String {
                guard menu == nil else { throw MenuExtractionError.invalidResponse }
                menu = child
            }
        }
        return menu
    }

    private func loadPage() throws {
        actions.removeAll()
        page = nil
        guard let owner, let level = levels.last,
              ownerIsCurrent(owner), elementPID(level.root) == owner.pid
        else { throw MenuExtractionError.invalidResponse }
        let snapshots = try reader.readSubmenuSnapshots(from: level.root)
        guard ownerIsCurrent(owner) else { throw MenuExtractionError.invalidResponse }
        let generation = UUID().uuidString
        var rows: [HiddenBarMenuRow] = []
        rows.reserveCapacity(snapshots.count)
        for (index, snapshot) in snapshots.enumerated() {
            let attributes = snapshot.attributes
            let role = attributes["AXRole"] as? String
            guard role == "AXMenuItem" || role == "AXSeparator" else {
                throw MenuExtractionError.invalidResponse
            }
            let title = attributes["AXTitle"] as? String ?? ""
            let separator = role == "AXSeparator" || title.isEmpty
            let enabled = !separator && attributes["AXEnabled"] as? Bool == true
            let id = "\(generation):\(index)"
            rows.append(HiddenBarMenuRow(
                id: id, title: title, enabled: enabled,
                mark: attributes["AXMenuItemMarkChar"] as? String,
                shortcut: shortcut(attributes), submenu: snapshot.submenuRoot != nil, separator: separator
            ))
            if enabled { actions[id] = snapshot }
        }
        page = HiddenBarMenuPage(title: level.title, rows: rows, backID: levels.count > 1 ? "\(generation):back" : nil)
    }

    private func isEnabledMenuItem(_ element: AXUIElement) throws -> Bool {
        let names = ["AXEnabled", "AXRole"]
        let values = try environment.readAttributes(element, names as CFArray, 0.25)
        let attributes = try MenuAXReader.decodeAttributeValues(names: names, values: values)
        return attributes["AXEnabled"] as? Bool == true && attributes["AXRole"] as? String == "AXMenuItem"
    }

    private func shortcut(_ attributes: [String: Any]) -> String? {
        guard let key = attributes["AXMenuItemCmdChar"] as? String, !key.isEmpty else { return nil }
        let modifiers = NSEvent.ModifierFlags.fromAXModifiers(attributes["AXMenuItemCmdModifiers"] as? Int)
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + key.uppercased()
    }
}
