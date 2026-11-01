// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowEffectTests: XCTestCase {
    private let initialFrame = CGRect(x: 40, y: 80, width: 320, height: 240)

    func testMixedFramePreparationKeepsOnlyTheExternalAXTarget() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HostedFrameRouting")
        defer {
            controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let hosted = makeWindow()
        defer { hosted.close() }
        let token = try admit(hosted, to: workspace, controller: controller)
        let external = makeWindow()
        defer { external.close() }
        let reference = AXWindowRef(
            element: AXUIElementCreateApplication(getpid()), windowId: external.windowNumber
        )
        let externalToken = controller.workspaceManager.addWindow(
            reference, pid: getpid(), windowId: external.windowNumber, to: workspace
        )
        let target = initialFrame.offsetBy(dx: initialFrame.width, dy: initialFrame.height)
        let preparation = LayoutDiffExecutor(refreshController: controller.layoutRefreshController)
            .prepareFrameOnlyUpdates([
                .init(token: token, frame: target, forceApply: true, allowsTerminalRecovery: true),
                .init(token: externalToken, frame: target, components: .position, forceApply: false)
            ], controller: controller)

        XCTAssertEqual(preparation.frameUpdates.map(\.windowId), [externalToken.windowId])
        let update = try XCTUnwrap(preparation.frameUpdates.first)
        XCTAssertEqual(update.pid, externalToken.pid)
        XCTAssertEqual(update.windowId, externalToken.windowId)
        XCTAssertTrue(CFEqual(update.expectedWindow.element, reference.element))
        XCTAssertEqual(update.frame, target)
        XCTAssertEqual(update.components, .position)
        XCTAssertTrue(preparation.terminalRecoveryFrameUpdates.isEmpty)
        XCTAssertEqual(hosted.frame, target)
        XCTAssertNil(controller.axManager.recentFrameWriteFailure(for: token.windowId))
    }

    func testOrdinaryVisibilityPlanShowsAndFramesOnlyThroughTheNativeOwner() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HostedVisibilityFrame")
        defer {
            controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let window = makeWindow()
        defer { window.close() }
        let token = try admit(window, to: workspace, controller: controller)
        let target = initialFrame.offsetBy(dx: initialFrame.width, dy: initialFrame.height)
        let bounds = initialFrame.union(target)
        let displayId = CGMainDisplayID()
        let monitor = Monitor(
            id: .init(displayId: displayId), displayId: displayId,
            frame: bounds, visibleFrame: bounds, hasNotch: false, name: "Hosted Visibility"
        )
        var diff = WorkspaceLayoutDiff()
        diff.visibilityChanges = [.show(token)]
        diff.frameChanges = [.init(token: token, frame: target, forceApply: true)]
        let plan = WorkspaceLayoutPlan(
            workspaceId: workspace,
            monitor: LayoutMonitorSnapshot(
                monitorId: monitor.id, displayId: displayId,
                frame: bounds, visibleFrame: bounds, workingFrame: bounds, fullscreenLayoutFrame: bounds,
                scale: window.backingScaleFactor, orientation: monitor.autoOrientation
            ),
            sessionPatch: .init(workspaceId: workspace, viewportState: nil),
            diff: diff
        )
        XCTAssertFalse(LayoutDiffExecutor.isFrameOnly(diff))
        XCTAssertTrue(controller.shellAppWindowManager.setHidden(true, for: token))
        var application = LayoutVisibilityApplication(
            plan: plan, monitor: monitor, controller: controller,
            refreshController: controller.layoutRefreshController
        )

        application.execute()

        XCTAssertEqual(window.frame, target)
        XCTAssertEqual(window.ordering, [.out, .front])
        XCTAssertNil(controller.axManager.parkTargetFrame(for: token.windowId))
        XCTAssertNil(controller.axManager.recentFrameWriteFailure(for: token.windowId))
    }

    func testNativeFrameComponentsKeepTheTopEdgeWhenOnlySizeChanges() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HostedFrameComponents")
        defer { controller.layoutRefreshController.resetState() }
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let window = makeWindow()
        defer { window.close() }
        let token = try admit(window, to: workspace, controller: controller)
        let sizeTarget = CGRect(origin: .zero, size: CGSize(
            width: initialFrame.width * 2, height: initialFrame.height * 2
        ))

        XCTAssertTrue(controller.shellAppWindowManager.setFrame(sizeTarget, for: token, components: .size))
        XCTAssertEqual(window.frame.size, sizeTarget.size)
        XCTAssertEqual(window.frame.minX, initialFrame.minX)
        XCTAssertEqual(window.frame.maxY, initialFrame.maxY)
        let positionTarget = initialFrame.offsetBy(dx: initialFrame.width, dy: initialFrame.height)
        XCTAssertTrue(controller.shellAppWindowManager.setFrame(positionTarget, for: token, components: .position))
        XCTAssertEqual(window.frame.size, sizeTarget.size)
        XCTAssertEqual(window.frame.minX, positionTarget.minX)
        XCTAssertEqual(window.frame.maxY, positionTarget.maxY)
    }

    func testParkingAndRestoreUseNativeOrderingWithoutAXParkJobs() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "HostedParking")
        defer {
            controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let window = makeWindow()
        defer { window.close() }
        let token = try admit(window, to: workspace, controller: controller)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let parked = LayoutRefreshController.WindowPositionPlan(
            entry: entry, frame: initialFrame.offsetBy(dx: -initialFrame.width, dy: .zero)
        )

        controller.layoutRefreshController.applyParkPositionPlans(
            [parked], movablePlans: [parked], animationTick: false
        )
        XCTAssertEqual(window.ordering, [.out])
        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertNil(controller.axManager.parkTargetFrame(for: token.windowId))
        let restored = controller.layoutRefreshController.applyPositionPlans([
            .init(entry: entry, frame: initialFrame)
        ])
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(window.ordering, [.out, .front])
        XCTAssertNil(controller.axManager.recentFrameWriteFailure(for: token.windowId))
    }

    func testNativeFocusAndNormalCloseAvoidExternalFocusOperations() throws {
        var operations: [String] = []
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "HostedFocusClose",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in operations.append("activate") },
                focusSpecificWindow: { _, _, _ in operations.append("focus") },
                raiseWindow: { _ in operations.append("raise") },
                orderWindow: { _ in operations.append("order") }
            )
        )
        defer {
            controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let window = makeWindow()
        defer { window.close() }
        let token = try admit(window, to: workspace, controller: controller)
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: token))
        var nativeActivations = 0
        controller.shellAppWindowManager.activateApplication = { nativeActivations += 1 }

        XCTAssertTrue(controller.performWindowFronting(entry))
        XCTAssertEqual(window.ordering, [.key])
        XCTAssertEqual(nativeActivations, [HostedEffectWindow.Ordering.key].count)
        XCTAssertTrue(operations.isEmpty)
        controller.performWindowOrdering(windowId: token.windowId)
        XCTAssertEqual(window.ordering, [.key, .front])
        XCTAssertTrue(operations.isEmpty)
        XCTAssertTrue(controller.windowActionHandler.closeWindow(handle: handle))
        XCTAssertEqual(window.closeRequests, [handle].count)
        window.close()
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertNil(controller.shellAppWindowManager.frame(for: token))
        XCTAssertFalse(controller.shellAppWindowManager.close(token))
        XCTAssertTrue(operations.isEmpty)
    }

    func testExternalFrontingKeepsItsExactFocusThenRaiseOperations() throws {
        var operations: [String] = []
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "ExternalFocusUnchanged",
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in operations.append("activate") },
                focusSpecificWindow: { _, _, _ in operations.append("focus") },
                raiseWindow: { _ in operations.append("raise") },
                orderWindow: { _ in operations.append("order") }
            )
        )
        defer { controller.layoutRefreshController.resetState() }
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let window = makeWindow()
        defer { window.close() }
        let reference = AXWindowRef(
            element: AXUIElementCreateApplication(getpid()), windowId: window.windowNumber
        )
        let token = controller.workspaceManager.addWindow(
            reference, pid: getpid(), windowId: window.windowNumber, to: workspace
        )

        XCTAssertTrue(controller.performWindowFronting(try XCTUnwrap(controller.workspaceManager.entry(for: token))))
        XCTAssertEqual(operations, ["focus", "raise"])
        controller.performWindowOrdering(windowId: token.windowId)
        XCTAssertEqual(operations, ["focus", "raise", "order"])
        XCTAssertTrue(window.ordering.isEmpty)
    }

    private func makeWindow() -> HostedEffectWindow {
        let window = HostedEffectWindow(
            contentRect: initialFrame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func admit(
        _ window: NSWindow,
        to workspace: WorkspaceDescriptor.ID,
        controller: WMController
    ) throws -> WindowToken {
        try XCTUnwrap(controller.shellAppWindowManager.admit(
            window,
            metadata: HostedWindowMetadata(appId: "effect-test", title: "Effect Test", minimumSize: initialFrame.size),
            to: workspace
        ))
    }
}

@MainActor
private final class HostedEffectWindow: NSWindow {
    enum Ordering: Equatable {
        case front
        case out
        case key
    }

    var ordering: [Ordering] = []
    var closeRequests = 0
    private var reportsVisible = true
    override var isVisible: Bool {
        reportsVisible
    }

    override func orderFront(_ sender: Any?) {
        reportsVisible = true
        ordering.append(.front)
    }

    override func orderOut(_ sender: Any?) {
        reportsVisible = false
        ordering.append(.out)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        reportsVisible = true
        ordering.append(.key)
    }

    override func performClose(_ sender: Any?) {
        closeRequests += 1
    }
}
