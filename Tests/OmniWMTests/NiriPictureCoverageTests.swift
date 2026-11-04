// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriPictureCoverageTests: NiriInteractionTestCase {
    private let sourceFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let scale: CGFloat = 2

    @MainActor private final class PermissionState {
        var granted = true
    }

    func testDeniedPicturesExcludeOnlyTheParkedMultiDisplayTopNeighbor() {
        let enabled = input(available: true)
        let disabled = input(available: false)
        let nativeSingleDisplay = input(available: false, hasOtherMonitor: false)
        let expectedTrailingOffset = -(sourceFrame.height - disabled.containerSpans[disabled.selectedIndex])

        XCTAssertEqual(NiriSettledCoverageEvaluator.bestOffset(for: enabled), enabled.semanticOffset)
        XCTAssertEqual(NiriSettledCoverageEvaluator.bestOffset(for: disabled), expectedTrailingOffset)
        XCTAssertEqual(
            NiriSettledCoverageEvaluator.bestOffset(for: nativeSingleDisplay), nativeSingleDisplay.semanticOffset
        )
        let recovered = input(available: false, semanticOffset: expectedTrailingOffset)
        XCTAssertEqual(NiriSettledCoverageEvaluator.bestOffset(for: recovered), expectedTrailingOffset)
    }

    func testActiveOversizedColumnRemainsCountedWithoutPictures() {
        let source = monitor(id: 100, frame: sourceFrame)
        let oversized = NiriSettledCoverageEvaluator.Input(
            containerSpans: [sourceFrame.height + sourceFrame.height / 2, sourceFrame.height / 2],
            selectedIndex: 0, activeIndex: 0, semanticOffset: 0, gap: 0, workingFrame: sourceFrame,
            sourceMonitor: source, monitors: [source, otherMonitor], orientation: .vertical, scale: scale,
            edgePicturesAvailable: false
        )
        XCTAssertEqual(NiriSettledCoverageEvaluator.bestOffset(for: oversized), oversized.semanticOffset)
    }

    func testTopThresholdUsesFullDisplayAndOnePhysicalPixelBeyondItIsHidden() {
        let working = sourceFrame.insetBy(dx: 0, dy: sourceFrame.height / 10)
        let half = working.height / 2
        let upperSpan = sourceFrame.maxY - (working.minY + half)
        let touching = input(available: false, spans: [half, half, upperSpan], workingFrame: working)
        let crossing = input(
            available: false, spans: [half, half, upperSpan + 1 / scale], workingFrame: working
        )

        XCTAssertEqual(NiriSettledCoverageEvaluator.bestOffset(for: touching), touching.semanticOffset)
        XCTAssertEqual(NiriSettledCoverageEvaluator.bestOffset(for: crossing), -(working.height - half))
    }

    func testHorizontalCoverageIgnoresPictureCapability() {
        let enabled = input(available: true, orientation: .horizontal)
        let disabled = input(available: false, orientation: .horizontal)
        XCTAssertEqual(NiriSettledCoverageEvaluator.bestOffset(for: enabled), enabled.semanticOffset)
        XCTAssertEqual(NiriSettledCoverageEvaluator.bestOffset(for: disabled), disabled.semanticOffset)
    }

    func testCommandTimeRecoveryReadsEngineCapabilityWithoutCaptureReadiness() {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let source = nativeMonitor(id: 100, frame: sourceFrame)
        let other = nativeMonitor(id: 101, frame: otherMonitor.frame)
        _ = engine.ensureMonitor(for: source.id, monitor: source, orientation: .vertical)
        _ = engine.ensureMonitor(for: other.id, monitor: other, orientation: .horizontal)
        let spans = [sourceFrame.height / 2, sourceFrame.height / 2, sourceFrame.height]
        var nodes: [NiriWindow] = []
        for index in spans.indices {
            nodes.append(addWindow(engine, pid: 10_300, windowId: index + 1, to: workspaceId, after: nodes.last))
        }
        engine.moveWorkspace(workspaceId, to: source.id, monitor: source)
        for (column, span) in zip(engine.columns(in: workspaceId), spans) {
            column.height = .fixed(span)
            column.cachedHeight = span
        }
        let selectedIndex = 1
        var state = ViewportState(activeColumnIndex: selectedIndex, selectedNodeId: nodes[selectedIndex].id)
        let context = NiriInteractionContext(
            workspaceId: workspaceId, motion: .disabled, workingFrame: sourceFrame, gaps: 0, orientation: .vertical
        )
        engine.edgePicturesAvailable = false
        XCTAssertTrue(engine.recoverSettledCoverage(context: context, state: &state))
        XCTAssertEqual(state.viewOffset, -(sourceFrame.height - spans[selectedIndex]))

        state.jumpOffset(to: 0)
        engine.edgePicturesAvailable = true
        XCTAssertFalse(engine.recoverSettledCoverage(context: context, state: &state))
        XCTAssertEqual(state.viewOffset, 0)
    }

    @MainActor
    func testPermissionChangesUpdateEngineEvenWithNoActiveVerticalWorkspace() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMNiriPictureCoverageTests")
        let monitor = nativeMonitor(id: 100, frame: sourceFrame)
        controller.settings.monitors.updateOrientationSettings(
            .init(monitorName: monitor.name, monitorDisplayId: monitor.displayId, orientation: .horizontal),
            for: monitor
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        XCTAssertEqual(engine.edgePicturesAvailable, ScreenCapturePermissionMonitor.shared.isGranted)
        XCTAssertEqual(controller.workspaceManager.monitors.map {
            controller.settings.monitors.effectiveOrientation(for: $0)
        }, [.horizontal])
        let permissionState = PermissionState()
        let permission = ScreenCapturePermissionMonitor(
            preflight: { permissionState.granted }, notificationCenter: NotificationCenter()
        )
        XCTAssertTrue(permission.isGranted)
        let pictures = NiriEdgePictures(capture: { _, completion in
            XCTFail("Capability propagation must not capture a window")
            completion(nil)
            return nil
        }, activate: { _, _ in })
        controller.observePictureCaptureState(pictures, permission: permission)
        controller.workspaceManager.withEngineMutationScope { engine.edgePicturesAvailable = true }

        permissionState.granted = false
        XCTAssertFalse(permission.refresh())
        XCTAssertFalse(engine.edgePicturesAvailable)
        permissionState.granted = true
        XCTAssertTrue(permission.refresh())
        XCTAssertTrue(engine.edgePicturesAvailable)
    }

    private func input(
        available: Bool,
        hasOtherMonitor: Bool = true,
        semanticOffset: CGFloat = 0,
        spans: [CGFloat]? = nil,
        workingFrame: CGRect? = nil,
        orientation: Monitor.Orientation = .vertical
    ) -> NiriSettledCoverageEvaluator.Input {
        let source = monitor(id: 100, frame: sourceFrame)
        let span = orientation == .vertical ? sourceFrame.height : sourceFrame.width
        return NiriSettledCoverageEvaluator.Input(
            containerSpans: spans ?? [span / 2, span / 2, span], selectedIndex: 1, activeIndex: 1,
            semanticOffset: semanticOffset, gap: 0, workingFrame: workingFrame ?? sourceFrame,
            sourceMonitor: source, monitors: hasOtherMonitor ? [source, otherMonitor] : [source],
            orientation: orientation, scale: scale, edgePicturesAvailable: available
        )
    }

    private var otherMonitor: HiddenPlacementMonitorContext {
        monitor(
            id: 101,
            frame: sourceFrame.offsetBy(dx: sourceFrame.width * 2, dy: sourceFrame.height * 2)
        )
    }

    private func monitor(id: UInt32, frame: CGRect) -> HiddenPlacementMonitorContext {
        HiddenPlacementMonitorContext(id: .init(displayId: id), frame: frame, visibleFrame: frame)
    }

    private func nativeMonitor(id: UInt32, frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: id), displayId: id, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Coverage"
        )
    }
}
