// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellWidgetHost {
    var focusedIsland: Monitor.ID? {
        guard let focusedSurface else { return nil }
        return islandWindows.first { $0.value.surface === focusedSurface }?.key
    }

    func connectSurfaceFocus(_ surface: ShellWidgetSurface, isCurrent: @escaping @MainActor () -> Bool) {
        surface.onFocusChange = { [weak self, weak surface] focused in
            guard let self, let surface else { return }
            if focused {
                guard isCurrent() else { surface.blurDeclaredFocus()
                    return
                }
                focusShellSurface(surface)
            } else {
                guard !retainsPickerFocus(on: surface) else { return }
                releaseShellFocus(
                    from: surface,
                    restore: (surface.view.window as? ShellFocusPanel)?.isResigningKey != true
                )
            }
        }
    }

    func focusShellSurface(
        _ surface: ShellWidgetSurface,
        keyboardNavigation: Bool = false,
        presentation: Bool = false
    ) {
        if pickerFocus != nil, !presentation {
            if focusedSurface !== surface { surface.blurDeclaredFocus() }
            return
        }
        guard let window = surface.view.window as? ShellFocusPanel, window.isVisible,
              surface.declaredFocus || (keyboardNavigation && surface.focusAxis != nil) || presentation
        else { surface.blurDeclaredFocus()
            return
        }
        if focusedSurface !== surface {
            let previousSource = focusedSurface
            let previousWindow = focusedWindow
            let previousSuppression = focusedWindowSuppression
            if previousWindow == nil {
                shellPreviousKeyWindow = NSApp.keyWindow
                shellPreviousFirstResponder = NSApp.keyWindow?.firstResponder
                focusPolicyEngine?.beginLease(owner: .shellIsland, reason: "shell_focus", duration: nil)
            }
            focusedSurface = surface
            focusedWindow = window
            if previousWindow !== window {
                focusedWindowSuppression = OwnedWindowRegistry.shared.setManagedFocusRecoverySuppressed(
                    true,
                    for: window
                )
            }
            previousSource?.blurDeclaredFocus()
            if let previousWindow, previousWindow !== window {
                setShellKeyboardActive(false, surface: previousSource, window: previousWindow)
                if let previousSuppression {
                    OwnedWindowRegistry.shared.setManagedFocusRecoverySuppressed(
                        previousSuppression,
                        for: previousWindow
                    )
                }
            }
        }
        window.onBlur = { [weak self, weak surface] in
            guard let surface else { return }
            self?.shellWindowResigned(from: surface)
        }
        setShellKeyboardActive(true, surface: surface, window: window)
        window.makeKey()
        guard window.isKeyWindow else {
            releaseShellFocus(from: surface, restore: true)
            return
        }
        window.makeFirstResponder(surface.preferredFirstResponder)
        publishIslandFocus()
        updateIslandInputMonitoring()
    }

    func releaseShellFocus(from surface: ShellWidgetSurface, restore: Bool) {
        guard focusedSurface === surface else { return }
        let restore = restore && !isPresentingPicker(on: surface)
        let window = focusedWindow
        let suppression = focusedWindowSuppression
        let previousWindow = shellPreviousKeyWindow
        let previousResponder = shellPreviousFirstResponder
        focusedSurface = nil
        focusedWindow = nil
        focusedWindowSuppression = nil
        shellPreviousKeyWindow = nil
        shellPreviousFirstResponder = nil
        surface.blurDeclaredFocus()
        if let window {
            (window as? ShellFocusPanel)?.onBlur = nil
            setShellKeyboardActive(false, surface: surface, window: window)
            if let suppression { OwnedWindowRegistry.shared.setManagedFocusRecoverySuppressed(suppression, for: window)
            }
        }
        focusPolicyEngine?.endLease(owner: .shellIsland)
        if restore, Self.shouldRestoreShellFocus(
               previous: previousWindow,
               current: NSApp.keyWindow,
               source: window,
               appActive: NSApp.isActive
           ),
           let previousWindow
        {
            previousWindow.makeKey()
            if let previousResponder { previousWindow.makeFirstResponder(previousResponder) }
        } else if let window, window.isKeyWindow, (window as? ShellFocusPanel)?.isResigningKey != true {
            window.resignKey()
        }
        publishIslandFocus()
        updateIslandInputMonitoring()
    }

    private func setShellKeyboardActive(_ active: Bool, surface: ShellWidgetSurface?, window: NSWindow) {
        if let island = islandWindows.values.first(where: { $0.surface === surface }) {
            island.setKeyboardActive(active)
        } else {
            (window as? ShellFocusPanel)?.acceptsDeclaredFocus = active
        }
    }

    static func shouldRestoreShellFocus(
        previous: NSWindow?,
        current: NSWindow?,
        source: NSWindow?,
        appActive: Bool
    ) -> Bool {
        appActive && previous?.isVisible == true && (current == nil || current === source)
    }

    func containsShellFocus(_ surface: ShellWidgetSurface, at point: CGPoint) -> Bool {
        if let island = islandWindows.values
            .first(where: { $0.surface === surface }) { return island.contains(screenPoint: point) }
        guard let window = surface.view.window, window.isVisible else { return false }
        return surface.view.bounds.contains(surface.view.convert(window.convertPoint(fromScreen: point), from: nil))
    }

    private func acceptsShellFocus(_ surface: ShellWidgetSurface, at point: CGPoint) -> Bool {
        guard containsShellFocus(surface, at: point), let window = surface.view.window else { return false }
        if surface.focusAxis != nil { return true }
        let local = surface.view.convert(window.convertPoint(fromScreen: point), from: nil)
        return surface.layout.core.hitTest(
            x: Float(local.x),
            y: Float(local.y),
            matching: { $0.focusable },
            clip: surface.clips
        ).slot >= 0
    }

    func acceptsShellFocus(at point: CGPoint) -> Bool {
        if islandWindows.values.contains(where: { $0.acceptsFocus(at: point) }) { return true }
        if let popout, acceptsShellFocus(popout.surface, at: point) { return true }
        if let hiddenBarMenu, acceptsShellFocus(hiddenBarMenu.popout.surface, at: point) { return true }
        if drawer?.sections.contains(where: { acceptsShellFocus($0.surface, at: point) }) == true { return true }
        return widgets.values.contains { state in
            state.instances.values.contains { instance in
                instance.surface.map { acceptsShellFocus($0, at: point) } ?? false
            }
        }
    }
}
