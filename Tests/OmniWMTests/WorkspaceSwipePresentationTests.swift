// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSwipePresentationTests: XCTestCase {
    func testPreparedDynamicDestinationSurvivesRefreshUntilContactEnds() throws {
        let (controller, swipe, monitor, _) = try fixture()
        let manager = controller.workspaceManager
        let dynamic = try XCTUnwrap(manager.createDynamicWorkspace(named: "99", on: monitor.id))
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        XCTAssertEqual(swipe.preparation?.previous?.id, dynamic.id)
        let refreshController = controller.layoutRefreshController
        refreshController.finishRefresh(
            .init(kind: .immediateRelayout, reason: .workspaceTransition),
            didComplete: true, generation: refreshController.layoutState.refreshGeneration
        )
        XCTAssertNotNil(manager.descriptor(for: dynamic.id))

        swipe.stopPreparing(warm: true)

        XCTAssertNil(manager.descriptor(for: dynamic.id))
    }

    func testDynamicSourceSurvivesCommittedSwipeUntilPlacementCompletes() throws {
        let (controller, swipe, monitor, configuredId) = try fixture()
        let manager = controller.workspaceManager
        let dynamic = try XCTUnwrap(manager.createDynamicWorkspace(named: "99", on: monitor.id))
        XCTAssertTrue(manager.setActiveWorkspace(dynamic.id, on: monitor.id))
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        XCTAssertEqual(swipe.flight?.destination.id, configuredId)
        XCTAssertTrue(swipe.update(cumulative: 260, timestamp: 1.11))
        XCTAssertTrue(swipe.release(timestamp: 1.4, allowFlick: true))
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, configuredId)
        XCTAssertEqual(swipe.flight?.phase, .waitingForPlacement)

        let refreshController = controller.layoutRefreshController
        let refresh = try XCTUnwrap(refreshController.layoutState.activeRefresh)
        refreshController.layoutState.activeRefreshTask?.cancel()
        refreshController.layoutState.didExecuteEffectPlan = true
        refreshController.finishRefresh(
            refresh, didComplete: true, generation: refreshController.layoutState.refreshGeneration
        )
        XCTAssertNotNil(manager.descriptor(for: dynamic.id))
        XCTAssertTrue(swipe.hasPresentation)

        swipe.didSubmitPlacement()

        XCTAssertFalse(swipe.hasPresentation)
        XCTAssertNil(manager.descriptor(for: dynamic.id))
        XCTAssertNotNil(manager.descriptor(for: configuredId))
    }

    func testSingleRecognitionFrameFlickCommitsForEitherInputSign() throws {
        for cumulative in [-180.0, 180.0] {
            let (controller, swipe, monitor, source) = try fixture()
            _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
            swipe.begin(
                axis: .horizontal, cumulative: cumulative, timestamp: 1.03,
                recognitionMovement: SwipeEvent(delta: cumulative, timestamp: 1)
            )
            let flight = try XCTUnwrap(swipe.flight)
            XCTAssertEqual(flight.progress, 0)
            XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, source)
            XCTAssertTrue(swipe.release(timestamp: 1.04, allowFlick: true))
            XCTAssertEqual(flight.motion.target, 1)
            swipe.tick(displayId: monitor.displayId, timestamp: 3)
            XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, flight.destination.id)
            swipe.didSubmitPlacement()
            XCTAssertFalse(swipe.hasPresentation)
        }
    }

    func testBothInputAxesAnimateVerticallyWithConfiguredDestinationDirection() throws {
        for axis in WorkspaceSwipeAxis.allCases {
            for inverted in [false, true] {
                for cumulative in [-20.0, 20.0] {
                    let (controller, swipe, monitor, source) = try fixture()
                    let third = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "3", createIfMissing: true))
                    controller.workspaceManager.assignWorkspaceToMonitor(third, monitorId: monitor.id)
                    controller.settings.gestures.invertDirection = inverted
                    _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
                    swipe.begin(axis: axis, cumulative: cumulative, timestamp: 1.01)
                    let flight = try XCTUnwrap(swipe.flight)
                    let next = axis == .vertical ? (inverted == (cumulative > 0)) : (inverted == (cumulative < 0))
                    let expected = next
                        ? controller.workspaceManager.nextWorkspaceInOrder(
                            on: monitor.id,
                            from: source,
                            wrapAround: true
                        )
                        : controller.workspaceManager.previousWorkspaceInOrder(
                            on: monitor.id,
                            from: source,
                            wrapAround: true
                        )
                    XCTAssertEqual(flight.destination.id, expected?.id)
                    XCTAssertTrue(swipe.update(cumulative: cumulative * 8.5, timestamp: 1.1))
                    let distance = monitor.visibleFrame.height * 1.1 / 2
                    XCTAssertEqual(flight.progress, 0.5, accuracy: 0.000001)
                    XCTAssertEqual(flight.offset(destination: false).dx, 0)
                    XCTAssertEqual(flight.offset(destination: true).dx, 0)
                    XCTAssertEqual(flight.offset(destination: false).dy, next ? distance : -distance)
                    XCTAssertEqual(flight.offset(destination: true).dy, next ? -distance : distance)
                    swipe.cancel(reason: "test-complete")
                }
            }
        }
    }

    func testPreviewTrackingKeepsWorkspaceUntilReleaseSettles() throws {
        let (controller, swipe, monitor, source) = try fixture()
        let next = try XCTUnwrap(controller.workspaceManager.nextWorkspaceInOrder(
            on: monitor.id,
            from: source,
            wrapAround: true
        ))
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1))
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        XCTAssertTrue(swipe.update(cumulative: 260, timestamp: 1.11))
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, source)
        XCTAssertTrue(swipe.release(timestamp: 1.4, allowFlick: true))
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, source)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, next.id)
        XCTAssertEqual(swipe.flight?.phase, .waitingForPlacement)
        swipe.didSubmitPlacement()
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testDisplayTickUsesMediaClockWithoutCompletingReleaseImmediately() throws {
        let mediaTime = 288343.0
        let (controller, swipe, monitor, source) = try fixture(mediaTimeProvider: { mediaTime })
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1673)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1673.01)
        swipe.update(cumulative: 260, timestamp: 1673.11)
        XCTAssertTrue(swipe.release(timestamp: 1673.4, allowFlick: true))
        let destination = try XCTUnwrap(swipe.flight).destination.id

        swipe.tick(displayId: monitor.displayId, timestamp: mediaTime + 0.01)

        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, source)
        XCTAssertEqual(swipe.flight?.phase, .settling)
        XCTAssertGreaterThan(try XCTUnwrap(swipe.flight).progress, 0.8)
        XCTAssertLessThan(try XCTUnwrap(swipe.flight).progress, 1)
        swipe.tick(displayId: monitor.displayId, timestamp: mediaTime + 1)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, destination)
        XCTAssertEqual(swipe.flight?.phase, .waitingForPlacement)
        swipe.didSubmitPlacement()
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testFailedSettlementRetainsPresentationUntilPendingRevealEnds() throws {
        let (controller, swipe, monitor, _) = try fixture()
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        let flight = try XCTUnwrap(swipe.flight)
        let token = WindowToken(pid: 764_921, windowId: 764_922)
        let axRef = AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
        let entry = WindowState(
            token: token, axRef: axRef, workspaceId: flight.destination.id, mode: .floating,
            managedReplacementMetadata: nil, ruleEffects: .none, admissionHints: .none
        )
        let targetFrame = CGRect(x: 40, y: 50, width: 600, height: 400)
        let transaction = try XCTUnwrap(controller.layoutRefreshController.beginPendingRevealTransaction(
            for: entry,
            hiddenState: HiddenState(proportionalPosition: .zero, referenceMonitorId: monitor.id, reason: .scratchpad),
            targetFrame: targetFrame,
            monitor: monitor
        ))
        let settlement = AXFrameSettlement(tokens: [token])
        flight.phase = .waitingForPlacement
        flight.settlement = settlement
        controller.axManager.workspaceFrameSettlement = settlement
        settlement.reject(.init(pid: token.pid, window: axRef, frame: targetFrame))
        settlement.seal()
        XCTAssertTrue(settlement.failed)
        XCTAssertTrue(settlement.isSettled)

        swipe.checkSettlement()

        XCTAssertTrue(swipe.hasPresentation)
        XCTAssertTrue(swipe.flight === flight)
        XCTAssertNotNil(controller.layoutRefreshController.takePendingRevealTransaction(
            for: token.windowId, matching: transaction
        ))
        swipe.checkSettlement()
        XCTAssertFalse(swipe.hasPresentation)
        XCTAssertNil(controller.axManager.workspaceFrameSettlement)
    }

    func testUnrelatedEffectPlanDoesNotSealPlacementSettlement() throws {
        let (controller, swipe, monitor, _) = try fixture()
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        swipe.update(cumulative: 260, timestamp: 1.11)
        swipe.release(timestamp: 1.4, allowFlick: true)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        let settlement = try XCTUnwrap(swipe.flight?.settlement)
        XCTAssertTrue(controller.layoutRefreshController.workspaceSwipe === swipe)
        XCTAssertFalse(settlement.sealed)

        controller.layoutRefreshController.applyEffectPlan(EffectPlan(), controller: controller)

        XCTAssertFalse(settlement.sealed)
        XCTAssertTrue(swipe.hasPresentation)
        swipe.didSubmitPlacement()
        XCTAssertTrue(settlement.sealed)
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testCancellationDoesNotSwitchWorkspace() throws {
        let (controller, swipe, monitor, source) = try fixture()
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        swipe.update(cumulative: 70, timestamp: 1.11)
        swipe.release(timestamp: 1.4, allowFlick: true)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, source)
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testTouchCatchesSettlingAtCurrentProgressAndLiftCanCancel() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, source) = try fixture(mediaTimeProvider: { mediaTime })
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        swipe.update(cumulative: 80, timestamp: 1.05)
        swipe.release(timestamp: 1.06, allowFlick: true)
        mediaTime = 1.07
        let expected = try XCTUnwrap(swipe.flight).motion.progress(at: mediaTime)
        XCTAssertTrue(swipe.prepare(monitorId: monitor.id, timestamp: 1.07))
        XCTAssertEqual(try XCTUnwrap(swipe.flight).progress, expected, accuracy: 0.000001)
        XCTAssertNil(swipe.flight?.motion.target)
        mediaTime = 1.3
        swipe.release(timestamp: 1.3, allowFlick: true)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, source)
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testPreviousWorkspaceWrapsAsOneVisualStep() throws {
        let (controller, swipe, monitor, source) = try fixture()
        let last = controller.workspaceManager.workspaces(on: monitor.id).last?.id
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: -20, timestamp: 1.01)
        let flight = try XCTUnwrap(swipe.flight)
        XCTAssertEqual(flight.destination.id, last)
        XCTAssertNotEqual(flight.destination.id, source)
        XCTAssertEqual(flight.offset(destination: true).dy, monitor.visibleFrame.height * 1.1)
        swipe.cancel(reason: "test-complete")
    }

    func testLayoutInvalidationRetiresPresentation() throws {
        let (controller, swipe, monitor, source) = try fixture()
        defer { withExtendedLifetime(controller) {} }
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        XCTAssertTrue(swipe.hasPresentation)
        swipe.handleInvalidation(workspaceId: source, domains: .layout)
        XCTAssertFalse(swipe.hasPresentation)
        XCTAssertFalse(swipe.release(timestamp: 1.2, allowFlick: true))
        swipe.tick(displayId: monitor.displayId, timestamp: 4)
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testReduceMotionDoesNotPrepare() throws {
        let (controller, swipe, monitor, _) = try fixture()
        controller.motionPolicy.systemReducesMotion = true
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1))
        XCTAssertNil(swipe.preparation)
    }

    func testPhysicalPreparationPromotesOwnerWarmupWithoutRestartingStream() async throws {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(), previewCapture: capture,
            backdrop: try makeBackdrop(), hasCaptureAccess: { true }
        )
        let (controller, swipe, monitor, source) = try fixture(previewSurface: preview)
        controller.niriLayoutHandler.enableNiriLayout()
        let pid: pid_t = 764_941
        let windowId = 764_942
        let token = controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid, windowId: windowId, to: source
        )
        controller.workspaceManager.setCachedConstraints(.unconstrained, for: token)
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = engine.addWindow(token: token, to: source, afterSelection: nil)
        controller.workspaceManager.withNiriViewportState(for: source) { $0.selectedNodeId = node.id }
        controller.axManager.confirmFrameWrite(
            for: windowId, frame: CGRect(x: 50, y: 50, width: 600, height: 500)
        )
        let preparation = try XCTUnwrap(swipe.makePreparation(monitorId: monitor.id))
        XCTAssertEqual(preparation.source.items.map(\.handle.token), [token])
        preview.warm(
            source: preparation.source.items,
            destination: (preparation.previous?.items ?? []) + (preparation.next?.items ?? []),
            monitor: monitor, workingFrame: preparation.frame
        )
        await driver.waitForStarts(1)
        XCTAssertTrue(preview.isWarming)
        let stream = driver.streams[0]

        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1))

        XCTAssertFalse(preview.isWarming)
        XCTAssertNotNil(swipe.preparation)
        XCTAssertEqual(driver.streams.count, 1)
        XCTAssertEqual(stream.stopCount, 0)
        driver.completeAllStarts()
        for _ in 0 ..< 2 {
            let frame = try makeOverviewPreviewFrame()
            let published = expectation(description: "promoted owner stream publishes")
            capture.onPreview = { _, image in if image === frame { published.fulfill() } }
            stream.output.offer(frame)
            await fulfillment(of: [published], timeout: 1)
            XCTAssertTrue(capture.preview(for: stream.request.handle) === frame)
            XCTAssertEqual(stream.stopCount, 0)
        }
        XCTAssertEqual(driver.streams.count, 1)
        XCTAssertFalse(preview.isVisible)
        swipe.stopPreparing()
        await driver.waitForStops(1)
    }

    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
    }

    private func fixture(
        previewSurface: WorkspaceSwipePreview? = nil,
        mediaTimeProvider: @escaping () -> TimeInterval = { 1.4 }
    ) throws -> (WMController, WorkspaceSwipePresentation, Monitor, WorkspaceDescriptor.ID) {
        let controller = WMController(settings: makeSettings(), windowFocusOperations: WindowFocusOperations(
            activateApp: { _ in }, focusSpecificWindow: { _, _, _ in }, raiseWindow: { _ in }
        ))
        controller.motionPolicy.animationsEnabled = true
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let monitor = makeMonitor(1, x: 0, y: 0)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let source = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.workspaceId(for: "2", createIfMissing: true)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(source, on: monitor.id))
        let preview = try previewSurface ?? WorkspaceSwipePreview(
            ownedWindowRegistry: controller.ownedWindowRegistry,
            backdrop: makeBackdrop(), hasCaptureAccess: { true }
        )
        let swipe = WorkspaceSwipePresentation(
            refreshController: controller.layoutRefreshController,
            previewSurface: preview, mediaTimeProvider: mediaTimeProvider
        )
        controller.layoutRefreshController.workspaceSwipe = swipe
        return (controller, swipe, monitor, source)
    }

    private func makeMonitor(_ id: UInt32, x: CGFloat, y: CGFloat) -> Monitor {
        let frame = CGRect(x: x, y: y, width: 1600, height: 900)
        return Monitor(
            id: .init(displayId: id),
            displayId: id,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Swipe test"
        )
    }

    private func makeBackdrop() throws -> WorkspaceSwipeBackdrop {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 1600 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        let image = try XCTUnwrap(context.makeImage())
        let wallpaper = OverviewWallpaperCache()
        wallpaper.desktopImageURL = { _ in nil }
        wallpaper.captureWallpaper = { _ in image }
        return WorkspaceSwipeBackdrop(wallpaperCache: wallpaper)
    }
}
