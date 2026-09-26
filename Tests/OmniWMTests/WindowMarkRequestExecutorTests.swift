// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowMarkRequestExecutorTests: XCTestCase {
    func testInvalidNoFocusedUnknownAndStaleRefusalsAreTyped() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWindowMarkRefusals")
        let executor = IPCWindowMarkRequestExecutor(controller: controller)

        XCTAssertEqual(response(executor, .set(name: "bad\nname")).code, .invalidMark)
        XCTAssertEqual(response(executor, .set(name: "valid")).code, .noFocusedWindow)
        XCTAssertEqual(response(executor, .focus(name: "missing")).code, .unknownMark)

        let retiredToken = WindowToken(pid: 78_001, windowId: 78_101)
        XCTAssertEqual(controller.windowMarkRegistry.set("retired", for: retiredToken), .inserted)
        XCTAssertEqual(response(executor, .focus(name: "retired")).code, .staleMark)
        XCTAssertEqual(controller.windowMarkRegistry.lookup("retired"), .unknown)
    }

    func testDuplicateRefusalAndFocusControllerStateGates() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWindowMarkGates")
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "78", layoutType: .niri, controller: controller)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "78")
        let focusedToken = WindowToken(pid: 78_011, windowId: 78_111)
        let otherToken = WindowToken(pid: 78_012, windowId: 78_112)
        _ = WindowAdmissionTestSupport.track(focusedToken, in: workspaceId, controller: controller)
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(focusedToken, in: workspaceId))
        XCTAssertEqual(controller.windowMarkRegistry.set("reserved", for: otherToken), .inserted)
        let executor = IPCWindowMarkRequestExecutor(controller: controller)

        XCTAssertEqual(response(executor, .set(name: "reserved")).code, .duplicateMark)

        controller.isEnabled = false
        XCTAssertEqual(response(executor, .focus(name: "reserved")).code, .disabled)
        controller.isEnabled = true
        controller.settings.animationsEnabled = false
        controller.toggleOverview()
        defer {
            if controller.isOverviewOpen() {
                controller.toggleOverview()
            }
        }
        XCTAssertTrue(controller.isOverviewOpen())
        XCTAssertEqual(response(executor, .focus(name: "reserved")).code, .overviewOpen)
    }

    func testListPrunesStaleMarkWithoutDiscardingLiveMarks() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWindowMarkList")
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "79", layoutType: .niri, controller: controller)
        )
        let liveToken = WindowToken(pid: 79_001, windowId: 79_101)
        _ = WindowAdmissionTestSupport.track(liveToken, in: workspaceId, controller: controller)
        let staleToken = WindowToken(pid: 79_002, windowId: 79_102)
        XCTAssertEqual(controller.windowMarkRegistry.set("a-stale", for: staleToken), .inserted)
        XCTAssertEqual(controller.windowMarkRegistry.set("b-live", for: liveToken), .inserted)

        let executor = IPCWindowMarkRequestExecutor(controller: controller)
        let result = response(executor, .list)
        XCTAssertNil(result.code)
        guard case let .windowMarks(marks)? = result.result?.payload else {
            return XCTFail("Expected window mark list")
        }
        XCTAssertEqual(marks.marks.map(\.name), ["b-live"])
        XCTAssertEqual(controller.windowMarkRegistry.lookup("a-stale"), .unknown)
        XCTAssertEqual(controller.windowMarkRegistry.lookup("b-live"), .found(liveToken))
        XCTAssertEqual(response(executor, .list).result, result.result)
    }

    private func response(
        _ executor: IPCWindowMarkRequestExecutor,
        _ request: IPCWindowMarkRequest
    ) -> IPCResponse {
        executor.response(for: request, id: "mark-refusal")
    }
}
