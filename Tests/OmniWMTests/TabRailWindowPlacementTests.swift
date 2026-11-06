// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class TabRailWindowPlacementTests: XCTestCase {
    private final class Rail: TabRailWindow {
        var frontOrders = 0
        var hides = 0
        var orderIns: [UInt32?] = []
        var directOrders: [UInt32] = []
        var frameWrites: [CGRect] = []
        var moves: [CGRect] = []
        var movesSucceed = true
        var appKitMoveEvents = 0

        @objc(_windowMoved:) func recordAppKitMoveEvent(_: NSEvent) {
            appKitMoveEvents += 1
        }

        override func orderFront(_ sender: Any?) {
            frontOrders += 1
            super.orderFront(sender)
        }

        override func hideInWindowServer() {
            hides += 1
        }

        override func orderInWindowServer(above target: UInt32?) {
            orderIns.append(target)
        }

        override func orderDirectly(above target: UInt32) {
            directOrders.append(target)
        }

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            frameWrites.append(frameRect)
            super.setFrame(frameRect, display: flag)
        }

        override func moveInWindowServer(to target: CGRect) -> Bool {
            guard movesSucceed else { return false }
            moves.append(target)
            return true
        }
    }

    private let workspaceId = WorkspaceDescriptor.ID()
    private let owner = TabRailOwner.niriColumn(NodeId())
    private let tile = CGRect(x: 300, y: 100, width: 600, height: 600)
    private let windowId = 41

    private var key: TabRailKey {
        TabRailKey(workspaceId: workspaceId, owner: owner)
    }

    private func makeRail() -> Rail {
        Rail(owner: owner, workspaceId: workspaceId, motionPolicy: MotionPolicy(animationsEnabled: false))
    }

    private func info(
        tile: CGRect? = nil, activeWindowId: Int? = nil, orderingWindowId: Int? = nil
    ) -> TabRailInfo {
        TabRailInfo(
            workspaceId: workspaceId,
            owner: owner,
            plannedSeq: 1,
            tileFrame: tile ?? self.tile,
            tabCount: 2,
            activeVisualIndex: 0,
            activeWindowId: activeWindowId,
            orderingWindowId: orderingWindowId
        )
    }

    func testVisibleRailOrdersDirectlyAgainstItsTargetWithoutAppKit() {
        let rail = makeRail()
        defer { rail.close() }
        let second = windowId + 1

        rail.update(info: info(activeWindowId: windowId), forceOrdering: false)
        XCTAssertEqual(rail.frontOrders, 1)
        XCTAssertEqual(rail.directOrders, [UInt32(windowId)])

        rail.update(info: info(activeWindowId: second), forceOrdering: false)
        rail.update(info: info(activeWindowId: second), forceOrdering: true)

        XCTAssertEqual(rail.frontOrders, 1)
        XCTAssertEqual(rail.directOrders, [UInt32(windowId), UInt32(second), UInt32(second)])
    }

    func testRailOrdersAboveTheRingWhenTheRingSitsOnItsTarget() {
        let rail = makeRail()
        defer { rail.close() }
        let ring = UInt32(windowId + 1)
        let other = windowId + 2
        rail.ringOrderedAbove = { [windowId] in $0 == UInt32(windowId) ? ring : nil }

        rail.update(info: info(activeWindowId: windowId), forceOrdering: false)
        rail.update(info: info(activeWindowId: other), forceOrdering: false)

        XCTAssertEqual(rail.directOrders, [ring, UInt32(other)])
    }

    func testRailOrdersAgainstThePictureStandingInForItsWindow() {
        let rail = makeRail()
        defer { rail.close() }
        let picture = windowId + 1

        rail.update(info: info(activeWindowId: windowId, orderingWindowId: picture), forceOrdering: false)

        XCTAssertEqual(rail.directOrders, [UInt32(picture)])
    }

    func testRailWithoutATargetStillComesInThroughAppKit() {
        let rail = makeRail()
        defer { rail.close() }

        rail.update(info: info(), forceOrdering: true)
        rail.update(info: info(), forceOrdering: true)

        XCTAssertEqual(rail.frontOrders, 2)
        XCTAssertTrue(rail.directOrders.isEmpty)
    }

    func testAnimationOrdersDirectlyWhenItsTargetChanges() {
        let rail = makeRail()
        defer { rail.close() }
        let picture = windowId + 1
        rail.update(info: info(activeWindowId: windowId), forceOrdering: false)

        rail.updateAnimationGeometry(TabRailGeometryCommand(
            key: key, tileFrame: tile, visibleTileFrame: tile, orderingWindowId: picture
        ))

        XCTAssertEqual(rail.frontOrders, 1)
        XCTAssertEqual(rail.directOrders, [UInt32(windowId), UInt32(picture)])
    }

    func testRailLeavesAndReturnsThroughTheWindowServer() {
        let rail = makeRail()
        defer { rail.close() }
        let offDisplay = CGRect(origin: tile.origin, size: .zero)
        rail.update(info: info(activeWindowId: windowId), forceOrdering: false)

        rail.update(info: info(tile: offDisplay, activeWindowId: windowId), forceOrdering: false)
        rail.updateAnimationGeometry(TabRailGeometryCommand(
            key: key,
            tileFrame: offDisplay,
            visibleTileFrame: offDisplay
        ))
        XCTAssertEqual(rail.hides, 1)

        rail.update(info: info(activeWindowId: windowId), forceOrdering: false)

        XCTAssertEqual(rail.frontOrders, 1)
        XCTAssertEqual(rail.orderIns, [UInt32(windowId)])
        XCTAssertEqual(rail.directOrders, [UInt32(windowId), UInt32(windowId)])
    }

    func testRailStraddlingADisplayEdgeStaysOutOfAppKit() throws {
        let rail = makeRail()
        defer { rail.close() }
        let display = try XCTUnwrap(NSScreen.screens.first).frame
        rail.update(info: info(activeWindowId: windowId), forceOrdering: false)
        let moved = tile.offsetBy(dx: tile.width, dy: 0)
        rail.updateAnimationGeometry(TabRailGeometryCommand(key: key, tileFrame: moved, visibleTileFrame: moved))
        let writes = rail.frameWrites
        let moves = rail.moves
        var atEdge = tile
        atEdge.origin.x = display.minX

        rail.update(info: info(tile: atEdge, activeWindowId: windowId), forceOrdering: false)

        let frame = TabRailPlacement.frame(for: atEdge, tabCount: 2, style: .compact)
        XCTAssertFalse(display.contains(frame.center))
        XCTAssertEqual(rail.frameWrites, writes)
        XCTAssertEqual(rail.moves, moves + [frame])
    }

    func testRejectedMoveFallsBackToAppKit() {
        let rail = makeRail()
        defer { rail.close() }
        rail.update(info: info(activeWindowId: windowId), forceOrdering: false)
        let writes = rail.frameWrites
        rail.movesSucceed = false
        let moved = tile.offsetBy(dx: tile.width, dy: 0)

        rail.updateAnimationGeometry(TabRailGeometryCommand(key: key, tileFrame: moved, visibleTileFrame: moved))

        let frame = TabRailPlacement.frame(for: moved, tabCount: 2, style: .compact)
        XCTAssertEqual(rail.frameWrites, writes + [frame])
        XCTAssertEqual(rail.appliedFrame, frame)
    }

    func testRailIgnoresWindowServerMoveEvents() throws {
        let rail = makeRail()
        defer { rail.close() }
        rail.update(info: info(activeWindowId: windowId), forceOrdering: false)

        rail.sendEvent(try XCTUnwrap(NSEvent.otherEvent(
            with: .appKitDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: rail.windowNumber, context: nil,
            subtype: NSEvent.EventSubtype.windowMoved.rawValue, data1: 0, data2: 0
        )))

        XCTAssertEqual(rail.appKitMoveEvents, 0)
    }

    func testPlacementStaysOnADisplayUntilItsCenterReachesAnother() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = left.offsetBy(dx: left.width, dy: 0)
        let size = CGSize(width: 100, height: 100)
        func target(centeredOn center: CGPoint) -> CGRect {
            CGRect(origin: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), size: size)
        }
        func stays(_ target: CGRect, current: CGRect?) -> Bool {
            WindowServerPlacementPolicy.staysOnDisplay(
                target,
                current: current,
                centerIsOnADisplay: [left, right].contains { $0.contains(target.center) }
            )
        }
        let inset = size.width / 4

        XCTAssertTrue(stays(target(centeredOn: CGPoint(x: left.midX, y: left.midY)), current: left))
        XCTAssertTrue(stays(target(centeredOn: CGPoint(x: left.maxX - inset, y: left.midY)), current: left))
        XCTAssertFalse(stays(target(centeredOn: CGPoint(x: left.maxX + inset, y: left.midY)), current: left))
        XCTAssertTrue(stays(target(centeredOn: CGPoint(x: left.minX - inset, y: left.midY)), current: left))
        XCTAssertFalse(stays(target(centeredOn: CGPoint(x: left.minX - size.width, y: left.midY)), current: left))
        XCTAssertFalse(stays(target(centeredOn: CGPoint(x: left.midX, y: left.midY)), current: nil))
    }
}
