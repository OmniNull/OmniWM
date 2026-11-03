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

    func testOffscreenTitleBarHidesColumnBeforeMacOSCanConstrainItOntoLaptop() {
        for samples: [CGFloat] in [[0], [2545, 0]] {
            let result = visibility(position: 2545, samples: samples, monitors: [portrait, laptop])
            XCTAssertFalse(result.visibleRect.intersects(laptop.frame))
            XCTAssertGreaterThan(result.visibleRect.maxY, portrait.frame.maxY)
            guard case .hidden(.maximum) = result.state else {
                return XCTFail("A column whose title bar is offscreen must be parked through AX")
            }
        }
    }

    func testFocusedColumnAndSingleDisplayRetainVisibility() {
        for (position, monitors): (CGFloat, [HiddenPlacementMonitorContext]) in [
            (0, [portrait, laptop]), (2545, [portrait])
        ] {
            guard case .visible = visibility(position: position, samples: [0], monitors: monitors).state else {
                return XCTFail("An onscreen title bar or single-display layout must remain visible")
            }
        }
    }

    func testBottomPeekIsHiddenBeforeMacOSExpandsItToAVisibleTitleBar() {
        let result = visibility(position: -2519, samples: [0], monitors: [portrait, laptop])
        XCTAssertEqual(result.visibleRect.intersection(portrait.frame).height, 1)
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
        let bottomGap = CGRect(x: -1426, y: -2560, width: 1412, height: 14)
        for edge: AxisHideEdge in [.minimum, .maximum] {
            for height: CGFloat in [2506, 950] {
                for x: CGFloat in [-1426, -1372] {
                    let size = CGSize(width: 1412, height: height)
                    let origin = try XCTUnwrap(controller.layoutRefreshController.liveFrameHideOrigin(
                        for: CGRect(origin: CGPoint(x: x, y: 0), size: size),
                        monitor: source, side: edge.encodedHideSide, reason: .layoutTransient
                    ))
                    let parked = CGRect(origin: origin, size: size)
                    XCTAssertFalse(parked.intersects(laptop.frame))
                    XCTAssertFalse(parked.intersects(bottomGap))
                    XCTAssertEqual(parked.intersection(portrait.frame).width, 1)
                }
            }
        }
    }

    private func visibility(
        position: CGFloat,
        samples: [CGFloat],
        monitors: [HiddenPlacementMonitorContext]
    ) -> NiriColumnVisibility {
        NiriLayoutViewport(
            area: WorkingAreaContext(
                workingFrame: CGRect(x: -1426, y: -2546, width: 1412, height: 2506),
                viewFrame: portrait.frame, scale: 1
            ),
            orientation: .vertical, workspaceOffset: 0, viewPositions: samples, revealMargin: 64
        ).columnVisibility(
            for: NiriPreparedLayoutColumn(span: 2506, renderOffset: .zero, position: position),
            at: 0, viewPosition: 0,
            hiddenPlacementMonitor: portrait, hiddenPlacementMonitors: monitors
        )
    }
}
