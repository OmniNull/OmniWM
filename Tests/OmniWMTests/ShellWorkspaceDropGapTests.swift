// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMShellCore
import XCTest

@MainActor
final class ShellWorkspaceDropGapTests: XCTestCase {
    private let windowIDs = (1 ... 4).map { "ow_\($0)" }

    private func bar(gap: ShellBarDrag.Gap?) -> ShellBarData {
        var bar = ShellBarData()
        let items = windowIDs.map { id in
            ShellBarItem(
                id: id, bundle: "com.apple.finder", name: "Finder", focused: false, count: 1, hidden: 0,
                windows: [ShellBarWindow(id: id, title: "App", focused: false, hidden: false)]
            )
        }
        bar.workspaces = [ShellBarWorkspace(id: "1", name: "1", focused: true, windows: items)]
        bar.drag = gap.map { ShellBarDrag(sources: [windowIDs[0]], workspaces: ["1"], gaps: [$0]) }
        return bar
    }

    private func frames(of widget: ShellRenderedWidget) -> [UInt64: Rect] {
        var frames: [UInt64: Rect] = [:]
        for element in widget.surface.layout.core.elements(matching: { _ in true }) {
            frames[widget.surface.layout.core.key(of: element)] = widget.surface.layout.core.absoluteFrame(of: element)
        }
        return frames
    }

    func testWorkspaceIconsPartAroundADropGap() throws {
        let gap = ShellBarDrag.Gap(workspace: "1", before: 3)
        let widget = try ShellRenderedWidget(source: ShellRenderedWidget.bundledSource("workspaces"))
        widget.render(bar(gap: nil))
        let resting = frames(of: widget)
        widget.render(bar(gap: gap))
        let parted = frames(of: widget)
        let shifted = widget.tree().filter { $0.layout.dx != 0 }
        XCTAssertEqual(shifted.count, windowIDs.count)
        XCTAssertEqual(shifted.count { $0.layout.dx < 0 }, gap.before - 1)
        for node in shifted {
            let before = try XCTUnwrap(resting[node.key])
            let after = try XCTUnwrap(parted[node.key])
            XCTAssertEqual(
                after,
                Rect(x: before.x + node.layout.dx, y: before.y, width: before.width, height: before.height)
            )
        }
    }
}
