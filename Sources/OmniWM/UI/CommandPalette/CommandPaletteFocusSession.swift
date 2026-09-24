// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

@MainActor
final class CommandPaletteFocusSession {
    private let environment: CommandPaletteEnvironment
    private weak var wmController: WMController?
    private(set) var restoreFocusTarget: CommandPaletteFocusTarget?
    private(set) var menuFocusTarget: CommandPaletteFocusTarget?
    private(set) var summonAnchor: CommandPaletteSummonAnchor?
    private var cachedMenuTargetApp: CommandPaletteAppSnapshot?

    init(environment: CommandPaletteEnvironment) {
        self.environment = environment
    }

    func begin(wmController: WMController) {
        self.wmController = wmController
        restoreFocusTarget = captureFrontmostFocusTarget()
        menuFocusTarget = resolveMenuFocusTarget()
        summonAnchor = Self.resolveSummonAnchor(for: wmController)
    }

    func clear() {
        restoreFocusTarget = nil
        menuFocusTarget = nil
        summonAnchor = nil
        wmController = nil
    }

    static func resolveSummonAnchor(for wmController: WMController) -> CommandPaletteSummonAnchor? {
        guard let activeWorkspace = wmController.activeWorkspace() else { return nil }

        let anchorToken = if let focusedToken = wmController.workspaceManager.selectedManagedToken,
                             let entry = wmController.workspaceManager.entry(for: focusedToken),
                             entry.workspaceId == activeWorkspace.id
        {
            focusedToken
        } else {
            wmController.workspaceManager.lastFocusedToken(in: activeWorkspace.id)
        }

        guard let anchorToken,
              let entry = wmController.workspaceManager.entry(for: anchorToken),
              entry.workspaceId == activeWorkspace.id
        else {
            return nil
        }

        return .init(token: anchorToken, workspaceId: activeWorkspace.id)
    }

    static func resolveMenuTarget(
        current: CommandPaletteAppSnapshot?,
        cached: CommandPaletteAppSnapshot?,
        ownBundleIdentifier: String?
    ) -> CommandPaletteAppSnapshot? {
        sanitizedMenuTarget(current, ownBundleIdentifier: ownBundleIdentifier)
            ?? sanitizedMenuTarget(cached, ownBundleIdentifier: ownBundleIdentifier)
    }

    private func captureFrontmostFocusTarget() -> CommandPaletteFocusTarget? {
        guard let app = environment.frontmostApplication(),
              !app.isTerminated
        else {
            return nil
        }

        return captureFocusTarget(for: app)
    }

    private func resolveMenuFocusTarget() -> CommandPaletteFocusTarget? {
        let ownBundleIdentifier = environment.ownBundleIdentifier()
        let currentTarget = environment.frontmostApplication().map(CommandPaletteAppSnapshot.init(app:))
        if let currentTarget = Self.resolveMenuTarget(
            current: currentTarget,
            cached: nil,
            ownBundleIdentifier: ownBundleIdentifier
        ) {
            cachedMenuTargetApp = currentTarget
            return focusTarget(for: currentTarget)
        }

        let cachedTarget = liveCachedMenuTarget()
        guard let resolvedTarget = Self.resolveMenuTarget(
            current: nil,
            cached: cachedTarget,
            ownBundleIdentifier: ownBundleIdentifier
        ) else {
            return nil
        }
        return focusTarget(for: resolvedTarget)
    }

    private static func sanitizedMenuTarget(
        _ target: CommandPaletteAppSnapshot?,
        ownBundleIdentifier: String?
    ) -> CommandPaletteAppSnapshot? {
        guard let target, !target.isTerminated else { return nil }
        guard target.bundleIdentifier != ownBundleIdentifier else { return nil }
        return target
    }

    private func liveCachedMenuTarget() -> CommandPaletteAppSnapshot? {
        guard let cachedMenuTargetApp else { return nil }
        guard let app = environment.runningApplication(cachedMenuTargetApp.processIdentifier) else {
            self.cachedMenuTargetApp = nil
            return nil
        }

        let liveTarget = CommandPaletteAppSnapshot(app: app)
        guard !liveTarget.isTerminated else {
            self.cachedMenuTargetApp = nil
            return nil
        }

        if let expectedBundleIdentifier = cachedMenuTargetApp.bundleIdentifier,
           liveTarget.bundleIdentifier != expectedBundleIdentifier
        {
            self.cachedMenuTargetApp = nil
            return nil
        }

        self.cachedMenuTargetApp = liveTarget
        return liveTarget
    }

    private func captureFocusTarget(for app: NSRunningApplication) -> CommandPaletteFocusTarget {
        let focusedWindow = focusedWindow(for: app)
        return CommandPaletteFocusTarget(
            app: CommandPaletteAppSnapshot(app: app),
            focusedWindow: focusedWindow,
            focusedWindowID: focusedWindow.flatMap(getWindowId(from:))
        )
    }

    private func focusTarget(for appSnapshot: CommandPaletteAppSnapshot) -> CommandPaletteFocusTarget? {
        guard let app = environment.runningApplication(appSnapshot.processIdentifier),
              !app.isTerminated
        else {
            if cachedMenuTargetApp?.processIdentifier == appSnapshot.processIdentifier {
                cachedMenuTargetApp = nil
            }
            return nil
        }

        return captureFocusTarget(for: app)
    }

    private func focusedWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success else {
            return nil
        }
        guard let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(windowValue, to: AXUIElement.self)
    }

    func focus(target: CommandPaletteFocusTarget) -> Bool {
        guard let app = environment.runningApplication(target.app.processIdentifier),
              !app.isTerminated,
              !app.isHidden
        else {
            return false
        }

        if let focusedWindow = target.focusedWindow,
           let windowId = target.focusedWindowID
        {
            if let wmController {
                wmController.performWindowOrdering(windowId: Int(windowId))
            } else {
                SkyLight.shared.orderWindow(UInt32(windowId), relativeTo: 0, order: .above)
            }

            focusWindow(
                pid: target.app.processIdentifier,
                windowId: UInt32(windowId),
                windowRef: focusedWindow
            )
        }

        app.activate(options: [])
        return true
    }

    func clipboardPasteTarget() -> CommandPaletteClipboardPasteTarget? {
        guard let restoreFocusTarget,
              let expectedWindowId = restoreFocusTarget.focusedWindowID,
              !restoreFocusTarget.app.isTerminated,
              restoreFocusTarget.app.bundleIdentifier != environment.ownBundleIdentifier(),
              environment.runningApplication(restoreFocusTarget.app.processIdentifier) != nil
        else {
            return nil
        }
        return CommandPaletteClipboardPasteTarget(
            focusTarget: restoreFocusTarget,
            expectedWindowId: expectedWindowId
        )
    }
}
