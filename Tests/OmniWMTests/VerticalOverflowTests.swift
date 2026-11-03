// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class VerticalOverflowTests: XCTestCase {
    private let portrait = HiddenPlacementMonitorContext(
        id: .init(displayId: 77),
        frame: CGRect(x: -1440, y: -2560, width: 1440, height: 2560),
        visibleFrame: CGRect(x: -1440, y: -2560, width: 1440, height: 2530)
    )
    private let laptop = HiddenPlacementMonitorContext(
        id: .init(displayId: 78),
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950)
    )

    private let insets = (horizontal: CGFloat(14), bottom: CGFloat(14), top: CGFloat(10))

    private var workingFrame: CGRect {
        CGRect(
            x: portrait.visibleFrame.minX + insets.horizontal,
            y: portrait.visibleFrame.minY + insets.bottom,
            width: portrait.visibleFrame.width - insets.horizontal * 2,
            height: portrait.visibleFrame.height - insets.bottom - insets.top
        )
    }

    private var offscreenTitleBarPosition: CGFloat {
        portrait.frame.maxY - workingFrame.minY - LayoutRefreshController.hiddenWindowEdgeRevealEpsilon
    }

    func testSelectedOversizedVerticalColumnPreservesAcceptedMinimumOnMultipleDisplays() throws {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        let selected = WindowToken(pid: 77, windowId: 77)
        let other = WindowToken(pid: 78, windowId: 78)
        let node = engine.addWindow(token: selected, to: workspaceId, afterSelection: nil)
        _ = engine.addWindow(token: other, to: workspaceId, afterSelection: nil)
        let acceptedMinimumHeight = portrait.frame.height + laptop.frame.height
        engine.updateWindowConstraints(
            for: selected,
            constraints: WindowSizeConstraints(
                minSize: CGSize(width: 0, height: acceptedMinimumHeight), maxSize: .zero, isFixed: false
            ),
            in: workspaceId, motion: .disabled
        )
        let sideNeighbor = HiddenPlacementMonitorContext(
            id: laptop.id,
            frame: laptop.frame.offsetBy(dx: 0, dy: portrait.frame.minY),
            visibleFrame: laptop.visibleFrame.offsetBy(dx: 0, dy: portrait.frame.minY)
        )
        let result = engine.calculateLayoutWithVisibility(
            state: ViewportState(activeColumnIndex: 0, selectedNodeId: node.id),
            workspaceId: workspaceId, monitorFrame: portrait.visibleFrame, screenFrame: portrait.frame,
            gaps: (horizontal: 0, vertical: 0), scale: 1,
            orientation: .vertical, hiddenPlacementMonitor: portrait,
            hiddenPlacementMonitors: [portrait, sideNeighbor], isSettled: true
        )
        let frame = try XCTUnwrap(result.frames[selected])
        XCTAssertEqual(engine.columns(in: workspaceId).count, 2)
        XCTAssertEqual(frame.height, acceptedMinimumHeight)
        XCTAssertGreaterThan(frame.height, portrait.frame.height)
        XCTAssertEqual(frame.minY, portrait.visibleFrame.minY)
        XCTAssertFalse(frame.intersects(sideNeighbor.frame))
        XCTAssertNil(result.hiddenHandles[selected])
    }

    func testOffscreenTitleBarHidesColumnBeforeMacOSCanConstrainItOntoLaptop() {
        for samples: [CGFloat] in [[0], [offscreenTitleBarPosition, 0]] {
            let result = visibility(position: offscreenTitleBarPosition, samples: samples, monitors: [portrait, laptop])
            XCTAssertFalse(result.visibleRect.intersects(laptop.frame))
            XCTAssertGreaterThan(result.visibleRect.maxY, portrait.frame.maxY)
            guard case .hidden(.maximum) = result.state else {
                return XCTFail("A column whose title bar is offscreen must be parked through AX")
            }
        }
    }

    func testActiveColumnPastTheTopEdgeStaysVisibleWhileInactiveOnesPark() {
        let topJustPastEdge = portrait.frame.maxY - workingFrame.maxY
            + LayoutRefreshController.hiddenWindowEdgeRevealEpsilon
        for position in [topJustPastEdge, offscreenTitleBarPosition] {
            for samples: [CGFloat] in [[0], [position, 0]] {
                let active = visibility(
                    position: position, samples: samples, monitors: [portrait, laptop], isActive: true
                )
                XCTAssertGreaterThan(active.visibleRect.maxY, portrait.frame.maxY)
                XCTAssertFalse(active.visibleRect.intersects(laptop.frame))
                guard case .visible = active.state else {
                    return XCTFail("The active column must stay visible while its top passes the edge")
                }
                guard case .hidden(.maximum) = visibility(
                    position: position, samples: samples, monitors: [portrait, laptop]
                ).state else {
                    return XCTFail("An inactive column whose top passes the edge must be parked")
                }
            }
        }
    }

    func testFocusedColumnAndSingleDisplayRetainVisibility() {
        for (position, monitors): (CGFloat, [HiddenPlacementMonitorContext]) in [
            (0, [portrait, laptop]), (offscreenTitleBarPosition, [portrait])
        ] {
            guard case .visible = visibility(position: position, samples: [0], monitors: monitors).state else {
                return XCTFail("An onscreen title bar or single-display layout must remain visible")
            }
        }
    }

    func testBottomPeekIsHiddenBeforeMacOSExpandsItToAVisibleTitleBar() {
        let reveal = LayoutRefreshController.hiddenWindowEdgeRevealEpsilon
        let position = portrait.frame.minY - workingFrame.maxY + reveal
        let result = visibility(position: position, samples: [0], monitors: [portrait, laptop])
        XCTAssertEqual(result.visibleRect.intersection(portrait.frame).height, reveal)
        guard case .hidden(.minimum) = result.state else {
            return XCTFail("A settled column below the working area must not peek into the bottom gap")
        }
    }

    func testBothVerticalHideSidesParkOutsideBottomGapAndAvoidLaptopAfterSizeClamp() throws {
        let controller = WindowAdmissionTestSupport.controller()
        func monitor(_ context: HiddenPlacementMonitorContext) -> Monitor {
            Monitor(
                id: context.id, displayId: context.id.displayId,
                frame: context.frame, visibleFrame: context.visibleFrame,
                hasNotch: false, name: "Parking"
            )
        }
        let source = monitor(portrait)
        controller.workspaceManager.applyMonitorConfigurationChange([source, monitor(laptop)])
        let bottomGap = CGRect(
            x: workingFrame.minX, y: portrait.frame.minY,
            width: workingFrame.width, height: workingFrame.minY - portrait.frame.minY
        )
        let clampedX = laptop.frame.minX - workingFrame.width + portrait.frame.maxY - workingFrame.maxY
        for edge: AxisHideEdge in [.minimum, .maximum] {
            for height in [workingFrame.height, laptop.visibleFrame.height] {
                for x in [workingFrame.minX, clampedX] {
                    let size = CGSize(width: workingFrame.width, height: height)
                    let origin = try XCTUnwrap(controller.layoutRefreshController.liveFrameHideOrigin(
                        for: CGRect(origin: CGPoint(x: x, y: portrait.frame.maxY), size: size),
                        monitor: source, side: edge.encodedHideSide, reason: .layoutTransient
                    ))
                    let parked = CGRect(origin: origin, size: size)
                    XCTAssertFalse(parked.intersects(laptop.frame))
                    XCTAssertFalse(parked.intersects(bottomGap))
                    XCTAssertEqual(
                        parked.intersection(portrait.frame).width,
                        LayoutRefreshController.hiddenWindowEdgeRevealEpsilon
                    )
                }
            }
        }
    }

    func testCenteredVerticalParksSitOnThePhysicalPixelGrid() throws {
        let controller = WindowAdmissionTestSupport.controller()
        for scale: CGFloat in [1, 2] {
            func monitor(_ context: HiddenPlacementMonitorContext) -> Monitor {
                Monitor(
                    id: context.id, displayId: context.id.displayId,
                    frame: context.frame, visibleFrame: context.visibleFrame,
                    hasNotch: false, backingScale: scale, name: "Parking"
                )
            }
            let source = monitor(portrait)
            controller.workspaceManager.applyMonitorConfigurationChange([source, monitor(laptop)])
            let pixel = 1 / scale
            for (shortfallInPixels, offsetFromCenter) in [(CGFloat(1), pixel / 2), (2, 0)] {
                let size = CGSize(
                    width: workingFrame.width,
                    height: portrait.visibleFrame.height - shortfallInPixels * pixel
                )
                let origin = try XCTUnwrap(controller.layoutRefreshController.liveFrameHideOrigin(
                    for: CGRect(origin: workingFrame.origin, size: size),
                    monitor: source, side: AxisHideEdge.maximum.encodedHideSide, reason: .layoutTransient
                ))
                let centered = portrait.visibleFrame.midY - size.height / 2
                XCTAssertEqual(abs(origin.y - centered), offsetFromCenter)
                XCTAssertEqual((origin.y * scale).rounded(), origin.y * scale)
                let parked = CGRect(origin: origin, size: size)
                XCTAssertFalse(parked.intersects(laptop.frame))
                XCTAssertEqual(
                    parked.intersection(portrait.frame).width,
                    LayoutRefreshController.hiddenWindowEdgeRevealEpsilon
                )
            }
        }
    }

    private func visibility(
        position: CGFloat,
        samples: [CGFloat],
        monitors: [HiddenPlacementMonitorContext],
        isActive: Bool = false
    ) -> NiriColumnVisibility {
        NiriLayoutViewport(
            area: WorkingAreaContext(
                workingFrame: workingFrame,
                viewFrame: portrait.frame, scale: 1
            ),
            orientation: .vertical, workspaceOffset: 0, viewPositions: samples,
            revealMargin: portrait.frame.height - workingFrame.height
        ).columnVisibility(
            for: NiriPreparedLayoutColumn(span: workingFrame.height, renderOffset: .zero, position: position),
            at: (index: 0, isActive: isActive), viewPosition: 0,
            hiddenPlacementMonitor: portrait, hiddenPlacementMonitors: monitors
        )
    }
}
