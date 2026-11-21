// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowFocusTests: XCTestCase {
    func testKeyboardFocusKeepsTheExactNativeTargetAndExistingFronting() throws {
        let fixture = try HostedFocusFixture()
        defer { fixture.cleanup() }
        let other = try fixture.addHosted()
        let target = try fixture.addHosted()

        XCTAssertNotNil(fixture.controller.focusWindow(target, raisesWindow: false))

        XCTAssertEqual(fixture.recorder.operations, [.nativeFront(target), .nativeActivate, .nativeExactFocus(target)])
        XCTAssertNotEqual(other, target)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, target)
    }

    func testMouseFocusActivatesTheExactWindowWithoutRaisingAndReadsThePolicyOnRetry() throws {
        let fixture = try HostedFocusFixture()
        defer { fixture.cleanup() }
        _ = try fixture.addHosted()
        let target = try fixture.addHosted()
        fixture.controller.settings.focus.raiseOnMouseFocus = false
        let request = try XCTUnwrap(fixture.controller.focusWindow(target, origin: .focusFollowsMouse))

        XCTAssertEqual(fixture.recorder.operations, [.nativeKey(target), .nativeExactFocus(target)])
        fixture.controller.settings.focus.raiseOnMouseFocus = true
        fixture.controller.retryManagedFocusFronting(request)
        fixture.controller.settings.focus.raiseOnMouseFocus = false
        fixture.controller.retryManagedFocusFronting(request)

        XCTAssertEqual(fixture.recorder.operations, [
            .nativeKey(target), .nativeExactFocus(target), .nativeFront(target), .nativeActivate,
            .nativeExactFocus(target),
            .nativeKey(target), .nativeExactFocus(target)
        ])
        XCTAssertTrue(fixture.recorder.coverageQueries.isEmpty)
    }

    func testCoveredMouseFocusUsesTheSamePolicyForHostedAndExternalWindows() throws {
        for hosted in [true, false] {
            let fixture = try HostedFocusFixture()
            defer { fixture.cleanup() }
            let target: WindowToken
            if hosted { target = try fixture.addHosted() }
            else { target = fixture.addExternal() }
            let floating = try fixture.addHosted()
            XCTAssertTrue(fixture.controller.workspaceManager.setWindowMode(.floating, for: floating))
            fixture.controller.settings.focus.raiseOnMouseFocus = true
            fixture.recorder.covered = true
            let request = try XCTUnwrap(fixture.controller.focusWindow(target, origin: .focusFollowsMouse))

            XCTAssertEqual(
                fixture.recorder.operations,
                hosted ? [.nativeKey(target), .nativeExactFocus(target)] : [.externalFocus(target)]
            )
            XCTAssertEqual(fixture.recorder.coverageQueries.map(\.windowId), [UInt32(target.windowId)])
            XCTAssertEqual(fixture.recorder.coverageQueries.map(\.candidates), [Set([UInt32(floating.windowId)])])
            fixture.recorder.operations.removeAll()
            fixture.recorder.covered = false
            fixture.controller.retryManagedFocusFronting(request)

            XCTAssertEqual(
                fixture.recorder.operations,
                hosted
                    ? [.nativeFront(target), .nativeActivate, .nativeExactFocus(target)]
                    : [.externalFocus(target), .externalRaise]
            )
        }
    }

    func testSupersededAndCanceledRequestsCannotFocusANativeWindow() throws {
        let fixture = try HostedFocusFixture()
        defer { fixture.cleanup() }
        let previous = try fixture.addHosted()
        let target = try fixture.addHosted()
        let stale = try XCTUnwrap(fixture.controller.focusWindow(previous))
        let current = try XCTUnwrap(fixture.controller.focusWindow(target))
        let previousEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: previous))
        let targetEntry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: target))
        fixture.recorder.operations.removeAll()

        XCTAssertFalse(fixture.controller.applyManagedFocusRequest(
            stale,
            entry: previousEntry,
            validatesPointer: false
        ))
        XCTAssertFalse(fixture.controller.applyManagedFocusRequest(
            current,
            entry: previousEntry,
            validatesPointer: false
        ))
        fixture.controller.cancelManagedFocusRequest(current)
        XCTAssertFalse(fixture.controller.applyManagedFocusRequest(
            current,
            entry: targetEntry,
            validatesPointer: false
        ))

        XCTAssertTrue(fixture.recorder.operations.isEmpty)
    }

    func testClosedNativeTokensCannotFocusOrActivateTheApplication() throws {
        let fixture = try HostedFocusFixture()
        defer { fixture.cleanup() }
        let token = try fixture.addHosted()
        let window = try XCTUnwrap(fixture.controller.shellAppWindowManager.windows[token])
        window.close()

        XCTAssertNil(fixture.controller.focusWindow(token))
        XCTAssertFalse(fixture.controller.shellAppWindowManager.focus(token, raisesWindow: false))
        XCTAssertFalse(fixture.controller.shellAppWindowManager.focus(token))
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
    }
}

