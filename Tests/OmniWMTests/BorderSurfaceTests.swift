// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import OmniWMLayerCorners
import QuartzCore
import XCTest

final class BorderSurfaceTests: XCTestCase {
    @MainActor
    private final class RecordingLayerPanel: BorderLayerPanel {
        var orders: [(NSWindow.OrderingMode, Int, Int)] = []
        var presentationEvents: [String] = []
        var invalidWindowNumber = false
        var borderUpdateCount = 0

        var renderedCornerRadii: WindowCornerRadii {
            let radii = borderLayer.cornerRadii
            return WindowCornerRadii(
                topLeft: radii.topLeft.width, topRight: radii.topRight.width,
                bottomLeft: radii.bottomLeft.width, bottomRight: radii.bottomRight.width
            )
        }

        override func updateBorder(
            geometry: BorderConfig.ResolvedGeometry,
            cornerRadii: WindowCornerRadii,
            color: CGColor,
            scale: CGFloat
        ) {
            borderUpdateCount += 1
            super.updateBorder(geometry: geometry, cornerRadii: cornerRadii, color: color, scale: scale)
        }

        override var windowNumber: Int {
            invalidWindowNumber ? 0 : super.windowNumber
        }

        var shows = 0
        var hides = 0
        var closes = 0

        override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
            orders.append((place, otherWin, level.rawValue))
        }

        override func orderFront(_ sender: Any?) {
            shows += 1
            presentationEvents.append("show")
        }

        override func orderOut(_ sender: Any?) {
            hides += 1
            super.orderOut(sender)
        }

