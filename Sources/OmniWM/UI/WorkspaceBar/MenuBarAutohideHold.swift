// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension Notification.Name {
    static let menuBarHidingDidChange = Notification.Name("AppleInterfaceMenuBarHidingChangedNotification")
}

struct MenuBarHideHold: Codable, Equatable {
    var previous: Bool?
    var temporarilyVisible: Bool?

    var applied: Bool {
        temporarilyVisible != true
    }
}

@MainActor
final class MenuBarAutohideHold {
    struct System {
        let preference: @MainActor () -> Bool?
        let apply: @MainActor (Bool?) -> Bool

        static var live: System {
            System(
                preference: {
                    CFPreferencesCopyValue(
                        hideKey as CFString,
                        kCFPreferencesAnyApplication,
                        kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost
                    ) as? Bool
                },
                apply: { value in
                    CFPreferencesSetValue(
                        hideKey as CFString,
                        value.map { $0 as CFBoolean },
                        kCFPreferencesAnyApplication,
                        kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost
                    )
                    guard CFPreferencesSynchronize(
                        kCFPreferencesAnyApplication,
                        kCFPreferencesCurrentUser,
                        kCFPreferencesAnyHost
                    ), SkyLight.shared.setMenuBarAutohideEnabled(value == true) else { return false }
                    DistributedNotificationCenter.default().postNotificationName(
                        .menuBarHidingDidChange,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                    return true
                }
            )
        }

        private static let hideKey = "_HIHideMenuBar"
    }

    private let system: System
    private let runtimeState: RuntimeStateStore
    private var request: Bool?
    private var deferredRequest: Bool?
    private var menuAccess = false

    init(system: System = .live, runtimeState: RuntimeStateStore) {
        self.system = system
        self.runtimeState = runtimeState
        if runtimeState.menuBarHideHold?.temporarilyVisible == true {
            if apply(hiding: false) == nil { restoreCurrentPreference() }
        }
    }

    var hidesMenuBar: Bool {
        request == true
    }

    func update(hiding: Bool) {
        if menuAccess {
            deferredRequest = hiding
            return
        }
        apply(hiding: hiding)
    }

    @discardableResult
    func setMenuAccess(_ active: Bool) -> Bool {
        guard menuAccess != active else { return true }
        if active {
            let current = system.preference()
            let previousHold = currentHold(matching: current)
            var hold = previousHold ?? MenuBarHideHold(previous: current)
            hold.temporarilyVisible = true
            saveHold(hold)
            guard system.apply(false) else {
                Log.hiddenBar.error("Failed to reveal the macOS menu bar for menu access")
                if system.preference() == false {
                    restoreAfterMenuAccess()
                } else {
                    saveHold(previousHold)
                }
                return false
            }
            menuAccess = true
            return true
        }
        menuAccess = false
        return restoreAfterMenuAccess()
    }

    @discardableResult
    private func restoreAfterMenuAccess() -> Bool {
        let hiding = deferredRequest ?? request ?? false
        let policyChanged = deferredRequest != nil && deferredRequest != request
        deferredRequest = nil
        if currentHold(matching: system.preference()) == nil {
            saveHold(nil)
            if !policyChanged { return restoreCurrentPreference() }
        }
        request = nil
        if let applied = apply(hiding: hiding) { return applied }
        return restoreCurrentPreference()
    }

    private func currentHold(matching preference: Bool?) -> MenuBarHideHold? {
        guard let hold = runtimeState.menuBarHideHold, preference == hold.applied else { return nil }
        return hold
    }

    private func saveHold(_ hold: MenuBarHideHold?) {
        runtimeState.menuBarHideHold = hold
        runtimeState.flushNow()
    }

    @discardableResult
    private func restoreCurrentPreference() -> Bool {
        guard system.apply(system.preference()) else {
            Log.hiddenBar.error("Failed to restore the macOS menu bar setting")
            return false
        }
        return true
    }

    @discardableResult
    private func apply(hiding: Bool) -> Bool? {
        guard request != hiding else { return nil }
        request = hiding
        let current = system.preference()
        let hold = currentHold(matching: current)
        if hold == nil { saveHold(nil) }
        if hiding {
            guard current != true else { return nil }
            var nextHold = hold ?? MenuBarHideHold(previous: current)
            nextHold.temporarilyVisible = nil
            saveHold(nextHold)
            guard system.apply(true) else {
                Log.shell.error("Failed to hide the macOS menu bar")
                if system.preference() != true {
                    saveHold(hold)
                }
                return false
            }
            if nextHold.previous == true { saveHold(nil) }
            return true
        } else if let hold {
            guard system.apply(hold.previous) else {
                Log.shell.error("Failed to restore the macOS menu bar")
                return false
            }
            saveHold(nil)
            return true
        }
        return nil
    }
}

extension WorkspaceBarManager {
    static func hidesMenuBar(_ resolved: ResolvedBarSettings) -> Bool {
        resolved.fullWidth && resolved.position != .belowMenuBar
    }

    static func coversAppMenus(_ resolved: ResolvedBarSettings) -> Bool {
        hidesMenuBar(resolved) || resolved.notchMode == .fillLeftOfNotch
    }
}

extension SkyLight {
    func setMenuBarAutohideEnabled(_ enabled: Bool) -> Bool {
        spaces.setMenuBarAutohideEnabled?(getMainConnectionID(), enabled) == .success
    }
}
