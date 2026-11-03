// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class StatusBarLayoutTests: XCTestCase {
    func testDisabledLayoutPreservesTheExistingImageAndTitle() {
        let icon = OmniWMBrandMark.statusItemImage(pointSize: 18)
        XCTAssertTrue(StatusBarController.statusButtonImage(icon: icon, layout: nil) === icon)
        XCTAssertEqual(
            StatusBarController.statusButtonTitle(workspaceLabel: "Code", focusedAppName: "Xcode"),
            " Code \u{2013} Xcode"
        )
        XCTAssertEqual(
            StatusBarController.statusButtonTitle(workspaceLabel: nil, focusedAppName: nil, modeTitle: "Paused"),
            " Paused"
        )
    }

    func testBothLayoutsProduceVisibleGlyphsAndPreserveStateColors() throws {
        for layout in [ActiveLayoutKind.niri, .dwindle] {
            let image = try XCTUnwrap(StatusBarController.statusButtonImage(icon: nil, layout: layout))
            XCTAssertTrue(image.isTemplate)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            XCTAssertTrue((0 ..< bitmap.pixelsWide).contains { x in
                (0 ..< bitmap.pixelsHigh).contains { y in
                    (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
                }
            })

            let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                NSColor.systemRed.setFill()
                rect.fill()
                return true
            }
            let combined = try XCTUnwrap(StatusBarController.statusButtonImage(icon: icon, layout: layout))
            XCTAssertFalse(combined.isTemplate)
            XCTAssertGreaterThan(combined.size.width, image.size.width)
            let combinedBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(combined.tiffRepresentation)))
            let center = Int(9 * CGFloat(combinedBitmap.pixelsWide) / combined.size.width)
            let color = try XCTUnwrap(combinedBitmap.colorAt(x: center, y: combinedBitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.redComponent, color.greenComponent)
        }
    }

    func testNativeStatusButtonKeepsTheLayoutImageWhenTheBrandIconIsHidden() throws {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        button.image = StatusBarController.statusButtonImage(icon: nil, layout: .niri)
        button.imagePosition = StatusBarController.labeledImagePosition(
            showIcon: false, hasStateIcon: false, showLayout: true
        )
        let imageRect = try XCTUnwrap(button.cell?.imageRect(forBounds: NSRect(x: 0, y: 0, width: 64, height: 24)))
        XCTAssertFalse(imageRect.isEmpty)
        XCTAssertEqual(
            StatusBarController.labeledImagePosition(showIcon: false, hasStateIcon: false),
            .noImage
        )
    }

    func testLayoutsUseDistinctExpectedGlyphs() throws {
        var masks: [[Bool]] = []
        for (layout, symbol) in [
            (ActiveLayoutKind.niri, "rectangle.split.3x1"),
            (.dwindle, "rectangle.split.2x2")
        ] {
            let image = try XCTUnwrap(StatusBarController.statusButtonImage(icon: nil, layout: layout))
            let expected = try XCTUnwrap(NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)))
            let mask = try glyphMask(image)
            let expectedMask = try glyphMask(expected)
            XCTAssertTrue(mask == expectedMask, "\(layout) should use \(symbol)")
            masks.append(mask)
        }
        XCTAssertNotEqual(masks[0], masks[1])
    }

    private func glyphMask(_ image: NSImage) throws -> [Bool] {
        let native = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        let nativeBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(native.tiffRepresentation)))
        let raster = NSImage(cgImage: try XCTUnwrap(nativeBitmap.cgImage), size: image.size)
        let canvas = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            raster.draw(in: rect)
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(canvas.tiffRepresentation)))
        return (0 ..< bitmap.pixelsHigh).flatMap { y in
            (0 ..< bitmap.pixelsWide).map { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }
        }
    }

    func testLayoutAccessibilityRetainsExistingStateInformation() {
        for layout in [ActiveLayoutKind.niri, .dwindle] {
            let name = StatusBarController.layoutDisplayName(layout)
            XCTAssertEqual(
                StatusBarController.statusButtonAccessibilityValue(
                    workspaceLabel: nil, focusedAppName: nil,
                    isRecording: false, isSecureInputActive: false, layout: layout
                ),
                name
            )
            XCTAssertEqual(
                StatusBarController.statusButtonAccessibilityValue(
                    workspaceLabel: "Code", focusedAppName: "Xcode",
                    isRecording: true, isSecureInputActive: true, layout: layout
                ),
                "Recording diagnostics, Secure Input is on, Workspace Code, Focused app Xcode, " + name
            )
        }
    }

    func testLayoutOnlyKeepsTheStatusItemRefreshConsumerEnabled() {
        let controller = WindowAdmissionTestSupport.controller(prefix: "StatusBarLayout")
        controller.settings.workspaceBar.enabled = false
        let statusBar = StatusBarController(
            settings: controller.settings, controller: controller, hiddenBarController: controller.hiddenBarController
        )
        controller.statusBarController = statusBar
        XCTAssertFalse(controller.statusBarRefreshIsEnabled)
        controller.settings.statusBar.showLayout = true
        XCTAssertTrue(controller.statusBarRefreshIsEnabled)
        XCTAssertTrue(controller.hasWorkspaceBarDataConsumers)
        controller.settings.statusBar.showLayout = false
        XCTAssertFalse(controller.statusBarRefreshIsEnabled)
    }

    func testMissingWorkspaceKeepsTheHiddenBrandOffWithoutLosingTheMenuButton() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "StatusBarMissingWorkspace")
        controller.hotkeysEnabled = false
        controller.settings.workspaceBar.enabled = false
        controller.settings.hiddenBar.enabled = false
        controller.settings.statusBar.showLayout = true
        controller.settings.statusBar.showWorkspaceName = false
        controller.settings.statusBar.showIcon = false
        controller.workspaceManager.commitMonitorSessions([:])
        let suite = "StatusBarMissingWorkspaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let statusBar = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: controller.hiddenBarController,
            statusItemDefaults: defaults
        )
        controller.statusBarController = statusBar
        defer {
            statusBar.cleanup()
            defaults.removePersistentDomain(forName: suite)
        }
        statusBar.setup()
        let button = try XCTUnwrap(statusBar.statusButton)
        let cell = try XCTUnwrap(button.cell)
        let bounds = NSRect(x: 0, y: 0, width: 64, height: 24)
        XCTAssertNil(controller.activeStatusBarWorkspaceSummary())
        XCTAssertTrue(cell.imageRect(forBounds: bounds).isEmpty)
        XCTAssertEqual(button.title, " \u{2026}")
        XCTAssertEqual(button.imagePosition, .noImage)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.target === statusBar)
        XCTAssertNotNil(button.action)
        XCTAssertGreaterThan(cell.cellSize.width, 0)
        XCTAssertEqual(button.accessibilityValue() as? String, "Window manager controls")

        controller.settings.statusBar.showIcon = true
        statusBar.refreshWorkspaces()
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.imagePosition, .imageOnly)

        controller.settings.statusBar.showIcon = false
        statusBar.refreshWorkspaces()
        XCTAssertTrue(cell.imageRect(forBounds: bounds).isEmpty)
        XCTAssertEqual(button.title, " \u{2026}")

        controller.keyboardModeKind = .paused
        statusBar.refreshWorkspaces()
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.title, " Paused")
        XCTAssertEqual(button.imagePosition, .imageLeft)

        controller.keyboardModeKind = .normal
        controller.settings.statusBar.showLayout = false
        statusBar.refreshWorkspaces()
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.imagePosition, .imageOnly)
    }
}
