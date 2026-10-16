// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarNotificationBadgeTests: XCTestCase {
    private func item(badge: String) -> ShellBarItem {
        let window = ShellBarWindow(id: "ow_1", title: "Mail", focused: false, hidden: false)
        return ShellBarItem(
            id: "ow_1", bundle: "com.example.mail", name: "Mail", focused: false, count: 3, hidden: 1,
            badge: badge, windows: [window, window, window]
        )
    }

    private func bar(height: Double, vertical: Bool = false, compact: Bool = false, badge: String) -> ShellBarData {
        var bar = ShellBarData()
        bar.style.height = height
        bar.style.vertical = vertical
        bar.workspaces = [ShellBarWorkspace(id: "1", name: "1", focused: true, windows: [item(badge: badge)])]
        bar.scratchpads = [ShellBarScratchpad(
            id: 1, name: "Mail", focused: false, revealed: false, visible: false,
            windows: [item(badge: badge)], compact: compact
        )]
        return bar
    }

    func testBadgesKeepTheBarGeometryAcrossOrientationsAndScratchpadPresentations() throws {
        let widgets = try ["workspaces", "scratchpads"].map(ShellRenderedWidget.init)
        for vertical in [false, true] {
            for compact in [true, false] {
                for height in [20.0, 28, 40] {
                    var data = bar(height: height, vertical: vertical, compact: compact, badge: "123456789 unread")
                    let sizes = ["off", "dot", "text"].map { mode in
                        data.badges = mode
                        return widgets.map { widget in
                            widget.render(data)
                            return widget.surface.size
                        }
                    }
                    XCTAssertEqual(sizes[1], sizes[0], "dot \(vertical) \(compact) \(height)")
                    XCTAssertEqual(sizes[2], sizes[0], "text \(vertical) \(compact) \(height)")
                }
            }
        }
    }

    func testBadgesFitTheIconSlotAndGiveTwoDigitsRoom() throws {
        let widget = try ShellRenderedWidget("workspaces")
        for (height, icon) in [(20.0, 12.0), (28, 18), (40, 30)] {
            var widths: [String: CGFloat] = [:]
            for label in ["7", "42", "999+", "123456789 unread messages"] {
                var data = bar(height: height, badge: label)
                data.badges = "text"
                widget.render(data)
                let badgeHeight = max(9, icon * 0.55)
                let badges = widget.layers().filter {
                    $0.backgroundColor != nil && $0.borderWidth == 0 && abs($0.bounds.height - badgeHeight) < 0.5
                        && abs($0.cornerRadius - badgeHeight / 2) < 0.5
                }
                XCTAssertEqual(badges.count, 1, "\(label) \(height)")
                for badge in badges {
                    XCTAssertGreaterThan(badge.bounds.width, 0)
                    XCTAssertLessThanOrEqual(badge.bounds.width, max(16, icon + 4), "\(label) \(height)")
                    XCTAssertLessThanOrEqual(badge.bounds.height, icon)
                    widths[label] = badge.bounds.width
                }
            }
            XCTAssertGreaterThan(widths["42"] ?? 0, widths["7"] ?? .infinity, "\(height)")
        }
    }
}
