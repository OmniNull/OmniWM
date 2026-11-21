// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
import IOKit.pwr_mgt
import ScreenCaptureKit

@MainActor
enum SystemAPIProbes {
    static func axProbes() -> [PrivateAPISelfTest] {
        let trusted = AXIsProcessTrusted()
        var tests = [PrivateAPISelfTest("AXIsProcessTrusted", trusted ? .works : .failed, "trusted=\(trusted)")]
        let app = AXUIElementCreateApplication(getpid())
        var roleValue: CFTypeRef?
        let copyErr = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &roleValue)
        tests.append(PrivateAPISelfTest(
            "AXUIElementCopyAttributeValue",
            copyErr == .success ? .works : .failed,
            "err=\(copyErr.rawValue)"
        ))
        var observer: AXObserver?
        let createErr = AXObserverCreate(getpid(), privateAPIProbeAXObserverCallback, &observer)
        guard let observer else {
            tests.append(PrivateAPISelfTest(
                "AXObserverCreate/Add/Remove",
                .failed,
                "observer nil err=\(createErr.rawValue)"
            ))
            return tests
        }
        let note = kAXFocusedWindowChangedNotification as CFString
        let addErr = AXObserverAddNotification(observer, app, note, nil)
        let removeErr = AXObserverRemoveNotification(observer, app, note)
        let ok = createErr == .success && addErr == .success && removeErr == .success
        tests.append(PrivateAPISelfTest(
            "AXObserverCreate/Add/Remove",
            ok ? .works : .failed,
            "create=\(createErr.rawValue) add=\(addErr.rawValue) remove=\(removeErr.rawValue)"
        ))
        return tests
    }

    static func inputProbes() -> [PrivateAPISelfTest] {
        var tests: [PrivateAPISelfTest] = []
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) {
            CFMachPortInvalidate(tap)
            tests.append(PrivateAPISelfTest("CGEvent.tapCreate", .works, "listen-only tap created + invalidated"))
        } else {
            tests.append(PrivateAPISelfTest("CGEvent.tapCreate", .failed, "nil — input monitoring permission?"))
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F4D_4E50), id: 0xFFFF)
        let status = RegisterEventHotKey(UInt32(kVK_F19), 0, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            let unregistered = UnregisterEventHotKey(ref) == noErr
            tests.append(PrivateAPISelfTest(
                "RegisterEventHotKey",
                unregistered ? .works : .failed,
                "register + unregister"
            ))
        } else {
            tests.append(PrivateAPISelfTest(
                "RegisterEventHotKey",
                .inconclusive,
                "status=\(status) — key may be reserved"
            ))
        }
        tests.append(PrivateAPISelfTest(
            "IsSecureEventInputEnabled",
            .works,
            "secureInput=\(IsSecureEventInputEnabled())"
        ))
        return tests
    }

    static func multitouchProbes() -> [PrivateAPISelfTest] {
        let resolved = MultitouchBinding.resolvedSymbols()
        let missing = resolved.filter { !$0.resolved }.map(\.name)
        var tests = [PrivateAPISelfTest(
            "MultitouchSupport symbols",
            missing.isEmpty ? .works : .failed,
            missing.isEmpty ? "all \(resolved.count) resolved" : "missing: \(missing.joined(separator: ", "))"
        )]
        if let binding = MultitouchBinding() {
            let count = binding.deviceCount()
            tests.append(PrivateAPISelfTest("MTDeviceCreateList", count >= 0 ? .works : .failed, "devices=\(count)"))
        } else {
            tests.append(PrivateAPISelfTest("MTDeviceCreateList", .inconclusive, "binding unavailable"))
        }
        return tests
    }

    static func captureProbe() async -> PrivateAPISelfTest {
        guard CGPreflightScreenCaptureAccess() else {
            return PrivateAPISelfTest("SCShareableContent", .inconclusive, "Screen Recording not granted")
        }
        do {
            let content = try await SCShareableContent.current
            return PrivateAPISelfTest(
                "SCShareableContent",
                .works,
                "windows=\(content.windows.count) displays=\(content.displays.count)"
            )
        } catch {
            return PrivateAPISelfTest("SCShareableContent", .failed, "error=\(error.localizedDescription)")
        }
    }

    static func monitorProbes() -> [PrivateAPISelfTest] {
        let displayId = NSScreen.main?.displayId
        var tests = [PrivateAPISelfTest(
            "NSScreen.displayId",
            displayId != nil ? .works : .failed,
            "main=\(displayId.map(String.init) ?? "nil")"
        )]
        if let displayId {
            let mode = CGDisplayCopyDisplayMode(displayId)
            tests.append(PrivateAPISelfTest(
                "CGDisplayCopyDisplayMode",
                mode != nil ? .works : .failed,
                "refreshRate=\(mode?.refreshRate ?? -1)"
            ))
        }
        return tests
    }

    static func systemProbes() -> [PrivateAPISelfTest] {
        var tests: [PrivateAPISelfTest] = []
        var assertionID: IOPMAssertionID = 0
        let createResult = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            "OmniWM probe" as CFString,
            nil, nil, nil, 1, nil,
            &assertionID
        )
        if createResult == kIOReturnSuccess {
            let released = IOPMAssertionRelease(assertionID) == kIOReturnSuccess
            tests.append(PrivateAPISelfTest(
                "IOPMAssertionCreateWithDescription",
                released ? .works : .failed,
                "create + release"
            ))
        } else {
            tests.append(PrivateAPISelfTest("IOPMAssertionCreateWithDescription", .failed, "create=\(createResult)"))
        }
        tests.append(slpsFocusProbe())
        tests.append(PrivateAPISelfTest("GhosttyKit", .inconclusive, "statically linked; surface lifecycle not probed"))
        return tests
    }

    private static func slpsFocusProbe() -> PrivateAPISelfTest {
        guard let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return PrivateAPISelfTest("_SLPSSetFrontProcessWithOptions", .inconclusive, "no frontmost app")
        }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(frontPid, &psn) == noErr else {
            return PrivateAPISelfTest("_SLPSSetFrontProcessWithOptions", .failed, "GetProcessForPID failed")
        }
        let status = _SLPSSetFrontProcessWithOptions(&psn, 0, kCPSUserGenerated)
        return PrivateAPISelfTest(
            "_SLPSSetFrontProcessWithOptions",
            status == noErr ? .works : .failed,
            "re-front status=\(status)"
        )
    }
}

private func privateAPIProbeAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {}
