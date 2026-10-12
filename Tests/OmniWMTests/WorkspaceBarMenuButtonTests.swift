// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarMenuButtonTests: XCTestCase {
    func testPrimaryMenuButtonMatchesMeasurementAndDoesNotClaimWorkspacePresses() throws {
        for orientation in [WorkspaceBarOrientation.horizontal, .vertical] {
            for slice in [WorkspaceBarIslandSlice.all, .active, .secondary] {
                let item = WorkspaceBarItem(
                    id: UUID(), name: "1", rawName: "1", isFocused: slice != .secondary,
                    tiledWindows: [], floatingWindows: []
                )
                let snapshot = WorkspaceBarSnapshot(
                    projection: WorkspaceBarProjection(items: [item], scratchpads: []),
                    showLabels: true, showSystemStatsButton: false, backgroundOpacity: 0.1,
                    barHeight: 28, accentColor: nil, textColor: nil, orientation: orientation
                )
                let interaction = WorkspaceBarIslandInteraction()
                let host = NSHostingView(rootView: WorkspaceBarView(
                    model: WorkspaceBarModel(snapshot: snapshot),
                    slice: slice,
                    motionPolicy: MotionPolicy(animationsEnabled: false),
                    onFocusWorkspace: { _ in },
                    onFocusWindow: { _ in },
                    onActivateScratchpad: { _ in },
                    interaction: interaction
                ))
                let measurement = NSHostingView(rootView: WorkspaceBarMeasurementView(snapshot: snapshot, slice: slice))
                measurement.layoutSubtreeIfNeeded()
                let size = measurement.fittingSize
                let panel = WorkspaceBarPanel.defaultPanel()
                panel.contentView = host
                panel.setFrame(CGRect(origin: CGPoint(x: 200, y: 300), size: size), display: false)
                defer { panel.close() }
                host.layoutSubtreeIfNeeded()

                let buttons = menuButtons(in: host)
                XCTAssertEqual(buttons.count, slice == .secondary ? 0 : 1, "\(orientation) \(slice)")
                guard let button = buttons.first else { continue }
                XCTAssertEqual(button.frame.width, 24, accuracy: 0.5)
                XCTAssertEqual(button.frame.height, 24, accuracy: 0.5)
                let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
                ))
                XCTAssertTrue(WorkspaceBarMenuButton.contains(event, in: panel))
                let local = host.workspaceBarLocalPoint(forWindowPoint: point)
                XCTAssertNil(interaction.target(at: local))
                var tracker = WorkspaceBarPressTracker()
                XCTAssertEqual(
                    tracker.handle(.rightDown, modifiers: [], target: interaction.target(at: local)),
                    .passThrough
                )
                let screenRect = panel.convertToScreen(button.convert(button.bounds, to: nil))
                XCTAssertTrue(panel.frame.contains(screenRect), "\(orientation) \(slice)")
            }
        }
    }

    func testMenuButtonDeliversRightClickAndAccessibilityPressThroughSameCallback() throws {
        var events: [NSEvent.EventType?] = []
        var receivedAnchor: NSView?
        let host = NSHostingView(rootView: WorkspaceBarMenuButton(
            iconSize: 18,
            textColor: nil,
            isSecureInputActive: false
        ) { anchor, event in
            events.append(event?.type)
            receivedAnchor = anchor
        }.frame(width: 24, height: 24))
        let panel = WorkspaceBarPanel.defaultPanel()
        panel.contentView = host
        panel.setFrame(CGRect(x: 200, y: 300, width: 24, height: 24), display: false)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(menuButtons(in: host).first)
        let location = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let rightUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseUp, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))

        button.rightMouseUp(with: rightUp)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0], .rightMouseUp)
        XCTAssertTrue(receivedAnchor === button)
        receivedAnchor = nil
        _ = button.accessibilityPerformPress()
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(receivedAnchor === button)
    }

    func testMenuButtonShowsSecureInputLockOnlyWhileActive() throws {
        let host = NSHostingView(rootView: badgeButton(isSecureInputActive: true))
        host.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(menuButtons(in: host).first)
        XCTAssertEqual(button.image?.isTemplate, false)
        XCTAssertEqual(button.accessibilityValue() as? String, "Secure Input is on")

        host.rootView = badgeButton(isSecureInputActive: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.image?.isTemplate, true)
        XCTAssertNil(button.accessibilityValue() as? String)
    }

    private func badgeButton(isSecureInputActive: Bool) -> WorkspaceBarMenuButton {
        WorkspaceBarMenuButton(iconSize: 18, textColor: nil, isSecureInputActive: isSecureInputActive) { _, _ in }
    }

    private func menuButtons(in view: NSView) -> [WorkspaceBarMenuButton.MenuButton] {
        if let button = view as? WorkspaceBarMenuButton.MenuButton { return [button] }
        return view.subviews.flatMap(menuButtons(in:))
    }
}
