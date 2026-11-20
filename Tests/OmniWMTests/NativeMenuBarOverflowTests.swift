// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class NativeMenuBarOverflowTests: XCTestCase {
    private struct Node {
        var identifier: String?
        var frame: CGRect?
        var children: [Node] = []
    }

    private func overflow(_ menuBars: [Node]) -> NativeMenuBarOverflow {
        NativeMenuBarOverflow(NativeMenuBarOverflow.Tree(
            menuBars: { menuBars },
            children: \.children,
            identifier: \.identifier,
            frame: \.frame
        ))
    }

    private func item(_ x: CGFloat, y: CGFloat = 0, width: CGFloat = 32) -> Node {
        Node(frame: CGRect(x: x, y: y, width: width, height: 33))
    }

    private let barLeftOfNotch = CGRect(x: 0, y: 0, width: 656, height: 33)

    func testExpandedOverflowCoversABarItsItemsLandOn() {
        let expanded = overflow([Node(children: [
            item(431.5),
            item(605.5),
            Node(
                identifier: NativeMenuBarOverflow.expandedIndicator,
                frame: CGRect(x: 898, y: 1, width: 18, height: 30)
            ),
            item(923)
        ])])

        XCTAssertTrue(expanded.covers(barLeftOfNotch))
        XCTAssertFalse(expanded.covers(barLeftOfNotch.offsetBy(dx: 0, dy: 1440)))
    }

    func testCollapsedOverflowLeavesTheBarAlone() {
        let collapsed = overflow([Node(children: [
            item(431.5),
            Node(identifier: "menu-bar-overflow-indicator", frame: CGRect(x: 898, y: 1, width: 18, height: 30)),
            item(923)
        ])])

        XCTAssertEqual(collapsed, NativeMenuBarOverflow())
        XCTAssertFalse(collapsed.covers(barLeftOfNotch))
    }

    func testExpandedOverflowRightOfTheNotchLeavesTheBarAlone() {
        let expanded = overflow([Node(children: [
            Node(
                identifier: NativeMenuBarOverflow.expandedIndicator,
                frame: CGRect(x: 898, y: 1, width: 18, height: 30)
            ),
            item(923),
            item(965),
            Node(frame: .zero)
        ])])

        XCTAssertEqual(expanded.itemFrames.count, 3)
        XCTAssertFalse(expanded.covers(barLeftOfNotch))
    }

    func testOnlyTheExpandedMenuBarCounts() {
        let external = Node(children: [item(-900, y: -1440), item(-500, y: -1440)])
        let builtIn = Node(children: [
            item(500),
            Node(
                identifier: NativeMenuBarOverflow.expandedIndicator,
                frame: CGRect(x: 898, y: 1, width: 18, height: 30)
            )
        ])

        let mixed = overflow([external, builtIn])

        XCTAssertTrue(mixed.covers(barLeftOfNotch))
        XCTAssertFalse(mixed.covers(CGRect(x: -939, y: -1440, width: 1712, height: 30)))
    }
}
