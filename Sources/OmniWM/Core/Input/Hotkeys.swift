// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

@MainActor
final class HotkeyCenter {
    var onCommand: ((HotkeyInvocation) -> Void)?
    var isMouseButtonCaptured: ((Int64) -> Bool)?

    private let carbonRegistrations = CarbonHotkeyRegistration()
    private var isRunning = false
    private var commandHotkeysSuspended = false

    private var configuration = HotkeyRuntimeConfiguration()
    private var sideSpecificDispatch: [CommandHotkeyTapMatcher.Entry] = []
    private var mouseButtonDispatch: [MouseButtonBinding: HotkeyCommand] = [:]
    private var suppressedHotkeyKeyCodes: Set<UInt32> = []
    var hyperTriggerTap: CFMachPort?
    var hyperTriggerRunLoopSource: CFRunLoopSource?
    var hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)
    private let capsLockHyperRemapper = CapsLockHyperRemapper()
    private var capsLockToggler = CapsLockToggler()
    private var capsLockHyperRemapActive = false

    private(set) var registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
    private(set) var systemHyperTriggerFailure: SystemHyperTriggerFailure?

    private static var hyperFlagMask: UInt64 {
        let hyper = KeySymbolMapper.hyperModifiers
        return ModifierFlagMask.all.reduce(UInt64(0)) { mask, flag in
            hyper & flag.carbon != 0 ? mask | flag.independent : mask
        }
    }

    var isHyperTriggerActive: Bool {
        hyperTrigger.isActive
    }

    func hotkeyHealthFacts() -> HotkeyHealthFacts {
        HotkeyHealthFacts(
            isRunning: isRunning,
            isHyperTriggerActive: hyperTrigger.isActive,
            hyperTriggerTapInstalled: hyperTriggerTap != nil,
            capsLockHyperRemapActive: capsLockHyperRemapActive,
            systemHyperTriggerEnabled: configuration.systemHyperTrigger.isEnabled,
            systemHyperTriggerName: configuration.systemHyperTrigger.humanReadableString,
            systemHyperTriggerFailure: systemHyperTriggerFailure.map { "\($0)" },
            suppressedHotkeyCount: suppressedHotkeyKeyCodes.count,
            registrationFailureCount: registrationFailures.count,
            sideSpecificCount: sideSpecificDispatch.count,
            bindingCount: configuration.bindings.count,
            bindings: Self.bindingFacts(for: configuration.bindings)
        )
    }

    isolated deinit {
        carbonRegistrations.unregister()
        stopHyperTriggerTap()
        restoreCapsLockHyperRemap()
        carbonRegistrations.removeEventHandler()
    }

    func handleCarbonHotkey(id: UInt32, kind: UInt32) {
        carbonRegistrations.handle(id: id, kind: kind, onCommand: onCommand)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        carbonRegistrations.installEventHandler(center: self)

        refreshCommandHotkeyRegistrations()
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.start")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        carbonRegistrations.unregister()
        stopHyperTriggerTap()
        restoreCapsLockHyperRemap()
        carbonRegistrations.removeEventHandler()
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.stop")
    }

    func setCommandHotkeysSuspended(_ suspended: Bool) {
        guard commandHotkeysSuspended != suspended else { return }
        commandHotkeysSuspended = suspended
        if isRunning {
            refreshCommandHotkeyRegistrations()
        }
    }

    func updateBindings(
        _ newBindings: [HotkeyBinding],
        systemHyperTrigger newSystemHyperTrigger: SystemHyperTrigger = .default,
        force: Bool = false
    ) {
        let nextConfiguration = HotkeyRuntimeConfiguration(
            bindings: newBindings,
            systemHyperTrigger: newSystemHyperTrigger
        )
        guard force || nextConfiguration != configuration else { return }
        configuration = nextConfiguration
        if isRunning {
            refreshCommandHotkeyRegistrations()
        }
    }

    private func reconcileEventTap() {
        stopHyperTriggerTap()
        restoreCapsLockHyperRemap()
        systemHyperTriggerFailure = nil
        hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)

        let hyperEnabled = configuration.systemHyperTrigger.isEnabled
        guard hyperEnabled || !sideSpecificDispatch.isEmpty else { return }

        if hyperEnabled {
            if activateCapsLockHyperRemapIfNeeded() {
                hyperTrigger = HyperTriggerStateMachine(
                    trigger: configuration.systemHyperTrigger,
                    capsLockRemapped: capsLockHyperRemapActive
                )
            } else {
                systemHyperTriggerFailure = .capsLockRemapUnavailable
                DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.capsLockRemap.failed")
                FallbackFiringRecorder.shared.note(.input, "capsLockHyperRemapFailed")
            }
        }

        if setupHyperTriggerTapIfNeeded() {
            DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.hyperTap.installed")
        } else {
            if hyperEnabled {
                systemHyperTriggerFailure = .eventTapUnavailable
            }
            DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.hyperTap.failed")
            FallbackFiringRecorder.shared.note(.input, "hyperTapSetupFailed")
            restoreCapsLockHyperRemap()
            hyperTrigger = HyperTriggerStateMachine(trigger: .none, capsLockRemapped: false)
        }
    }

    private func refreshCommandHotkeyRegistrations() {
        carbonRegistrations.unregister()
        let plan = Self.registrationPlan(for: configuration.bindings)
        registrationFailures = plan.failures

        guard !commandHotkeysSuspended else {
            sideSpecificDispatch = []
            mouseButtonDispatch = [:]
            reconcileEventTap()
            DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.suspended")
            return
        }

        carbonRegistrations.register(plan.registrations, failures: &registrationFailures)

        sideSpecificDispatch = plan.sideSpecificRegistrations.map {
            CommandHotkeyTapMatcher.Entry(binding: $0.binding, command: $0.command)
        }
        mouseButtonDispatch = plan.mouseButtonRegistrations
        reconcileEventTap()
        if !sideSpecificDispatch.isEmpty, hyperTriggerTap == nil {
            for entry in sideSpecificDispatch {
                registrationFailures[entry.command] = .requiresInputMonitoring
            }
            sideSpecificDispatch = []
        }
        DiagnosticsEventRecorder.shared.recordLifecycle(
            name: "hotkeys.registered registered=\(carbonRegistrations.count) "
                + "failures=\(registrationFailures.count) sided=\(sideSpecificDispatch.count) "
                + "mouse=\(mouseButtonDispatch.count)"
        )
    }

    private func activateCapsLockHyperRemapIfNeeded() -> Bool {
        guard configuration.systemHyperTrigger.requiresCapsLockRemap else { return true }
        guard !capsLockHyperRemapActive else { return true }
        guard capsLockHyperRemapper.apply() else { return false }
        capsLockHyperRemapActive = true
        return true
    }

    private func restoreCapsLockHyperRemap() {
        guard capsLockHyperRemapActive else { return }
        capsLockHyperRemapper.restore()
        capsLockHyperRemapActive = false
    }

    private func setupHyperTriggerTapIfNeeded() -> Bool {
        if hyperTriggerTap != nil { return true }
        let eventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                center.handleHyperTriggerEvent(type: type, event: event)
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        hyperTriggerTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPtr
        )
        guard let tap = hyperTriggerTap else {
            FallbackFiringRecorder.shared.note(.input, "hyperTapCreateFailed")
            return false
        }
        hyperTriggerRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = hyperTriggerRunLoopSource else {
            EventTapTeardown.tearDown(
                tap: &hyperTriggerTap,
                runLoopSource: &hyperTriggerRunLoopSource
            )
            FallbackFiringRecorder.shared.note(.input, "hyperTapRunLoopSourceFailed")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func resetTransientInputState() {
        hyperTrigger.reset()
        suppressedHotkeyKeyCodes.removeAll()
    }

    func stopHyperTriggerTap() {
        resetTransientInputState()
        EventTapTeardown.tearDown(
            tap: &hyperTriggerTap,
            runLoopSource: &hyperTriggerRunLoopSource
        )
    }
}