        override func close() {
            closes += 1
            super.close()
        }
    }

    @MainActor
    private final class BorderOperationsRecorder {
        struct OrderCall: Equatable {
            let windowId: UInt32
            let targetWindowId: UInt32
            let level: Int
            let order: SkyLightWindowOrder
        }

        var layerPanels: [RecordingLayerPanel] = []
        var screencaptureExclusionCount = 0
        var windowInfoQueryCount = 0
        var backingScaleQueryCount = 0
        var backingScale: CGFloat = 2
        var screenFrame = CGRect(x: 0, y: 0, width: 5000, height: 5000)
        var orderCalls: [OrderCall] = []
        var failsNextCreation = false
        var windowInfoProvider: @MainActor (UInt32) -> WindowServerInfo? = {
            WindowServerInfo(id: $0, pid: 1234, level: 0, frame: .zero)
        }

        func operations() -> BorderWindow.Operations {
            BorderWindow.Operations(
                createLayerPanel: { [weak self] frame in
                    _ = NSApplication.shared
                    guard let panel = RecordingLayerPanel(frame: frame) else { return nil }
                    panel.invalidWindowNumber = self?.failsNextCreation == true
                    self?.failsNextCreation = false
                    self?.layerPanels.append(panel)
                    return panel
                },
                excludeFromScreencaptureSelection: { [weak self] _ in self?.screencaptureExclusionCount += 1 },
                queryWindowInfoDeferred: { [weak self] windowId in
                    guard let self else { return nil }
                    windowInfoQueryCount += 1
                    return windowInfoProvider(windowId)
                },
                backingScaleForFrame: { [weak self] _ in
                    guard let self else { return (2, .null) }
                    backingScaleQueryCount += 1
                    return (backingScale, screenFrame)
                },
                orderWindow: { [weak self] wid, targetWid, order in
                    guard let self, let panel = layerPanels.first(where: { $0.windowNumber == Int(wid) }) else {
                        XCTFail("Direct order must use the owned panel")
                        return
                    }
                    panel.presentationEvents.append("order")
                    orderCalls.append(OrderCall(
                        windowId: wid, targetWindowId: targetWid, level: panel.level.rawValue, order: order
                    ))
                }
            )
        }
    }

    @MainActor
    private final class DeferredLevelProbe {
        var requests: [UInt32] = []
        var onRequest: (() -> Void)?
        private var continuation: CheckedContinuation<WindowServerInfo?, Never>?

        func query(_ windowId: UInt32) async -> WindowServerInfo? {
            await withCheckedContinuation {
                XCTAssertNil(continuation)
                continuation = $0
                requests.append(windowId)
                onRequest?()
            }
        }

        func complete(_ info: WindowServerInfo?) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: info)
        }

        func operations(_ recorder: BorderOperationsRecorder) -> BorderWindow.Operations {
            var operations = recorder.operations()
            operations.queryWindowInfoDeferred = { await self.query($0) }
            return operations
        }
    }

    @MainActor
    private final class DeferredCornerProbe {
        var requests: [WindowToken] = []
        var onRequest: (() -> Void)?
        private var continuation: CheckedContinuation<WindowCornerSample?, Error>?

        func query(_ token: WindowToken) async throws -> WindowCornerSample? {
            try await withCheckedThrowingContinuation {
                XCTAssertNil(continuation)
                continuation = $0
                requests.append(token)
                onRequest?()
            }
        }

        func complete(_ sample: WindowCornerSample?) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: sample)
        }

        func applier(_ recorder: BorderOperationsRecorder) -> BorderSurfaceApplier {
            BorderSurfaceApplier(
                borderWindowOperations: recorder.operations(),
                cornerSampleProvider: { try await self.query($0) }
            )
        }
    }

    @MainActor
    private func makeApplier(
        _ recorder: BorderOperationsRecorder,
        cornerSampleProvider: @escaping @MainActor (WindowToken) async throws -> WindowCornerSample? = { _ in nil }
    ) -> BorderSurfaceApplier {
        BorderSurfaceApplier(
            borderWindowOperations: recorder.operations(),
            cornerSampleProvider: cornerSampleProvider
        )
    }

    private let frame = CGRect(x: 10, y: 10, width: 200, height: 150)
    private let configRed = BorderConfig(
        enabled: true,
        width: 4,
        color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
    )
    private let configBlue = BorderConfig(
        enabled: true,
        width: 4,
        color: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)
    )

    private func token(windowId: Int = 77, pid: pid_t = 1234) -> WindowToken {
        WindowToken(pid: pid, windowId: windowId)
    }

    private func desired(
        _ config: BorderConfig,
        token: WindowToken? = nil,
        frame: CGRect? = nil
    ) -> DesiredBorderSurface {
        DesiredBorderSurface(token: token ?? self.token(), frame: frame ?? self.frame, config: config)
    }

    private func sample(
        _ radii: WindowCornerRadii,
        size: CGSize? = nil,
        source: WindowCornerSource = .resolved
    ) -> WindowCornerSample {
        WindowCornerSample(radii: radii, observedSize: size ?? frame.size, source: source)
    }

    @MainActor
    private func reconcileFixture() throws -> (controller: WMController, entry: WindowState) {
        let controller = WindowAdmissionTestSupport.controller(prefix: "BorderMotionQueryTests")
        controller.settings.workspaceBar.enabled = false
        controller.settings.borders.enabled = true
        let monitor = Monitor(
            id: .init(displayId: 814_101), displayId: 814_101,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visibleFrame: .zero,
            hasNotch: false, name: "Border Motion"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        _ = controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id)
        _ = controller.workspaceManager.focusWorkspace(id: workspaceId)
        controller.workspaceManager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: String(monitor.displayId), spaceIds: [1], currentSpaceId: 1)],
            activeSpaceId: 1, fullscreenSpaceIds: [], windowSpace: [:]
        ))
        let token = WindowToken(pid: 814_102, windowId: 814_103)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: frame)
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(token, in: workspaceId))
        controller.hasStartedServices = true
        return (controller, try XCTUnwrap(controller.workspaceManager.entry(for: token)))
    }

    @MainActor
    private func startViewportMotion(_ controller: WMController, workspaceId: WorkspaceDescriptor.ID) {
        let previous = ViewportState()
        var next = previous
        next.springOffset(to: 500)
        controller.workspaceManager.animationDriver.reconcileViewportCommit(
            workspaceId: workspaceId, previous: previous, next: next,
            transition: next.offsetTransition, at: 0
        )
    }

    @MainActor
    func testScheduledReconcilesDrawDuringMotionAndSampleCornersAfterSettlement() async throws {
        for fullScene in [false, true] {
            let (controller, entry) = try reconcileFixture()
            let recorder = BorderOperationsRecorder()
            recorder.windowInfoProvider = { WindowServerInfo(id: $0, pid: entry.pid, level: 0, frame: .zero) }
            var queries = 0
            let applier = makeApplier(recorder) { _ in
                queries += 1
                return self.sample(WindowCornerRadii(uniform: 13))
            }
            let reconciler = SurfaceReconciler(controller: controller, borderApplier: applier)
            let resolved = expectation(description: "eligible corners resolved")
            let notify = applier.onCornerSampleResolved
            applier.onCornerSampleResolved = { notify?()
                resolved.fulfill()
            }
            defer {
                controller.hasStartedServices = false
                reconciler.cleanup()
            }
            startViewportMotion(controller, workspaceId: entry.workspaceId)
            if fullScene {
                reconciler.noteWorldChanged()
            } else {
                reconciler.noteBorderChanged()
            }

            reconciler.reconcileNow()

            XCTAssertEqual(queries, 0)
            XCTAssertEqual(reconciler.appliedScene.border?.token, entry.token)
            XCTAssertEqual(reconciler.appliedScene.border?.frame, frame)
            XCTAssertNotNil(recorder.layerPanels.first?.borderLayer.rimColor)
            XCTAssertFalse(reconciler.reconcileScheduled)
            XCTAssertFalse(controller.workspaceManager.animationDriver.tick(in: entry.workspaceId, at: 1000))
            reconciler.noteRestackOccurred()
            reconciler.reconcileAnimationTick()
            XCTAssertEqual(reconciler.pendingReconcileScope, .borderOnly)
            XCTAssertEqual(queries, 0)

            reconciler.reconcileNow()
            reconciler.noteBorderChanged()
            reconciler.reconcileNow()

            await fulfillment(of: [resolved], timeout: 1)
            reconciler.reconcileNow()
            XCTAssertEqual(queries, 1)
            XCTAssertNotNil(recorder.layerPanels.first?.borderLayer.rimColor)
            XCTAssertEqual(reconciler.appliedScene.border?.token, entry.token)
        }
    }

    @MainActor
    func testSettledCornerRefreshWaitsForPendingFrameVerification() async throws {
        let (controller, entry) = try reconcileFixture()
        let recorder = BorderOperationsRecorder()
        var queries = 0
        let pendingFrame = frame.offsetBy(dx: 20, dy: 0)
        let applier = makeApplier(recorder) { _ in
            queries += 1
            return self.sample(WindowCornerRadii(uniform: 13))
        }
        let reconciler = SurfaceReconciler(controller: controller, borderApplier: applier)
        let resolved = expectation(description: "eligible corners resolved")
        let notify = applier.onCornerSampleResolved
        applier.onCornerSampleResolved = { notify?()
            resolved.fulfill()
        }
        defer {
            controller.hasStartedServices = false
            reconciler.cleanup()
        }
        startViewportMotion(controller, workspaceId: entry.workspaceId)
        let request = try XCTUnwrap(controller.axManager.stageFrameWrite(for: AXFrameApplicationTarget(
            pid: entry.pid, window: entry.axRef, frame: pendingFrame
        )))
        XCTAssertFalse(controller.workspaceManager.animationDriver.tick(in: entry.workspaceId, at: 1000))
        reconciler.noteRestackOccurred()
        reconciler.reconcileNow()
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(reconciler.appliedScene.border?.frame, pendingFrame)

        let result = WindowAdmissionTestSupport.successfulFrameResult(request: request)
        controller.axManager.handleFrameApplyResults([result])
        reconciler.handleVerifiedFrameApplySuccess(result)
        reconciler.reconcileNow()

        await fulfillment(of: [resolved], timeout: 1)
        reconciler.reconcileNow()
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(reconciler.appliedScene.border?.token, entry.token)
    }

    @MainActor
    func testViewportMotionInAnotherWorkspaceDoesNotDeferBorderCorners() async throws {
        let (controller, entry) = try reconcileFixture()
        let recorder = BorderOperationsRecorder()
        var queries = 0
        let applier = makeApplier(recorder) { _ in
            queries += 1
            return self.sample(WindowCornerRadii(uniform: 13))
        }
        let reconciler = SurfaceReconciler(controller: controller, borderApplier: applier)
        let resolved = expectation(description: "eligible corners resolved")
        let notify = applier.onCornerSampleResolved
        applier.onCornerSampleResolved = { notify?()
            resolved.fulfill()
        }
        defer {
            controller.hasStartedServices = false
            reconciler.cleanup()
        }
        startViewportMotion(controller, workspaceId: WorkspaceDescriptor.ID())
        reconciler.noteBorderChanged()
        reconciler.reconcileNow()

        await fulfillment(of: [resolved], timeout: 1)
        reconciler.reconcileNow()
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(reconciler.appliedScene.border?.token, entry.token)
    }

    @MainActor
    func testRepeatedIdenticalApplyIsNoOp() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let cornersAfterFirst = recorder.layerPanels.first?.renderedCornerRadii
        let updatesAfterFirst = recorder.layerPanels.first?.borderUpdateCount
        let orderingAfterFirst = recorder.orderCalls.count

        _ = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertEqual(recorder.layerPanels.first?.renderedCornerRadii, cornersAfterFirst)
        XCTAssertEqual(recorder.layerPanels.first?.borderUpdateCount, updatesAfterFirst)
        XCTAssertEqual(recorder.orderCalls.count, orderingAfterFirst)
    }

    @MainActor
    func testForceOrderingReordersWithoutRedraw() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let cornersAfterFirst = recorder.layerPanels.first?.renderedCornerRadii
        let updatesAfterFirst = recorder.layerPanels.first?.borderUpdateCount
        let moveAndOrdersAfterFirst = recorder.orderCalls.count

        _ = applier.apply(desired(configRed), forceOrdering: true)

        XCTAssertEqual(recorder.layerPanels.first?.renderedCornerRadii, cornersAfterFirst)
        XCTAssertEqual(recorder.layerPanels.first?.borderUpdateCount, updatesAfterFirst)
        XCTAssertGreaterThan(recorder.orderCalls.count, moveAndOrdersAfterFirst)
    }

    @MainActor
    func testFailedCreateReturnsFalseThenRetries() {
        let recorder = BorderOperationsRecorder()
        recorder.failsNextCreation = true
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        let firstApplied = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertFalse(firstApplied.didApply)
        XCTAssertEqual(recorder.layerPanels.first?.closes, 1)

        let secondApplied = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertTrue(secondApplied.didApply)
        XCTAssertEqual(recorder.layerPanels.count, 2)
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: recorder.layerPanels[1].windowNumber))
    }

    @MainActor
    func testUnavailableNativeRendererDoesNotPublishOrOrderASurface() {
        let recorder = BorderOperationsRecorder()
        var operations = recorder.operations()
        operations.createLayerPanel = { _ in nil }
        let window = BorderWindow(config: configRed, operations: operations)

        XCTAssertFalse(window.update(frame: frame, targetToken: token()))
        XCTAssertNil(window.windowId)
        XCTAssertNil(window.frameOnScreen)
        XCTAssertTrue(recorder.layerPanels.isEmpty)
        XCTAssertTrue(recorder.orderCalls.isEmpty)
        XCTAssertEqual(recorder.screencaptureExclusionCount, 0)
        XCTAssertEqual(recorder.windowInfoQueryCount, 0)
    }

    @MainActor
    func testConfigResyncedAfterHide() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder)
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        _ = applier.apply(nil, forceOrdering: false)
        XCTAssertEqual(recorder.layerPanels.first?.borderLayer.rimColor?.components, [1, 0, 0, 1])

        _ = applier.apply(desired(configBlue), forceOrdering: false)

        XCTAssertEqual(recorder.layerPanels.first?.borderLayer.rimColor?.components, [0, 0, 1, 1])
    }

    @MainActor
    func testLayerBorderPreservesSurfaceLifecycle() throws {
        let recorder = BorderOperationsRecorder()
        let applier = BorderSurfaceApplier(
            borderWindowOperations: recorder.operations(),
            cornerSampleProvider: { _ in nil }
        )
        defer { applier.cleanup() }
        XCTAssertTrue(applier.apply(desired(configRed), forceOrdering: false).didApply)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let id = panel.windowNumber
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: id))
        XCTAssertFalse(SurfaceCoordinator.shared.isCaptureEligible(windowNumber: id))
        XCTAssertEqual(recorder.screencaptureExclusionCount, 1)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertFalse(panel.isRestorable)
        XCTAssertEqual(panel.borderLayer.cornerCurve, .continuous)
        XCTAssertNil(panel.borderLayer.backgroundColor)
        XCTAssertNil(panel.borderLayer.contents)
        XCTAssertNil(panel.borderLayer.mask)
        XCTAssertFalse(panel.contentView?.isFlipped ?? true)
        XCTAssertFalse(panel.borderLayer.isGeometryFlipped)
        XCTAssertNil(panel.borderLayer.animationKeys())
        for key in ["rimWidth", "rimColor", "cornerRadii", "bounds", "position", "contentsScale"] {
            XCTAssertTrue(panel.borderLayer.actions?[key] is NSNull)
        }
        XCTAssertTrue(panel.orders.isEmpty)
        XCTAssertEqual(panel.shows, 1)
        XCTAssertEqual(panel.presentationEvents, ["show", "order"])
        XCTAssertEqual(recorder.orderCalls.count, 1)
        XCTAssertEqual(recorder.orderCalls[0].order, .below)
        XCTAssertEqual(recorder.orderCalls[0].targetWindowId, UInt32(token().windowId))

        _ = applier.apply(nil, forceOrdering: false)
        XCTAssertGreaterThanOrEqual(panel.hides, 1)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: id))
        _ = applier.apply(desired(configBlue), forceOrdering: false)
        XCTAssertEqual(recorder.layerPanels.count, 1)
        XCTAssertEqual(panel.shows, 2)
        XCTAssertEqual(panel.presentationEvents, ["show", "order", "show", "order"])
        XCTAssertTrue(SurfaceCoordinator.shared.contains(windowNumber: id))
        applier.cleanup()
        XCTAssertEqual(panel.closes, 1)
        XCTAssertFalse(SurfaceCoordinator.shared.contains(windowNumber: id))
    }

    @MainActor
    func testLayerBorderTranslationResizeScaleAndColorKeepOnePanel() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1
        recorder.windowInfoProvider = { WindowServerInfo(id: $0, pid: 1234, level: 8, frame: .zero) }
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        defer { window.destroy() }
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let originalUpdateCount = panel.borderUpdateCount
        let translated = frame.offsetBy(dx: -4000, dy: 3000)
        XCTAssertTrue(window.update(frame: translated, targetToken: token()))
        XCTAssertEqual(panel.frame, translated.insetBy(dx: -4, dy: -4))
        XCTAssertEqual(panel.borderUpdateCount, originalUpdateCount)
        XCTAssertEqual(recorder.windowInfoQueryCount, 0)
        XCTAssertTrue(panel.orders.isEmpty)
        XCTAssertEqual(panel.shows, 1)
        XCTAssertEqual(recorder.orderCalls.count, 1)
        XCTAssertEqual(recorder.orderCalls[0].level, 0)

        let resized = CGRect(x: 50, y: 80, width: 900, height: 700)
        XCTAssertTrue(window.update(frame: resized, targetToken: token()))
        XCTAssertEqual(panel.frame, resized.insetBy(dx: -4, dy: -4))
        XCTAssertEqual(panel.borderLayer.bounds, CGRect(origin: .zero, size: resized.size))
        XCTAssertEqual(panel.borderUpdateCount, originalUpdateCount + 1)
        window.updateConfig(configBlue)
        XCTAssertTrue(window.update(frame: resized, targetToken: token()))
        XCTAssertEqual(panel.borderLayer.rimColor?.components, [0, 0, 1, 1])
        recorder.backingScale = 2
        window.invalidateScaleCache()
        XCTAssertTrue(window.update(frame: resized, targetToken: token()))
        XCTAssertEqual(panel.borderLayer.contentsScale, 2)
        let scaledUpdateCount = panel.borderUpdateCount
        let fractional = resized.offsetBy(dx: 0.5, dy: -0.5)
        XCTAssertTrue(window.update(frame: fractional, targetToken: token()))
        XCTAssertEqual(panel.frame, fractional.insetBy(dx: -4, dy: -4).integral)
        XCTAssertEqual(
            panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
            fractional
        )
        XCTAssertEqual(panel.borderUpdateCount, scaledUpdateCount)
        XCTAssertEqual(recorder.layerPanels.count, 1)
        XCTAssertNil(panel.borderLayer.animationKeys())
    }

    @MainActor
    func testLayerBorderDirectOrderingRetargetsWithoutShowingAgain() throws {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        defer { window.destroy() }
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        for offset in 1 ... 100 {
            XCTAssertTrue(window.update(frame: frame.offsetBy(dx: CGFloat(offset), dy: 0), targetToken: token()))
        }
        XCTAssertEqual(recorder.orderCalls.count, 1)
        XCTAssertEqual(panel.shows, 1)

        let next = token(windowId: 78)
        XCTAssertTrue(window.update(frame: frame, targetToken: next))
        XCTAssertTrue(window.update(frame: frame, targetToken: next, forceOrdering: true))
        window.reorder(relativeTo: next)
        XCTAssertEqual(recorder.orderCalls.map(\.targetWindowId), [77, 78, 78, 78])
        XCTAssertTrue(recorder.orderCalls.allSatisfy { $0.order == .below })
        XCTAssertEqual(panel.presentationEvents, ["show", "order", "order", "order", "order"])
        XCTAssertEqual(panel.shows, 1)
        XCTAssertTrue(panel.orders.isEmpty)

        window.hide()
        window.reorder(relativeTo: next)
        XCTAssertEqual(panel.shows, 2)
        XCTAssertEqual(Array(panel.presentationEvents.suffix(2)), ["show", "order"])
        window.destroy()
        XCTAssertEqual(panel.closes, 1)
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        let recreated = try XCTUnwrap(recorder.layerPanels.last)
        XCTAssertFalse(recreated === panel)
        XCTAssertEqual(recreated.presentationEvents, ["show", "order"])
        XCTAssertEqual(recorder.orderCalls.last?.windowId, UInt32(recreated.windowNumber))
        XCTAssertEqual(recorder.orderCalls.last?.targetWindowId, 77)
    }

    @MainActor
    func testLayerBorderDeferredLevelUsesDirectOrderWithoutAnotherShow() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredLevelProbe()
        let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
        defer { window.destroy() }
        let started = expectation(description: "level query started")
        probe.onRequest = { started.fulfill() }
        let resolved = expectation(description: "level query resolved")
        window.onWindowLevelResolved = { resolved.fulfill() }
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        await fulfillment(of: [started], timeout: 1)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let latestFrame = frame.offsetBy(dx: 120, dy: 0)
        XCTAssertTrue(window.update(frame: latestFrame, targetToken: token()))
        XCTAssertEqual(recorder.orderCalls.map(\.level), [0])
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero))
        await fulfillment(of: [resolved], timeout: 1)
        XCTAssertTrue(window.update(frame: latestFrame, targetToken: token()))
        XCTAssertEqual(recorder.orderCalls.map(\.level), [0, 8])
        XCTAssertEqual(panel.shows, 1)
        XCTAssertEqual(panel.presentationEvents, ["show", "order", "order"])
        XCTAssertTrue(panel.orders.isEmpty)
        XCTAssertEqual(probe.requests, [77])
        XCTAssertEqual(panel.frame, latestFrame.insetBy(dx: -4, dy: -4).integral)
        XCTAssertTrue(window.update(frame: latestFrame, targetToken: token()))
        XCTAssertEqual(recorder.orderCalls.count, 2)
    }

    @MainActor
    func testNativeBorderPreservesFractionalWidthAndIndependentCornerGeometry() throws {
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)
        let radii = WindowCornerRadii(topLeft: 22, topRight: 0, bottomLeft: 3, bottomRight: 11)
        let config = BorderConfig(enabled: true, width: 4.5, color: configRed.color)
        for scale: CGFloat in [1, 2] {
            let recorder = BorderOperationsRecorder()
            recorder.backingScale = scale
            let window = BorderWindow(config: config, operations: recorder.operations())
            defer { window.destroy() }
            XCTAssertTrue(window.update(frame: target, targetToken: token(), cornerRadii: radii))
            let panel = try XCTUnwrap(recorder.layerPanels.first)
            let geometry = config.resolvedGeometry(for: target, scale: scale)
            XCTAssertEqual(panel.borderLayer.rimWidth, Double(geometry.width))
            XCTAssertEqual(panel.renderedCornerRadii, radii)
            XCTAssertEqual(panel.borderLayer.cornerRadii.topLeft.height, 22)
            XCTAssertEqual(panel.borderLayer.cornerRadii.topRight.height, 0)
            XCTAssertEqual(panel.borderLayer.cornerRadii.bottomRight.height, 11)
            XCTAssertEqual(panel.borderLayer.cornerRadii.bottomLeft.height, 3)
            XCTAssertEqual(panel.borderLayer.contentsScale, scale)
            XCTAssertEqual(panel.borderLayer.rimColor?.components, [1, 0, 0, 1])
            XCTAssertNil(panel.borderLayer.backgroundColor)
            XCTAssertNil(panel.borderLayer.contents)
            XCTAssertEqual(panel.frame, geometry.surfaceFrame.integral)
            XCTAssertEqual(
                panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
                geometry.targetFrame
            )
        }
    }

    @MainActor
    func testSolidRingPreservesRGBAAndSquareCornersWithoutAnAdditionalStroke() throws {
        let recorder = BorderOperationsRecorder()
        let colors = [
            SettingsColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.375),
            SettingsColor(red: 0.875, green: 0.25, blue: 0.5, alpha: 0.625)
        ]
        let window = BorderWindow(
            config: BorderConfig(enabled: true, width: 4, color: colors[0]),
            operations: recorder.operations()
        )
        defer { window.destroy() }

        for color in colors {
            window.updateConfig(BorderConfig(enabled: true, width: 4, color: color))
            XCTAssertTrue(window.update(frame: frame, targetToken: token(), cornerRadii: .zero))
            let panel = try XCTUnwrap(recorder.layerPanels.first)
            XCTAssertEqual(
                panel.borderLayer.rimColor?.components,
                [CGFloat(color.red), CGFloat(color.green), CGFloat(color.blue), CGFloat(color.alpha)]
            )
            XCTAssertEqual(panel.borderLayer.rimOpacity, 0)
            let renderedColors = try XCTUnwrap(panel.gradientStrokeLayer.colors as? [CGColor])
            XCTAssertEqual(renderedColors.count, 2)
            for renderedColor in renderedColors {
                XCTAssertEqual(renderedColor.components, panel.borderLayer.rimColor?.components)
            }
            XCTAssertEqual(panel.borderLayer.rimWidth, 4)
            XCTAssertEqual(panel.borderLayer.borderWidth, 0)
            XCTAssertEqual(panel.renderedCornerRadii, .zero)
            XCTAssertNil(panel.borderLayer.backgroundColor)
            XCTAssertNil(panel.borderLayer.mask)
            XCTAssertFalse(panel.borderLayer.masksToBounds)
            XCTAssertNil(panel.borderLayer.animationKeys())
        }
        XCTAssertEqual(recorder.layerPanels.count, 1)
        XCTAssertEqual(recorder.layerPanels.first?.borderUpdateCount, 2)
    }

    @MainActor
    func testNativeRimFractionalTranslationsKeepTargetAlignedWithoutRedraw() throws {
        let config = BorderConfig(enabled: true, width: 4.5, color: configRed.color)
        let target = CGRect(x: 10, y: 20, width: 100.5, height: 80.5)
        for scale: CGFloat in [1, 2] {
            let recorder = BorderOperationsRecorder()
            recorder.backingScale = scale
            let window = BorderWindow(config: config, operations: recorder.operations())
            defer { window.destroy() }
            XCTAssertTrue(window.update(frame: target, targetToken: token()))
            let panel = try XCTUnwrap(recorder.layerPanels.first)
            let updateCount = panel.borderUpdateCount
            let orderCount = recorder.orderCalls.count
            let scaleQueries = recorder.backingScaleQueryCount
            let levelQueries = recorder.windowInfoQueryCount

            for offset: CGFloat in [0, 0.5, -0.5, 13.5] {
                let translated = target.offsetBy(dx: offset, dy: -offset)
                let geometry = config.resolvedGeometry(for: translated, scale: scale)
                XCTAssertTrue(window.update(frame: translated, targetToken: token()))
                XCTAssertEqual(panel.frame, geometry.surfaceFrame.integral)
                XCTAssertEqual(panel.borderLayer.bounds, CGRect(origin: .zero, size: geometry.targetFrame.size))
                XCTAssertEqual(
                    panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
                    geometry.targetFrame
                )
                XCTAssertEqual(panel.borderLayer.rimWidth, Double(geometry.width))
                XCTAssertEqual(panel.borderUpdateCount, updateCount)
            }
            XCTAssertEqual(recorder.layerPanels.count, 1)
            XCTAssertEqual(recorder.orderCalls.count, orderCount)
            XCTAssertEqual(recorder.backingScaleQueryCount, scaleQueries)
            XCTAssertEqual(recorder.windowInfoQueryCount, levelQueries)
        }
    }

    @MainActor
    func testGradientAndGlowFractionalTranslationsReuseAlignedPaths() throws {
        let config = BorderConfig(
            enabled: true, width: 4.5, color: configRed.color,
            gradient: BorderGradient(
                enabled: true, start: configRed.color, end: configRed.color, direction: .topLeftToBottomRight
            ),
            glow: BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        )
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 2
        let window = BorderWindow(config: config, operations: recorder.operations())
        defer { window.destroy() }
        let target = CGRect(x: 10, y: 20, width: 100.5, height: 80.5)
        XCTAssertTrue(window.update(frame: target, targetToken: token()))
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let gradientPath = try XCTUnwrap(panel.gradientRingMaskLayer.path)
        let bands = try XCTUnwrap(panel.glowMaskLayer.sublayers)
        let bandPaths = try bands.map { try XCTUnwrap(($0 as? CAShapeLayer)?.path) }
        let redraws = panel.borderUpdateCount
        let orders = recorder.orderCalls.count
        let levels = recorder.windowInfoQueryCount
        let scales = recorder.backingScaleQueryCount
        for offset: CGFloat in [0, 0.5, -0.5, 13.5, 14] {
            let translated = target.offsetBy(dx: offset, dy: -offset)
            let geometry = config.resolvedGeometry(for: translated, scale: 2)
            XCTAssertTrue(window.update(frame: translated, targetToken: token()))
            for layer in [panel.gradientStrokeLayer, panel.glowColorLayer] {
                let localTarget = layer.convert(geometry.localized().targetFrame, to: nil)
                XCTAssertEqual(localTarget.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY), geometry.targetFrame)
            }
            XCTAssertTrue(panel.gradientRingMaskLayer.path === gradientPath)
            for (index, band) in bands.enumerated() {
                XCTAssertTrue(panel.glowMaskLayer.sublayers?[index] === band)
                XCTAssertTrue((band as? CAShapeLayer)?.path === bandPaths[index])
            }
            XCTAssertEqual(panel.borderUpdateCount, redraws)
        }
        XCTAssertEqual(recorder.layerPanels.count, 1)
        XCTAssertEqual(recorder.orderCalls.count, orders)
        XCTAssertEqual(recorder.windowInfoQueryCount, levels)
        XCTAssertEqual(recorder.backingScaleQueryCount, scales)
    }

    @MainActor
    func testControllerCachesBorderAppearanceAndRefreshesAfterModeChanges() {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        defer { app.appearance = originalAppearance }
        app.appearance = NSAppearance(named: .aqua)
        let controller = WindowAdmissionTestSupport.controller(prefix: "BorderAppearanceCache")
        XCTAssertFalse(controller.borderUsesDarkAppearance)
        let lightColor = controller.settings.borders.color
        let darkColor = SettingsColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        controller.settings.borders.darkColor = darkColor
        app.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(WorldView(controller: controller).borderConfig.color, lightColor)
        controller.refreshBorderAppearance()
        XCTAssertEqual(WorldView(controller: controller).borderConfig.color, darkColor)
        controller.settings.appearanceMode = .light
        controller.applyCurrentAppearanceMode()
        XCTAssertFalse(controller.borderUsesDarkAppearance)
        XCTAssertEqual(WorldView(controller: controller).borderConfig.color, lightColor)
        controller.settings.appearanceMode = .dark
        controller.applyCurrentAppearanceMode()
        XCTAssertTrue(controller.borderUsesDarkAppearance)
        XCTAssertEqual(WorldView(controller: controller).borderConfig.color, darkColor)
    }

    @MainActor
    func testExteriorBorderExpandsSurfaceAndLeavesFillTransparent() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        defer { window.destroy() }
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)

        XCTAssertTrue(window.update(frame: target, targetToken: token(windowId: 55)))
        let panel = try XCTUnwrap(recorder.layerPanels.first)

        XCTAssertEqual(window.targetFrameOnScreen, target)
        XCTAssertEqual(window.frameOnScreen, CGRect(x: 6, y: 16, width: 108, height: 88))
        XCTAssertEqual(panel.borderLayer.bounds, CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(panel.borderLayer.rimWidth, 4)
        XCTAssertEqual(panel.renderedCornerRadii, WindowCornerRadii(uniform: 9))
        XCTAssertNil(panel.borderLayer.backgroundColor)
        XCTAssertNil(panel.borderLayer.contents)
        XCTAssertNil(panel.borderLayer.mask)
        XCTAssertFalse(panel.borderLayer.isOpaque)
    }

    @MainActor
    func testFractionalWidthUsesTheSamePhysicalPixelClearanceForSurfaceAndDrawing() throws {
        let recorder = BorderOperationsRecorder()
        recorder.backingScale = 1
        let config = BorderConfig(
            enabled: true,
            width: 4.5,
            color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let window = BorderWindow(config: config, operations: recorder.operations())
        defer { window.destroy() }
        let target = CGRect(x: 10, y: 20, width: 100, height: 80)

        XCTAssertTrue(window.update(frame: target, targetToken: token(windowId: 55)))
        let panel = try XCTUnwrap(recorder.layerPanels.first)

        XCTAssertEqual(config.resolvedGeometry(for: target, scale: 1).width, 5)
        XCTAssertEqual(window.targetFrameOnScreen, target)
        XCTAssertEqual(window.frameOnScreen, CGRect(x: 5, y: 15, width: 110, height: 90))
        XCTAssertEqual(panel.borderLayer.bounds, CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(panel.borderLayer.rimWidth, 5)
        XCTAssertEqual(panel.renderedCornerRadii, WindowCornerRadii(uniform: 9))
    }

    @MainActor
    func testScaleInvalidationBypassesApplierEqualityAndReconfiguresExistingSurface() {
        let recorder = BorderOperationsRecorder()
        let applier = makeApplier(recorder) { _ in
            self.sample(WindowCornerRadii(uniform: 9))
        }
        defer { applier.cleanup() }

        _ = applier.apply(desired(configRed), forceOrdering: false)
        let scaleQueries = recorder.backingScaleQueryCount
        recorder.backingScale = 1
        let creationCount = recorder.layerPanels.count

        applier.invalidateDisplayScale()
        _ = applier.apply(desired(configRed), forceOrdering: false)

        XCTAssertEqual(recorder.backingScaleQueryCount, scaleQueries + 1)
        XCTAssertEqual(recorder.layerPanels.first?.borderLayer.contentsScale, 1)
        XCTAssertEqual(recorder.layerPanels.count, creationCount)
    }

    @MainActor
    func testWidthChangesReshapeExistingSurfaceWithoutChangingTargetOrRadii() throws {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        defer { window.destroy() }
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let originalCorners = panel.renderedCornerRadii
        let originalBounds = panel.borderLayer.bounds
        for width: CGFloat in [8, 1] {
            window.updateConfig(BorderConfig(enabled: true, width: width, color: configRed.color))
            XCTAssertTrue(window.update(frame: frame, targetToken: target))

            XCTAssertEqual(window.targetFrameOnScreen, frame)
            XCTAssertEqual(window.frameOnScreen, frame.insetBy(dx: -width, dy: -width))
            XCTAssertEqual(panel.frame, frame.insetBy(dx: -width, dy: -width).integral)
            XCTAssertEqual(panel.borderLayer.bounds, originalBounds)
            XCTAssertEqual(panel.borderLayer.rimWidth, Double(width))
            XCTAssertEqual(panel.renderedCornerRadii, originalCorners)
            XCTAssertEqual(
                panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
                frame
            )
        }
        XCTAssertEqual(recorder.layerPanels.count, 1)
    }

    @MainActor
    func testGradientAndGlowOnlyConfigChangesRedrawWithoutResize() throws {
        let baseConfig = BorderConfig(
            enabled: true,
            width: 4,
            color: configRed.color,
            glow: BorderGlow(enabled: true, radius: 8, opacity: 0)
        )
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: baseConfig, operations: recorder.operations())
        defer { window.destroy() }
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        XCTAssertFalse(panel.gradientStrokeLayer.isHidden)
        XCTAssertTrue(panel.glowColorLayer.isHidden)
        XCTAssertEqual(panel.borderUpdateCount, 1)

        var gradientConfig = baseConfig
        gradientConfig.gradient = BorderGradient(
            enabled: true,
            start: configRed.color,
            end: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1),
            direction: .topLeftToBottomRight
        )
        window.updateConfig(gradientConfig)
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        XCTAssertFalse(panel.gradientStrokeLayer.isHidden)
        XCTAssertEqual(panel.borderUpdateCount, 2)

        var glowConfig = gradientConfig
        glowConfig.glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        window.updateConfig(glowConfig)
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        XCTAssertFalse(panel.glowColorLayer.isHidden)
        XCTAssertEqual(panel.borderUpdateCount, 3)

        var glowColorConfig = glowConfig
        glowColorConfig.glow?.color = SettingsColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        window.updateConfig(glowColorConfig)
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        XCTAssertEqual(panel.borderUpdateCount, 4)

        window.updateConfig(glowColorConfig)
        XCTAssertTrue(window.update(frame: frame, targetToken: token()))
        XCTAssertEqual(panel.borderUpdateCount, 4)
    }

    @MainActor
    func testFiveHundredSameDisplayTranslationsAvoidLevelAndScaleQueriesReshapesAndRedraws() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let queryCount = recorder.windowInfoQueryCount
        let backingScaleQueryCount = recorder.backingScaleQueryCount
        let originalCorners = recorder.layerPanels.first?.renderedCornerRadii
        let creationCount = recorder.layerPanels.count
        let orderCount = recorder.orderCalls.count
        let updateCount = recorder.layerPanels.first?.borderUpdateCount

        for offset in 1 ... 500 {
            _ = window.update(
                frame: frame.offsetBy(dx: CGFloat(offset), dy: CGFloat(offset % 20)),
                targetToken: target
            )
        }

        XCTAssertEqual(recorder.windowInfoQueryCount, queryCount)
        XCTAssertEqual(recorder.backingScaleQueryCount, backingScaleQueryCount)
        XCTAssertEqual(recorder.layerPanels.first?.renderedCornerRadii, originalCorners)
        XCTAssertEqual(recorder.layerPanels.first?.borderUpdateCount, updateCount)
        XCTAssertEqual(recorder.layerPanels.count, creationCount)
        XCTAssertEqual(recorder.orderCalls.count, orderCount)
        XCTAssertEqual(
            recorder.layerPanels.first?.frame,
            frame.offsetBy(dx: 500, dy: 0).insetBy(dx: -4, dy: -4).integral
        )
        if let panel = recorder.layerPanels.first {
            XCTAssertEqual(
                panel.borderLayer.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
                frame.offsetBy(dx: 500, dy: 0)
            )
        }
    }

    @MainActor
    func testOneHundredResizesReusePanelAndUpdateLayerGeometry() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = token(windowId: 55)

        _ = window.update(frame: frame, targetToken: target)
        let originalUpdateCount = recorder.layerPanels.first?.borderUpdateCount ?? 0
        let creationCount = recorder.layerPanels.count

        for delta in 1 ... 100 {
            _ = window.update(
                frame: CGRect(
                    origin: frame.origin,
                    size: CGSize(width: frame.width + CGFloat(delta), height: frame.height)
                ),
                targetToken: target
            )
        }

        XCTAssertEqual(recorder.layerPanels.first?.borderUpdateCount, originalUpdateCount + 100)
        XCTAssertEqual(
            recorder.layerPanels.first?.borderLayer.bounds.size,
            CGSize(width: frame.width + 100, height: frame.height)
        )
        XCTAssertEqual(recorder.layerPanels.count, creationCount)
    }

    @MainActor
    func testChangingFractionalCornerRadiiRedraws() {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        let target = CGRect(x: 0, y: 0, width: 100, height: 80)

        _ = window.update(
            frame: target,
            targetToken: token(windowId: 55),
            cornerRadii: WindowCornerRadii(uniform: 9)
        )
        let cornersAfterFirst = recorder.layerPanels.first?.renderedCornerRadii

        _ = window.update(
            frame: target,
            targetToken: token(windowId: 55),
            cornerRadii: WindowCornerRadii(topLeft: 11.5, topRight: 9, bottomLeft: 8.5, bottomRight: 7)
        )
        XCTAssertNotEqual(recorder.layerPanels.first?.renderedCornerRadii, cornersAfterFirst)
    }

    @MainActor
    func testDeinitClosesLayerPanel() throws {
        let recorder = BorderOperationsRecorder()
        var window: BorderWindow? = BorderWindow(config: configRed, operations: recorder.operations())
        XCTAssertTrue(window?.update(frame: frame, targetToken: token()) == true)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        window = nil
        XCTAssertEqual(panel.closes, 1)
    }

    @MainActor
    func testReturningFocusReusesThatWindowsCornersWithoutFallbackFrame() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredCornerProbe()
        let applier = probe.applier(recorder)
        defer { applier.cleanup() }
        for (windowId, radius) in [(77, 24.0), (78, 12.0)] {
            let requested = expectation(description: "corners requested for \(windowId)")
            probe.onRequest = { requested.fulfill() }
            _ = applier.apply(desired(configRed, token: token(windowId: windowId)), forceOrdering: false)
            await fulfillment(of: [requested], timeout: 1)
            let resolved = expectation(description: "corners resolved for \(windowId)")
            applier.onCornerSampleResolved = { resolved.fulfill() }
            probe.complete(sample(WindowCornerRadii(uniform: radius)))
            await fulfillment(of: [resolved], timeout: 1)
        }
        let unexpectedQuery = expectation(description: "unchanged windows reuse cached corners")
        unexpectedQuery.isInverted = true
        probe.onRequest = { unexpectedQuery.fulfill() }
        applier.onCornerSampleResolved = nil
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        for (windowId, radius) in [(77, 24.0), (78, 12.0), (77, 24.0)] {
            _ = applier.apply(desired(configRed, token: token(windowId: windowId)), forceOrdering: false)
            XCTAssertEqual(panel.renderedCornerRadii, WindowCornerRadii(uniform: radius))
        }
        await fulfillment(of: [unexpectedQuery], timeout: 0.05)
        XCTAssertEqual(probe.requests.count, 2)
    }

    @MainActor
    func testDeferredCornersDoNotInheritAnotherTargetsCache() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredCornerProbe()
        let applier = probe.applier(recorder)
        defer { applier.cleanup() }
        let started = expectation(description: "first target query")
        probe.onRequest = { started.fulfill() }
        _ = applier.apply(desired(configRed), forceOrdering: false)
        await fulfillment(of: [started], timeout: 1)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let fallback = panel.renderedCornerRadii
        let resolved = expectation(description: "first target cache")
        applier.onCornerSampleResolved = { resolved.fulfill() }
        probe.complete(sample(WindowCornerRadii(uniform: 20)))
        await fulfillment(of: [resolved], timeout: 1)
        _ = applier.apply(desired(configRed), forceOrdering: false)
        XCTAssertNotEqual(panel.renderedCornerRadii, fallback)
        _ = applier.apply(
            desired(configRed, token: token(windowId: 78)),
            forceOrdering: false, refreshCornerRadii: false
        )
        XCTAssertEqual(panel.renderedCornerRadii, fallback)
        XCTAssertEqual(probe.requests, [token()])
    }

    @MainActor
    func testDeferredCornersRearmExhaustedRetryAfterSettledSizeChangeOrHide() async {
        for hide in [false, true] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            for attempt in 0 ..< 2 {
                let started = expectation(description: "query")
                probe.onRequest = { started.fulfill() }
                let resolved = expectation(description: "first failure schedules retry")
                resolved.isInverted = attempt == 1
                applier.onCornerSampleResolved = { resolved.fulfill() }
                _ = applier.apply(desired(configRed), forceOrdering: false)
                await fulfillment(of: [started], timeout: 1)
                probe.complete(nil)
                await fulfillment(of: [resolved], timeout: attempt == 1 ? 0.05 : 1)
            }
            if hide { _ = applier.apply(nil, forceOrdering: false) }
            let newFrame = hide ? frame : frame.insetBy(dx: -20, dy: 0)
            let started = expectation(description: "new geometry rearms query")
            probe.onRequest = { started.fulfill() }
            _ = applier.apply(desired(configRed, frame: newFrame), forceOrdering: false)
            await fulfillment(of: [started], timeout: 1)
            let resolved = expectation(description: "new geometry accepted")
            applier.onCornerSampleResolved = { resolved.fulfill() }
            probe.complete(sample(WindowCornerRadii(uniform: 12), size: newFrame.size))
            await fulfillment(of: [resolved], timeout: 1)
            _ = applier.apply(desired(configRed, frame: newFrame), forceOrdering: false)
            XCTAssertEqual(probe.requests.count, 3)
        }
    }

    @MainActor
    func testDeferredCornersKeepMovingAndReconcileCurrentGeometry() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredCornerProbe()
        let applier = probe.applier(recorder)
        defer { applier.cleanup() }
        let started = expectation(description: "corner query started")
        probe.onRequest = { started.fulfill() }
        let resolved = expectation(description: "corners resolved")
        applier.onCornerSampleResolved = { resolved.fulfill() }
        XCTAssertTrue(applier.apply(desired(configRed), forceOrdering: false).didApply)
        await fulfillment(of: [started], timeout: 1)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let fallbackCorners = panel.renderedCornerRadii
        var latest = frame
        for offset in 1 ... 500 {
            latest = frame.offsetBy(dx: CGFloat(offset), dy: 0)
            let outcome = applier.apply(
                desired(configRed, frame: latest), forceOrdering: false, refreshCornerRadii: offset % 2 == 0
            )
            XCTAssertTrue(outcome.didApply)
        }
        XCTAssertEqual(probe.requests, [token()])
        XCTAssertEqual(panel.frame, latest.insetBy(dx: -4, dy: -4).integral)
        XCTAssertEqual(panel.renderedCornerRadii, fallbackCorners)
        probe.complete(sample(WindowCornerRadii(uniform: 20)))
        await fulfillment(of: [resolved], timeout: 1)
        _ = applier.apply(desired(configRed, frame: latest), forceOrdering: false)
        XCTAssertNotEqual(panel.renderedCornerRadii, fallbackCorners)
        XCTAssertEqual(panel.frame, latest.insetBy(dx: -4, dy: -4).integral)
        XCTAssertEqual(recorder.orderCalls.last?.targetWindowId, 77)
        XCTAssertEqual(recorder.orderCalls.last?.order, .below)
        XCTAssertEqual(probe.requests, [token()])
    }

    @MainActor
    func testDeferredCornersRejectTokenAndSizeABAAndCoalesceLatestRequest() async throws {
        for changeSize in [false, true] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            let first = expectation(description: "first query")
            probe.onRequest = { first.fulfill() }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            await fulfillment(of: [first], timeout: 1)
            let panel = try XCTUnwrap(recorder.layerPanels.first)
            _ = applier.apply(desired(
                configRed,
                token: changeSize ? token() : token(windowId: 78),
                frame: changeSize ? frame.insetBy(dx: -10, dy: 0) : frame
            ), forceOrdering: false)
            _ = applier.apply(desired(configRed), forceOrdering: false)
            let fallbackCorners = panel.renderedCornerRadii
            let newest = expectation(description: "latest query")
            probe.onRequest = { newest.fulfill() }
            var resolvedCount = 0
            applier.onCornerSampleResolved = { resolvedCount += 1 }
            probe.complete(sample(WindowCornerRadii(uniform: 30)))
            await fulfillment(of: [newest], timeout: 1)
            XCTAssertEqual(resolvedCount, 0)
            XCTAssertEqual(panel.renderedCornerRadii, fallbackCorners)
            XCTAssertEqual(probe.requests, [token(), token()])
            let resolved = expectation(description: "current sample")
            applier.onCornerSampleResolved = { resolved.fulfill() }
            probe.complete(sample(WindowCornerRadii(uniform: 15)))
            await fulfillment(of: [resolved], timeout: 1)
            _ = applier.apply(desired(configRed), forceOrdering: false)
            XCTAssertNotEqual(panel.renderedCornerRadii, fallbackCorners)
        }
    }

    @MainActor
    func testDeferredCornersLifecycleInvalidationRejectsEnteredRead() async throws {
        for invalidation in 0 ..< 3 {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            let first = expectation(description: "old lifetime")
            probe.onRequest = { first.fulfill() }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            await fulfillment(of: [first], timeout: 1)
            switch invalidation {
            case 0: _ = applier.apply(nil, forceOrdering: false)
            case 1: applier.cleanup()
            default: applier.invalidateDisplayScale()
            }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            let latest = expectation(description: "new lifetime")
            probe.onRequest = { latest.fulfill() }
            var notifications = 0
            applier.onCornerSampleResolved = { notifications += 1 }
            probe.complete(sample(WindowCornerRadii(uniform: 30)))
            await fulfillment(of: [latest], timeout: 1)
            XCTAssertEqual(notifications, 0)
            XCTAssertEqual(probe.requests, [token(), token()])
            let resolved = expectation(description: "current lifetime")
            applier.onCornerSampleResolved = { resolved.fulfill() }
            probe.complete(sample(WindowCornerRadii(uniform: 15)))
            await fulfillment(of: [resolved], timeout: 1)
            _ = applier.apply(desired(configRed), forceOrdering: false)
            XCTAssertEqual(recorder.layerPanels.count, invalidation == 1 ? 2 : 1)
        }
    }

    @MainActor
    func testDeferredCornersDoNotRestartWhileHiddenOrAnimating() async {
        for hide in [false, true] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            let first = expectation(description: "entered read")
            probe.onRequest = { first.fulfill() }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            await fulfillment(of: [first], timeout: 1)
            if hide {
                _ = applier.apply(nil, forceOrdering: false)
            } else {
                _ = applier.apply(
                    desired(configRed, frame: frame.insetBy(dx: -20, dy: 0)),
                    forceOrdering: false, refreshCornerRadii: false
                )
            }
            let unexpected = expectation(description: "no query or notification")
            unexpected.isInverted = true
            probe.onRequest = { unexpected.fulfill() }
            applier.onCornerSampleResolved = { unexpected.fulfill() }
            probe.complete(nil)
            await fulfillment(of: [unexpected], timeout: 0.05)
            XCTAssertEqual(probe.requests.count, 1)
            let settled = expectation(description: "settled query")
            probe.onRequest = { settled.fulfill() }
            _ = applier.apply(desired(configRed), forceOrdering: false)
            await fulfillment(of: [settled], timeout: 1)
            let accepted = expectation(description: "stale failure did not spend current retry")
            applier.onCornerSampleResolved = { accepted.fulfill() }
            probe.complete(nil)
            await fulfillment(of: [accepted], timeout: 1)
        }
    }

    @MainActor
    func testDeferredCornersActualFailuresExhaustOnlyOneRetry() async {
        for invalid in [
            nil,
            sample(WindowCornerRadii(uniform: 20), size: CGSize(width: 400, height: 150)),
            sample(WindowCornerRadii(uniform: 20), size: .zero)
        ] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredCornerProbe()
            let applier = probe.applier(recorder)
            defer { applier.cleanup() }
            for attempt in 0 ..< 2 {
                let started = expectation(description: "query \(attempt)")
                probe.onRequest = { started.fulfill() }
                let resolved = expectation(description: "retry only on first failure")
                resolved.isInverted = attempt == 1
                applier.onCornerSampleResolved = { resolved.fulfill() }
                _ = applier.apply(desired(configRed), forceOrdering: false)
                await fulfillment(of: [started], timeout: 1)
                for _ in 0 ..< 50 {
                    XCTAssertTrue(applier.apply(desired(configRed), forceOrdering: false).didApply)
                }
                probe.complete(invalid)
                await fulfillment(of: [resolved], timeout: attempt == 1 ? 0.05 : 1)
            }
            let unexpected = expectation(description: "exhausted budget")
            unexpected.isInverted = true
            probe.onRequest = { unexpected.fulfill() }
            _ = applier.apply(
                desired(configRed, frame: frame.insetBy(dx: -10, dy: 0)),
                forceOrdering: false, refreshCornerRadii: false
            )
            for _ in 0 ..< 50 {
                XCTAssertTrue(applier.apply(desired(configRed), forceOrdering: false).didApply)
            }
            await fulfillment(of: [unexpected], timeout: 0.05)
            XCTAssertEqual(probe.requests.count, 2)
        }
    }

    @MainActor
    func testDeferredCornersReuseCacheUntilCurrentSizeIsAccepted() async throws {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredCornerProbe()
        let applier = probe.applier(recorder)
        defer { applier.cleanup() }
        let first = expectation(description: "initial query")
        probe.onRequest = { first.fulfill() }
        _ = applier.apply(desired(configRed), forceOrdering: false)
        await fulfillment(of: [first], timeout: 1)
        let resolved = expectation(description: "initial corners")
        applier.onCornerSampleResolved = { resolved.fulfill() }
        probe.complete(sample(WindowCornerRadii(uniform: 20)))
        await fulfillment(of: [resolved], timeout: 1)
        _ = applier.apply(desired(configRed), forceOrdering: false)
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        let resized = frame.insetBy(dx: -20, dy: 0)
        _ = applier.apply(desired(configRed, frame: resized), forceOrdering: false, refreshCornerRadii: false)
        let cachedCorners = panel.renderedCornerRadii
        let refresh = expectation(description: "size refresh")
        probe.onRequest = { refresh.fulfill() }
        _ = applier.apply(desired(configRed, frame: resized), forceOrdering: false)
        await fulfillment(of: [refresh], timeout: 1)
        XCTAssertEqual(panel.renderedCornerRadii, cachedCorners)
        let retry = expectation(description: "old size rejected")
        applier.onCornerSampleResolved = { retry.fulfill() }
        probe.complete(sample(WindowCornerRadii(uniform: 30)))
        await fulfillment(of: [retry], timeout: 1)
        let retryStarted = expectation(description: "retry")
        probe.onRequest = { retryStarted.fulfill() }
        _ = applier.apply(desired(configRed, frame: resized), forceOrdering: false)
        await fulfillment(of: [retryStarted], timeout: 1)
        XCTAssertEqual(panel.renderedCornerRadii, cachedCorners)
        let accepted = expectation(description: "current size accepted")
        applier.onCornerSampleResolved = { accepted.fulfill() }
        probe.complete(sample(WindowCornerRadii(uniform: 12), size: resized.size))
        await fulfillment(of: [accepted], timeout: 1)
        _ = applier.apply(desired(configRed, frame: resized), forceOrdering: false)
        XCTAssertNotEqual(panel.renderedCornerRadii, cachedCorners)
        XCTAssertEqual(probe.requests.count, 3)
    }

    @MainActor
    func testDeferredLevelKeepsMovingAndAppliesLatestFrameWithoutAnotherQuery() async {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredLevelProbe()
        let applier = BorderSurfaceApplier(
            borderWindowOperations: probe.operations(recorder),
            cornerSampleProvider: { _ in nil }
        )
        defer { applier.cleanup() }
        let started = expectation(description: "query started")
        probe.onRequest = { started.fulfill() }
        let resolved = expectation(description: "level resolved")
        applier.onWindowLevelResolved = { resolved.fulfill() }
        _ = applier.apply(desired(configRed), forceOrdering: false)
        await fulfillment(of: [started], timeout: 1)
        var latestFrame = frame
        for offset in 1 ... 500 {
            latestFrame = frame.offsetBy(dx: CGFloat(offset), dy: 0)
            let outcome = applier.apply(desired(configRed, frame: latestFrame), forceOrdering: false)
            XCTAssertFalse(outcome.needsWindowLevelRetry)
        }
        XCTAssertEqual(probe.requests, [77])
        XCTAssertEqual(recorder.windowInfoQueryCount, 0)
        XCTAssertEqual(recorder.orderCalls.first?.level, 0)
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero))
        await fulfillment(of: [resolved], timeout: 1)
        _ = applier.apply(desired(configRed, frame: latestFrame), forceOrdering: false)
        XCTAssertEqual(recorder.orderCalls.last?.level, 8)
        XCTAssertEqual(
            recorder.layerPanels.last?.frame,
            latestFrame.insetBy(dx: -4, dy: -4).integral
        )
        _ = applier.apply(desired(configRed, frame: latestFrame), forceOrdering: false)
        XCTAssertEqual(probe.requests, [77])
    }

    @MainActor
    func testDeferredLevelRejectsAtoBtoAAndCoalescesToLatestTarget() async {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredLevelProbe()
        let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
        let first = expectation(description: "first A read")
        probe.onRequest = { first.fulfill() }
        _ = window.update(frame: frame, targetToken: token())
        await fulfillment(of: [first], timeout: 1)
        _ = window.update(frame: frame, targetToken: token(windowId: 78))
        _ = window.update(frame: frame, targetToken: token())
        let newest = expectation(description: "new A read")
        probe.onRequest = { newest.fulfill() }
        let resolved = expectation(description: "only current A accepted")
        window.onWindowLevelResolved = { resolved.fulfill() }
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 99, frame: .zero))
        await fulfillment(of: [newest], timeout: 1)
        XCTAssertFalse(window.hasDeferredLevelUpdate)
        XCTAssertEqual(window.appliedTargetLevel, 0)
        XCTAssertEqual(probe.requests, [77, 77])
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 7, frame: .zero))
        await fulfillment(of: [resolved], timeout: 1)
        _ = window.update(frame: frame, targetToken: token())
        XCTAssertEqual(window.appliedTargetLevel, 7)
        XCTAssertEqual(probe.requests.count, 2)
    }

    @MainActor
    func testDeferredLevelInvalidResultsRetryOnceWithoutFrameLoop() async {
        let invalid: [WindowServerInfo?] = [
            nil,
            WindowServerInfo(id: 78, pid: 1234, level: 8, frame: .zero),
            WindowServerInfo(id: 77, pid: 4321, level: 8, frame: .zero)
        ]
        for info in invalid {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredLevelProbe()
            let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
            for attempt in 0 ..< 2 {
                let started = expectation(description: "read \(attempt)")
                let resolved = expectation(description: "failure \(attempt)")
                probe.onRequest = { started.fulfill() }
                window.onWindowLevelResolved = { resolved.fulfill() }
                _ = window.update(frame: frame, targetToken: token())
                await fulfillment(of: [started], timeout: 1)
                let orderCount = recorder.orderCalls.count
                for offset in 1 ... 50 {
                    _ = window.update(
                        frame: frame.offsetBy(dx: CGFloat(offset), dy: 0), targetToken: token()
                    )
                    XCTAssertFalse(window.needsWindowLevelRetry)
                }
                XCTAssertEqual(recorder.orderCalls.count, orderCount)
                probe.complete(info)
                await fulfillment(of: [resolved], timeout: 1)
                XCTAssertEqual(window.needsWindowLevelRetry, attempt == 0)
            }
            _ = window.update(frame: frame, targetToken: token())
            for offset in 1 ... 50 {
                _ = window.update(frame: frame.offsetBy(dx: CGFloat(offset), dy: 0), targetToken: token())
            }
            XCTAssertFalse(window.needsWindowLevelRetry)
            XCTAssertEqual(probe.requests.count, 2)
            XCTAssertEqual(window.appliedTargetLevel, 0)
        }
    }

    @MainActor
    func testDeferredLevelHideAndDestroyRejectOldResultsBeforeSameTargetReturns() async {
        for destroy in [false, true] {
            let recorder = BorderOperationsRecorder()
            let probe = DeferredLevelProbe()
            let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
            let first = expectation(description: "old instance read")
            probe.onRequest = { first.fulfill() }
            _ = window.update(frame: frame, targetToken: token())
            await fulfillment(of: [first], timeout: 1)
            if destroy { window.destroy() } else { window.hide() }
            _ = window.update(frame: frame, targetToken: token())
            let next = expectation(description: "new lifetime read")
            probe.onRequest = { next.fulfill() }
            probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 99, frame: .zero))
            await fulfillment(of: [next], timeout: 1)
            XCTAssertFalse(window.hasDeferredLevelUpdate)
            XCTAssertEqual(window.appliedTargetLevel, 0)
            let resolved = expectation(description: "current lifetime accepted")
            window.onWindowLevelResolved = { resolved.fulfill() }
            probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero))
            await fulfillment(of: [resolved], timeout: 1)
            _ = window.update(frame: frame, targetToken: token())
            XCTAssertEqual(window.appliedTargetLevel, 8)
            XCTAssertEqual(recorder.layerPanels.count, destroy ? 2 : 1)
        }
    }

    @MainActor
    func testDeferredLevelPendingRefreshReusesOnlySameTargetCache() async {
        let recorder = BorderOperationsRecorder()
        let probe = DeferredLevelProbe()
        let window = BorderWindow(config: configRed, operations: probe.operations(recorder))
        let first = expectation(description: "first query")
        probe.onRequest = { first.fulfill() }
        _ = window.update(frame: frame, targetToken: token())
        await fulfillment(of: [first], timeout: 1)
        let resolved = expectation(description: "first level")
        window.onWindowLevelResolved = { resolved.fulfill() }
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 8, frame: .zero))
        await fulfillment(of: [resolved], timeout: 1)
        _ = window.update(frame: frame, targetToken: token())
        let refresh = expectation(description: "same target refresh")
        probe.onRequest = { refresh.fulfill() }
        window.reorder(relativeTo: token())
        XCTAssertEqual(window.appliedTargetLevel, 8)
        await fulfillment(of: [refresh], timeout: 1)
        _ = window.update(frame: frame, targetToken: token(windowId: 78))
        XCTAssertEqual(window.appliedTargetLevel, 0)
        let second = expectation(description: "new target query")
        probe.onRequest = { second.fulfill() }
        probe.complete(WindowServerInfo(id: 77, pid: 1234, level: 99, frame: .zero))
        await fulfillment(of: [second], timeout: 1)
        let secondResolved = expectation(description: "second target level")
        window.onWindowLevelResolved = { secondResolved.fulfill() }
        probe.complete(WindowServerInfo(id: 78, pid: 1234, level: 7, frame: .zero))
        await fulfillment(of: [secondResolved], timeout: 1)
        _ = window.update(frame: frame, targetToken: token(windowId: 78))
        XCTAssertEqual(window.appliedTargetLevel, 7)
        XCTAssertEqual(probe.requests, [77, 77, 78])
    }

    @MainActor
    func testNativeRimCornersNormalizeToTargetSize() throws {
        let recorder = BorderOperationsRecorder()
        let window = BorderWindow(config: configRed, operations: recorder.operations())
        defer { window.destroy() }
        XCTAssertTrue(window.update(
            frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            targetToken: token(), cornerRadii: WindowCornerRadii(uniform: 80)
        ))
        let panel = try XCTUnwrap(recorder.layerPanels.first)
        XCTAssertEqual(panel.renderedCornerRadii, WindowCornerRadii(uniform: 25))
    }
}

