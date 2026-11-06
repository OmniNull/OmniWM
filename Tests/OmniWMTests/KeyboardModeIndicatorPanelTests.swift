// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class KeyboardModeIndicatorPanelTests: XCTestCase {
    private let left = monitor(1, CGRect(x: 0, y: 0, width: 1440, height: 900))
    private let right = monitor(2, CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    private let guide = [KeyboardModeGuideEntry(key: "H", title: "Focus Left")]

    private static func monitor(_ id: CGDirectDisplayID, _ frame: CGRect) -> Monitor {
        Monitor(
            id: .init(displayId: id),
            displayId: id,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "M\(id)"
        )
    }

    private func makeIndicator() -> (KeyboardModeIndicatorController, OwnedWindowRegistry) {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        return (KeyboardModeIndicatorController(ownedWindowRegistry: registry), registry)
    }

    func testShowsOnePassivePillPerDisplayAndTheGuideOnlyOnTheInteractionDisplay() throws {
        let (indicator, registry) = makeIndicator()
        defer { indicator.destroy() }

        indicator.show(kind: .prefix, guide: guide, monitors: [left, right], interactionMonitorId: right.id)

        let panels = registry.visibleWindows(kind: .keyboardModeIndicator).compactMap { $0 as? NSPanel }
        XCTAssertEqual(panels.count, 2)
        for panel in panels {
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        }
        let leftPanel = try XCTUnwrap(panels.first { left.frame.contains($0.frame) })
        let rightPanel = try XCTUnwrap(panels.first { right.frame.contains($0.frame) })
        XCTAssertGreaterThan(rightPanel.frame.height, leftPanel.frame.height)
        XCTAssertEqual(leftPanel.frame.minY, left.visibleFrame.minY + KeyboardModeIndicatorController.bottomInset)
        XCTAssertEqual(leftPanel.frame.midX, left.visibleFrame.midX)
        XCTAssertTrue(registry.visibleWindows(kind: .utility).isEmpty)
    }

    func testGuideStaysOnItsDisplayUntilTheModeChangesAndHidesOnNormal() {
        let (indicator, registry) = makeIndicator()
        defer { indicator.destroy() }

        indicator.show(kind: .window, guide: guide, monitors: [left, right], interactionMonitorId: left.id)
        indicator.show(kind: .window, guide: guide, monitors: [left, right], interactionMonitorId: right.id)
        XCTAssertEqual(indicator.guideMonitorId, left.id)

        indicator.show(kind: .paused, guide: [], monitors: [right], interactionMonitorId: right.id)
        XCTAssertEqual(indicator.guideMonitorId, right.id)
        XCTAssertEqual(registry.visibleWindows(kind: .keyboardModeIndicator).count, 1)

        indicator.show(kind: .normal, guide: [], monitors: [left, right], interactionMonitorId: left.id)
        XCTAssertTrue(registry.visibleWindows(kind: .keyboardModeIndicator).isEmpty)
        XCTAssertEqual(indicator.kind, .normal)
    }

    func testGuideIsCappedAndFitsTheDisplay() {
        var guide = (0 ..< 40).map { KeyboardModeGuideEntry(key: "K\($0)", title: "Action \($0)") }
        guide[0] = KeyboardModeGuideEntry(key: "L", title: String(repeating: "Very long shell widget name ", count: 20))

        XCTAssertEqual(KeyboardModeIndicatorView.shownGuide(guide).count, 24)
        for maxWidth in [CGFloat(1400), 600, 360] {
            let view = NSHostingView(rootView: KeyboardModeIndicatorView(
                kind: .window,
                guide: guide,
                maxWidth: maxWidth
            ))
            XCTAssertLessThanOrEqual(view.fittingSize.width, maxWidth, "\(maxWidth)")
            XCTAssertLessThan(view.fittingSize.height, 500)
        }
    }

    func testBindingChangesRefreshTheGuideWithoutMovingIt() throws {
        let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "KeyboardModeGuide",
            ownedWindowRegistry: registry
        )
        defer { controller.keyboardModeIndicator.destroy() }
        let keyH = KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: 0)
        controller.settings.updateModeKey(for: "focus.left", newModeKey: keyH)
        controller.updateHotkeyBindings(controller.settings.hotkeyBindings)
        controller.keyboardModeDidChange(.window)
        let guideMonitorId = try XCTUnwrap(controller.keyboardModeIndicator.guideMonitorId)
        XCTAssertEqual(shownGuide(registry).map(\.title), [HotkeyCommand.focus(.left).localizedDisplayName])

        controller.settings.updateModeKey(for: "focus.left", newModeKey: nil)
        controller.settings.updateModeKey(for: "focus.right", newModeKey: keyH)
        controller.updateHotkeyBindings(controller.settings.hotkeyBindings)

        XCTAssertEqual(shownGuide(registry).map(\.title), [HotkeyCommand.focus(.right).localizedDisplayName])
        XCTAssertEqual(controller.keyboardModeIndicator.guideMonitorId, guideMonitorId)
    }

    private func shownGuide(_ registry: OwnedWindowRegistry) -> [KeyboardModeGuideEntry] {
        registry.visibleWindows(kind: .keyboardModeIndicator).flatMap {
            ($0.contentView as? NSHostingView<KeyboardModeIndicatorView>)?.rootView.guide ?? []
        }
    }
}
