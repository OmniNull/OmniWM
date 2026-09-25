// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SpatialNeighborTokenTests: XCTestCase {
    private func token(_ id: Int) -> WindowToken {
        WindowToken(pid: 1, windowId: id)
    }

    private func pick(
        from sourceFrame: CGRect?,
        _ candidates: [(WindowToken, CGRect)],
        direction: Direction,
        targetFrame: CGRect
    ) -> WindowToken? {
        WorkspaceNavigationHandler.spatialNeighborToken(
            from: sourceFrame,
            candidates: candidates.map { (token: $0.0, frame: $0.1) },
            direction: direction,
            targetFrame: targetFrame
        )
    }

    func testRightPicksLeftMostEligible() {
        let target = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        let left = token(1)
        let right = token(2)
        let result = pick(
            from: CGRect(x: 0, y: 200, width: 500, height: 600),
            [
                (right, CGRect(x: 1500, y: 0, width: 400, height: 1000)),
                (left, CGRect(x: 1000, y: 0, width: 400, height: 1000))
            ],
            direction: .right,
            targetFrame: target
        )
        XCTAssertEqual(result, left)
    }

    func testLeftPicksRightMostEligible() {
        let target = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let near = token(1)
        let far = token(2)
        let result = pick(
            from: CGRect(x: 1500, y: 200, width: 500, height: 600),
            [
                (far, CGRect(x: 0, y: 0, width: 400, height: 1000)),
                (near, CGRect(x: 500, y: 0, width: 400, height: 1000))
            ],
            direction: .left,
            targetFrame: target
        )
        XCTAssertEqual(result, near)
    }

    func testDownPicksTopMostEligible() {
        let target = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let top = token(1)
        let bottom = token(2)
        let result = pick(
            from: CGRect(x: 200, y: 1100, width: 600, height: 400),
            [
                (bottom, CGRect(x: 0, y: 0, width: 1000, height: 400)),
                (top, CGRect(x: 0, y: 600, width: 1000, height: 400))
            ],
            direction: .down,
            targetFrame: target
        )
        XCTAssertEqual(result, top)
    }

    func testUpPicksBottomMostEligible() {
        let target = CGRect(x: 0, y: 1000, width: 1000, height: 1000)
        let top = token(1)
        let bottom = token(2)
        let result = pick(
            from: CGRect(x: 200, y: 200, width: 600, height: 400),
            [
                (top, CGRect(x: 0, y: 1600, width: 1000, height: 400)),
                (bottom, CGRect(x: 0, y: 1000, width: 1000, height: 400))
            ],
            direction: .up,
            targetFrame: target
        )
        XCTAssertEqual(result, bottom)
    }

    func testCrossAxisOverlapBeatsCloserUnalignedCandidate() {
        let target = CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        let edgeButUnaligned = token(1)
        let alignedButFar = token(2)
        let result = pick(
            from: CGRect(x: 0, y: 400, width: 500, height: 200),
            [
                (edgeButUnaligned, CGRect(x: 1000, y: 0, width: 100, height: 100)),
                (alignedButFar, CGRect(x: 1500, y: 400, width: 100, height: 200))
            ],
            direction: .right,
            targetFrame: target
        )
        XCTAssertEqual(result, alignedButFar)
    }

    func testNoSourceFramePicksNearestEdgeByTargetCenter() {
        let target = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let offCenter = token(1)
        let centered = token(2)
        let result = pick(
            from: nil,
            [
                (offCenter, CGRect(x: 0, y: 600, width: 200, height: 400)),
                (centered, CGRect(x: 400, y: 600, width: 200, height: 400))
            ],
            direction: .down,
            targetFrame: target
        )
        XCTAssertEqual(result, centered)
    }

    func testEmptyCandidatesReturnsNil() {
        let result = pick(
            from: CGRect(x: 0, y: 0, width: 100, height: 100),
            [],
            direction: .right,
            targetFrame: CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        )
        XCTAssertNil(result)
    }

    func testEmptyCandidatesDoNotComputeTargetFrame() {
        var computed = false
        func targetFrame() -> CGRect {
            computed = true
            return CGRect(x: 1000, y: 0, width: 1000, height: 1000)
        }

        let result = WorkspaceNavigationHandler.spatialNeighborToken(
            from: nil,
            candidates: [(token: WindowToken, frame: CGRect)](),
            direction: .right,
            targetFrame: targetFrame()
        )
        XCTAssertNil(result)
        XCTAssertFalse(computed)
    }

    func testNegativeOriginStackedMonitorsDownPicksTopMost() {
        let target = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let top = token(1)
        let bottom = token(2)
        let result = pick(
            from: CGRect(x: 100, y: 100, width: 600, height: 600),
            [
                (bottom, CGRect(x: 0, y: -1080, width: 1920, height: 400)),
                (top, CGRect(x: 0, y: -400, width: 1920, height: 400))
            ],
            direction: .down,
            targetFrame: target
        )
        XCTAssertEqual(result, top)
    }
}