final class WindowCornerRadiiTests: XCTestCase {
    @MainActor
    func testParserPreservesFourFractionalValues() {
        let values = [
            NSNumber(value: 11.5),
            NSNumber(value: 12.25),
            NSNumber(value: 13.75),
            NSNumber(value: 14.5)
        ] as CFArray

        XCTAssertEqual(
            SkyLight.parseCornerRadii(values),
            WindowCornerRadii(topLeft: 11.5, topRight: 12.25, bottomLeft: 14.5, bottomRight: 13.75)
        )
    }

    @MainActor
    func testParserAcceptsUniformValueAndRejectsMalformedValues() {
        let uniform = [NSNumber(value: 11.5)] as CFArray
        let partial = [NSNumber(value: 1), NSNumber(value: 2)] as CFArray
        let excessive = [
            NSNumber(value: 1),
            NSNumber(value: 2),
            NSNumber(value: 3),
            NSNumber(value: 4),
            NSNumber(value: 5)
        ] as CFArray
        let negative = [NSNumber(value: -1)] as CFArray
        let nonfinite = [NSNumber(value: Double.nan)] as CFArray
        let nonnumber = [NSString(string: "11.5")] as CFArray

        XCTAssertEqual(SkyLight.parseCornerRadii(uniform), WindowCornerRadii(uniform: 11.5))
        XCTAssertNil(SkyLight.parseCornerRadii(partial))
        XCTAssertNil(SkyLight.parseCornerRadii(excessive))
        XCTAssertNil(SkyLight.parseCornerRadii(negative))
        XCTAssertNil(SkyLight.parseCornerRadii(nonfinite))
        XCTAssertNil(SkyLight.parseCornerRadii(nonnumber))
    }

