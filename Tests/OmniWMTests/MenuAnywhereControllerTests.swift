// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
private final class MenuTrackingProbe: NSMenu {
    private nonisolated let cancellations = Mutex(0)

    var cancellationCount: Int {
        cancellations.withLock { $0 }
    }

    override func cancelTracking() {
        cancellations.withLock { $0 += 1 }
    }
}

@MainActor
final class MenuAnywhereControllerTests: XCTestCase {
    func testLoadedItemsCommitOnceAndPreserveDisabledState() {
        let enabled = NSMenuItem(title: "Enabled", action: nil, keyEquivalent: "")
        let disabled = NSMenuItem(title: "Disabled", action: nil, keyEquivalent: "")
        disabled.isEnabled = false
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return .loaded([enabled, disabled])
        }
        let menu = rootedMenu()

        controller.menuNeedsUpdate(menu)
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(loadCount, 1)
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.count, 2)
        XCTAssertTrue(menu.items[0] === enabled)
        XCTAssertTrue(menu.items[1] === disabled)
        XCTAssertFalse(menu.items[1].isEnabled)
    }

    func testAuthoritativeEmptyCommitsDisabledStatusOnce() {
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return .loaded([])
        }
        let menu = rootedMenu()

        controller.menuNeedsUpdate(menu)
        let status = menu.items.first
        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertTrue(menu.items.first === status)
        XCTAssertEqual(status?.title, "(No items)")
        XCTAssertFalse(status?.isEnabled ?? true)
    }

    func testUnavailableCommitsStatusAndFreshMenuCanRecover() {
        let recovered = NSMenuItem(title: "Recovered", action: nil, keyEquivalent: "")
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return loadCount == 1 ? .unavailable : .loaded([recovered])
        }
        let firstMenu = rootedMenu()

        controller.menuNeedsUpdate(firstMenu)
        controller.menuNeedsUpdate(firstMenu)

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(firstMenu.items.count, 1)
        XCTAssertEqual(firstMenu.items.first?.title, "(Unavailable)")
        XCTAssertFalse(firstMenu.items.first?.isEnabled ?? true)

        let secondMenu = rootedMenu()
        controller.menuNeedsUpdate(secondMenu)

        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(secondMenu.items.count, 1)
        XCTAssertTrue(secondMenu.items.first === recovered)
    }

    func testLiteralLoadingTitleIsNotTreatedAsPlaceholder() {
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return .unavailable
        }
        let menu = rootedMenu()
        let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
        menu.addItem(item)

        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertTrue(menu.items.first === item)
        XCTAssertFalse(menu.autoenablesItems)
    }

    func testRootlessMenuDoesNotLoad() {
        var loadCount = 0
        let controller = MenuAnywhereController { _, _, _ in
            loadCount += 1
            return .unavailable
        }
        let menu = NSMenu(title: "Rootless")

        controller.menuNeedsUpdate(menu)

        XCTAssertEqual(loadCount, 0)
        XCTAssertTrue(menu.items.isEmpty)
        XCTAssertFalse(menu.autoenablesItems)
    }

    func testControllerDoesNotImplementMenuWillOpen() {
        let controller = MenuAnywhereController { _, _, _ in .unavailable }

        XCTAssertFalse(controller.responds(to: #selector(NSMenuDelegate.menuWillOpen(_:))))
    }

    func testAnchoredRootLoadsExplicitAppAndCleansItemsAfterTracking() {
        let app = NSRunningApplication.current
        let element = AXUIElementCreateApplication(91_640)
        let item = NSMenuItem(title: "Action", action: nil, keyEquivalent: "")
        var tracking: [Bool] = []
        var rootLoads = 0
        var presented: NSMenu?
        let controller = MenuAnywhereController(
            menuLoader: { pid, content, target, action in
                rootLoads += 1
                XCTAssertEqual(pid, app.processIdentifier)
                XCTAssertEqual(content, .application)
                item.representedObject = element
                item.target = target
                item.action = action
                return .loaded([item])
            },
            menuPresenter: { menu, _ in
                presented = menu
                XCTAssertEqual(tracking, [true])
                XCTAssertEqual(menu.items.map(\.title), ["Action"])
                XCTAssertFalse(menu.autoenablesItems)
                XCTAssertNotNil(item.representedObject)
                XCTAssertNotNil(item.target)
                XCTAssertNotNil(item.action)
            },
            submenuLoader: { _, _, _ in
                XCTFail("Root contents must load before native tracking")
                return .unavailable
            }
        )
        controller.onMenuTrackingChanged = { tracking.append($0) }

        controller.showNativeMenu(
            for: app,
            content: .application,
            anchor: CGRect(x: 500, y: 800, width: 20, height: 24),
            edge: .below,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 1000)
        )

        XCTAssertEqual(rootLoads, 1)
        XCTAssertEqual(tracking, [true, false])
        XCTAssertTrue(presented?.items.isEmpty == true)
        XCTAssertNil(item.representedObject)
        XCTAssertNil(item.target)
        XCTAssertNil(item.action)
    }

    func testAnchoredRootSeparatesEmptyAndUnavailableStatuses() {
        let cases: [(MenuSubmenuLoadResult, String)] = [
            (.loaded([]), "(No items)"),
            (.unavailable, "(Unavailable)")
        ]
        for (result, title) in cases {
            var presented = false
            let controller = MenuAnywhereController(
                menuLoader: { _, content, _, _ in
                    XCTAssertEqual(content, .apple)
                    return result
                },
                menuPresenter: { menu, _ in
                    presented = true
                    XCTAssertEqual(menu.items.count, 1)
                    XCTAssertEqual(menu.items.first?.title, title)
                    XCTAssertFalse(menu.items.first?.isEnabled ?? true)
                },
                submenuLoader: { _, _, _ in .unavailable }
            )

            controller.showNativeMenu(
                for: .current,
                content: .apple,
                anchor: CGRect(x: 500, y: 800, width: 20, height: 24),
                edge: .below,
                visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 1000)
            )

            XCTAssertTrue(presented)
        }
    }

    func testAnchoredMenuRespectsEveryBarEdgeAndVisibleScreenBounds() {
        let anchor = CGRect(x: 550, y: 500, width: 24, height: 24)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 1000)
        let edges: [PopupAttachment.Edge] = [.below, .above, .left, .right]
        for edge in edges {
            let controller = MenuAnywhereController(
                menuLoader: { _, _, _, _ in
                    .loaded([NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")])
                },
                menuPresenter: { menu, point in
                    let frame = CGRect(
                        x: point.x, y: point.y - menu.size.height,
                        width: menu.size.width, height: menu.size.height
                    )
                    XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX + 8)
                    XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX - 8)
                    XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + 8)
                    XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
                    switch edge {
                    case .below: XCTAssertLessThanOrEqual(frame.maxY, anchor.minY - PopupAttachment.gap)
                    case .above: XCTAssertGreaterThanOrEqual(frame.minY, anchor.maxY + PopupAttachment.gap)
                    case .left: XCTAssertLessThanOrEqual(frame.maxX, anchor.minX - PopupAttachment.gap)
                    case .right: XCTAssertGreaterThanOrEqual(frame.minX, anchor.maxX + PopupAttachment.gap)
                    }
                },
                submenuLoader: { _, _, _ in .unavailable }
            )

            controller.showNativeMenu(
                for: .current, content: .application,
                anchor: anchor, edge: edge, visibleFrame: visibleFrame
            )
        }
    }

    func testCancellationTargetsOnlyActiveMenuAndOverlappingRequestDoesNotReload() {
        let menu = MenuTrackingProbe()
        var rootLoads = 0
        var submenuLoads = 0
        let controller = MenuAnywhereController(
            menuLoader: { _, _, _, _ in
                rootLoads += 1
                return .loaded([NSMenuItem(title: "Menu", action: nil, keyEquivalent: "")])
            },
            menuPresenter: { active, _ in
                XCTAssertTrue(active === menu)
                guard let controller = active.delegate as? MenuAnywhereController else {
                    XCTFail("Missing menu tracking delegate")
                    return
                }
                active.axRootElement = AXUIElementCreateApplication(91_650)
                controller.menuNeedsUpdate(active)
                controller.cancelTracking()
                XCTAssertEqual(menu.cancellationCount, 1)
                controller.showNativeMenu(
                    for: .current, content: .apple,
                    anchor: .zero, edge: .below,
                    visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 1000)
                )
                XCTAssertEqual(rootLoads, 1)
            },
            makeMenu: { menu },
            submenuLoader: { _, _, _ in
                submenuLoads += 1
                return .unavailable
            }
        )
        controller.cancelTracking()
        XCTAssertEqual(menu.cancellationCount, 0)
        controller.showNativeMenu(
            for: .current, content: .application,
            anchor: CGRect(x: 500, y: 800, width: 20, height: 24), edge: .below,
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 1000)
        )
        controller.cancelTracking()

        XCTAssertEqual(rootLoads, 1)
        XCTAssertEqual(submenuLoads, 0)
        XCTAssertEqual(menu.cancellationCount, 1)
    }

    private func rootedMenu() -> NSMenu {
        let menu = NSMenu(title: "Submenu")
        menu.axRootElement = AXUIElementCreateApplication(91_500)
        return menu
    }
}
