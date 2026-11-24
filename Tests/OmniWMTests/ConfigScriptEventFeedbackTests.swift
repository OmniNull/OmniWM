// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptEventFeedbackTests: XCTestCase {
    func testExternalLaunchBurstIsBoundPerListenerAndRecoversAfterQuiet() throws {
        var feedback = ConfigScriptEventFeedback()
        let start = ContinuousClock.now
        let handler = 0
        let other = handler + 1
        let launch = ConfigScriptDispatch(
            operation: .native(.openApp("test.event.app")),
            source: "focus.luau",
            line: #line
        )
        let run = ConfigScriptDispatch(
            operation: .native(.runProgram(["test-event"])),
            source: launch.source,
            line: #line
        )
        let notice = ConfigScriptDispatch(operation: .native(.showNotice("test")), source: launch.source, line: #line)
        let interval = ConfigScriptEventFeedback.launchQuietPeriod / 2
        var now = start
        for _ in 0 ..< ConfigScriptEventFeedback.launchLimit {
            try feedback.checkLaunch(launch, from: handler, at: now)
            now += interval
        }
        XCTAssertThrowsError(try feedback.checkLaunch(run, from: handler, at: now)) { error in
            XCTAssertEqual((error as? ConfigScriptError)?.source, run.source)
            XCTAssertEqual((error as? ConfigScriptError)?.line, run.line)
        }
        try feedback.checkLaunch(notice, from: handler, at: now)
        try feedback.checkLaunch(run, from: other, at: now)
        try feedback.checkLaunch(run, from: handler, at: now + interval)
    }

    func testNativeFocusConfirmationCarriesTheIssuingListenerChainAndSupersessionDropsIt() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "ConfigScriptEventFeedbackTests")
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let first = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let second = WindowToken(pid: first.pid, windowId: first.windowId + 1)
        let third = WindowToken(pid: second.pid, windowId: second.windowId + 1)
        for token in [first, second, third] {
            _ = WindowAdmissionTestSupport.track(token, in: workspace.id, controller: controller)
        }
        _ = manager.setManagedFocus(first, in: workspace.id)
        func request(_ token: WindowToken) -> ManagedFocusRequest {
            let request = controller.intentLedger.beginManagedRequest(
                token: token, workspaceId: workspace.id, origin: .keyboardOrProgrammatic
            )
            _ = manager.beginManagedFocusRequest(token, in: workspace.id, requestId: request.requestId)
            return request
        }
        let cause = ConfigScriptEventCause(function: 2, ancestors: [1])
        let expected = ConfigScriptListenerMask(arrayLiteral: 1, cause.function)
        var feedback = ConfigScriptEventFeedback()
        var observed: [ConfigScriptListenerMask] = []
        let observers = ConfigScriptEventObservers(controller: controller, kinds: [.windowActive]) { kind, _ in
            observed.append(feedback.exclusions(for: kind, controller: controller) ?? [])
        }
        defer { observers.stop() }
        XCTAssertNil(feedback.currentExclusions)
        feedback.begin(cause, controller: controller)
        XCTAssertEqual(feedback.currentExclusions, expected)
        XCTAssertEqual(feedback.exclusions(for: .workspaceActive, controller: controller), expected)
        let issued = request(second)
        feedback.end(controller: controller)
        XCTAssertNil(feedback.currentExclusions)
        XCTAssertTrue(observed.isEmpty)
        XCTAssertNil(feedback.exclusions(for: .workspaceActive, controller: controller))
        try confirm(issued, in: controller)
        XCTAssertEqual(observed, [expected])
        feedback.begin(cause, controller: controller)
        _ = request(first)
        feedback.end(controller: controller)
        let replacement = request(third)
        try confirm(replacement, in: controller)
        XCTAssertEqual(observed, [expected, []])
    }

    func testDeferredCloseFollowsTheHandleOnceAndCombinesOverlappingCauses() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let original = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let other = WindowToken(pid: original.pid, windowId: original.windowId + 1)
        let updated = WindowToken(pid: original.pid, windowId: other.windowId + 1)
        _ = WindowAdmissionTestSupport.track(original, in: workspace.id, controller: controller)
        _ = WindowAdmissionTestSupport.track(other, in: workspace.id, controller: controller)
        let handle = try XCTUnwrap(manager.handle(for: original))
        let ancestor = #line
        let issuer = ConfigScriptEventCause(function: #line, ancestors: [ancestor])
        let concurrent = ConfigScriptEventCause(function: #line, ancestors: [])
        let issued = ConfigScriptListenerMask(arrayLiteral: ancestor, issuer.function)
        var combined = issued
        combined.insert(concurrent.function)
        var feedback = ConfigScriptEventFeedback()
        feedback.begin(issuer, controller: controller)
        feedback.recordClose(handle, outcome: .windowActionFailed, controller: controller)
        feedback.end(controller: controller)
        XCTAssertNil(feedback.closeExclusions(token: original))
        feedback.begin(issuer, controller: controller)
        feedback.recordClose(handle, outcome: .executed, controller: controller)
        feedback.end(controller: controller)
        XCTAssertNotNil(manager.rekeyWindow(
            from: original,
            to: updated,
            newAXRef: WindowAdmissionTestSupport.axRef(for: updated)
        ))
        XCTAssertNil(feedback.closeExclusions(token: original))
        XCTAssertNil(feedback.closeExclusions(token: other))
        var deliveries: [ConfigScriptListenerMask] = []
        let observers = ConfigScriptEventObservers(controller: controller, kinds: [.windowClose]) { _, payload in
            guard let id = payload.id, let decoded = ConfigScriptWindowID.decode(id),
                  decoded.session == controller.scriptSession.identity
            else { return XCTFail("Expected the removed window ID") }
            deliveries.append(feedback.closeExclusions(token: decoded.token) ?? [])
        }
        defer { observers.stop() }
        feedback.begin(concurrent, controller: controller)
        XCTAssertNotNil(manager.removeWindow(pid: updated.pid, windowId: updated.windowId))
        feedback.recordClose(handle, outcome: .executed, controller: controller)
        feedback.end(controller: controller)
        XCTAssertEqual(deliveries, [combined])
        XCTAssertNil(feedback.closeExclusions(token: updated))
        XCTAssertNotNil(manager.removeWindow(pid: other.pid, windowId: other.windowId))
        XCTAssertEqual(deliveries, [combined, []])
    }

    private func confirm(_ request: ManagedFocusRequest, in controller: WMController) throws {
        controller.axEventHandler.handleManagedAppActivation(
            entry: try XCTUnwrap(controller.workspaceManager.entry(for: request.token)),
            isWorkspaceActive: true, appFullscreen: false, activeRequestId: request.requestId
        )
        XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, request.token)
        XCTAssertNil(controller.intentLedger.activeManagedRequest(requestId: request.requestId))
    }
}
