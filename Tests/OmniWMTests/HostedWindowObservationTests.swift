// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowObservationTests: XCTestCase {
    private let initialFrame = CGRect(x: 40, y: 80, width: 320, height: 240)

    func testKeyNotificationConfirmsTheExactPendingNativeWindowWithoutAX() throws {
        var operations: [String] = []
        let controller = makeController(operations: { operations.append($0) })
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let window = makeWindow()
        defer { window.close() }
        let token = try admit(window, controller: controller)
        let request = try XCTUnwrap(controller.focusWindow(token))
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)

        controller.shellAppWindowManager.windowDidBecomeKey(notification(window))

        XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, token)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(operations.isEmpty)
    }

    func testNonKeyAndSupersededNotificationsCannotStealManagedFocus() throws {
        let controller = makeController()
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let previous = makeWindow()
        let current = makeWindow()
        defer { previous.close()
            current.close()
        }
        let previousToken = try admit(previous, controller: controller)
        let currentToken = try admit(current, controller: controller)
        let request = try XCTUnwrap(controller.focusWindow(currentToken))
        previous.reportsKey = false

        controller.shellAppWindowManager.windowDidBecomeKey(notification(previous))
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertNotEqual(controller.workspaceManager.nativeManagedFocusToken, previousToken)

        previous.reportsKey = true
        controller.shellAppWindowManager.windowDidBecomeKey(notification(previous))
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.requestId, request.requestId)
        XCTAssertNotEqual(controller.workspaceManager.nativeManagedFocusToken, previousToken)
        controller.shellAppWindowManager.windowDidBecomeKey(notification(current))
        XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, currentToken)
    }

    func testClosedWindowNotificationsCannotUpdateManagedState() throws {
        let controller = makeController()
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let window = makeWindow()
        let token = try admit(window, controller: controller)
        window.close()
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        let sequence = controller.workspaceManager.worldSeq
        window.reportsKey = true
        window.reportsMinimized = true

        controller.shellAppWindowManager.windowDidBecomeKey(notification(window))
        controller.shellAppWindowManager.windowDidMiniaturize(notification(window))
        controller.shellAppWindowManager.windowDidResize(notification(window))

        XCTAssertEqual(controller.workspaceManager.worldSeq, sequence)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
    }

    func testMinimizeAndRestoreUseWorldStoreWithoutAXSuppression() throws {
        let controller = makeController()
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let window = makeWindow()
        defer { window.close() }
        let token = try admit(window, controller: controller)
        window.reportsMinimized = true

        controller.shellAppWindowManager.windowDidMiniaturize(notification(window))

        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isMinimized, true)
        XCTAssertFalse(controller.axManager.isWindowNativeSuppressed(token))
        window.reportsMinimized = false
        controller.shellAppWindowManager.windowDidDeminiaturize(notification(window))
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isMinimized, false)
        XCTAssertFalse(controller.axManager.isWindowNativeSuppressed(token))
    }

    func testHostedAndExternalMinimizationShareFocusCancellationAndVisibilityRefresh() throws {
        for hosted in [false, true] {
            let controller = makeController()
            defer { controller.layoutRefreshController.resetState()
                controller.axManager.cleanup()
            }
            let window = makeWindow()
            defer { window.close() }
            let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            let token: WindowToken
            if hosted {
                token = try admit(window, controller: controller)
                controller.shellAppWindowManager.liveResizeStarts[token] = window.frame
            } else {
                token = WindowToken(pid: getpid(), windowId: window.windowNumber)
                _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
            }
            let request = controller.intentLedger.beginManagedRequest(
                token: token, workspaceId: workspace, origin: .keyboardOrProgrammatic
            )
            _ = controller.workspaceManager.beginManagedFocusRequest(
                token, in: workspace, onMonitor: nil, requestId: request.requestId
            )
            for minimized in [true, false] {
                controller.layoutRefreshController.resetState()
                window.reportsMinimized = minimized
                if hosted {
                    if minimized { controller.shellAppWindowManager.windowDidMiniaturize(notification(window)) }
                    else { controller.shellAppWindowManager.windowDidDeminiaturize(notification(window)) }
                } else {
                    XCTAssertTrue(controller.axEventHandler.updateWindowMinimizedState(minimized, token: token))
                }
                let refresh = controller.layoutRefreshController.layoutState.pendingRefresh
                    ?? controller.layoutRefreshController.layoutState.activeRefresh
                XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isMinimized, minimized)
                XCTAssertEqual(controller.axManager.isWindowNativeSuppressed(token), !hosted && minimized)
                XCTAssertNil(controller.intentLedger.activeManagedRequest)
                XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
                XCTAssertEqual(refresh?.reason, minimized ? .windowMinimized : .windowDeminiaturized)
                XCTAssertEqual(refresh?.affectedWorkspaceIds, [workspace])
                XCTAssertNil(controller.shellAppWindowManager.liveResizeStarts[token])
            }
        }
    }

    func testIssuedFrameCallbacksDoNotCommitWorldState() throws {
        let controller = makeController()
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let window = makeWindow()
        defer { window.close() }
        let token = try admit(window, controller: controller)
        let sequence = controller.workspaceManager.worldSeq
        let target = initialFrame.offsetBy(dx: initialFrame.width, dy: initialFrame.height)
        XCTAssertTrue(controller.shellAppWindowManager.setFrame(target, for: token))
        XCTAssertEqual(controller.workspaceManager.worldSeq, sequence)
        controller.shellAppWindowManager.applyingFrames.insert(token)
        defer { controller.shellAppWindowManager.applyingFrames.remove(token) }

        controller.shellAppWindowManager.windowDidResize(notification(window))
        controller.shellAppWindowManager.windowDidMove(notification(window))

        XCTAssertEqual(controller.workspaceManager.worldSeq, sequence)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.frame, initialFrame)
    }

    func testNativeGeometryObservationsKeepTheTiledModeAndRejectUnchangedFrames() throws {
        let controller = makeController()
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let window = makeWindow()
        defer { window.close() }
        let token = try admit(window, controller: controller)
        let frame = initialFrame.offsetBy(dx: initialFrame.width, dy: initialFrame.height)
        let mode = controller.workspaceManager.entry(for: token)?.mode
        let phase = controller.workspaceManager.entry(for: token)?.lifecyclePhase

        XCTAssertTrue(controller.workspaceManager.observeHostedWindowGeometry(frame: frame, for: token))

        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.frame, frame)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.mode, mode)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.lifecyclePhase, phase)
        XCTAssertNil(controller.workspaceManager.floatingState(for: token))
        let sequence = controller.workspaceManager.worldSeq
        XCTAssertFalse(controller.workspaceManager.observeHostedWindowGeometry(frame: frame, for: token))
        XCTAssertEqual(controller.workspaceManager.worldSeq, sequence)
    }

    func testOnlyExternalTargetsEnterTheAXNativeTitleBarDragObserver() throws {
        let controller = makeController()
        defer { controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let hosted = makeWindow()
        let external = makeWindow()
        defer { hosted.close()
            external.close()
        }
        let hostedToken = try admit(hosted, controller: controller)
        let workspace = try XCTUnwrap(controller.workspaceManager.entry(for: hostedToken)?.workspaceId)
        let externalToken = WindowToken(pid: getpid(), windowId: external.windowNumber)
        _ = WindowAdmissionTestSupport.track(externalToken, in: workspace, controller: controller)

        XCTAssertNil(controller.mouseEventHandler.nativeTitleBarDragCandidate(
            windowIdUnderPointer: hostedToken.windowId
        ))
        XCTAssertEqual(controller.mouseEventHandler.nativeTitleBarDragCandidate(
            windowIdUnderPointer: externalToken.windowId
        ), externalToken)
    }

    private func makeController(operations: @escaping (String) -> Void = { _ in }) -> WMController {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "HostedWindowObservations",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in operations("activate") },
                focusSpecificWindow: { _, _, _ in operations("focus") },
                raiseWindow: { _ in operations("raise") },
                orderWindow: { _ in operations("order") }
            )
        )
        controller.hasStartedServices = true
        controller.shellAppWindowManager.activateApplication = {}
        return controller
    }

    private func makeWindow() -> HostedObservationWindow {
        let window = HostedObservationWindow(
            contentRect: initialFrame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func admit(_ window: NSWindow, controller: WMController) throws -> WindowToken {
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        return try XCTUnwrap(controller.shellAppWindowManager.admit(
            window,
            metadata: HostedWindowMetadata(
                appId: "observations",
                title: "Observations",
                minimumSize: initialFrame.size
            ),
            to: workspace
        ))
    }

    private func notification(_ window: NSWindow) -> Notification {
        Notification(name: NSWindow.didBecomeKeyNotification, object: window)
    }
}

@MainActor
private final class HostedObservationWindow: NSWindow {
    var reportsKey = false
    var reportsMinimized = false
    private var reportsVisible = true

    override var isKeyWindow: Bool {
        reportsKey
    }

    override var isMiniaturized: Bool {
        reportsMinimized
    }

    override var isVisible: Bool {
        reportsVisible
    }

    override func orderFront(_ sender: Any?) {
        reportsVisible = true
    }

    override func orderOut(_ sender: Any?) {
        reportsVisible = false
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        reportsKey = true
        reportsVisible = true
    }
}
