// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

struct AXWindowRef: Hashable, @unchecked Sendable {
    let element: AXUIElement
    let windowId: Int

    init(element: AXUIElement, windowId: Int) {
        self.element = element
        self.windowId = windowId
    }

    init(element: AXUIElement) throws {
        self.element = element
        var value: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &value)
        guard result == .success else { throw AXErrorWrapper.cannotGetWindowId }
        self.windowId = Int(value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowId == rhs.windowId
    }
}

enum AXErrorWrapper: Error {
    case cannotSetFrame
    case cannotGetAttribute
    case cannotGetWindowId
}

func sameAXWindowIdentity(_ lhs: AXWindowRef, _ rhs: AXWindowRef) -> Bool {
    lhs.windowId == rhs.windowId && CFEqual(lhs.element, rhs.element)
}

enum AXWindowHeuristicReason: String, Sendable {
    case attributeFetchFailed
    case accessoryWithoutClose
    case noButtonsOnNonStandardSubrole
    case nonStandardSubrole
    case missingFullscreenButton
    case disabledFullscreenButton
}

struct AXWindowFacts: Equatable, Sendable {
    let role: String?
    let subrole: String?
    let title: String?
    let hasCloseButton: Bool
    let hasFullscreenButton: Bool
    let fullscreenButtonEnabled: Bool?
    let hasZoomButton: Bool
    let hasMinimizeButton: Bool
    let appPolicy: NSApplication.ActivationPolicy?
    let bundleId: String?
    let attributeFetchSucceeded: Bool
    var isMain: Bool?
    var isModal: Bool?
}

struct AXWindowDecisionEvidence: Equatable, Sendable {
    let facts: AXWindowFacts
    let sizeConstraints: WindowSizeConstraints

    static func unavailable(
        role: String? = nil,
        subrole: String? = nil,
        appPolicy: NSApplication.ActivationPolicy? = nil,
        bundleId: String? = nil
    ) -> Self {
        Self(
            facts: AXWindowFacts(
                role: role,
                subrole: subrole,
                title: nil,
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: appPolicy,
                bundleId: bundleId,
                attributeFetchSucceeded: false
            ),
            sizeConstraints: .unconstrained
        )
    }
}

struct AXWindowFactAttributeValues {
    let role: String?
    let subrole: String?
    let title: String?
    let closeButton: Any?
    let fullscreenButton: Any?
    let fullscreenButtonEnabled: Bool?
    let zoomButton: Any?
    let minimizeButton: Any?
    var main: Any?
    var modal: Any?
}

struct AXWindowConstraintInputs {
    let hasGrowArea: Bool
    let hasZoomButton: Bool
    let subrole: String?
    let minSize: CGSize?
    let maxSize: CGSize?
    let currentSize: CGSize?
}

enum AXFullscreenButtonEvidence {
    case absent
    case present(AXUIElement)
    case failed

    var element: AXUIElement? {
        guard case let .present(element) = self else { return nil }
        return element
    }

    var succeeded: Bool {
        guard case .failed = self else { return true }
        return false
    }
}

struct AXWindowHeuristicDisposition: Equatable, Sendable {
    let disposition: WindowDecisionDisposition
    let reasons: [AXWindowHeuristicReason]
}

enum AXWindowType {
    case tiling
    case floating
}

enum AXWindowService {
    // Held AXUIElement references for windows that may be pruned from the
    // app's kAXWindowsAttribute enumeration (e.g. scratchpad-hidden Calculator
    // windows that drop out of the AX windows list while off-screen). Survives
    // AppAXContext reconciliation because we hold the CFType ref directly.
    private static let pinnedElementsLock = NSLock()
    private nonisolated(unsafe) static var pinnedElements: [UInt32: AXUIElement] = [:]

    static func pinAXElement(_ element: AXUIElement, for windowId: UInt32) {
        pinnedElementsLock.lock()
        defer { pinnedElementsLock.unlock() }
        pinnedElements[windowId] = element
    }

    static func unpinAXElement(for windowId: UInt32) {
        pinnedElementsLock.lock()
        defer { pinnedElementsLock.unlock() }
        pinnedElements.removeValue(forKey: windowId)
    }

    static func hasPinnedAXElement(for windowId: UInt32) -> Bool {
        pinnedElementsLock.lock()
        defer { pinnedElementsLock.unlock() }
        return pinnedElements[windowId] != nil
    }

    private static func pinnedAXElement(for windowId: UInt32) -> AXUIElement? {
        pinnedElementsLock.lock()
        defer { pinnedElementsLock.unlock() }
        return pinnedElements[windowId]
    }

    static func pinnedWindowId(for windowId: UInt32) -> CGWindowID? {
        guard let pinned = pinnedAXElement(for: windowId) else { return nil }
        var resolvedWindowId: CGWindowID = 0
        guard _AXUIElementGetWindow(pinned, &resolvedWindowId) == .success else { return nil }
        return resolvedWindowId
    }

