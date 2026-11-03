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

    func testBothLayoutsProduceVisibleTemplateGlyphs() throws {
        for layout in [ActiveLayoutKind.niri, .dwindle] {
            let image = try XCTUnwrap(StatusBarController.statusButtonImage(icon: nil, layout: layout))
            XCTAssertTrue(image.isTemplate)
            XCTAssertTrue(try glyphMask(image).contains(true))
        }
    }

    func testCombinedImagesPreserveBothComponentsAndColors() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var result: Result<Void, Error>?
            appearance.performAsCurrentDrawingAppearance {
                result = Result { try self.checkCombinedImages() }
            }
            try XCTUnwrap(result).get()
        }
    }

    private func checkCombinedImages() throws {
        for (layout, symbol) in [
            (ActiveLayoutKind.niri, "rectangle.split.3x1"),
            (.dwindle, "rectangle.split.2x2")
        ] {
            let image = try XCTUnwrap(StatusBarController.statusButtonImage(icon: nil, layout: layout))
            let expectedSymbol = try XCTUnwrap(NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)))
            let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                NSColor.systemRed.setFill()
                rect.fill()
                return true
            }
            for isTemplate in [false, true] {
                icon.isTemplate = isTemplate
                let combined = try XCTUnwrap(StatusBarController.statusButtonImage(icon: icon, layout: layout))
                XCTAssertEqual(combined.isTemplate, isTemplate)
                XCTAssertEqual(combined.size.width, icon.size.width + 5 + image.size.width)
                let layoutRect = NSRect(
                    x: icon.size.width + 5,
                    y: (combined.size.height - image.size.height) / 2,
                    width: image.size.width,
                    height: image.size.height
                )
                let expectedGlyph = isTemplate ? expectedSymbol : try XCTUnwrap(
                    expectedSymbol.withSymbolConfiguration(.init(paletteColors: [.labelColor]))
                )
                let expected = NSImage(size: combined.size, flipped: false) { _ in
                    expectedGlyph.draw(in: layoutRect)
                    return true
                }
                let expectedMask = try glyphMask(expected, in: layoutRect)
                let combinedMask = try glyphMask(combined, in: layoutRect)
                XCTAssertTrue(combinedMask == expectedMask, "\(layout) should remain visible beside the icon")
                let iconRect = NSRect(
                    x: 0,
                    y: (combined.size.height - icon.size.height) / 2,
                    width: icon.size.width,
                    height: icon.size.height
                )
                let iconMask = try glyphMask(combined, in: iconRect)
                let expectedIconMask = try glyphMask(icon)
                XCTAssertTrue(iconMask == expectedIconMask, "\(layout) should preserve the icon")
                if !isTemplate {
                    try checkVisibleColors(colorBitmap(combined, in: iconRect), matching: .systemRed)
                    try checkVisibleColors(colorBitmap(combined, in: layoutRect), matching: .labelColor)
                }
            }
        }
    }

    private func colorBitmap(_ image: NSImage, in region: NSRect) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        let transform = NSAffineTransform()
        transform.scaleX(by: 64 / region.width, yBy: 64 / region.height)
        transform.translateX(by: -region.minX, yBy: -region.minY)
        transform.concat()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return bitmap
    }

    private func checkVisibleColors(_ bitmap: NSBitmapImageRep, matching expected: NSColor) throws {
        let expected = try XCTUnwrap(expected.usingColorSpace(.genericRGB))
        let colors = (0 ..< bitmap.pixelsHigh).flatMap { y in
            (0 ..< bitmap.pixelsWide).compactMap { x -> NSColor? in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.genericRGB),
                      color.alphaComponent > 0.5
                else { return nil }
                return color
            }
        }
        XCTAssertGreaterThan(colors.count, 1)
        XCTAssertTrue(colors.allSatisfy {
            abs($0.redComponent - expected.redComponent) < 0.02
                && abs($0.greenComponent - expected.greenComponent) < 0.02
                && abs($0.blueComponent - expected.blueComponent) < 0.02
        }, "Visible pixels should match \(expected)")
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

    private func glyphMask(_ image: NSImage, in region: NSRect? = nil) throws -> [Bool] {
        let bitmap = try glyphBitmap(image, in: region)
        return (0 ..< bitmap.pixelsHigh).flatMap { y in
            (0 ..< bitmap.pixelsWide).map { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }
        }
    }

    private func glyphBitmap(_ image: NSImage, in region: NSRect? = nil) throws -> NSBitmapImageRep {
        let native = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        let nativeBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(native.tiffRepresentation)))
        let raster = NSImage(cgImage: try XCTUnwrap(nativeBitmap.cgImage), size: image.size)
        let canvas = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            raster.draw(
                in: rect,
                from: region ?? NSRect(origin: .zero, size: image.size),
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(canvas.tiffRepresentation)))
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
