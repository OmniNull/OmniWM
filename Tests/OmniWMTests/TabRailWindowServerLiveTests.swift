// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    final class TabRailWindowServerLiveTests: XCTestCase {
        func testRailWindowServerBoundsFollowSkyLightAndAppKitPlacements() throws {
            let screen = try XCTUnwrap(NSScreen.main)
            let manager = TabRailManager()
            defer { manager.removeAll() }
            let workspaceId = WorkspaceDescriptor.ID()
            let owner = TabRailOwner.niriColumn(NodeId())
            let key = TabRailKey(workspaceId: workspaceId, owner: owner)
            func info(_ tile: CGRect, tabCount: Int = 3) -> TabRailInfo {
                TabRailInfo(
                    workspaceId: workspaceId,
                    owner: owner,
                    plannedSeq: 1,
                    tileFrame: tile,
                    tabCount: tabCount,
                    activeVisualIndex: 0,
                    activeWindowId: nil
                )
            }

            let start = CGRect(
                x: screen.visibleFrame.minX + 240,
                y: screen.visibleFrame.midY - 300,
                width: 600,
                height: 600
            )
            manager.updateRails([info(start)], forceOrdering: true)
            let window = try XCTUnwrap(manager.existingWindow(for: key) as? TabRailWindow)
            let railOffset = window.appliedFrame.minX - start.minX
            assertWindowServerBounds(of: window)

            let ticked = start.offsetBy(dx: 137, dy: 0)
            manager.applyAnimationGeometry([TabRailGeometryCommand(
                key: key,
                tileFrame: ticked,
                visibleTileFrame: ticked
            )])
            manager.updateRails([info(ticked)])
            XCTAssertEqual(window.appliedFrame.minX - ticked.minX, railOffset)
            assertWindowServerBounds(of: window)

            let settledMove = ticked.offsetBy(dx: -91, dy: 40)
            manager.updateRails([info(settledMove)])
            XCTAssertEqual(window.appliedFrame.minX - settledMove.minX, railOffset)
            assertWindowServerBounds(of: window)

            let sizeBefore = window.appliedFrame.size
            manager.updateRails([info(settledMove, tabCount: 6)])
            XCTAssertNotEqual(window.appliedFrame.size, sizeBefore)
            assertWindowServerBounds(of: window)

            manager.updateRails([info(start)])
            XCTAssertEqual(window.appliedFrame.minX - start.minX, railOffset)
            assertWindowServerBounds(of: window)
        }

        func testFixedTopResizeAfterSkyLightMoveCorrectsTheWindowServerOrigin() throws {
            let screen = try XCTUnwrap(NSScreen.main)
            let manager = TabRailManager()
            defer { manager.removeAll() }
            let workspaceId = WorkspaceDescriptor.ID()
            let owner = TabRailOwner.niriColumn(NodeId())
            let key = TabRailKey(workspaceId: workspaceId, owner: owner)
            func info(_ tile: CGRect, tabCount: Int) -> TabRailInfo {
                TabRailInfo(
                    workspaceId: workspaceId,
                    owner: owner,
                    plannedSeq: 1,
                    tileFrame: tile,
                    tabCount: tabCount,
                    activeVisualIndex: 0,
                    activeWindowId: nil
                )
            }

            let start = CGRect(
                x: screen.visibleFrame.minX + 240,
                y: screen.visibleFrame.midY - 300,
                width: 600,
                height: 600
            )
            manager.updateRails([info(start, tabCount: 2)], forceOrdering: true)
            let window = try XCTUnwrap(manager.existingWindow(for: key) as? TabRailWindow)
            let cachedFrame = window.frame
            assertWindowServerBounds(of: window)

            let ticked = start.offsetBy(dx: 120, dy: 0)
            manager.applyAnimationGeometry([TabRailGeometryCommand(
                key: key,
                tileFrame: ticked,
                visibleTileFrame: ticked
            )])
            XCTAssertEqual(window.frame, cachedFrame)
            XCTAssertNotEqual(window.appliedFrame, cachedFrame)
            assertWindowServerBounds(of: window)

            let resizedHeight = TabRailStyle.compact.fittedHeight(tabCount: 4, availableHeight: start.height)
            let fixedTop = start.offsetBy(dx: 0, dy: (cachedFrame.height - resizedHeight) / 2)
            manager.updateRails([info(fixedTop, tabCount: 4)])
            XCTAssertNotEqual(window.appliedFrame.size, cachedFrame.size)
            XCTAssertEqual(window.appliedFrame.minX, cachedFrame.minX)
            XCTAssertEqual(window.appliedFrame.maxY, cachedFrame.maxY)
            assertWindowServerBounds(of: window)
        }

        func testFractionalRailReturnsToItsAppKitPlacementAfterAnimationMoves() throws {
            let screen = try XCTUnwrap(NSScreen.main)
            let manager = TabRailManager()
            defer { manager.removeAll() }
            let workspaceId = WorkspaceDescriptor.ID()
            let owner = TabRailOwner.niriColumn(NodeId())
            let key = TabRailKey(workspaceId: workspaceId, owner: owner)
            func info(_ tile: CGRect) -> TabRailInfo {
                TabRailInfo(
                    workspaceId: workspaceId,
                    owner: owner,
                    plannedSeq: 1,
                    tileFrame: tile,
                    tabCount: 2,
                    activeVisualIndex: 0,
                    activeWindowId: nil
                )
            }

            let start = CGRect(
                x: screen.visibleFrame.minX + 240.25,
                y: screen.visibleFrame.midY - 300.25,
                width: 600,
                height: 600.5
            )
            manager.updateRails([info(start)], forceOrdering: true)
            let window = try XCTUnwrap(manager.existingWindow(for: key) as? TabRailWindow)
            CATransaction.flush()
            let windowId = UInt32(window.windowNumber)
            _ = SkyLight.shared.isWindowOrderedIn(windowId)
            let realizedBounds = try XCTUnwrap(SkyLight.shared.getWindowBounds(windowId))

            let away = start.offsetBy(dx: 137.5, dy: 0)
            manager.applyAnimationGeometry([TabRailGeometryCommand(key: key, tileFrame: away, visibleTileFrame: away)])
            manager.applyAnimationGeometry([TabRailGeometryCommand(
                key: key,
                tileFrame: start,
                visibleTileFrame: start
            )])
            manager.updateRails([info(start)])

            CATransaction.flush()
            _ = SkyLight.shared.isWindowOrderedIn(windowId)
            XCTAssertEqual(SkyLight.shared.getWindowBounds(windowId), realizedBounds)
            XCTAssertEqual(window.appliedFrame.origin.x, window.appliedFrame.origin.x.rounded(.down))
            XCTAssertEqual(window.appliedFrame.origin.y, window.appliedFrame.origin.y.rounded(.down))
        }

        private func assertWindowServerBounds(
            of window: TabRailWindow,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            CATransaction.flush()
            let windowId = UInt32(window.windowNumber)
            XCTAssertEqual(SkyLight.shared.isWindowOrderedIn(windowId), true, file: file, line: line)
            XCTAssertEqual(
                SkyLight.shared.getWindowBounds(windowId),
                ScreenCoordinateSpace.toWindowServer(rect: window.appliedFrame),
                file: file,
                line: line
            )
        }
    }
#endif
