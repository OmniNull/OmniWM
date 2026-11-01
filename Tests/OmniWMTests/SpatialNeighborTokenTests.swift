// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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

    func testPicksEligibleCandidateForEachDirection() {
        typealias Case = (
            label: String,
            source: CGRect,
            candidates: [(id: Int, frame: CGRect)],
            direction: Direction,
            target: CGRect,
            expected: Int
        )
        let cases: [Case] = [
            (
                "right picks left-most",
                CGRect(x: 0, y: 200, width: 500, height: 600),
                [
                    (2, CGRect(x: 1500, y: 0, width: 400, height: 1000)),
                    (1, CGRect(x: 1000, y: 0, width: 400, height: 1000))
                ],
                .right,
                CGRect(x: 1000, y: 0, width: 1000, height: 1000),
                1
            ),
            (
                "left picks right-most",
                CGRect(x: 1500, y: 200, width: 500, height: 600),
                [
                    (2, CGRect(x: 0, y: 0, width: 400, height: 1000)),
                    (1, CGRect(x: 500, y: 0, width: 400, height: 1000))
                ],
                .left,
                CGRect(x: 0, y: 0, width: 1000, height: 1000),
                1
            ),
            (
                "down picks top-most",
                CGRect(x: 200, y: 1100, width: 600, height: 400),
                [
                    (2, CGRect(x: 0, y: 0, width: 1000, height: 400)),
                    (1, CGRect(x: 0, y: 600, width: 1000, height: 400))
                ],
                .down,
                CGRect(x: 0, y: 0, width: 1000, height: 1000),
                1
            ),
            (
                "up picks bottom-most",
                CGRect(x: 200, y: 200, width: 600, height: 400),
                [
                    (1, CGRect(x: 0, y: 1600, width: 1000, height: 400)),
                    (2, CGRect(x: 0, y: 1000, width: 1000, height: 400))
                ],
                .up,
                CGRect(x: 0, y: 1000, width: 1000, height: 1000),
                2
            ),
            (
                "cross-axis overlap beats closer unaligned candidate",
                CGRect(x: 0, y: 400, width: 500, height: 200),
                [
                    (1, CGRect(x: 1000, y: 0, width: 100, height: 100)),
                    (2, CGRect(x: 1500, y: 400, width: 100, height: 200))
                ],
                .right,
                CGRect(x: 1000, y: 0, width: 1000, height: 1000),
                2
            )
        ]
        for testCase in cases {
            let result = pick(
                from: testCase.source,
                testCase.candidates.map { (token($0.id), $0.frame) },
                direction: testCase.direction,
                targetFrame: testCase.target
            )
            XCTAssertEqual(result, token(testCase.expected), testCase.label)
        }
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

    func testEmptyCandidatesDoNotComputeTargetFrame() {
        for source in [nil, CGRect(x: 0, y: 0, width: 100, height: 100)] {
            var computed = false
            func targetFrame() -> CGRect {
                computed = true
                return CGRect(x: 1000, y: 0, width: 1000, height: 1000)
            }

            let result = WorkspaceNavigationHandler.spatialNeighborToken(
                from: source,
                candidates: [(token: WindowToken, frame: CGRect)](),
                direction: .right,
                targetFrame: targetFrame()
            )
            XCTAssertNil(result)
            XCTAssertFalse(computed)
        }
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
