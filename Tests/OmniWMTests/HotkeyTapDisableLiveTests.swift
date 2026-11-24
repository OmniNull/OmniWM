// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#if OMNIWM_LIVE_CHECKS
    import CoreGraphics
    import Foundation
    @testable import OmniWM
    import XCTest

    @MainActor
    final class HotkeyTapDisableLiveTests: XCTestCase {
        private let center = HotkeyCenter()
        private let disabled = XCTestExpectation(description: "Quartz delivered the disable notification")

        func testModesOnlyTapReportsOneDisable() async throws {
            let modeKey = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("W"))
            center.updateBindings(
                [HotkeyBinding(
                    id: "workspace",
                    command: .workspace(.switchTo(2)),
                    trigger: .unassigned,
                    modeKey: modeKey
                )],
                systemHyperTrigger: .none
            )
            try await withKeyboardTap { _ in self.center.updateEventTapEnablement() }
        }

        func testSystemDisableReleasesArmedCaptureWhenTapOtherwiseRequired() async throws {
            center.windowSwitcherEnabled = true
            center.keyboardModeInput.state = .window
            let modeKey = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("W"))
            center.suppressedHotkeyKeyCodes.insert(modeKey.keyCode)
            try await withKeyboardTap { CGEvent.tapEnable(tap: $0, enable: false) }
            XCTAssertEqual(center.keyboardModeKind, .normal)
            XCTAssertTrue(center.suppressedHotkeyKeyCodes.isEmpty)
        }

        private func withKeyboardTap(_ disable: (CFMachPort) -> Void) async throws {
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: CGEventMask(1) << CGEventType.null.rawValue,
                callback: { _, type, event, context in
                    if type == .tapDisabledByUserInput, let context {
                        MainActor.assumeIsolated {
                            Unmanaged<HotkeyTapDisableLiveTests>.fromOpaque(context).takeUnretainedValue()
                                .receiveDisable(event)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { throw MissingTestPrerequisite("Needs a listen-only Quartz tap") }
            defer { CFMachPortInvalidate(tap) }
            let source = try XCTUnwrap(CFMachPortCreateRunLoopSource(nil, tap, 0))
            center.hyperTriggerTap = tap
            defer { center.hyperTriggerTap = nil }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            defer { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            disable(tap)
            await fulfillment(of: [disabled], timeout: failureBound)
        }

        private func receiveDisable(_ event: CGEvent) {
            guard let tap = center.hyperTriggerTap else { return }
            let pendingBefore = pendingMessages(on: tap)
            XCTAssertFalse(CGEvent.tapIsEnabled(tap: tap))
            _ = center.handleHyperTriggerEvent(type: .tapDisabledByUserInput, event: event)
            XCTAssertFalse(CGEvent.tapIsEnabled(tap: tap))
            XCTAssertEqual(pendingMessages(on: tap), pendingBefore)
            center.hyperTriggerTap = nil
            disabled.fulfill()
        }

        private func pendingMessages(on tap: CFMachPort) -> mach_port_msgcount_t {
            var status = mach_port_status()
            var count = mach_msg_type_number_t(MemoryLayout<mach_port_status>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutableBytes(of: &status) { bytes in
                mach_port_get_attributes(
                    mach_task_self_, CFMachPortGetPort(tap), MACH_PORT_RECEIVE_STATUS,
                    bytes.bindMemory(to: integer_t.self).baseAddress, &count
                )
            }
            XCTAssertEqual(result, KERN_SUCCESS)
            return status.mps_msgcount
        }
    }
#endif
