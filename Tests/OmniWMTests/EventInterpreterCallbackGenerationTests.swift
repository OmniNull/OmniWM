// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

final class EventInterpreterCallbackGenerationTests: XCTestCase {
    @MainActor
    func testFocusedWindowCallbackRequiresCurrentGeneration() {
        let pid: pid_t = 701_001
        let currentGeneration: UInt64 = 12
        let controller = WindowAdmissionTestSupport.controller()
        defer { stop(controller) }
        controller.hasStartedServices = true
        controller.eventIntake.open(sink: controller.eventInterpreter)

        var factReadCount = 0
        controller.factResolver.factProvider = { _ in
            factReadCount += 1
            return nil
        }
        let interpreter = EventInterpreter(
            controller: controller,
            callbackGenerationProvider: { candidatePID in
                candidatePID == pid ? currentGeneration : nil
            }
        )

        interpreter.handleIntakeEvent(
            stamped(.axWindow(.focusedWindowChanged(pid: pid, callbackGeneration: currentGeneration - 1)))
        )
        XCTAssertEqual(factReadCount, 0)

        interpreter.handleIntakeEvent(
            stamped(.axWindow(.focusedWindowChanged(pid: pid, callbackGeneration: currentGeneration)))
        )
        XCTAssertEqual(factReadCount, 1)
    }

    @MainActor
    func testTitleCallbackRefreshesManagedTitleForCurrentGeneration() throws {
        let pid: pid_t = 701_004
        let windowId = 801_004
        let currentGeneration: UInt64 = 32
        let controller = WindowAdmissionTestSupport.controller()
        defer { stop(controller) }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: pid, windowId: windowId)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        _ = controller.workspaceManager.setManagedReplacementMetadata(
            ManagedReplacementMetadata(
                bundleId: "com.omniwm.tests.title",
                workspaceId: workspaceId,
                mode: .tiling,
                role: nil,
                subrole: nil,
                title: "Original",
                windowLevel: 0,
                parentWindowId: nil,
                frame: frame
            ),
            for: token
        )
        controller.axEventHandler.windowInfoProvider = { id in
            WindowServerInfo(id: id, pid: pid, level: 0, frame: frame, title: "Renamed")
        }
        let interpreter = EventInterpreter(
            controller: controller,
            callbackGenerationProvider: { candidatePID in
                candidatePID == pid ? currentGeneration : nil
            }
        )

        interpreter.handleIntakeEvent(stamped(.axWindow(.titleChanged(
            pid: pid,
            windowId: UInt32(windowId),
            callbackGeneration: currentGeneration - 1
        ))))
        XCTAssertEqual(controller.workspaceManager.managedReplacementMetadata(for: token)?.title, "Original")

        interpreter.handleIntakeEvent(stamped(.axWindow(.titleChanged(
            pid: pid,
            windowId: UInt32(windowId),
            callbackGeneration: currentGeneration
        ))))
        XCTAssertEqual(controller.workspaceManager.managedReplacementMetadata(for: token)?.title, "Renamed")
    }

    @MainActor
    func testDestroyedWindowCallbackRequiresCurrentGeneration() throws {
        let pid: pid_t = 701_002
        let windowId = 801_002
        let currentGeneration: UInt64 = 22
        let controller = WindowAdmissionTestSupport.controller()
        defer { stop(controller) }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let axRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: windowId
        )
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        let interpreter = EventInterpreter(
            controller: controller,
            callbackGenerationProvider: { candidatePID in
                candidatePID == pid ? currentGeneration : nil
            }
        )

        interpreter.handleIntakeEvent(
            stamped(
                .axWindow(.windowDestroyed(
                    pid: pid,
                    axRef: axRef,
                    callbackGeneration: currentGeneration - 1
                ))
            )
        )
        XCTAssertNotNil(controller.workspaceManager.entry(for: token))

        interpreter.handleIntakeEvent(
            stamped(
                .axWindow(.windowDestroyed(
                    pid: pid,
                    axRef: axRef,
                    callbackGeneration: currentGeneration
                ))
            )
        )
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    @MainActor
    func testMinimizationCallbacksRequireCurrentGeneration() throws {
        let pid: pid_t = 701_003
        let currentGeneration: UInt64 = 32
        let controller = WindowAdmissionTestSupport.controller()
        defer { stop(controller) }
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let axRef = AXWindowRef(
            element: AXUIElementCreateApplication(pid),
            windowId: 801_003
        )
        let token = controller.workspaceManager.addWindow(
            axRef,
            pid: pid,
            windowId: axRef.windowId,
            to: workspaceId
        )
        let interpreter = EventInterpreter(
            controller: controller,
            callbackGenerationProvider: { candidatePID in
                candidatePID == pid ? currentGeneration : nil
            }
        )

        interpreter.handleIntakeEvent(
            stamped(
                .axWindow(.windowMiniaturized(
                    pid: pid,
                    axRef: axRef,
                    callbackGeneration: currentGeneration - 1
                ))
            )
        )
        XCTAssertEqual(controller.workspaceManager.observedState(for: token)?.isMinimized, false)

        interpreter.handleIntakeEvent(
            stamped(
                .axWindow(.windowMiniaturized(
                    pid: pid,
                    axRef: axRef,
                    callbackGeneration: currentGeneration
                ))
            )
        )
        XCTAssertEqual(controller.workspaceManager.observedState(for: token)?.isMinimized, true)

        interpreter.handleIntakeEvent(
            stamped(
                .axWindow(.windowDeminiaturized(
                    pid: pid,
                    axRef: axRef,
                    callbackGeneration: currentGeneration - 1
                ))
            )
        )
        XCTAssertEqual(controller.workspaceManager.observedState(for: token)?.isMinimized, true)

        interpreter.handleIntakeEvent(
            stamped(
                .axWindow(.windowDeminiaturized(
                    pid: pid,
                    axRef: axRef,
                    callbackGeneration: currentGeneration
                ))
            )
        )
        XCTAssertEqual(controller.workspaceManager.observedState(for: token)?.isMinimized, false)
    }

    private func stamped(_ event: IntakeEvent) -> StampedIntakeEvent {
        StampedIntakeEvent(seq: 1, event: event)
    }

    @MainActor
    private func stop(_ controller: WMController) {
        controller.factResolver.stop()
        controller.deadlineWheel.stop()
        controller.eventIntake.close()
    }
}
