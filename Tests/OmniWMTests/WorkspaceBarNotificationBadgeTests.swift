// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarNotificationBadgeTests: XCTestCase {
    func testBadgesPreserveBarGeometryAcrossOrientationsAndScratchpadPresentations() async {
        let service = await makeService()
        defer { service.stop() }
        let window = makeWindow()
        for orientation in [WorkspaceBarOrientation.horizontal, .vertical] {
            for presentation in [WorkspaceBarScratchpadPresentation.compact, .expanded] {
                for barHeight in [CGFloat(20), 28, 40] {
                    let snapshot = WorkspaceBarSnapshot(
                        projection: WorkspaceBarProjection(
                            items: [WorkspaceBarItem(
                                id: UUID(), name: "1", rawName: "1", isFocused: true,
                                tiledWindows: [window], floatingWindows: []
                            )],
                            scratchpads: [WorkspaceBarScratchpadItem(
                                index: 1, label: "Mail", windows: [window], isVisible: false,
                                presentation: presentation
                            )]
                        ),
                        showLabels: true, showSystemStatsButton: false, backgroundOpacity: 0.1,
                        barHeight: barHeight, accentColor: nil, textColor: nil, orientation: orientation
                    )
                    let plain = NSHostingView(rootView: bar(snapshot: snapshot, service: nil))
                    plain.layoutSubtreeIfNeeded()
                    for mode in [WorkspaceBarNotificationBadgeMode.dot, .text] {
                        service.configure(mode: mode, interval: 5, bundleIDs: ["com.example.mail"])
                        let badged = NSHostingView(rootView: bar(snapshot: snapshot, service: service))
                        badged.layoutSubtreeIfNeeded()
                        XCTAssertEqual(badged.fittingSize, plain.fittingSize)
                    }
                }
            }
        }
    }

    func testShortAndOverflowingTextFitsReservedBadgeSpace() async {
        let sizes: [(CGFloat, CGFloat)] = [(12, 6), (18, 12), (30, 24)]
        for label in ["7", "42", "999+", "123456789 unread messages"] {
            let service = await makeService(label: label)
            defer { service.stop() }
            for (iconSize, maximumWidth) in sizes {
                let host = NSHostingView(rootView: WorkspaceBarNotificationBadge(
                    bundleId: "com.example.mail", iconSize: iconSize
                ).environment(service))
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.width, 0)
                XCTAssertLessThanOrEqual(host.fittingSize.width, maximumWidth)
                XCTAssertLessThanOrEqual(host.fittingSize.height, iconSize)
            }
        }
    }

    private func makeService(label: String = "123456789 unread messages") async -> WorkspaceBarBadgeService {
        let refreshed = expectation(description: "Initial badge read published")
        let service = WorkspaceBarBadgeService(
            notificationCenter: NotificationCenter(),
            read: { _, _ in
                DockBadgeReadResult(labels: ["com.example.mail": label], dockPID: 42)
            },
            sleep: { _ in
                refreshed.fulfill()
                throw CancellationError()
            }
        )
        service.configure(mode: .text, interval: 5, bundleIDs: ["com.example.mail"])
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(service.label(for: "com.example.mail"), label)
        return service
    }

    private func bar(snapshot: WorkspaceBarSnapshot, service: WorkspaceBarBadgeService?) -> WorkspaceBarView {
        WorkspaceBarView(
            model: WorkspaceBarModel(snapshot: snapshot),
            motionPolicy: MotionPolicy(animationsEnabled: false),
            onFocusWorkspace: { _ in },
            onFocusWindow: { _ in },
            onActivateScratchpad: { _ in },
            notificationBadges: service
        )
    }

    private func makeWindow() -> WorkspaceBarWindowItem {
        let token = WindowToken(pid: 42, windowId: 1)
        return WorkspaceBarWindowItem(
            id: token, handle: WindowHandle(id: token), windowId: 1, appName: "Mail",
            bundleId: "com.example.mail", icon: nil, isFocused: false, windowCount: 3,
            hiddenWindowCount: 1, allWindows: []
        )
    }
}
