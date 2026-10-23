// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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

    func testAnimationFollowsInputAxisWithConfiguredDestinationDirection() throws {
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
                    XCTAssertEqual(flight.progress, 0.5, accuracy: 0.000001)
                    let sourceOffset = flight.offset(destination: false)
                    let destinationOffset = flight.offset(destination: true)
                    switch axis {
                    case .horizontal:
                        let distance = monitor.visibleFrame.width * 1.1 / 2
                        XCTAssertEqual(sourceOffset.dy, 0)
                        XCTAssertEqual(destinationOffset.dy, 0)
                        XCTAssertEqual(sourceOffset.dx, next ? -distance : distance)
                        XCTAssertEqual(destinationOffset.dx, next ? distance : -distance)
                    case .vertical:
                        let distance = monitor.visibleFrame.height * 1.1 / 2
                        XCTAssertEqual(sourceOffset.dx, 0)
                        XCTAssertEqual(destinationOffset.dx, 0)
                        XCTAssertEqual(sourceOffset.dy, next ? distance : -distance)
                        XCTAssertEqual(destinationOffset.dy, next ? -distance : distance)
                    }
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
        controller.axManager.workspaceFrameSettlements = [settlement]
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
        XCTAssertTrue(controller.axManager.workspaceFrameSettlements.isEmpty)
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

    func testTouchCatchesCancellingSettleAtCurrentProgress() throws {
        var mediaTime = 1.3
        let (controller, swipe, monitor, source) = try fixture(mediaTimeProvider: { mediaTime })
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        swipe.update(cumulative: 80, timestamp: 1.05)
        swipe.release(timestamp: 1.3, allowFlick: true)
        XCTAssertEqual(swipe.flight?.motion.target, 0)
        mediaTime = 1.31
        let expected = try XCTUnwrap(swipe.flight).motion.progress(at: mediaTime)
        XCTAssertTrue(swipe.prepare(monitorId: monitor.id, timestamp: 1.31))
        XCTAssertEqual(try XCTUnwrap(swipe.flight).progress, expected, accuracy: 0.000001)
        XCTAssertNil(swipe.flight?.motion.target)
        mediaTime = 1.6
        swipe.release(timestamp: 1.6, allowFlick: true)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, source)
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testOnePastSwipeCreatesItsDestinationOnlyOnceRecognized() throws {
        let (controller, swipe, monitor, _) = try fixture()
        let manager = controller.workspaceManager
        controller.settings.workspaces.configurations = ["1", "2"].map { WorkspaceConfiguration(name: $0) }
        manager.applySettings()
        let last = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        _ = WindowAdmissionTestSupport.track(
            WindowToken(pid: 982_001, windowId: 982_002), in: last, controller: controller
        )
        XCTAssertTrue(manager.setActiveWorkspace(last, on: monitor.id))
        controller.settings.gestures.workspaceSwipeEdgeBehavior = .onePast

        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        XCTAssertNil(swipe.preparation?.next)
        XCTAssertNil(manager.workspaceId(named: "3"))

        swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.01)

        let created = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertEqual(try XCTUnwrap(swipe.flight).destination.id, created)
        swipe.cancel(reason: "test-complete")
    }

    func testTouchDuringCommittingSettleLeavesTheSwitchRunning() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, _) = try fixture(mediaTimeProvider: { mediaTime })
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        swipe.update(cumulative: 80, timestamp: 1.05)
        swipe.release(timestamp: 1.06, allowFlick: true)
        let destination = try XCTUnwrap(swipe.flight).destination.id
        mediaTime = 1.07
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1.07))
        XCTAssertNil(swipe.flight)
        XCTAssertEqual(swipe.flights[monitor.id]?.motion.target, 1)
        swipe.stopPreparing(warm: true)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, destination)
    }

    func testSwipeDuringCommittingSettleChainsFromTheDestination() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, _) = try fixture(mediaTimeProvider: { mediaTime })
        let manager = controller.workspaceManager
        let third = try XCTUnwrap(manager.workspaceId(for: "3", createIfMissing: true))
        manager.assignWorkspaceToMonitor(third, monitorId: monitor.id)
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.01)
        swipe.update(cumulative: -80, timestamp: 1.05)
        swipe.release(timestamp: 1.06, allowFlick: true)
        let first = try XCTUnwrap(swipe.flight)
        XCTAssertEqual(first.motion.target, 1)
        mediaTime = 1.1
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1.1))
        let residual = try XCTUnwrap(first.residual(at: mediaTime))
        XCTAssertGreaterThan(residual.dx, 0)

        swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.12)

        let second = try XCTUnwrap(swipe.flight)
        XCTAssertFalse(second === first)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, first.destination.id)
        XCTAssertEqual(second.preparation.source.id, first.destination.id)
        XCTAssertEqual(
            second.destination.id,
            manager.nextWorkspaceInOrder(on: monitor.id, from: first.destination.id, wrapAround: true)?.id
        )
        XCTAssertEqual(second.offset(destination: false).dx, residual.dx, accuracy: 0.000001)
        XCTAssertTrue(swipe.hasDisplayWork(monitor.displayId))

        XCTAssertTrue(swipe.update(cumulative: -260, timestamp: 1.2))
        mediaTime = 1.4
        XCTAssertTrue(swipe.release(timestamp: 1.4, allowFlick: true))
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, second.destination.id)
        XCTAssertEqual(second.carried, .zero)
        swipe.didSubmitPlacement()
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testSwipeOnAnotherMonitorRunsAlongsideTheSettlingSwitch() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, other, source, otherSource) = try twoMonitorFixture { mediaTime }
        let manager = controller.workspaceManager
        let first = try settleForwardSwipe(swipe, on: monitor)
        mediaTime = 1.1

        XCTAssertFalse(swipe.prepare(monitorId: other.id, timestamp: 1.1))
        XCTAssertTrue(manager.setInteractionMonitor(other.id))
        swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.12)

        let second = try XCTUnwrap(swipe.flight)
        XCTAssertTrue(swipe.flights[monitor.id] === first)
        XCTAssertTrue(swipe.flights[other.id] === second)
        XCTAssertEqual(second.preparation.source.id, otherSource)
        XCTAssertEqual(second.carried, .zero)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, source)

        swipe.tick(displayId: monitor.displayId, timestamp: 3)

        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, first.destination.id)
        XCTAssertEqual(first.phase, .waitingForPlacement)
        XCTAssertEqual(manager.interactionMonitorId, other.id)
        XCTAssertEqual(manager.activeWorkspace(on: other.id)?.id, otherSource)
        XCTAssertNil(second.motion.target)

        XCTAssertTrue(swipe.update(cumulative: -260, timestamp: 1.2))
        mediaTime = 1.4
        XCTAssertTrue(swipe.release(timestamp: 1.4, allowFlick: true))
        swipe.tick(displayId: other.displayId, timestamp: 3)
        XCTAssertEqual(manager.activeWorkspace(on: other.id)?.id, second.destination.id)
        XCTAssertEqual(manager.interactionMonitorId, other.id)
        swipe.cancelAll(reason: "test-complete")
        XCTAssertFalse(swipe.hasPresentation)
    }

    func testCancelledNewerSwipeTakesTheFocusTheBackgroundSwitchSkipped() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, other, _, otherSource) = try twoMonitorFixture { mediaTime }
        let manager = controller.workspaceManager
        let first = try settleForwardSwipe(swipe, on: monitor)
        mediaTime = 1.1
        XCTAssertFalse(swipe.prepare(monitorId: other.id, timestamp: 1.1))
        swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.12)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, first.destination.id)
        XCTAssertEqual(manager.interactionMonitorId, monitor.id)

        swipe.update(cumulative: -30, timestamp: 1.5)
        mediaTime = 2
        XCTAssertTrue(swipe.release(timestamp: 2, allowFlick: true))
        XCTAssertEqual(swipe.flight?.motion.target, 0)
        swipe.tick(displayId: other.displayId, timestamp: 4)

        XCTAssertEqual(manager.activeWorkspace(on: other.id)?.id, otherSource)
        XCTAssertNil(swipe.flights[other.id])
        XCTAssertEqual(manager.interactionMonitorId, other.id)
        swipe.cancelAll(reason: "test-complete")
    }

    func testInstantSwitchOnAnotherDisplayKeepsFocusFromTheSettlingSwitch() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, other, _, otherSource) = try twoMonitorFixture { mediaTime }
        let manager = controller.workspaceManager
        let first = try settleForwardSwipe(swipe, on: monitor)
        mediaTime = 1.1

        controller.workspaceNavigationHandler.switchWorkspaceBySwipe(isNext: true, monitorId: other.id)

        XCTAssertNotEqual(manager.activeWorkspace(on: other.id)?.id, otherSource)
        XCTAssertEqual(manager.interactionMonitorId, other.id)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, first.destination.id)
        XCTAssertEqual(manager.interactionMonitorId, other.id)
        swipe.cancelAll(reason: "test-complete")
    }

    func testSettlingSwitchStillTakesFocusWhenNothingNewerSwitched() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, other, _, _) = try twoMonitorFixture { mediaTime }
        let manager = controller.workspaceManager
        let first = try settleForwardSwipe(swipe, on: monitor)
        mediaTime = 1.1
        XCTAssertTrue(manager.setInteractionMonitor(other.id))

        swipe.tick(displayId: monitor.displayId, timestamp: 3)

        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, first.destination.id)
        XCTAssertEqual(manager.interactionMonitorId, monitor.id)
        swipe.cancelAll(reason: "test-complete")
    }

    private func settleForwardSwipe(
        _ swipe: WorkspaceSwipePresentation, on monitor: Monitor
    ) throws -> WorkspaceSwipePresentation.Flight {
        _ = swipe.prepare(monitorId: monitor.id, timestamp: 1)
        swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.01)
        swipe.update(cumulative: -80, timestamp: 1.05)
        swipe.release(timestamp: 1.06, allowFlick: true)
        let flight = try XCTUnwrap(swipe.flight)
        XCTAssertEqual(flight.motion.target, 1)
        return flight
    }

    private func twoMonitorFixture(
        mediaTimeProvider: @escaping () -> TimeInterval
    ) throws -> (
        WMController, WorkspaceSwipePresentation, Monitor, Monitor, WorkspaceDescriptor.ID, WorkspaceDescriptor.ID
    ) {
        let (controller, swipe, monitor, source) = try fixture(mediaTimeProvider: mediaTimeProvider)
        let manager = controller.workspaceManager
        let other = makeMonitor(2, x: 1600, y: 0)
        controller.settings.workspaces.configurations = ["1", "2", "3", "4"].map {
            WorkspaceConfiguration(
                name: $0,
                monitorAssignment: .specificDisplay(OutputId(from: Int($0)! <= 2 ? monitor : other))
            )
        }
        manager.applyMonitorConfigurationChange([monitor, other])
        manager.applySettings()
        let otherSource = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertTrue(manager.setActiveWorkspace(otherSource, on: other.id))
        XCTAssertTrue(manager.setActiveWorkspace(source, on: monitor.id))
        return (controller, swipe, monitor, other, source, otherSource)
    }

    func testRefusedChainDetachesTheGestureAndLetsTheFirstSwitchFinish() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, _) = try fixture(mediaTimeProvider: { mediaTime })
        let manager = controller.workspaceManager
        controller.settings.workspaces.configurations = ["1", "2"].map { WorkspaceConfiguration(name: $0) }
        controller.settings.workspaceBar.hideEmptyWorkspaces = true
        manager.applySettings()
        let empty = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let occupied = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        _ = WindowAdmissionTestSupport.track(
            WindowToken(pid: 983_001, windowId: 983_002), in: occupied, controller: controller
        )
        XCTAssertTrue(manager.setActiveWorkspace(empty, on: monitor.id))
        let first = try settleForwardSwipe(swipe, on: monitor)
        XCTAssertEqual(first.destination.id, occupied)
        mediaTime = 1.1
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1.1))

        XCTAssertTrue(swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.12))

        XCTAssertNil(swipe.flight)
        XCTAssertFalse(swipe.release(timestamp: 1.15, allowFlick: true))
        XCTAssertTrue(swipe.flights[monitor.id] === first)
        XCTAssertEqual(first.motion.target, 1)
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, occupied)
        XCTAssertEqual(first.phase, .waitingForPlacement)
        swipe.cancelAll(reason: "test-complete")
    }

    func testChainPastANoneEdgeDetachesAndKeepsTheFirstSwitch() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, ids) = try edgeFixture(.none, active: "1") { mediaTime }
        let first = try settleForwardSwipe(swipe, on: monitor)
        XCTAssertEqual(first.destination.id, ids["2"])
        mediaTime = 1.1
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1.1))

        XCTAssertTrue(swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.12))

        XCTAssertNil(swipe.flight)
        XCTAssertFalse(swipe.release(timestamp: 1.15, allowFlick: true))
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(controller.workspaceManager.activeWorkspace(on: monitor.id)?.id, ids["2"])
        swipe.cancelAll(reason: "test-complete")
    }

    func testChainFromOnePastsCreatedWorkspaceDetachesAndKeepsTheFirstSwitch() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, _) = try edgeFixture(.onePast, active: "2") { mediaTime }
        let manager = controller.workspaceManager
        let first = try settleForwardSwipe(swipe, on: monitor)
        let created = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertEqual(first.destination.id, created)
        mediaTime = 1.1
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1.1))

        XCTAssertTrue(swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.12))

        XCTAssertNil(swipe.flight)
        XCTAssertNil(manager.workspaceId(named: "4"))
        XCTAssertFalse(swipe.release(timestamp: 1.15, allowFlick: true))
        swipe.tick(displayId: monitor.displayId, timestamp: 3)
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, created)
        swipe.cancelAll(reason: "test-complete")
    }

    func testChainIntoOnePastsCreatedWorkspaceAnimatesFromTheLastOccupied() throws {
        var mediaTime = 1.06
        let (controller, swipe, monitor, ids) = try edgeFixture(.onePast, active: "1") { mediaTime }
        let manager = controller.workspaceManager
        let first = try settleForwardSwipe(swipe, on: monitor)
        XCTAssertEqual(first.destination.id, ids["2"])
        mediaTime = 1.1
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1.1))

        XCTAssertTrue(swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.12))

        let second = try XCTUnwrap(swipe.flight)
        let created = try XCTUnwrap(manager.workspaceId(named: "3"))
        XCTAssertEqual(manager.activeWorkspace(on: monitor.id)?.id, ids["2"])
        XCTAssertEqual(second.preparation.source.id, ids["2"])
        XCTAssertEqual(second.destination.id, created)
        swipe.cancelAll(reason: "test-complete")
    }

    private func edgeFixture(
        _ behavior: WorkspaceSwipeEdgeBehavior,
        active: String,
        mediaTimeProvider: @escaping () -> TimeInterval
    ) throws -> (WMController, WorkspaceSwipePresentation, Monitor, [String: WorkspaceDescriptor.ID]) {
        let (controller, swipe, monitor, _) = try fixture(mediaTimeProvider: mediaTimeProvider)
        let manager = controller.workspaceManager
        controller.settings.workspaces.configurations = ["1", "2"].map { WorkspaceConfiguration(name: $0) }
        controller.settings.gestures.workspaceSwipeEdgeBehavior = behavior
        manager.applySettings()
        var ids: [String: WorkspaceDescriptor.ID] = [:]
        for (index, name) in ["1", "2"].enumerated() {
            let id = try XCTUnwrap(manager.workspaceId(for: name, createIfMissing: true))
            ids[name] = id
            _ = WindowAdmissionTestSupport.track(
                WindowToken(pid: 984_001, windowId: 984_100 + index), in: id, controller: controller
            )
        }
        XCTAssertTrue(manager.setActiveWorkspace(try XCTUnwrap(ids[active]), on: monitor.id))
        return (controller, swipe, monitor, ids)
    }

    func testChainKeepsTheOverlayAndWallpaperWithoutRecapturing() throws {
        var captures = 0
        let image = try makeWallpaperImage()
        let wallpaper = OverviewWallpaperCache()
        wallpaper.desktopImageURL = { _ in nil }
        wallpaper.captureWallpaper = { _ in
            captures += 1
            return image
        }
        let preview = WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(),
            backdrop: WorkspaceSwipeBackdrop(wallpaperCache: wallpaper),
            hasCaptureAccess: { true }
        )
        let overlayCloses = OverlayCloseCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { note in
            if let window = note.object as? NSWindow,
               String(describing: type(of: window)).contains("WorkspaceSwipePreviewPanel")
            {
                overlayCloses.increment()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var mediaTime = 1.06
        let (controller, swipe, monitor, _) = try fixture(previewSurface: preview, mediaTimeProvider: { mediaTime })
        let third = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "3", createIfMissing: true))
        controller.workspaceManager.assignWorkspaceToMonitor(third, monitorId: monitor.id)
        _ = try settleForwardSwipe(swipe, on: monitor)
        XCTAssertTrue(preview.isVisible)
        let capturesBeforeChain = captures
        mediaTime = 1.1
        XCTAssertFalse(swipe.prepare(monitorId: monitor.id, timestamp: 1.1))

        XCTAssertTrue(swipe.begin(axis: .horizontal, cumulative: -20, timestamp: 1.12))

        XCTAssertNotNil(swipe.flight)
        XCTAssertTrue(preview.isVisible)
        XCTAssertEqual(captures, capturesBeforeChain, "chaining re-captured the wallpaper on the main thread")
        XCTAssertEqual(overlayCloses.value, 0, "chaining closed the overlay window and opened a new one")
        swipe.cancelAll(reason: "test-complete")
    }

    private func makeWallpaperImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 1600 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        return try XCTUnwrap(context.makeImage())
    }

    func testOverlayReplaceRefusesUncapturedWindowsAndKeepsItsWindow() async throws {
        let fixture = try previewFixture()
        let preview = fixture.preview
        let monitor = fixture.monitor
        let item = WorkspaceSwipePreview.Item(
            handle: fixture.handle,
            frame: CGRect(x: 50, y: 50, width: 600, height: 500)
        )
        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))

        XCTAssertFalse(preview.replace(source: [], destination: [item], monitor: monitor))

        XCTAssertTrue(preview.isVisible)
        preview.stop()
        try await cachePreviewThroughContact(fixture)
        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))

        XCTAssertTrue(preview.replace(source: [], destination: [item], monitor: monitor))

        XCTAssertTrue(preview.isVisible)
    }

    func testOverlayPrefetchCapturesUpcomingWindowsSoAChainCanUseThem() async throws {
        let fixture = try previewFixture()
        let preview = fixture.preview
        let monitor = fixture.monitor
        let item = WorkspaceSwipePreview.Item(
            handle: fixture.handle,
            frame: CGRect(x: 50, y: 50, width: 600, height: 500)
        )
        XCTAssertTrue(preview.begin(source: [], destination: [], monitor: monitor))
        XCTAssertFalse(preview.replace(source: [], destination: [item], monitor: monitor))

        preview.prefetch(shown: [], upcoming: [item], monitor: monitor)

        XCTAssertTrue(preview.isWarming)
        try await fixture.driver.waitForStarts(1)
        fixture.driver.completeAllStarts()
        try await publish(try makeOverviewPreviewFrame(), through: fixture.driver.streams[0], into: fixture.capture)
        try await fixture.driver.waitForStops(1)
        XCTAssertNotNil(fixture.capture.preview(for: fixture.handle))
        XCTAssertTrue(preview.isVisible)
        XCTAssertTrue(preview.replace(source: [], destination: [item], monitor: monitor))
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

    func testContactCapturesOnlyMissingPreviewsUntilTheirFirstFrame() async throws {
        let fixture = try previewFixture()

        XCTAssertFalse(fixture.swipe.prepare(monitorId: fixture.monitor.id, timestamp: 1))

        XCTAssertNotNil(fixture.swipe.preparation)
        try requireContactWarmup(fixture)
        try await fixture.driver.waitForStarts(1)
        fixture.driver.completeAllStarts()
        try await publish(try makeOverviewPreviewFrame(), through: fixture.driver.streams[0], into: fixture.capture)
        try await fixture.driver.waitForStops(1)
        XCTAssertFalse(fixture.preview.isWarming)
        XCTAssertNotNil(fixture.capture.preview(for: fixture.handle))
        XCTAssertEqual(fixture.driver.streams.count, 1)
        fixture.swipe.stopPreparing()
    }

    func testContactWithCachedPreviewsStartsNoCapture() async throws {
        let fixture = try previewFixture()
        try await cachePreviewThroughContact(fixture)

        XCTAssertFalse(fixture.swipe.prepare(monitorId: fixture.monitor.id, timestamp: 2))

        XCTAssertFalse(fixture.preview.isWarming)
        XCTAssertNotNil(fixture.swipe.preparation)
        XCTAssertEqual(fixture.driver.streams.count, 1)
        fixture.swipe.stopPreparing()
    }

    func testRecognitionStreamsOnlyTheSourceAndDestination() async throws {
        let fixture = try previewFixture()
        try await cachePreviewThroughContact(fixture)
        XCTAssertFalse(fixture.swipe.prepare(monitorId: fixture.monitor.id, timestamp: 2))
        XCTAssertEqual(fixture.driver.streams.count, 1)

        fixture.swipe.begin(axis: .vertical, cumulative: 20, timestamp: 2.01)

        XCTAssertTrue(fixture.swipe.hasPresentation)
        _ = try XCTUnwrap(
            fixture.capture.hasPendingFirstFrames ? fixture.capture : nil,
            "Recognition must start continuous capture for the swipe"
        )
        try await fixture.driver.waitForStarts(2)
        XCTAssertFalse(fixture.preview.isWarming)
        let stream = fixture.driver.streams[1]
        XCTAssertTrue(stream.request.handle === fixture.handle)
        fixture.driver.completeAllStarts()
        for _ in 0 ..< 2 {
            let frame = try makeOverviewPreviewFrame()
            try await publish(frame, through: stream, into: fixture.capture)
            XCTAssertTrue(fixture.capture.preview(for: fixture.handle) === frame)
            XCTAssertEqual(stream.stopCount, 0)
        }
        XCTAssertEqual(fixture.driver.streams.count, 2)
        fixture.swipe.cancel(reason: "test")
        XCTAssertEqual(stream.stopCount, 1)
    }

    func testCommittedSwipeKeepsOverlayUntilWindowServerParksTheSourceWindow() async throws {
        let fixture = try previewFixture()
        defer { fixture.swipe.cancel(reason: "test") }
        try await cachePreviewThroughContact(fixture)
        let sleeper = ManualSleeper()
        var parked = false
        var reads = 0
        fixture.swipe.handoffSleep = { try await sleeper.sleep(for: $0) }
        fixture.swipe.handoffWindowInfo = { ids in
            reads += 1
            return Dictionary(uniqueKeysWithValues: ids.map {
                ($0, Self.windowInfo(id: $0, appKitFrame: parked ? Self.parkedFrame : Self.sourceFrame))
            })
        }
        commitSwipe(fixture)

        fixture.swipe.didSubmitPlacement()
        let handoff = try XCTUnwrap(fixture.swipe.flight?.handoff)
        let firstReadback = try XCTUnwrap(handoff.readback)
        await firstReadback.value

        XCTAssertEqual(reads, 1)
        XCTAssertTrue(fixture.swipe.hasPresentation)
        parked = true
        fixture.swipe.windowFrameChanged(764_942)
        let confirmedReadback = try XCTUnwrap(handoff.readback)
        await confirmedReadback.value
        XCTAssertFalse(fixture.swipe.hasPresentation)
        XCTAssertEqual(reads, 2)
    }

    func testHandoffDeadlineRemovesTheOverlayWithoutConfirmation() async throws {
        let fixture = try previewFixture()
        defer { fixture.swipe.cancel(reason: "test") }
        try await cachePreviewThroughContact(fixture)
        let sleeper = ManualSleeper()
        let waiting = expectation(description: "Handoff deadline entered the controlled sleep")
        var reads = 0
        fixture.swipe.handoffSleep = {
            waiting.fulfill()
            try await sleeper.sleep(for: $0)
        }
        fixture.swipe.handoffWindowInfo = { ids in
            reads += 1
            return Dictionary(uniqueKeysWithValues: ids.map {
                ($0, Self.windowInfo(id: $0, appKitFrame: Self.sourceFrame))
            })
        }
        commitSwipe(fixture)

        fixture.swipe.didSubmitPlacement()
        let handoff = try XCTUnwrap(fixture.swipe.flight?.handoff)
        let readback = try XCTUnwrap(handoff.readback)
        let deadline = try XCTUnwrap(handoff.deadline)
        await readback.value
        await fulfillment(of: [waiting], timeout: 2)
        guard sleeper.pendingCount == 1 else {
            XCTFail("Handoff deadline did not enter the controlled sleep")
            return
        }

        XCTAssertEqual(reads, 1)
        XCTAssertTrue(fixture.swipe.hasPresentation)
        sleeper.resumeNext()
        await deadline.value
        XCTAssertFalse(fixture.swipe.hasPresentation)
    }

    func testHandoffDoesNotWaitForSourceWindowsAlreadyParkedAtTheDisplayEdge() {
        let monitor = makeMonitor(1, x: 0, y: 0)
        let visible = WorkspaceSwipePreview.Item(
            handle: WindowHandle(id: WindowToken(pid: 764_961, windowId: 11)), frame: Self.sourceFrame
        )
        let edgeSliver = CGRect(x: monitor.visibleFrame.maxX - 1, y: 50, width: 600, height: 500)
        let parked = WorkspaceSwipePreview.Item(
            handle: WindowHandle(id: WindowToken(pid: 764_961, windowId: 12)), frame: edgeSliver
        )
        let destination = WorkspaceSwipePresentation.Workspace(id: UUID(), items: [])
        let flight = WorkspaceSwipePresentation.Flight(
            preparation: WorkspaceSwipePresentation.Preparation(
                monitor: monitor, frame: monitor.visibleFrame,
                source: WorkspaceSwipePresentation.Workspace(id: UUID(), items: [visible, parked]),
                previous: destination, next: destination
            ),
            destination: destination, axis: .vertical, cumulative: 20, isNext: true, timestamp: 1,
            recognitionMovement: nil
        )
        let handoff = WorkspaceSwipePresentation.Handoff(flight: flight)

        XCTAssertEqual(handoff.windowIds, [11])
        XCTAssertFalse(handoff.shortfalls(in: [
            11: Self.windowInfo(id: 11, appKitFrame: Self.sourceFrame),
            12: Self.windowInfo(id: 12, appKitFrame: edgeSliver)
        ]).isEmpty)
        XCTAssertTrue(handoff.shortfalls(in: [
            11: Self.windowInfo(id: 11, appKitFrame: Self.parkedFrame),
            12: Self.windowInfo(id: 12, appKitFrame: edgeSliver)
        ]).isEmpty)
    }

    func testHandoffWithoutWindowServerAccessRemovesTheOverlayAtSettlement() async throws {
        let fixture = try previewFixture()
        defer { fixture.swipe.cancel(reason: "test") }
        try await cachePreviewThroughContact(fixture)
        let sleeper = ManualSleeper()
        fixture.swipe.handoffSleep = { try await sleeper.sleep(for: $0) }
        fixture.swipe.handoffWindowInfo = { _ in nil }
        commitSwipe(fixture)

        fixture.swipe.didSubmitPlacement()
        let readback = try XCTUnwrap(fixture.swipe.flight?.handoff?.readback)
        await readback.value
        XCTAssertFalse(fixture.swipe.hasPresentation)
    }

    func testTurningSwipeOrAnimationsOffReleasesThePreviewAndItsCache() async throws {
        let disablers: [@MainActor (WMController) -> Void] = [
            { $0.settings.gestures.workspaceSwipeEnabled = false },
            { $0.setAnimationsEnabled(false) },
            { $0.motionPolicy.systemReducesMotion = true }
        ]
        for disable in disablers {
            let driver = OverviewPreviewTestDriver()
            let capture = driver.makeCapture(consumer: .workspaceSwipe)
            let preview = try WorkspaceSwipePreview(
                ownedWindowRegistry: OwnedWindowRegistry(), previewCapture: capture,
                backdrop: makeBackdrop(), hasCaptureAccess: { true }
            )
            let (controller, swipe, monitor, _) = try fixture(previewSurface: preview)
            defer {
                swipe.cancel(reason: "test")
                preview.stop()
                capture.clear()
                driver.finish()
            }
            controller.settings.gestures.workspaceSwipeEnabled = true
            let handle = WindowHandle(id: WindowToken(pid: 764_951, windowId: 1))
            capture.reconcile(
                represented: [handle],
                visible: [OverviewPreviewRequest(handle: handle, pixelWidth: 80, pixelHeight: 60)]
            )
            try await driver.waitForStarts(1)
            driver.completeAllStarts()
            let frame = try makeOverviewPreviewFrame()
            let published = expectation(description: "swipe frame published")
            capture.onPreview = { _, image in if image === frame { published.fulfill() } }
            driver.streams[0].output.offer(frame)
            guard await XCTWaiter.fulfillment(of: [published], timeout: 1) == .completed else {
                XCTFail("Expected preview publication")
                throw OverviewPreviewTestWaitError.publication
            }
            capture.clear()
            try await driver.waitForStops(1)
            XCTAssertGreaterThan(capture.cachedByteCount, 0)

            disable(controller)

            XCTAssertEqual(capture.cachedByteCount, 0)
            XCTAssertFalse(swipe.previewSurface(controller, for: monitor.id) === preview)
        }
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
        let backdrop = try makeBackdrop()
        let swipe = WorkspaceSwipePresentation(
            refreshController: controller.layoutRefreshController,
            previewSurface: preview,
            previewFactory: { controller in
                WorkspaceSwipePreview(
                    ownedWindowRegistry: controller.ownedWindowRegistry, backdrop: backdrop, hasCaptureAccess: { true }
                )
            },
            mediaTimeProvider: mediaTimeProvider
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

    private static let sourceFrame = CGRect(x: 50, y: 50, width: 600, height: 500)
    private static let parkedFrame = CGRect(x: 100_000, y: 100_000, width: 600, height: 500)

    private static func windowInfo(id: UInt32, appKitFrame: CGRect) -> WindowServerInfo {
        WindowServerInfo(id: id, pid: 764_941, level: 0, frame: ScreenCoordinateSpace.toWindowServer(rect: appKitFrame))
    }

    private func commitSwipe(_ fixture: PreviewFixture) {
        XCTAssertFalse(fixture.swipe.prepare(monitorId: fixture.monitor.id, timestamp: 1))
        fixture.swipe.begin(axis: .vertical, cumulative: 20, timestamp: 1.01)
        XCTAssertTrue(fixture.swipe.update(cumulative: 260, timestamp: 1.11))
        XCTAssertTrue(fixture.swipe.release(timestamp: 1.4, allowFlick: true))
        fixture.swipe.tick(displayId: fixture.monitor.displayId, timestamp: 3)
        XCTAssertEqual(fixture.swipe.flight?.phase, .waitingForPlacement)
    }

    private struct PreviewFixture {
        let controller: WMController
        let driver: OverviewPreviewTestDriver
        let capture: OverviewThumbnailCapture
        let preview: WorkspaceSwipePreview
        let swipe: WorkspaceSwipePresentation
        let monitor: Monitor
        let handle: WindowHandle
    }

    private func previewFixture() throws -> PreviewFixture {
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture()
        let preview = try WorkspaceSwipePreview(
            ownedWindowRegistry: OwnedWindowRegistry(), previewCapture: capture,
            backdrop: makeBackdrop(), hasCaptureAccess: { true }
        )
        let (controller, swipe, monitor, source) = try fixture(previewSurface: preview)
        addTeardownBlock { @MainActor in
            swipe.cancel(reason: "test")
            preview.stop()
            capture.clear()
            driver.finish()
        }
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
        let handle = try XCTUnwrap(preparation.source.items.first?.handle)
        return PreviewFixture(
            controller: controller, driver: driver, capture: capture, preview: preview, swipe: swipe,
            monitor: monitor, handle: handle
        )
    }

    private func requireContactWarmup(_ fixture: PreviewFixture) throws {
        _ = try XCTUnwrap(
            fixture.preview.isWarming ? fixture.preview : nil,
            "Contact must capture only missing previews, not start continuous capture"
        )
    }

    private func cachePreviewThroughContact(_ fixture: PreviewFixture) async throws {
        XCTAssertFalse(fixture.swipe.prepare(monitorId: fixture.monitor.id, timestamp: 1))
        try requireContactWarmup(fixture)
        try await fixture.driver.waitForStarts(1)
        fixture.driver.completeAllStarts()
        try await publish(try makeOverviewPreviewFrame(), through: fixture.driver.streams[0], into: fixture.capture)
        try await fixture.driver.waitForStops(1)
        fixture.swipe.stopPreparing()
        XCTAssertNotNil(fixture.capture.preview(for: fixture.handle))
    }

    private func publish(
        _ frame: OverviewPreviewFrame,
        through stream: OverviewPreviewTestStream,
        into capture: OverviewThumbnailCapture
    ) async throws {
        let published = expectation(description: "swipe preview frame published")
        capture.onPreview = { _, preview in if preview === frame { published.fulfill() } }
        stream.output.offer(frame)
        guard await XCTWaiter.fulfillment(of: [published], timeout: 1) == .completed else {
            XCTFail("Expected preview publication")
            throw OverviewPreviewTestWaitError.publication
        }
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

private final class OverlayCloseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
