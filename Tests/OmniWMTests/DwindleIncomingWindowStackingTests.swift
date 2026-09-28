// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class DwindleIncomingWindowStackingTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let first = WindowToken(pid: 1, windowId: 1)
    private let second = WindowToken(pid: 2, windowId: 2)
    private let third = WindowToken(pid: 3, windowId: 3)

    private func makeEngine(stackIncomingWindows: Bool = true) -> (DwindleLayoutEngine, WorkspaceDescriptor.ID) {
        let engine = DwindleLayoutEngine()
        engine.settings.stackIncomingWindows = stackIncomingWindows
        return (engine, WorkspaceDescriptor.ID())
    }

    func testIncomingWindowJoinsSelectedTileAsActiveMember() throws {
        let (engine, workspace) = makeEngine()
        engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)

        engine.addWindow(token: second, to: workspace, activeWindowFrame: nil, joinsSelectedTile: true)

        XCTAssertEqual(engine.tileCount(in: workspace), 1)
        let snapshot = try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace))
        XCTAssertEqual(snapshot.members.map(\.token), [first, second])
        XCTAssertEqual(snapshot.activeToken, second)
        XCTAssertEqual(Set(engine.calculateLayout(for: workspace, screen: screen).keys), [second])
    }

    func testIncomingWindowIsInsertedAfterActiveMemberOfExistingStack() throws {
        let (engine, workspace) = makeEngine()
        engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
        engine.addWindow(token: second, to: workspace, activeWindowFrame: nil, joinsSelectedTile: true)
        XCTAssertTrue(engine.activateWindow(first, in: workspace))

        engine.addWindow(token: third, to: workspace, activeWindowFrame: nil, joinsSelectedTile: true)

        let snapshot = try XCTUnwrap(engine.tileSnapshot(for: third, in: workspace))
        XCTAssertEqual(snapshot.members.map(\.token), [first, third, second])
        XCTAssertEqual(snapshot.activeToken, third)
    }

    func testIncomingWindowInEmptyWorkspaceBecomesRootTile() throws {
        let (engine, workspace) = makeEngine()

        engine.addWindow(token: first, to: workspace, activeWindowFrame: nil, joinsSelectedTile: true)

        XCTAssertEqual(engine.tileCount(in: workspace), 1)
        XCTAssertEqual(try XCTUnwrap(engine.tileSnapshot(for: first, in: workspace)).members.map(\.token), [first])
    }

    func testPreselectionStillSplitsIncomingWindow() {
        let (engine, workspace) = makeEngine()
        engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)
        _ = engine.calculateLayout(for: workspace, screen: screen)
        XCTAssertTrue(engine.setPreselection(.right, in: workspace))

        engine.addWindow(token: second, to: workspace, activeWindowFrame: nil, joinsSelectedTile: true)

        XCTAssertEqual(engine.tileCount(in: workspace), 2)
        XCTAssertNil(engine.existingState(for: workspace)?.preselection)
    }

    func testIncomingWindowSplitsWhenSettingIsOff() {
        let (engine, workspace) = makeEngine(stackIncomingWindows: false)
        engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)

        engine.addWindow(token: second, to: workspace, activeWindowFrame: nil, joinsSelectedTile: true)

        XCTAssertEqual(engine.tileCount(in: workspace), 2)
    }

    func testWindowThatIsNotIncomingSplitsEvenWhenSettingIsOn() {
        let (engine, workspace) = makeEngine()
        engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)

        engine.addWindow(token: second, to: workspace, activeWindowFrame: nil)

        XCTAssertEqual(engine.tileCount(in: workspace), 2)
    }

    func testSyncWindowsStacksOnlyStackingTokens() throws {
        let (engine, workspace) = makeEngine()
        engine.addWindow(token: first, to: workspace, activeWindowFrame: nil)

        _ = engine.syncWindows(
            [first, second, third],
            in: workspace,
            focusedToken: first,
            stackingTokens: [second]
        )

        XCTAssertEqual(engine.tileCount(in: workspace), 2)
        XCTAssertEqual(try XCTUnwrap(engine.tileSnapshot(for: second, in: workspace)).members.map(\.token), [
            first, second
        ])
        XCTAssertEqual(try XCTUnwrap(engine.tileSnapshot(for: third, in: workspace)).members.map(\.token), [third])
    }
}
