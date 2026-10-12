// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
import Foundation

struct HotkeyBindingFact: Sendable, Equatable {
    let command: String
    let display: String
    let route: String
}

struct HotkeyHealthFacts: Sendable, Equatable {
    let isRunning: Bool
    let isHyperTriggerActive: Bool
    let hyperTriggerTapInstalled: Bool
    let capsLockHyperRemapActive: Bool
    let systemHyperTriggerEnabled: Bool
    let systemHyperTriggerName: String
    let systemHyperTriggerFailure: String?
    let suppressedHotkeyCount: Int
    let registrationFailureCount: Int
    let sideSpecificCount: Int
    let bindingCount: Int
    let bindings: [HotkeyBindingFact]
}

struct InputHealthSnapshot: Sendable, Equatable {
    let hotkey: HotkeyHealthFacts
    let mouseTapInstalled: Bool
    let secureInput: SecureInputHealthFacts
    let liveModifierFlags: UInt
    let mouseTapDisableCount: Int
    let hyperTapDisableCount: Int
    let lastTapDisable: Date?

    func formatted() -> String {
        var lines = [
            "hotkeyCenterRunning=\(hotkey.isRunning) hyperActive=\(hotkey.isHyperTriggerActive) "
                +
                "hyperTapInstalled=\(hotkey.hyperTriggerTapInstalled) capsLockRemap=\(hotkey.capsLockHyperRemapActive)",
            "systemHyperTrigger=\(hotkey.systemHyperTriggerName) enabled=\(hotkey.systemHyperTriggerEnabled) "
                + "failure=\(hotkey.systemHyperTriggerFailure ?? "none")",
            "bindings=\(hotkey.bindingCount) sideSpecific=\(hotkey.sideSpecificCount) "
                +
                "registrationFailures=\(hotkey.registrationFailureCount) suppressedKeys=\(hotkey.suppressedHotkeyCount)",
            "mouseTapInstalled=\(mouseTapInstalled) modifierFlags=\(InputDiagnostics.modifierLabel(liveModifierFlags))",
            "secureInput observed=\(secureInput.observed) live=\(secureInput.live) "
                + "subscribed=\(secureInput.subscribed) notifications=\(secureInput.notifications)",
            "tapDisables mouse=\(mouseTapDisableCount) hyper=\(hyperTapDisableCount) "
                + "last=\(lastTapDisable?.ISO8601Format() ?? "never")"
        ]
        if !hotkey.bindings.isEmpty {
            lines.append("bindings:")
            lines.append(contentsOf: hotkey.bindings.map { "  \($0.command) \($0.display) route=\($0.route)" })
        }
        return lines.joined(separator: "\n")
    }
}

