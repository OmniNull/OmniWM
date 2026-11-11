// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@preconcurrency import AppKit
import Foundation
import OmniWMIPC

extension HotkeyCenter {
    var keyboardModeKind: KeyboardModeKind {
        keyboardModeInput.kind
    }

    var keyboardModeKeyFailures: [HotkeyCommand: KeyboardModeKeyFailure] {
        keyboardModeTable.failures
    }

    func configureKeyboardModes(_ settings: SettingsExport.KeyboardModes) {
        guard pauseTimeout != settings.pauseTimeout else { return }
        pauseTimeout = settings.pauseTimeout
        if keyboardModeInput.kind == .paused {
            scheduleKeyboardModeTimer()
        }
    }

    @discardableResult
    func performKeyboardModeCommand(_ command: IPCKeyboardModeCommand) -> Bool {
        switch command {
        case .togglePause:
            if keyboardModeInput.kind == .paused {
                return setKeyboardMode(.normal)
            }
            guard isRunning else { return false }
            return setKeyboardMode(.paused)
        case .beginPrefix:
            guard canArmKeyboardMode else { return false }
            return setKeyboardMode(.prefix(repeatDeadline: nil))
        case .toggleWindowMode:
            if keyboardModeInput.kind == .window {
                return setKeyboardMode(.normal)
            }
            guard canArmKeyboardMode else { return false }
            return setKeyboardMode(.window)
        case .exit:
            return setKeyboardMode(.normal)
        }
    }

    func cancelArmedKeyboardMode() {
        guard keyboardModeInput.capturesKeys else { return }
        setKeyboardMode(.normal)
    }

    func releaseKeyboardModeCapture() {
        suppressedHotkeyKeyCodes.removeAll()
        cancelArmedKeyboardMode()
    }

    var canArmKeyboardMode: Bool {
        isRunning
            && !commandHotkeysSuspended
            && keyboardModeInput.kind != .paused
            && !keyboardModeTable.isEmpty
            && hyperTriggerTap != nil
            && isKeyboardModeArmingBlocked?() != true
    }

    func routeHotkeyInvocation(_ invocation: HotkeyInvocation) {
        guard case let .keyboardMode(command) = invocation.command else {
            onCommand?(invocation)
            return
        }
        guard invocation.trigger?.isRepeat != true else { return }
        performKeyboardModeCommand(command)
    }

    @discardableResult
    func setKeyboardMode(_ state: KeyboardModeInput.State) -> Bool {
        let previous = keyboardModeInput.state
        guard previous != state else { return false }
        keyboardModeInput.state = state
        keyboardModeDidChange(from: previous)
        return true
    }

    func handleKeyboardModeKeyDown(keyCode: UInt32, event: CGEvent) -> Bool {
        let previous = keyboardModeInput.state
        let decision = keyboardModeInput.handleKeyDown(
            keyCode: keyCode,
            rawFlags: event.flags.rawValue,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            now: keyboardModeNow(),
            table: keyboardModeTable
        )
        if decision.consumed {
            suppressedHotkeyKeyCodes.insert(keyCode)
        }
        if let command = decision.command {
            InputTrace.record("hotkey.mode cmd=\(command.displayName)")
            onCommand?(HotkeyInvocation(command: command))
        }
        if keyboardModeInput.state != previous {
            keyboardModeDidChange(from: previous)
        }
        return decision.consumed
    }

    func applyRegistrationFilters() {
        if keyboardModeCaptureUnavailable {
            for binding in configuration.bindings
                where Self.needsModeCapture(binding.command) && !binding.binding.isUnassigned
            {
                registrationFailures[binding.command] = .requiresInputMonitoring
            }
        }
        guard keyboardModeInput.kind == .paused || keyboardModeCaptureUnavailable else { return }
        carbonRegistrations.unregister(keeping: { isRegistrationAllowed($0.command) })
        sideSpecificDispatch.removeAll { !isRegistrationAllowed($0.command) }
        mouseButtonDispatch = mouseButtonDispatch.filter { isRegistrationAllowed($0.value) }
    }

