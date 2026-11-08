// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class StatusBarLayoutTests: XCTestCase {
    private let layoutSymbols: [(layout: ActiveLayoutKind, symbol: String)] = [
        (.niri, "rectangle.split.3x1"),
        (.dwindle, "rectangle.split.2x2")
    ]

    func testDisabledLayoutPreservesTheExistingImageAndTitle() {
        let icon = OmniWMBrandMark.statusItemImage(pointSize: StatusBarController.statusIconPointSize)
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

    func testLayoutsUseDistinctExpectedGlyphs() throws {
        var glyphSamples: [[UInt8]] = []
        for (layout, symbol) in layoutSymbols {
            let image = try XCTUnwrap(StatusBarController.statusButtonImage(icon: nil, layout: layout))
            let expected = try expectedGlyph(symbol)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, expected.size)
            let imageSamples = try samples(image)
            XCTAssertEqual(imageSamples, try samples(expected), "\(layout) should use \(symbol)")
            glyphSamples.append(imageSamples)
        }
        XCTAssertNotEqual(glyphSamples[0], glyphSamples[1])
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
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        for (layout, symbol) in layoutSymbols {
            let glyph = try expectedGlyph(symbol)
            for isTemplate in [false, true] {
                icon.isTemplate = isTemplate
                let combined = try XCTUnwrap(StatusBarController.statusButtonImage(icon: icon, layout: layout))
                XCTAssertEqual(combined.isTemplate, isTemplate)
                XCTAssertEqual(
                    combined.size.width, icon.size.width + StatusBarController.layoutIconSpacing + glyph.size.width
                )
                let height = max(icon.size.height, glyph.size.height)
                let drawnGlyph = isTemplate
                    ? glyph
                    : try XCTUnwrap(glyph.withSymbolConfiguration(.init(paletteColors: [.labelColor])))
                let expected = NSImage(size: combined.size, flipped: false) { _ in
                    icon.draw(in: NSRect(
                        x: 0, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height
                    ))
                    drawnGlyph.draw(in: NSRect(
                        x: icon.size.width + StatusBarController.layoutIconSpacing,
                        y: (height - glyph.size.height) / 2,
                        width: glyph.size.width,
                        height: glyph.size.height
                    ))
                    return true
                }
                XCTAssertEqual(try samples(combined), try samples(expected), "\(layout), template=\(isTemplate)")
            }
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
        let cell = try XCTUnwrap(button.cell)
        let imageRect = cell.imageRect(forBounds: NSRect(origin: .zero, size: cell.cellSize))
        XCTAssertFalse(imageRect.isEmpty)
        XCTAssertEqual(
            StatusBarController.labeledImagePosition(showIcon: false, hasStateIcon: false),
            .noImage
        )
    }

    func testLayoutAccessibilityRetainsExistingStateInformation() {
        for (layout, name) in [
            (ActiveLayoutKind.niri, LayoutType.niri.localizedDisplayName),
            (.dwindle, LayoutType.dwindle.localizedDisplayName)
        ] {
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

    func testMissingWorkspaceShowsTheBrandWithoutLosingTheMenuButton() throws {
        let controller = WindowAdmissionTestSupport.controller(prefix: "StatusBarMissingWorkspace")
        controller.workspaceManager.commitMonitorSessions([:])
        let (statusBar, button) = try makeStatusBar(for: controller, showIcon: false)
        let cell = try XCTUnwrap(button.cell)
        XCTAssertNil(controller.activeStatusBarWorkspaceSummary())
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.target === statusBar)
        XCTAssertNotNil(button.action)
        XCTAssertEqual(
            button.accessibilityValue() as? String,
            StatusBarController.statusButtonAccessibilityValue(
                workspaceLabel: nil, focusedAppName: nil, isRecording: false, isSecureInputActive: false
            )
        )

        for showIcon in [false, true, false] {
            controller.settings.statusBar.showIcon = showIcon
            statusBar.refreshWorkspaces()
            XCTAssertNotNil(button.image)
            XCTAssertGreaterThan(cell.cellSize.width, 0)
            XCTAssertFalse(cell.imageRect(forBounds: NSRect(origin: .zero, size: cell.cellSize)).isEmpty)
            XCTAssertEqual(button.title, "")
            XCTAssertEqual(button.imagePosition, .imageOnly)
        }

        controller.keyboardModeKind = .paused
        statusBar.refreshWorkspaces()
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.title, " " + (try XCTUnwrap(StatusBarController.keyboardModeTitle(.paused))))
        XCTAssertEqual(button.imagePosition, .imageLeft)

        controller.keyboardModeKind = .normal
        controller.settings.statusBar.showLayout = false
        statusBar.refreshWorkspaces()
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.imagePosition, .imageOnly)
    }

    func testRefreshingAnUnchangedLayoutKeepsTheSameImage() throws {
        for showIcon in [false, true] {
            let controller = WindowAdmissionTestSupport.controller(prefix: "StatusBarSameImage")
            let (statusBar, button) = try makeStatusBar(for: controller, showIcon: showIcon)
            let layout = try XCTUnwrap(controller.activeStatusBarWorkspaceSummary()).layout
            let image = try XCTUnwrap(button.image)
            XCTAssertTrue(
                image === (showIcon
                    ? StatusBarController.brandedLayoutImage(layout)
                    : StatusBarController.layoutGlyph(layout))
            )
            statusBar.refreshWorkspaces()
            XCTAssertTrue(button.image === image, "showIcon=\(showIcon)")
        }
    }

    private func makeStatusBar(
        for controller: WMController,
        showIcon: Bool
    ) throws -> (StatusBarController, NSStatusBarButton) {
        controller.hotkeysEnabled = false
        controller.settings.workspaceBar.enabled = false
        controller.settings.hiddenBar.enabled = false
        controller.settings.statusBar.showLayout = true
        controller.settings.statusBar.showWorkspaceName = false
        controller.settings.statusBar.showIcon = showIcon
        let suite = "StatusBarLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let statusBar = StatusBarController(
            settings: controller.settings,
            controller: controller,
            hiddenBarController: controller.hiddenBarController,
            statusItemDefaults: defaults
        )
        controller.statusBarController = statusBar
        addTeardownBlock {
            statusBar.cleanup()
            defaults.removePersistentDomain(forName: suite)
        }
        statusBar.setup()
        return (statusBar, try XCTUnwrap(statusBar.statusButton))
    }

    private func expectedGlyph(_ symbol: String) throws -> NSImage {
        try XCTUnwrap(NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: StatusBarController.layoutSymbolPointSize, weight: .regular)))
    }

    private func samples(_ image: NSImage) throws -> [UInt8] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width.rounded(.up)),
            pixelsHigh: Int(image.size.height.rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.draw(in: NSRect(origin: .zero, size: image.size))
        context.flushGraphics()
        let data = try XCTUnwrap(bitmap.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }
}
