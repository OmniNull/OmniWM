// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

struct HotkeyPlannedRegistration: Equatable {
    let binding: KeyBinding
    let command: HotkeyCommand
}

enum HotkeyRegistrationFailureReason: Equatable {
    case duplicateBinding
    case systemReserved
    case requiresInputMonitoring
}

enum SystemHyperTriggerFailure: Equatable {
    case eventTapUnavailable
    case capsLockRemapUnavailable
}

struct HotkeyRegistrationPlan: Equatable {
    let registrations: [HotkeyPlannedRegistration]
    let sideSpecificRegistrations: [HotkeyPlannedRegistration]
    let mouseButtonRegistrations: [MouseButtonBinding: HotkeyCommand]
    var failures: [HotkeyCommand: HotkeyRegistrationFailureReason]

    init(
        registrations: [HotkeyPlannedRegistration],
        sideSpecificRegistrations: [HotkeyPlannedRegistration] = [],
        mouseButtonRegistrations: [MouseButtonBinding: HotkeyCommand] = [:],
        failures: [HotkeyCommand: HotkeyRegistrationFailureReason]
    ) {
        self.registrations = registrations
        self.sideSpecificRegistrations = sideSpecificRegistrations
        self.mouseButtonRegistrations = mouseButtonRegistrations
        self.failures = failures
    }
}

struct HotkeyRuntimeConfiguration: Equatable {
    let bindings: [HotkeyBinding]
    let systemHyperTrigger: SystemHyperTrigger

    init(bindings: [HotkeyBinding] = [], systemHyperTrigger: SystemHyperTrigger = .default) {
        self.bindings = bindings
        self.systemHyperTrigger = systemHyperTrigger
    }
}