    @MainActor
    func testCornerSampleRecordsObservedSizeAndSource() {
        let resolved = [NSNumber(value: 20)] as CFArray
        let malformedResolved = [NSNumber(value: -1)] as CFArray
        let raw = [NSNumber(value: 11.5)] as CFArray
        let observedSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(
            SkyLight.cornerSample(resolved: resolved, raw: raw, observedSize: observedSize),
            WindowCornerSample(
                radii: WindowCornerRadii(uniform: 20),
                observedSize: observedSize,
                source: .resolved
            )
        )
        XCTAssertEqual(
            SkyLight.cornerSample(resolved: malformedResolved, raw: raw, observedSize: observedSize),
            WindowCornerSample(
                radii: WindowCornerRadii(uniform: 11.5),
                observedSize: observedSize,
                source: .raw
            )
        )
    }

    @MainActor
    /// Zero radii reported by the server are an invalid (not-yet-materialized)
    /// reading: the sample must fall through to raw radii, or to nil, so a square
    /// ring is never cached while rapidly cycling focus.
    func testCornerSampleTreatsZeroRadiiAsInvalidReading() {
        let zeroResolved = [
            NSNumber(value: 0),
            NSNumber(value: 0),
            NSNumber(value: 0),
            NSNumber(value: 0)
        ] as CFArray
        let raw = [NSNumber(value: 11.5)] as CFArray
        let observedSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(
            SkyLight.cornerSample(resolved: zeroResolved, raw: raw, observedSize: observedSize),
            WindowCornerSample(
                radii: WindowCornerRadii(uniform: 11.5),
                observedSize: observedSize,
                source: .raw
            )
        )
        XCTAssertNil(
            SkyLight.cornerSample(resolved: zeroResolved, raw: nil, observedSize: observedSize)
        )
        XCTAssertNil(
            SkyLight.cornerSample(resolved: zeroResolved, raw: zeroResolved, observedSize: observedSize)
        )
    }

