// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class QuakeTerminalBackgroundTests: XCTestCase {
    func testAppearanceUpdateReportsOnlyAcceptedChanges() {
        let background = makeBackground()
        let regular = appearance(backgroundBlur: -1)
        let clear = appearance(backgroundBlur: -2)

        XCTAssertFalse(background.updateAppearance(nil))
        XCTAssertTrue(background.updateAppearance(regular))
        XCTAssertFalse(background.updateAppearance(regular))
        XCTAssertTrue(background.updateAppearance(clear))
        XCTAssertFalse(background.updateAppearance(clear))
        XCTAssertTrue(background.updateAppearance(nil))
        XCTAssertFalse(background.updateAppearance(nil))
    }

    func testGlassIsInsertedBelowContentAndReusedAcrossAppearanceChanges() throws {
        let background = makeBackground()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let content = NSView(frame: container.bounds)
        container.addSubview(content)
        XCTAssertTrue(background.updateAppearance(appearance(backgroundBlur: -1)))

        background.reconcile(in: container, window: nil)
        let glass = try XCTUnwrap(container.subviews.first as? QuakeTerminalGlassView)
        let effect = try XCTUnwrap(glass.subviews.first as? NSGlassEffectView)
        XCTAssertEqual(container.subviews.count, 2)
        XCTAssertTrue(container.subviews.last === content)
        XCTAssertEqual(glass.frame, container.bounds)
        XCTAssertEqual(glass.autoresizingMask, [.width, .height])
        XCTAssertEqual(effect.style, .regular)

        XCTAssertTrue(background.updateAppearance(appearance(backgroundBlur: -2)))
        background.reconcile(in: container, window: nil)

        XCTAssertEqual(container.subviews.count, 2)
        XCTAssertTrue(container.subviews.first === glass)
        XCTAssertEqual(effect.style, .clear)
    }

    func testGlassUsesNativeQuakeWindowCornerRadius() throws {
        let window = QuakeTerminalWindow()
        defer { window.close() }
        let cornerRadiusKey = "_cornerRadius"
        guard window.responds(to: Selector(cornerRadiusKey)) else {
            XCTFail("Native window corner radius is unavailable")
            return
        }
        let radius = try XCTUnwrap(window.value(forKey: cornerRadiusKey) as? CGFloat)
        let container = try XCTUnwrap(window.contentView)
        let background = makeBackground()
        XCTAssertTrue(background.updateAppearance(appearance(backgroundBlur: -1)))

        background.reconcile(in: container, window: window)

        let glass = try XCTUnwrap(container.subviews.first as? QuakeTerminalGlassView)
        let effect = try XCTUnwrap(glass.subviews.first as? NSGlassEffectView)
        XCTAssertEqual(effect.cornerRadius, radius)
        XCTAssertFalse(window.isVisible)
    }

    func testGlassPropagatesNativeCornersAndRejectsInvalidRadii() throws {
        let window = QuakeCornerRadiusTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let glass = QuakeTerminalGlassView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = glass
        let effect = try XCTUnwrap(glass.subviews.first as? NSGlassEffectView)
        let cases: [(CGFloat, CGFloat)] = [(37, 37), (0.01, 0.01), (0, 0), (-1, 0), (.nan, 0), (.infinity, 0)]

        for (radius, expected) in cases {
            window.reportedRadius = radius
            glass.configure(style: .clear, backgroundColor: .black, backgroundOpacity: 0.8, isKeyWindow: true)

            XCTAssertEqual(effect.cornerRadius, expected)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testLosingAppearanceOrGlassStyleRemovesTheGlassView() throws {
        let absentOrStandard: [QuakeGhosttyAppearance?] = [nil, appearance(backgroundBlur: 0)]
        for replacement in absentOrStandard {
            let background = makeBackground()
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
            XCTAssertTrue(background.updateAppearance(appearance(backgroundBlur: -1)))
            background.reconcile(in: container, window: nil)
            let glass = try XCTUnwrap(container.subviews.first as? QuakeTerminalGlassView)

            XCTAssertTrue(background.updateAppearance(replacement))
            background.reconcile(in: container, window: nil)

            XCTAssertNil(glass.superview)
            XCTAssertTrue(container.subviews.isEmpty)
        }
    }

    func testMissingContainerClearsGlassButRetainsAcceptedAppearance() throws {
        let background = makeBackground()
        let oldContainer = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let newContainer = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let accepted = appearance(backgroundBlur: -1)
        XCTAssertTrue(background.updateAppearance(accepted))
        background.reconcile(in: oldContainer, window: nil)
        let oldGlass = try XCTUnwrap(oldContainer.subviews.first as? QuakeTerminalGlassView)

        background.reconcile(in: nil, window: nil)
        XCTAssertNil(oldGlass.superview)
        XCTAssertFalse(background.updateAppearance(accepted))
        background.reconcile(in: newContainer, window: nil)

        let newGlass = try XCTUnwrap(newContainer.subviews.first as? QuakeTerminalGlassView)
        XCTAssertFalse(newGlass === oldGlass)
        XCTAssertEqual(newGlass.frame, newContainer.bounds)
    }

    func testResetClearsOwnerReferencesWithoutRemovingOldContent() throws {
        let background = makeBackground()
        let oldContainer = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let newContainer = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let accepted = appearance(backgroundBlur: -1)
        XCTAssertTrue(background.updateAppearance(accepted))
        background.reconcile(in: oldContainer, window: nil)
        let oldGlass = try XCTUnwrap(oldContainer.subviews.first as? QuakeTerminalGlassView)

        background.reset()
        XCTAssertTrue(oldGlass.superview === oldContainer)
        XCTAssertFalse(background.updateAppearance(nil))
        background.reconcile(in: newContainer, window: nil)
        XCTAssertTrue(newContainer.subviews.isEmpty)
        XCTAssertTrue(background.updateAppearance(accepted))
        background.reconcile(in: newContainer, window: nil)

        let newGlass = try XCTUnwrap(newContainer.subviews.first as? QuakeTerminalGlassView)
        XCTAssertFalse(newGlass === oldGlass)
        XCTAssertTrue(oldGlass.superview === oldContainer)
    }

    func testExistingGlassIsNotImplicitlyReparentedToAnotherContainer() throws {
        let background = makeBackground()
        let oldContainer = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let newContainer = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertTrue(background.updateAppearance(appearance(backgroundBlur: -1)))
        background.reconcile(in: oldContainer, window: nil)
        let glass = try XCTUnwrap(oldContainer.subviews.first as? QuakeTerminalGlassView)

        background.reconcile(in: newContainer, window: nil)

        XCTAssertTrue(glass.superview === oldContainer)
        XCTAssertTrue(newContainer.subviews.isEmpty)
        XCTAssertEqual(oldContainer.subviews.count, 1)
    }

    private func appearance(backgroundBlur: Int16) -> QuakeGhosttyAppearance {
        QuakeGhosttyAppearance(red: 12, green: 34, blue: 56, opacity: 0.8, backgroundBlur: backgroundBlur)
    }

    private func makeBackground() -> QuakeTerminalBackground {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeBackgroundTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return QuakeTerminalBackground(settings: settings)
    }
}

@MainActor
private final class QuakeCornerRadiusTestWindow: NSWindow {
    var reportedRadius: CGFloat = 0

    @objc(_cornerRadius) func nativeCornerRadius() -> CGFloat {
        reportedRadius
    }
}
