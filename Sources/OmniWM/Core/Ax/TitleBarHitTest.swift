// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
import QuartzCore

struct TitleBarHit: Equatable {
    enum BarPlacement: Equatable {
        case windowHasNoBar
        case outsideBar
        case insideBar(elementWithinBar: Bool)
    }

    let role: String?
    var subrole: String?
    var placement: BarPlacement = .windowHasNoBar
}

enum TitleBarHitTest {
    static let messagingTimeout: Float = 0.05
    static let budget: CFTimeInterval = 0.12

    static let backgroundRoles: Set<String> = [
        kAXWindowRole,
        kAXToolbarRole,
        kAXTabGroupRole,
        kAXGroupRole,
        kAXStaticTextRole
    ]

    static let controlRoles: Set<String> = [
        kAXButtonRole,
        kAXRadioButtonRole,
        kAXCheckBoxRole,
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        kAXPopUpButtonRole,
        kAXMenuButtonRole,
        kAXSliderRole,
        kAXIncrementorRole,
        kAXDisclosureTriangleRole,
        kAXColorWellRole,
        "AXLink"
    ]

    static let tabButtonSubrole = "AXTabButton"

    static func isWindowBackground(role: String?) -> Bool {
        role.map(backgroundRoles.contains) ?? false
    }

    static func isControl(role: String?, subrole: String? = nil) -> Bool {
        subrole != tabButtonSubrole && (role.map(controlRoles.contains) ?? false)
    }

    static func isTitleBar(_ hit: TitleBarHit?) -> Bool {
        guard let hit else { return false }
        switch hit.placement {
        case .windowHasNoBar:
            return isWindowBackground(role: hit.role)
        case .outsideBar:
            return false
        case let .insideBar(elementWithinBar):
            return isWindowBackground(role: hit.role)
                || !(isControl(role: hit.role, subrole: hit.subrole) && elementWithinBar)
        }
    }

    static func hit(pid: pid_t, at point: CGPoint) -> TitleBarHit? {
        let probe = AccessibilityProbe(deadline: CACurrentMediaTime() + budget)
        let hit = probe.hit(pid: pid, at: ScreenCoordinateSpace.toWindowServer(point: point))
        return probe.ranOutOfTime ? nil : hit
    }
}

private final class AccessibilityProbe {
    private let deadline: CFTimeInterval
    private(set) var ranOutOfTime = false

    init(deadline: CFTimeInterval) {
        self.deadline = deadline
    }

    func hit(pid: pid_t, at location: CGPoint) -> TitleBarHit? {
        let app = AXUIElementCreateApplication(pid)
        guard limit(app) else { return nil }
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(location.x), Float(location.y), &found) == .success,
              let element = found
        else { return nil }
        let role = string(element, kAXRoleAttribute)
        guard let bar = window(of: element).flatMap(barFrame(of:)) else {
            return TitleBarHit(role: role)
        }
        guard bar.contains(location) else {
            return TitleBarHit(role: role, placement: .outsideBar)
        }
        let withinBar = frame(of: element).map { $0.maxY <= bar.maxY + 1 } ?? true
        return TitleBarHit(
            role: role,
            subrole: string(element, kAXSubroleAttribute),
            placement: .insideBar(elementWithinBar: withinBar)
        )
    }

    private func limit(_ element: AXUIElement) -> Bool {
        let remaining = deadline - CACurrentMediaTime()
        guard remaining > 0 else {
            ranOutOfTime = true
            return false
        }
        AXUIElementSetMessagingTimeout(element, min(TitleBarHitTest.messagingTimeout, Float(remaining)))
        return true
    }

    private func window(of element: AXUIElement) -> AXUIElement? {
        if let window = elementAttribute(element, kAXWindowAttribute) { return window }
        var current = element
        for _ in 0 ..< 16 {
            if string(current, kAXRoleAttribute) == kAXWindowRole { return current }
            guard let parent = elementAttribute(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    private func barFrame(of window: AXUIElement) -> CGRect? {
        guard let windowFrame = frame(of: window) else { return nil }
        var bar: CGRect?
        if let close = elementAttribute(window, kAXCloseButtonAttribute).flatMap(frame(of:)) {
            let depth = 2 * (close.minY - windowFrame.minY) + close.height
            bar = CGRect(x: windowFrame.minX, y: windowFrame.minY, width: windowFrame.width, height: depth)
        }
        if let toolbar = toolbarFrame(of: window) {
            bar = bar.map { $0.union(toolbar) } ?? toolbar
        }
        return bar
    }

    private func toolbarFrame(of window: AXUIElement) -> CGRect? {
        guard let value = attribute(window, kAXChildrenAttribute),
              let children = value as? [AXUIElement],
              let toolbar = children.first(where: { string($0, kAXRoleAttribute) == kAXToolbarRole })
        else { return nil }
        return frame(of: toolbar)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard limit(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let value = attribute(element, "AXFrame"), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value as AnyObject, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }
}