    @MainActor
    /// OmniWM stores a user-selected square corner as `squareStoredRadius` (0.01),
    /// so a small nonzero reading is the truth for that window and must survive the
    /// zero-sample rejection instead of falling back to the default rounded radii.
    func testCornerSampleKeepsUserSelectedSquareRadius() {
        let square = GlobalWindowCornerPreferences.squareStoredRadius
        let radii = [
            NSNumber(value: square),
            NSNumber(value: square),
            NSNumber(value: square),
            NSNumber(value: square)
        ] as CFArray
        let observedSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(
            SkyLight.cornerSample(resolved: radii, raw: nil, observedSize: observedSize),
            WindowCornerSample(
                radii: WindowCornerRadii(uniform: square),
                observedSize: observedSize,
                source: .resolved
            )
        )
    }

    @MainActor
    func testCornerSampleRejectsInvalidObservedSize() {
        let raw = [NSNumber(value: 11.5)] as CFArray

        XCTAssertNil(
            SkyLight.cornerSample(
                resolved: nil,
                raw: raw,
                observedSize: CGSize(width: 0, height: 600)
            )
        )
    }

    @MainActor
    func testDiagnosticCornerSamplesParseResolvedAndRawIndependently() {
        let resolved = [NSNumber(value: 20)] as CFArray
        let raw = [NSNumber(value: 11.5)] as CFArray
        let observedSize = CGSize(width: 800, height: 600)

        let samples = SkyLight.diagnosticCornerSamples(
            resolved: resolved,
            raw: raw,
            observedSize: observedSize
        )

        XCTAssertEqual(samples.resolved?.radii, WindowCornerRadii(uniform: 20))
        XCTAssertEqual(samples.resolved?.source, .resolved)
        XCTAssertEqual(samples.raw?.radii, WindowCornerRadii(uniform: 11.5))
        XCTAssertEqual(samples.raw?.source, .raw)
    }