private enum HostedFocusOperation: Equatable {
    case nativeKey(WindowToken)
    case nativeExactFocus(WindowToken)
    case nativeFront(WindowToken)
    case nativeActivate
    case externalFocus(WindowToken)
    case externalRaise
    case externalActivate
    case externalOrder
}

@MainActor
private final class HostedFocusRecorder {
    var operations: [HostedFocusOperation] = []
    var covered: Bool?
    var coverageQueries: [(windowId: UInt32, candidates: Set<UInt32>)] = []
}

@MainActor
private final class HostedFocusFixture {
    let controller: WMController
    let recorder: HostedFocusRecorder
    let workspace: WorkspaceDescriptor.ID
    private let initialFrame = CGRect(x: 40, y: 80, width: 320, height: 240)
    private var windows: [HostedFocusWindow] = []

    init() throws {
        let recorder = HostedFocusRecorder()
        self.recorder = recorder
        controller = WindowAdmissionTestSupport.controller(
            prefix: "HostedWindowFocus",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in recorder.operations.append(.externalActivate) },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append(.externalFocus(WindowToken(pid: pid, windowId: Int(windowId))))
                },
                raiseWindow: { _ in recorder.operations.append(.externalRaise) },
                orderWindow: { _ in recorder.operations.append(.externalOrder) },
                hasOverlappingWindowsAbove: { windowId, candidates in
                    recorder.coverageQueries.append((windowId, candidates))
                    return recorder.covered
                }
            )
        )
        controller.shellAppWindowManager.activateApplication = { recorder.operations.append(.nativeActivate) }
        controller.shellAppWindowManager.focusWithoutRaising = { recorder.operations.append(.nativeExactFocus($0)) }
        let bounds = CGRect(origin: .zero, size: CGSize(width: initialFrame.maxX, height: initialFrame.maxY))
        let display = CGDirectDisplayID.max
        let monitor = Monitor(
            id: .init(displayId: display), displayId: display, frame: bounds, visibleFrame: bounds,
            hasNotch: false, name: "Hosted Focus"
        )
        controller.settings.workspaces.configurations = [WorkspaceConfiguration(
            name: "1", monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: .dwindle
        )]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.setFocusFollowsMouse(true)
    }

    func addHosted() throws -> WindowToken {
        let window = makeWindow()
        return try XCTUnwrap(controller.shellAppWindowManager.admit(
            window,
            metadata: HostedWindowMetadata(appId: "focus", title: "Focus", minimumSize: initialFrame.size),
            to: workspace
        ))
    }

    func addExternal() -> WindowToken {
        let window = makeWindow()
        return controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(getpid()), windowId: window.windowNumber),
            pid: getpid(), windowId: window.windowNumber, to: workspace
        )
    }

    func cleanup() {
        for window in windows { window.close() }
        controller.layoutRefreshController.resetState()
        controller.surfaceReconciler.cleanup()
        controller.axManager.cleanup()
    }

    private func makeWindow() -> HostedFocusWindow {
        let window = HostedFocusWindow(
            contentRect: initialFrame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.recorder = recorder
        windows.append(window)
        return window
    }
}

@MainActor
private final class HostedFocusWindow: NSWindow {
    var recorder: HostedFocusRecorder?
    private var reportsKey = false

    override var isKeyWindow: Bool {
        reportsKey
    }

    override var isVisible: Bool {
        true
    }

    override func makeKey() {
        reportsKey = true
        recorder?.operations.append(.nativeKey(WindowToken(pid: getpid(), windowId: windowNumber)))
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        reportsKey = true
        recorder?.operations.append(.nativeFront(WindowToken(pid: getpid(), windowId: windowNumber)))
    }

    override func orderFront(_ sender: Any?) {}

    override func orderOut(_ sender: Any?) {}
}
