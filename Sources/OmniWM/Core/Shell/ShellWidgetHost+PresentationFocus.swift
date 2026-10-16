// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

@MainActor
final class ShellPickerFocus {
    weak var surface: ShellWidgetSurface?
    weak var parent: ShellFocusPanel?
    weak var child: NSWindow?
    let isCurrent: @MainActor () -> Bool
    let handle: ElementHandle
    let keyboardNavigation: Bool
    var finished = false

    init(
        surface: ShellWidgetSurface,
        parent: ShellFocusPanel,
        child: NSWindow?,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.surface = surface
        self.parent = parent
        self.child = child
        self.isCurrent = isCurrent
        handle = surface.declaredFocus ? surface.focused : .none
        keyboardNavigation = surface.focusAxis != nil
    }

    func finish() -> Bool {
        guard !finished else { return false }
        finished = true
        if let child { OwnedWindowRegistry.shared.unregister(child) }
        parent?.hasOwnedChildPresentation = nil
        return true
    }
}

extension ShellWidgetHost {
    func desktopSource(
        for surface: ShellWidgetSurface,
        isCurrent: @escaping @MainActor () -> Bool
    ) -> ShellDesktopSource? {
        guard let window = surface.view.window as? ShellFocusPanel else { return nil }
        let current: @MainActor () -> Bool = { [weak surface, weak window] in
            guard let surface, let window else { return false }
            return surface.visible && surface.view.window === window && window.isVisible && isCurrent()
        }
        guard current() else { return nil }
        return ShellDesktopSource(
            window: window,
            isCurrent: current,
            beginFocus: { [weak self, weak surface, weak window] child in
                guard let self, let surface, let window, current() else {
                    throw ShellResourceFailure("source_surface_unavailable")
                }
                guard pickerFocus == nil, window.attachedSheet == nil else {
                    throw ShellResourceFailure("picker_busy")
                }
                let focus = ShellPickerFocus(surface: surface, parent: window, child: child, isCurrent: current)
                pickerFocus = focus
                window.hasOwnedChildPresentation = { [weak focus] in focus?.finished == false }
                if let child {
                    OwnedWindowRegistry.shared.register(
                        child, surfaceId: "shell-picker-\(ObjectIdentifier(child))",
                        policy: SurfacePolicy(
                            kind: .utility,
                            hitTestPolicy: .frontmostInteractive,
                            capturePolicy: .included,
                            suppressesManagedFocusRecovery: true
                        )
                    )
                }
                focusShellSurface(surface, presentation: true)
                guard focusedSurface === surface else {
                    finishPickerFocus(focus, current: nil, appActive: false)
                    throw ShellResourceFailure("source_focus_unavailable")
                }
                return { [weak self, focus] resume in
                    if let self { finishPickerFocus(
                        focus,
                        current: NSApp.keyWindow,
                        appActive: NSApp.isActive,
                        resume: resume
                    ) } else { _ = focus.finish() }
                }
            }
        )
    }

    func isPresentingPicker(on surface: ShellWidgetSurface) -> Bool {
        pickerFocus?.surface === surface && pickerFocus?.finished == false
    }

    func retainsPickerFocus(on surface: ShellWidgetSurface) -> Bool {
        isPresentingPicker(on: surface) && pickerFocus?.isCurrent() == true
    }

    func shellWindowResigned(from surface: ShellWidgetSurface) {
        guard !retainsPickerFocus(on: surface) else { return }
        releaseShellFocus(from: surface, restore: false)
    }

    func finishPickerFocus(_ focus: ShellPickerFocus, current: NSWindow?, appActive: Bool, resume: Bool = true) {
        guard focus.finish(), pickerFocus === focus else { return }
        pickerFocus = nil
        guard let surface = focus.surface, focusedSurface === surface else { return }
        guard resume, Self.shouldResumePickerFocus(
            sourceCurrent: focus.isCurrent(), current: current, parent: focus.parent,
            child: focus.child, appActive: appActive
        ) else {
            releaseShellFocus(from: surface, restore: false)
            return
        }
        if surface.declaredFocus {
            focusShellSurface(surface)
        } else if surface.layout.core.contains(focus.handle), surface.layout.core.content(of: focus.handle).focusable {
            surface.focusDeclared(focus.handle)
        } else if focus.keyboardNavigation {
            focusShellSurface(surface, keyboardNavigation: true)
        } else {
            releaseShellFocus(from: surface, restore: true)
        }
    }

    static func shouldResumePickerFocus(
        sourceCurrent: Bool, current: NSWindow?, parent: NSWindow?, child: NSWindow?, appActive: Bool
    ) -> Bool {
        sourceCurrent && appActive && (current == nil || current === parent || current === child)
    }
}