    func testNormalizationPreventsOverlappingArcs() {
        let normalized = WindowCornerRadii(uniform: 80).normalized(to: CGSize(width: 100, height: 50))

        XCTAssertEqual(normalized, WindowCornerRadii(uniform: 25))
    }

    @MainActor
    func testNativeCornerABIMatchesAndRoundTripsDistinctEllipticalRadii() {
        guard omniwm_layer_border_available() else {
            XCTFail("Native corner method ABI must match before invoking it")
            return
        }
        let layer = CALayer()
        layer.cornerRadii = CACornerRadii(
            topLeft: CGSize(width: 1, height: 2),
            topRight: CGSize(width: 3, height: 4),
            bottomRight: CGSize(width: 5, height: 6),
            bottomLeft: CGSize(width: 7, height: 8)
        )
        let radii = layer.cornerRadii
        XCTAssertEqual(radii.topLeft, CGSize(width: 1, height: 2))
        XCTAssertEqual(radii.topRight, CGSize(width: 3, height: 4))
        XCTAssertEqual(radii.bottomRight, CGSize(width: 5, height: 6))
        XCTAssertEqual(radii.bottomLeft, CGSize(width: 7, height: 8))
    }

    @MainActor
    private func borderFrameFixture() throws -> (controller: WMController, entry: WindowState) {
        let controller = WindowAdmissionTestSupport.controller(prefix: "BorderSurfaceTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 813_101, windowId: 813_102)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )
        let cached = CGRect(x: 80, y: 90, width: 700, height: 500)
        controller.workspaceManager.updateFloatingGeometry(frame: cached, for: token)
        return (controller, try XCTUnwrap(controller.workspaceManager.entry(for: token)))
    }

    @MainActor
    /// Live bounds win for border placement even while an AX write is still pending,
    /// because apps apply writes late and the ring must hug what is presented.
    func testBorderFramePrefersLiveBoundsEvenWhileAXWriteIsPending() throws {
        let fixture = try borderFrameFixture()
        let pending = CGRect(x: 10, y: 20, width: 900, height: 600)
        let live = CGRect(x: 40, y: 50, width: 800, height: 500)
        let target = AXFrameApplicationTarget(
            pid: fixture.entry.pid,
            window: fixture.entry.axRef,
            frame: pending
        )
        XCTAssertNotNil(fixture.controller.axManager.stageFrameWrite(for: target))

        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in live })
        XCTAssertEqual(world.borderFrame(for: fixture.entry), live)

