// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellPopoutMorphTests: XCTestCase {
    private let first = CGRect(x: 100, y: 100, width: 200, height: 100)
    private let second = CGRect(x: 50, y: 60, width: 300, height: 140)
    private let morph = ShellAnimation(motion: .ease(seconds: 0.05), speed: 1, curve: ShellCurve(wire: 13, custom: nil))

    private func show(_ panel: ShellPopoutPanel, _ frame: CGRect, morph: ShellAnimation? = nil) {
        panel.show(frame: frame, level: .popUpMenu, chrome: ShellPopoutChrome(), fadeDuration: nil, morph: morph)
    }

    private func settled(after duration: CFTimeInterval) async {
        let probe = CALayer()
        var done = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { done = true }
        let wait = CABasicAnimation(keyPath: "opacity")
        wait.duration = duration
        probe.add(wait, forKey: "wait")
        CATransaction.commit()
        await until { done }
    }

    func testAVisiblePanelMorphsThroughBothFramesAndSettlesOnTheNewOne() async {
        let content = NSView()
        let panel = ShellPopoutPanel(content: content)
        defer { panel.orderOut(nil) }
        show(panel, first)
        show(panel, second, morph: morph)
        XCTAssertEqual(panel.frame, first.union(second))
        XCTAssertEqual(content.frame, CGRect(origin: .zero, size: second.size))
        XCTAssertNotNil(content.layer?.animation(forKey: ShellPopoutPanel.morphBounds))
        XCTAssertNotNil(content.layer?.animation(forKey: ShellPopoutPanel.morphPosition))
        await until { panel.frame == second }
        XCTAssertEqual(content.frame, CGRect(origin: .zero, size: second.size))
    }

    func testANewerPlacementWinsOverAnUnfinishedMorph() async {
        let content = NSView()
        let panel = ShellPopoutPanel(content: content)
        defer { panel.orderOut(nil) }
        let third = CGRect(x: 400, y: 400, width: 120, height: 80)
        show(panel, first)
        show(panel, second, morph: morph)
        show(panel, third)
        XCTAssertEqual(panel.frame, third)
        XCTAssertNil(content.layer?.animation(forKey: ShellPopoutPanel.morphBounds))
        await settled(after: 0.2)
        XCTAssertEqual(panel.frame, third)
        XCTAssertEqual(content.frame, CGRect(origin: .zero, size: third.size))
    }

    func testHiddenPanelsAndPlacementsWithoutAnimationDoNotMorph() {
        let content = NSView()
        let panel = ShellPopoutPanel(content: content)
        defer { panel.orderOut(nil) }
        show(panel, first, morph: morph)
        XCTAssertEqual(panel.frame, first)
        show(panel, second)
        XCTAssertEqual(panel.frame, second)
        XCTAssertNil(content.layer?.animation(forKey: ShellPopoutPanel.morphBounds))
    }
}
