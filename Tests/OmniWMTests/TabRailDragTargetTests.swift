// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class TabRailDragTargetTests: XCTestCase {
    func testCompactScalarHitKeepsMarkerCentersAndExactMidpointPartitions() {
        let motion = MotionPolicy(animationsEnabled: false)
        for count in [2, 5] {
            for active in [0, count - 1] {
                let bounds = CGRect(
                    x: 0, y: 0, width: TabRailMetrics.hitWidth,
                    height: TabRailStyle.iconRowHeight * CGFloat(count)
                )
                let layout = TabRailLayout(tabCount: count, bounds: bounds, activeVisualIndex: active, scale: 2)
                let overlay = TabRailTrackOverlayView(frame: bounds, motionPolicy: motion)
                overlay.update(layout: layout, activeVisualIndex: active, hoveredVisualIndex: nil, railHovered: false)
                for item in layout.items {
                    let point = CGPoint(x: layout.railRect.midX, y: item.pillRect.midY)
                    XCTAssertEqual(overlay.visualIndex(at: point), item.visualIndex)
                }
                for index in layout.items.indices.dropFirst() {
                    let upper = layout.items[index - 1]
                    let lower = layout.items[index]
                    let boundary = (upper.pillRect.midY + lower.pillRect.midY) / 2
                    XCTAssertEqual(
                        overlay.visualIndex(at: CGPoint(x: layout.railRect.midX, y: boundary)), upper.visualIndex
                    )
                    XCTAssertEqual(
                        overlay.visualIndex(at: CGPoint(x: layout.railRect.midX, y: boundary.nextDown)),
                        lower.visualIndex
                    )
                }
                XCTAssertNil(overlay.visualIndex(at: CGPoint(x: layout.railRect.maxX, y: layout.railRect.midY)))
                XCTAssertNil(overlay.visualIndex(at: CGPoint(x: layout.railRect.midX, y: layout.railRect.maxY)))
            }
        }
    }

    func testIconScalarTargetUsesScrolledVisibleRowsAndRejectsMissingTokens() throws {
        let tokens = (0 ..< 5).map { WindowToken(pid: 941_700, windowId: $0 + 1) }
        let bounds = CGRect(
            x: 0, y: 0, width: TabRailStyle.appIcons.hitWidth, height: TabRailStyle.iconRowHeight * 2
        )
        let view = TabRailView(frame: bounds, motionPolicy: MotionPolicy(animationsEnabled: false))
        let tabs = tokens.enumerated().map { index, token in
            TabRailTabInfo(
                visualIndex: index, token: index == 3 ? nil : token,
                windowId: token.windowId, appName: nil, title: nil, isActive: index == 0
            )
        }
        view.update(tabs: tabs, activeVisualIndex: 0, style: .appIcons)
        let icons = try XCTUnwrap(view.subviews.compactMap { $0 as? TabRailIconView }.first)
        let firstVisible = 2
        icons.scrollView.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(firstVisible) * TabRailStyle.iconRowHeight))
        let firstPoint = CGPoint(x: bounds.midX, y: bounds.maxY - TabRailStyle.iconRowHeight / 2)
        XCTAssertEqual(view.dragTarget(at: firstPoint)?.visualIndex, firstVisible)
        XCTAssertEqual(view.dragTarget(at: firstPoint)?.token, tokens[firstVisible])
        let missingPoint = CGPoint(x: bounds.midX, y: bounds.minY + TabRailStyle.iconRowHeight / 2)
        XCTAssertNil(view.dragTarget(at: missingPoint))
        XCTAssertNil(view.dragTarget(at: CGPoint(x: bounds.maxX, y: bounds.midY)))
        XCTAssertNil(view.dragTarget(at: CGPoint(x: bounds.midX, y: bounds.maxY)))
    }

    func testManagerTargetTracksAppliedGeometryAndOrderedOutRails() throws {
        let manager = TabRailManager(motionPolicy: MotionPolicy(animationsEnabled: false))
        defer { manager.removeAll() }
        let tokens = (0 ..< 2).map { WindowToken(pid: 941_701, windowId: $0 + 1) }
        let tile = CGRect(x: 300, y: 200, width: 600, height: 600)
        let info = TabRailInfo(
            workspaceId: WorkspaceDescriptor.ID(), owner: .dwindleTile(UUID()), plannedSeq: 1,
            tileFrame: tile, tabCount: tokens.count, activeVisualIndex: 0, activeWindowId: nil,
            tabs: tokens.enumerated().map { index, token in
                TabRailTabInfo(
                    visualIndex: index, token: token, windowId: token.windowId,
                    appName: nil, title: nil, isActive: index == 0
                )
            }
        )
        manager.updateRails([info])
        let window = try XCTUnwrap(manager.existingWindow(for: info.key) as? TabRailWindow)
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        let layout = TabRailLayout(
            tabCount: tokens.count, bounds: view.bounds, activeVisualIndex: 0, scale: window.backingScaleFactor
        )
        let marker = try XCTUnwrap(layout.items.first).pillRect
        let shift = CGSize(width: tile.width, height: tile.height / 2)
        let moved = tile.offsetBy(dx: shift.width, dy: shift.height)
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: moved, visibleTileFrame: moved)])
        let point = CGPoint(x: window.appliedFrame.minX + marker.midX, y: window.appliedFrame.minY + marker.midY)
        let target = try XCTUnwrap(manager.dragTarget(at: point))
        XCTAssertEqual(target.workspaceId, info.workspaceId)
        XCTAssertEqual(target.owner, info.owner)
        XCTAssertEqual(target.token, tokens[0])
        XCTAssertEqual(target.visualIndex, 0)
        XCTAssertNil(manager.dragTarget(at: CGPoint(x: point.x - shift.width, y: point.y - shift.height)))
        manager.applyAnimationGeometry([.init(key: info.key, tileFrame: moved, visibleTileFrame: .null)])
        XCTAssertFalse(window.isOrderedIn)
        XCTAssertNil(manager.dragTarget(at: point))
    }
}