        fixture.controller.axManager.cancelPendingFrameJobs([
            (pid: fixture.entry.pid, windowId: fixture.entry.windowId)
        ], reason: "test")
        XCTAssertNil(fixture.controller.axManager.pendingFrameWrite(for: fixture.entry.windowId))
        XCTAssertEqual(world.borderFrame(for: fixture.entry), live)
    }

    @MainActor
    /// When live bounds cannot be queried, a pending AX write is the next best
    /// authority for the border frame.
    func testBorderFrameFallsBackToPendingAXWriteWhenLiveBoundsAreUnavailable() throws {
        let fixture = try borderFrameFixture()
        let pending = CGRect(x: 10, y: 20, width: 900, height: 600)
        let target = AXFrameApplicationTarget(
            pid: fixture.entry.pid,
            window: fixture.entry.axRef,
            frame: pending
        )
        XCTAssertNotNil(fixture.controller.axManager.stageFrameWrite(for: target))

        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in nil })
        XCTAssertEqual(world.borderFrame(for: fixture.entry), pending)
    }

    @MainActor
    /// After an AX write settles, a divergent live frame is used for the border.
    func testBorderFrameUsesDivergentLiveBoundsAfterAXWriteSettles() throws {
        let fixture = try borderFrameFixture()
        let live = CGRect(x: 40, y: 50, width: 800, height: 500)
        fixture.controller.axManager.confirmFrameWrite(
            for: fixture.entry.windowId,
            frame: CGRect(x: 10, y: 20, width: 900, height: 600)
        )

        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in live })
        XCTAssertEqual(world.borderFrame(for: fixture.entry), live)
    }

    @MainActor
    /// With no live bounds and no pending write, the cached layout frame backs up
    /// border placement.
    func testBorderFrameFallsBackToCacheWhenLiveBoundsAreUnavailable() throws {
        let fixture = try borderFrameFixture()
        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in nil })

        XCTAssertEqual(world.borderFrame(for: fixture.entry), fixture.entry.floatingState?.lastFrame)
    }

    @MainActor
    /// Animation keeps the cached frame during ticks but the completed derivation
    /// returns to live bounds.
    func testCompletedBorderDerivationReturnsToLiveBoundsAfterAnimation() throws {
        let fixture = try borderFrameFixture()
        fixture.controller.hasStartedServices = true
        fixture.controller.settings.borders.enabled = true
        XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(
            fixture.entry.token,
            in: fixture.entry.workspaceId
        ))
        let cached = try XCTUnwrap(fixture.entry.floatingState?.lastFrame)
        let live = CGRect(x: 140, y: 150, width: 800, height: 500)
        let world = WorldView(controller: fixture.controller, liveBoundsProvider: { _ in live })
        let previous = DesiredBorderSurface(
            token: fixture.entry.token,
            frame: cached,
            config: BorderConfig.from(
                settings: fixture.controller.settings,
                isDark: fixture.controller.borderUsesDarkAppearance
            )
        )

        XCTAssertEqual(SurfaceDerivation.deriveAnimationBorder(world: world, previous: previous)?.frame, cached)
        XCTAssertEqual(SurfaceDerivation.deriveBorder(world: world)?.frame, live)
    }

    @MainActor
    func testFloatingToTilingBorderFrameUsesAcceptedTiledFrameOverStaleObservedFrame() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "BorderSurfaceTests")
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let token = WindowToken(pid: 813_001, windowId: 813_002)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: token),
            pid: token.pid,
            windowId: token.windowId,
            to: workspaceId,
            mode: .floating
        )
        let floatingFrame = CGRect(x: 80, y: 90, width: 700, height: 500)
        controller.workspaceManager.updateFloatingGeometry(frame: floatingFrame, for: token)
        let floatingEntry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        XCTAssertEqual(WorldView(controller: controller).cachedBorderFrame(for: floatingEntry), floatingFrame)

        XCTAssertTrue(controller.workspaceManager.setWindowMode(.tiling, for: token))
        let tiledFrame = CGRect(x: 12, y: 18, width: 1_100, height: 760)
        controller.axManager.confirmFrameWrite(for: token.windowId, frame: tiledFrame)
        let tiledEntry = try XCTUnwrap(controller.workspaceManager.entry(for: token))

        XCTAssertEqual(tiledEntry.observedState.frame, floatingFrame)
        XCTAssertEqual(WorldView(controller: controller).cachedBorderFrame(for: tiledEntry), tiledFrame)
    }
}