extension HotkeyCenter {
    private func handleHyperTriggerEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            InputTapHealth.recordTapDisabled(mouse: false, byTimeout: true)
            if let tap = hyperTriggerTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            resetTransientInputState()
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            InputTapHealth.recordTapDisabled(mouse: false, byTimeout: false)
            resetTransientInputState()
            return Unmanaged.passUnretained(event)
        case .keyDown,
             .keyUp:
            return handleHyperTriggerKeyEvent(type: type, event: event)
        case .flagsChanged:
            return handleHyperTriggerFlagsChanged(event)
        case .otherMouseDown,
             .otherMouseUp:
            return handleHyperTriggerMouseEvent(type: type, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleHyperTriggerKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        switch type {
        case .keyDown:
            let decision = hyperTrigger.handleKeyDown(keyCode, timestamp: timestamp)
            recordHyperDecision("keyDown", decision)
            switch decision {
            case .suppress:
                return nil
            case .toggleCapsLock:
                capsLockToggler.toggle()
                return nil
            case .inject:
                injectHyperFlags(into: event)
            case .passThrough:
                break
            }
            if suppressedHotkeyKeyCodes.contains(keyCode) {
                return nil
            }
            if dispatchSideSpecificHotkey(keyCode: keyCode, event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            if suppressedHotkeyKeyCodes.remove(keyCode) != nil {
                return nil
            }
            return applyHyperTriggerDecision(
                hyperTrigger.handleKeyUp(keyCode, timestamp: timestamp),
                to: event
            )
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleHyperTriggerFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        return applyHyperTriggerDecision(
            hyperTrigger.handleFlagsChanged(keyCode: keyCode, rawFlags: event.flags.rawValue),
            to: event
        )
    }

    private func handleHyperTriggerMouseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if isMouseButtonCaptured?(button) == true {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .otherMouseDown:
            return applyHyperTriggerDecision(hyperTrigger.handleMouseDown(button), to: event)
        case .otherMouseUp:
            return applyHyperTriggerDecision(hyperTrigger.handleMouseUp(button), to: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func applyHyperTriggerDecision(
        _ decision: HyperTriggerStateMachine.Decision,
        to event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        recordHyperDecision("apply", decision)
        switch decision {
        case .suppress:
            return nil
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .inject:
            injectHyperFlags(into: event)
            return Unmanaged.passUnretained(event)
        case .toggleCapsLock:
            capsLockToggler.toggle()
            return nil
        }
    }

    private func injectHyperFlags(into event: CGEvent) {
        event.flags = CGEventFlags(rawValue: event.flags.rawValue | Self.hyperFlagMask)
    }

    private func recordHyperDecision(_ phase: String, _ decision: HyperTriggerStateMachine.Decision) {
        guard decision != .passThrough else { return }
        InputTrace.record("hyper \(phase) decision=\(Self.decisionLabel(decision))")
    }

    func dispatchMouseButton(_ button: Int64, flags: CGEventFlags) -> Bool {
        guard isRunning, !mouseButtonDispatch.isEmpty else { return false }
        var modifiers = ModifierFlagMask.all.reduce(UInt32(0)) { mask, flag in
            flags.rawValue & flag.independent != 0 ? mask | flag.carbon : mask
        }
        if hyperTrigger.isActive {
            modifiers |= KeySymbolMapper.hyperModifiers
        }
        guard let binding = MouseButtonBinding(button: button, modifiers: modifiers),
              let command = mouseButtonDispatch[binding]
        else { return false }
        if hyperTrigger.isActive {
            _ = hyperTrigger.handleMouseDown(button)
        }
        InputTrace.record("hotkey.mouse cmd=\(command.displayName)")
        onCommand?(HotkeyInvocation(command: command))
        return true
    }

    private func dispatchSideSpecificHotkey(keyCode: UInt32, event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        let rawFlags = event.flags.rawValue
        if let entry = sideSpecificDispatch.first(where: {
            CommandHotkeyTapMatcher.matches($0.binding, keyCode: keyCode, rawFlags: rawFlags)
        }) {
            suppressedHotkeyKeyCodes.insert(keyCode)
            InputTrace.record("hotkey.sided cmd=\(entry.command.displayName)")
            onCommand?(
                HotkeyInvocation(
                    command: entry.command,
                    trigger: PhysicalHotkeyTrigger(
                        keyCode: entry.binding.keyCode,
                        modifiers: entry.binding.modifiers,
                        isRepeat: false
                    )
                )
            )
            return true
        }
        recordSidedMiss(keyCode: keyCode, rawFlags: rawFlags)
        return false
    }

    private func recordSidedMiss(keyCode: UInt32, rawFlags: UInt64) {
        guard InputTrace.shared.isActive, !sideSpecificDispatch.isEmpty else { return }
        let down = KeySymbolMapper.sidedModifierLabel(rawFlags)
        guard !down.isEmpty else { return }
        let nearMiss = CommandHotkeyTapMatcher.nearMiss(
            keyCode: keyCode,
            rawFlags: rawFlags,
            entries: sideSpecificDispatch
        )
        InputTrace.record(
            "hotkey.sided.miss key=\(KeySymbolMapper.keySymbol(keyCode)) down=\(down) "
                + "closest=\(nearMiss?.entry.command.displayName ?? "none") "
                + "needs=\(nearMiss?.entry.binding.displayString ?? "-") "
                + "reason=\(nearMiss?.reason ?? "-")"
        )
    }
}
