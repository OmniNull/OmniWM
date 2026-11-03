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
}
