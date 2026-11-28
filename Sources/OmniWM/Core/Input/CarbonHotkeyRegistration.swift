// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

@MainActor
final class CarbonHotkeyRegistration {
    private struct PressedHotKey: Hashable {
        let id: UInt32
        var onRelease = false
        var repeatWhileHeld = false

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    private var refsById: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var idToRegistration: [UInt32: HotkeyPlannedRegistration] = [:]
    private var pressedHotKeys: Set<PressedHotKey> = []
    private var retiredHotKeyIds: Set<UInt32> = []
    private var nextId: UInt32 = 1

    var count: Int {
        refsById.count
    }

    var registeredCommands: Set<HotkeyCommand> {
        Set(idToRegistration.values.map(\.command))
    }

    func installEventHandler(center: HotkeyCenter) {
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            MainActor.assumeIsolated {
                center.handleCarbonHotkey(id: hotKeyID.id, kind: GetEventKind(event))
            }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(center).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 2, &eventSpecs, selfPtr, &handler)
    }

    func register(
        _ registrations: [HotkeyPlannedRegistration],
        failures: inout [HotkeyCommand: HotkeyRegistrationFailureReason]
    ) {
        for registration in registrations {
            guard failures[registration.command] == nil else {
                continue
            }
            let id = nextId
            nextId &+= 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4F4D_4E49), id: id)
            let status = RegisterEventHotKey(
                registration.binding.keyCode,
                registration.binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refsById[id] = ref
                recordRegistration(registration, id: id)
            } else {
                failures[registration.command] = .systemReserved
                FallbackFiringRecorder.shared.note(.input, "hotkeyRegistrationFailed")
            }
        }
    }

    func recordRegistration(_ registration: HotkeyPlannedRegistration, id: UInt32) {
        idToRegistration[id] = registration
    }

    func invocation(id: UInt32, kind: UInt32) -> HotkeyInvocation? {
        if kind == UInt32(kEventHotKeyReleased) {
            guard pressedHotKeys.remove(PressedHotKey(id: id))?.onRelease == true,
                  let registration = idToRegistration[id]
            else { return nil }
            if !retiredHotKeyIds.isEmpty, retiredHotKeyIds.remove(id) != nil { return nil }
            return invocation(registration, isRepeat: false)
        }

        guard let registration = idToRegistration[id] else { return nil }
        let pressed = PressedHotKey(
            id: id,
            onRelease: registration.onRelease,
            repeatWhileHeld: registration.repeatWhileHeld
        )
        let isRepeat = !pressedHotKeys.insert(pressed).inserted
        guard !registration.onRelease else { return nil }
        if registration.repeatWhileHeld, !retiredHotKeyIds.isEmpty {
            if isRepeat {
                guard !retiredHotKeyIds.contains(id) else { return nil }
            } else {
                retiredHotKeyIds.remove(id)
            }
        }
        return invocation(registration, isRepeat: isRepeat)
    }

    func retireHeldBindings() {
        for pressed in pressedHotKeys where pressed.onRelease || pressed.repeatWhileHeld {
            retiredHotKeyIds.insert(pressed.id)
        }
    }

    func unregister(keeping isKept: (HotkeyPlannedRegistration) -> Bool = { _ in false }) {
        for (id, ref) in refsById where !(idToRegistration[id].map(isKept) ?? false) {
            UnregisterEventHotKey(ref)
            refsById[id] = nil
            idToRegistration[id] = nil
            pressedHotKeys.remove(PressedHotKey(id: id))
            if !retiredHotKeyIds.isEmpty { retiredHotKeyIds.remove(id) }
        }
    }

    func removeEventHandler() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private func invocation(_ registration: HotkeyPlannedRegistration, isRepeat: Bool) -> HotkeyInvocation {
        InputTrace.record("hotkey.carbon cmd=\(registration.command.displayName)")
        return HotkeyInvocation(
            command: registration.command,
            trigger: PhysicalHotkeyTrigger(
                keyCode: registration.binding.keyCode,
                modifiers: registration.binding.modifiers,
                isRepeat: isRepeat
            )
        )
    }
}