struct OwnedSurfaceSnapshot: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        let id: String
        let kind: String
        let hitTestPolicy: String
        let capturePolicy: String
        let suppressesManagedFocusRecovery: Bool
        let frame: CGRect?
        let isKeyWindow: Bool
        let isMainWindow: Bool
        let canBecomeKey: Bool
        let canBecomeMain: Bool
        let firstResponder: String?
    }

    let windows: [Window]
    let appActive: Bool
    let activationPolicy: String
    let keyWindowKind: String
    let mainWindowKind: String
    let hasFrontmostSuppressingWindow: Bool
    let hasVisibleSuppressingWindow: Bool

    func formatted() -> String {
        var lines = [
            "appActive=\(appActive) activationPolicy=\(activationPolicy) "
                + "keyWindow=\(keyWindowKind) mainWindow=\(mainWindowKind)",
            "hasFrontmostSuppressing=\(hasFrontmostSuppressingWindow) "
                + "hasVisibleSuppressing=\(hasVisibleSuppressingWindow)"
        ]
        if windows.isEmpty {
            lines.append("windows: none")
        } else {
            lines.append(contentsOf: windows.map { window in
                "[\(window.id)] kind=\(window.kind) frame=\(TraceFormat.rect(window.frame)) "
                    + "hit=\(window.hitTestPolicy) cap=\(window.capturePolicy) "
                    + "suppressRecovery=\(window.suppressesManagedFocusRecovery) "
                    + "key=\(window.isKeyWindow) main=\(window.isMainWindow) "
                    + "canKey=\(window.canBecomeKey) canMain=\(window.canBecomeMain) "
                    + "firstResponder=\(window.firstResponder ?? "nil")"
            })
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum InputDiagnostics {
    static func multitouchHealth(_ controller: WMController) -> String {
        controller.mouseEventHandler.multitouchDiagnosticsSnapshot?.formatted() ?? "sourceState=absent"
    }

    static func inputHealth(_ controller: WMController) -> InputHealthSnapshot {
        let counters = InputTapHealth.counters
        return InputHealthSnapshot(
            hotkey: controller.hotkeys.hotkeyHealthFacts(),
            mouseTapInstalled: MouseEventHandler._instance?.state.eventTap != nil,
            secureInput: controller.secureInputMonitor.healthFacts(),
            liveModifierFlags: NSEvent.modifierFlags.rawValue,
            mouseTapDisableCount: counters.mouseDisableCount,
            hyperTapDisableCount: counters.hyperDisableCount,
            lastTapDisable: counters.lastDisable
        )
    }

    static func ownedSurfaces(_ controller: WMController) -> OwnedSurfaceSnapshot {
        let infos = controller.ownedWindowRegistry.visibleSurfaceInfos()
        let keyWindow = NSApp?.keyWindow
        let mainWindow = NSApp?.mainWindow
        let windows = infos.map { info -> OwnedSurfaceSnapshot.Window in
            let window = info.window
            return OwnedSurfaceSnapshot.Window(
                id: info.id,
                kind: info.kind.rawValue,
                hitTestPolicy: hitTestLabel(info.hitTestPolicy),
                capturePolicy: info.capturePolicy == .included ? "included" : "excluded",
                suppressesManagedFocusRecovery: info.suppressesManagedFocusRecovery,
                frame: info.frame,
                isKeyWindow: window?.isKeyWindow ?? false,
                isMainWindow: window?.isMainWindow ?? false,
                canBecomeKey: window?.canBecomeKey ?? false,
                canBecomeMain: window?.canBecomeMain ?? false,
                firstResponder: window?.firstResponder.map { String(describing: type(of: $0)) }
            )
        }
        return OwnedSurfaceSnapshot(
            windows: windows,
            appActive: NSApp?.isActive ?? false,
            activationPolicy: activationPolicyLabel(NSApp?.activationPolicy()),
            keyWindowKind: matchedSurface(keyWindow, infos),
            mainWindowKind: matchedSurface(mainWindow, infos),
            hasFrontmostSuppressingWindow: controller.ownedWindowRegistry.hasFrontmostWindow,
            hasVisibleSuppressingWindow: controller.ownedWindowRegistry.hasVisibleWindow
        )
    }

    nonisolated static func modifierLabel(_ raw: UInt) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.capsLock) { parts.append("caps") }
        if flags.contains(.function) { parts.append("fn") }
        return parts.isEmpty ? "[]" : parts.joined(separator: "+")
    }

    private static func hitTestLabel(_ policy: HitTestPolicy) -> String {
        switch policy {
        case .interactive: "interactive"
        case .frontmostInteractive: "frontmostInteractive"
        case .passthrough: "passthrough"
        }
    }

    private static func activationPolicyLabel(_ policy: NSApplication.ActivationPolicy?) -> String {
        switch policy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        case .none: "unknown"
        @unknown default: "unknown"
        }
    }

    private static func matchedSurface(_ window: NSWindow?, _ infos: [SurfaceScene.VisibleSurfaceInfo]) -> String {
        guard let window else { return "nil" }
        if let info = infos.first(where: { $0.window === window }) {
            return "\(info.kind.rawValue):\(info.id)"
        }
        return "<non-surface:\(String(describing: type(of: window)))>"
    }
}
