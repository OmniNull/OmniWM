// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class WindowSwitcherPreviewsTests: XCTestCase {
    func testReadinessRequiresEveryRequestedPreviewAndResetsBetweenOpenings() throws {
        let first = WindowHandle(id: WindowToken(pid: 1, windowId: 1))
        let second = WindowHandle(id: WindowToken(pid: 1, windowId: 2))
        let frame = try makeOverviewPreviewFrame()
        var previews = WindowSwitcherPreviews()

        XCTAssertTrue(previews.isReady(for: []))
        XCTAssertFalse(previews.isReady(for: [first, second]))
        _ = previews.preview(for: first, candidate: frame)
        XCTAssertTrue(previews.isReady(for: [first]))
        XCTAssertFalse(previews.isReady(for: [first, second]))
        _ = previews.preview(for: second, candidate: nil)
        XCTAssertFalse(previews.isReady(for: [first, second]))
        _ = previews.preview(for: second, candidate: frame)
        XCTAssertTrue(previews.isReady(for: [first, second]))
        previews.removeAll()
        XCTAssertFalse(previews.isReady(for: [first, second]))
    }

    func testCachedPreviewRemainsStableUntilNextOpening() throws {
        let handle = WindowHandle(id: WindowToken(pid: 1, windowId: 1))
        let cached = try makeOverviewPreviewFrame()
        let refreshed = try makeOverviewPreviewFrame(width: 160, height: 60)
        var previews = WindowSwitcherPreviews()

        XCTAssertTrue(previews.preview(for: handle, candidate: cached) === cached)
        XCTAssertTrue(previews.preview(for: handle, candidate: refreshed) === cached)
        XCTAssertTrue(previews.preview(for: handle, candidate: nil) === cached)
        previews.removeAll()
        XCTAssertTrue(previews.preview(for: handle, candidate: refreshed) === refreshed)
    }

    func testMissingPreviewCanArriveWithoutReplacingOtherWindows() throws {
        let first = WindowHandle(id: WindowToken(pid: 1, windowId: 1))
        let second = WindowHandle(id: WindowToken(pid: 1, windowId: 2))
        let cached = try makeOverviewPreviewFrame()
        let arrived = try makeOverviewPreviewFrame()
        var previews = WindowSwitcherPreviews()

        XCTAssertTrue(previews.preview(for: first, candidate: cached) === cached)
        XCTAssertNil(previews.preview(for: second, candidate: nil))
        XCTAssertTrue(previews.preview(for: second, candidate: arrived) === arrived)
        XCTAssertTrue(previews.preview(for: first, candidate: arrived) === cached)
        XCTAssertTrue(previews.preview(for: second, candidate: cached) === arrived)
    }
}