    private static let titleCacheCap = 512
    @MainActor private static var titleCache: [UInt32: String?] = [:]
    @MainActor private static var titleInsertionOrder: [UInt32] = []

    @MainActor
    static func titlePreferFast(windowId: UInt32) -> String? {
        if let cached = titleCache[windowId] {
            return cached
        }
        let title = SkyLight.shared.getWindowTitle(windowId)
        storeTitleCacheEntry(windowId: windowId, title: title)
        return title
    }

    @MainActor
    static func invalidateCachedTitle(windowId: UInt32) {
        titleCache.removeValue(forKey: windowId)
        titleInsertionOrder.removeAll { $0 == windowId }
    }

    @MainActor
    static func invalidateCachedTitles(windowIds: [UInt32]) {
        for windowId in windowIds {
            titleCache.removeValue(forKey: windowId)
        }
        let windowIdSet = Set(windowIds)
        titleInsertionOrder.removeAll { windowIdSet.contains($0) }
    }

    @MainActor
    private static func storeTitleCacheEntry(windowId: UInt32, title: String?) {
        if titleCache.index(forKey: windowId) == nil {
            titleInsertionOrder.append(windowId)
        }
        titleCache[windowId] = title
        while titleCache.count > titleCacheCap, let oldest = titleInsertionOrder.first {
            titleInsertionOrder.removeFirst()
            titleCache.removeValue(forKey: oldest)
        }
    }

    static func shouldTreatAsTopLevelWindow(role: String?, subrole: String?) -> Bool {
        role == kAXWindowRole as String
    }

    static func windowId(_ window: AXWindowRef) -> Int {
        window.windowId
    }

    static func processIdentifier(_ window: AXWindowRef) -> pid_t? {
        return MainThreadAXSpanTrace.measure(.readProcessIdentifier, windowId: window.windowId) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(window.element, &pid) == .success else { return nil }
            return pid
        } succeeded: { $0 != nil }
    }

    static func isSizeSettable(_ window: AXWindowRef) -> Bool {
        return MainThreadAXSpanTrace.measure(.readSizeSettable, windowId: window.windowId) {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(
                window.element,
                kAXSizeAttribute as CFString,
                &settable
            ) == .success && settable.boolValue
        }
    }

    static func subrole(_ window: AXWindowRef) -> String? {
        MainThreadAXSpanTrace.measure(.readSubrole, windowId: window.windowId) {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window.element, kAXSubroleAttribute as CFString, &value)
            guard result == .success, let subrole = value as? String else { return nil }
            return subrole
        } succeeded: { $0 != nil }
    }

    static func roleAndSubrole(_ window: AXWindowRef) -> (role: String?, subrole: String?) {
        MainThreadAXSpanTrace.measure(.readRoleAndSubrole, windowId: window.windowId) {
            let attributes = [
                kAXRoleAttribute as CFString,
                kAXSubroleAttribute as CFString
            ] as CFArray
            var valuesPtr: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(window.element, attributes, .init(), &valuesPtr)
            guard result == .success, let values = valuesPtr, CFArrayGetCount(values) == 2 else { return (nil, nil) }
            return (
                AXAttributeValue.stringValue(AXAttributeValue.value(at: 0, in: values)),
                AXAttributeValue.stringValue(AXAttributeValue.value(at: 1, in: values))
            )
        } succeeded: { $0.role != nil }
    }

    static func axWindowRef(for windowId: UInt32, pid: pid_t) -> AXWindowRef? {
        MainThreadAXSpanTrace.measure(.lookupWindowRef, pid: pid, windowId: Int(windowId)) {
            if let pinned = pinnedAXElement(for: windowId) {
                var winId: CGWindowID = 0
                let result = MainThreadAXSpanTrace.measure(.lookupPinnedWindowID, pid: pid, windowId: Int(windowId)) {
                    _AXUIElementGetWindow(pinned, &winId)
                } succeeded: { $0 == .success } status: { $0.rawValue } resolvedWindowId: {
                    $0 == .success ? Int(winId) : nil
                }
                if result == .success, winId == windowId {
                    return AXWindowRef(element: pinned, windowId: Int(winId))
                }
                unpinAXElement(for: windowId)
            }

            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let result = MainThreadAXSpanTrace.measure(.readApplicationWindows, pid: pid, windowId: Int(windowId)) {
                AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            } succeeded: { $0 == .success } status: { $0.rawValue }

            guard result == .success, let windows = windowsRef as? [AXUIElement] else {
                return nil
            }

            for window in windows {
                var winId: CGWindowID = 0
                let result = MainThreadAXSpanTrace.measure(
                    .lookupCandidateWindowID, pid: pid, windowId: Int(windowId), count: windows.count
                ) {
                    _AXUIElementGetWindow(window, &winId)
                } succeeded: { $0 == .success } status: { $0.rawValue } resolvedWindowId: {
                    $0 == .success ? Int(winId) : nil
                }
                if result == .success, winId == windowId {
                    return AXWindowRef(element: window, windowId: Int(winId))
                }
            }

            return nil
        } succeeded: { $0 != nil }
    }
}