    func updateEventTapEnablement() {
        guard let tap = hyperTriggerTap else { return }
        let enabled = keyboardTapRequiredOutsideModes
            || keyboardModeInput.capturesKeys
            || !suppressedHotkeyKeyCodes.isEmpty
            || windowSwitcherInput.holdsKeyboard
        if CGEvent.tapIsEnabled(tap: tap) != enabled {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
    }

    var keyboardTapRequiredOutsideModes: Bool {
        configuration.systemHyperTrigger.isEnabled || !sideSpecificDispatch.isEmpty || windowSwitcherEnabled
    }

    private var keyboardModeCaptureUnavailable: Bool {
        !keyboardModeTable.isEmpty && hyperTriggerTap == nil
    }

    static func allowsRegistration(of command: HotkeyCommand, paused: Bool, captureUnavailable: Bool) -> Bool {
        if paused, !staysRegisteredWhilePaused(command) {
            return false
        }
        return !captureUnavailable || !needsModeCapture(command)
    }

    func isRegistrationAllowed(_ command: HotkeyCommand) -> Bool {
        Self.allowsRegistration(
            of: command,
            paused: keyboardModeInput.kind == .paused,
            captureUnavailable: keyboardModeCaptureUnavailable
        )
    }

    private static func staysRegisteredWhilePaused(_ command: HotkeyCommand) -> Bool {
        command == .keyboardMode(.togglePause) || command == .keyboardMode(.exit)
    }

    private static func needsModeCapture(_ command: HotkeyCommand) -> Bool {
        command == .keyboardMode(.beginPrefix) || command == .keyboardMode(.toggleWindowMode)
    }

    private func keyboardModeDidChange(from previous: KeyboardModeInput.State) {
        let previousKind = KeyboardModeInput.kind(of: previous)
        let kind = keyboardModeInput.kind
        if previousKind == .paused, kind != .paused {
            restoreRegistrationsAfterPause()
        } else if kind == .paused, previousKind != .paused {
            applyRegistrationFilters()
        }
        if kind != .normal, previousKind == .normal, windowSwitcherInput.isActive {
            windowSwitcherInput.cancel(generation: windowSwitcherInput.generation)
            onWindowSwitcherAction?(.cancel, windowSwitcherInput.generation)
        }
        scheduleKeyboardModeTimer()
        updateEventTapEnablement()
        guard kind != previousKind else { return }
        DiagnosticsEventRecorder.shared.recordLifecycle(name: "hotkeys.mode \(kind.rawValue)")
        onKeyboardModeChange?(kind)
    }

    private func restoreRegistrationsAfterPause() {
        guard isRunning, !commandHotkeysSuspended else { return }
        let plan = Self.registrationPlan(for: configuration.bindings)
        carbonRegistrations.register(
            plan.registrations.filter {
                !Self.staysRegisteredWhilePaused($0.command) && isRegistrationAllowed($0.command)
                    && !yieldsToPalette($0.binding)
            },
            failures: &registrationFailures
        )
        sideSpecificDispatch = hyperTriggerTap == nil ? [] : plan.sideSpecificRegistrations
            .filter { isRegistrationAllowed($0.command) && !yieldsToPalette($0.binding) }
            .map { CommandHotkeyTapMatcher.Entry(binding: $0.binding, command: $0.command) }
        mouseButtonDispatch = plan.mouseButtonRegistrations.filter { isRegistrationAllowed($0.value) }
    }

    private func scheduleKeyboardModeTimer() {
        keyboardModeTimer?.cancel()
        keyboardModeTimer = nil
        keyboardModeGeneration &+= 1
        let delay: Duration? = switch keyboardModeInput.state {
        case .paused:
            pauseTimeout
        case let .prefix(repeatDeadline?):
            .milliseconds(Int64((max(0, repeatDeadline - keyboardModeNow()) * 1000).rounded(.up)))
        case .normal,
             .prefix(repeatDeadline: nil),
             .window:
            nil
        }
        guard let delay else { return }
        let generation = keyboardModeGeneration
        let sleep = keyboardModeSleep
        keyboardModeTimer = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            self?.keyboardModeTimerFired(generation: generation)
        }
    }

    private func keyboardModeTimerFired(generation: UInt64) {
        guard generation == keyboardModeGeneration else { return }
        keyboardModeTimer = nil
        switch keyboardModeInput.state {
        case .paused:
            setKeyboardMode(.normal)
        case let .prefix(repeatDeadline?):
            if keyboardModeNow() >= repeatDeadline {
                setKeyboardMode(.normal)
            } else {
                scheduleKeyboardModeTimer()
            }
        case .normal,
             .prefix(repeatDeadline: nil),
             .window:
            break
        }
    }
}
