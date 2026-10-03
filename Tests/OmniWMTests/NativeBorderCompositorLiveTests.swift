// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreVideo
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import XCTest

@MainActor
final class NativeBorderCompositorLiveTests: XCTestCase {
    func testCompositorPreservesIndependentNativeCornersAndTransparentInterior() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SKYLIGHT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live compositor checks require OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let target = CGRect(x: screen.frame.midX - 160, y: screen.frame.midY - 120, width: 320, height: 240)
        let config = BorderConfig(
            enabled: true, width: 8, color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let geometry = config.resolvedGeometry(for: target, scale: screen.backingScaleFactor)
        let panel = try XCTUnwrap(BorderLayerPanel(frame: geometry.surfaceFrame))
        defer { panel.close() }
        panel.updateBorder(
            geometry: geometry.localized(),
            cornerRadii: WindowCornerRadii(topLeft: 0, topRight: 16, bottomLeft: 48, bottomRight: 32),
            color: NSColor.red.cgColor, scale: screen.backingScaleFactor
        )
        panel.updateEffects(
            geometry: geometry.localized(),
            cornerRadii: WindowCornerRadii(topLeft: 0, topRight: 16, bottomLeft: 48, bottomRight: 32),
            config: config, baseColor: NSColor.red.cgColor, scale: screen.backingScaleFactor
        )
        panel.applyFrame(targetFrame: geometry.targetFrame, surfaceFrame: geometry.surfaceFrame)
        panel.orderBack(nil)
        CATransaction.flush()

        let content = try await SCShareableContent.currentProcess
        let window = try XCTUnwrap(content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }))
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let capture = SCStreamConfiguration()
        capture.width = Int((geometry.surfaceFrame.width * screen.backingScaleFactor).rounded())
        capture.height = Int((geometry.surfaceFrame.height * screen.backingScaleFactor).rounded())
        capture.pixelFormat = kCVPixelFormatType_32BGRA
        capture.showsCursor = false
        capture.ignoreShadowsSingleWindow = true
        capture.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: capture)
        let bitmap = try XCTUnwrap(Bitmap(image: image))
        let insets = try XCTUnwrap(bitmap.cornerInsets)

        XCTAssertLessThan(insets[0], insets[1])
        XCTAssertLessThan(insets[1], insets[2])
        XCTAssertLessThan(insets[2], insets[3])
        XCTAssertEqual(bitmap.alpha(x: bitmap.width / 2, y: bitmap.height / 2), 0)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testGradientAndGlowMatchNativeRimDuringRetinaMovementAndAppearanceChanges() async throws {
        guard ProcessInfo.processInfo.environment["OMNIWM_RUN_SKYLIGHT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live compositor checks require OMNIWM_RUN_SKYLIGHT_LIVE_TESTS=1")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required")
        }
        let app = NSApplication.shared
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == 2 }) else {
            throw XCTSkip("The gradient/glow compositor check requires a 2× display")
        }
        let previousAppearance = app.appearance
        let controller = WindowAdmissionTestSupport.controller(prefix: "NativeBorderCompositorLiveTests")
        defer {
            controller.effectiveAppearanceObserver = nil
            app.appearance = previousAppearance
        }
        let settings = controller.settings
        settings.borders.enabled = true
        settings.borders.width = 8
        settings.borders.color = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        settings.borders.gradient = BorderGradient(
            enabled: true,
            start: settings.borders.color,
            end: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1),
            direction: .topLeftToBottomRight,
            dark: BorderGradientColors(
                start: SettingsColor(red: 0, green: 1, blue: 0, alpha: 1),
                end: SettingsColor(red: 1, green: 1, blue: 0, alpha: 1)
            )
        )
        settings.borders.glow = BorderGlow(enabled: true, radius: 8, opacity: 0.25)
        settings.appearanceMode = .light
        controller.applyCurrentAppearanceMode()
        XCTAssertFalse(controller.borderUsesDarkAppearance)
        let config = BorderConfig.from(settings: settings, isDark: controller.borderUsesDarkAppearance)
        let target = CGRect(
            x: floor(screen.frame.midX - 160), y: floor(screen.frame.midY - 120), width: 320, height: 240
        )
        let geometry = config.resolvedGeometry(for: target, scale: 2)
        let movedGeometry = config.resolvedGeometry(for: target.offsetBy(dx: 0.5, dy: 0.5), scale: 2)
        let panel = try XCTUnwrap(BorderLayerPanel(frame: geometry.surfaceFrame))
        defer { panel.close() }
        panel.orderBack(nil)

        for radius: CGFloat in [0, 24] {
            let radii = WindowCornerRadii(uniform: radius)
            let label = radius == 0 ? "square" : "rounded"
            var nativeConfig = config
            nativeConfig.gradient = nil
            nativeConfig.glow = nil
            configure(panel, geometry: geometry, radii: radii, config: nativeConfig, usesNativeRim: true)
            let native = try await capture(panel, label: "\(label)-native")
            configure(panel, geometry: geometry, radii: radii, config: config)
            let effects = try await capture(panel, label: "\(label)-effects")
            assertEffectOutline(effects, matches: native, geometry: geometry, panelFrame: panel.frame)

            let path = panel.gradientRingMaskLayer.path
            panel.applyFrame(targetFrame: movedGeometry.targetFrame, surfaceFrame: movedGeometry.surfaceFrame)
            let movedEffects = try await capture(panel, label: "\(label)-fractional-effects")
            XCTAssertTrue(panel.gradientRingMaskLayer.path === path)
            configure(panel, geometry: movedGeometry, radii: radii, config: nativeConfig, usesNativeRim: true)
            let movedNative = try await capture(panel, label: "\(label)-fractional-native")
            assertEffectOutline(movedEffects, matches: movedNative, geometry: movedGeometry, panelFrame: panel.frame)
        }

        settings.appearanceMode = .dark
        controller.applyCurrentAppearanceMode()
        XCTAssertTrue(controller.borderUsesDarkAppearance)
        let darkConfig = BorderConfig.from(settings: settings, isDark: controller.borderUsesDarkAppearance)
        configure(panel, geometry: movedGeometry, radii: WindowCornerRadii(uniform: 24), config: darkConfig)
        let dark = try await capture(panel, label: "rounded-dark-effects")
        let ringTop = Int((movedGeometry.surfacePadding + movedGeometry.width / 2 + 0.5) * 2)
        XCTAssertEqual(dark.green(x: dark.width / 2, y: ringTop), 255)
        XCTAssertEqual(dark.alpha(x: dark.width / 2, y: dark.height / 2), 0)
        XCTAssertTrue(controller.borderUsesDarkAppearance)
        XCTAssertEqual(app.appearance?.name, .darkAqua)
        controller.surfaceReconciler.reconcileNow()
        controller.refreshBorderAppearance()
        XCTAssertNil(controller.surfaceReconciler.pendingReconcileScope)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    private func configure(
        _ panel: BorderLayerPanel,
        geometry: BorderConfig.ResolvedGeometry,
        radii: WindowCornerRadii,
        config: BorderConfig,
        usesNativeRim: Bool = false
    ) {
        let color = BorderLayerPanel.cgColor(config.color)
        panel.updateBorder(geometry: geometry.localized(), cornerRadii: radii, color: color, scale: 2)
        panel.updateEffects(
            geometry: geometry.localized(), cornerRadii: radii, config: config, baseColor: color, scale: 2
        )
        panel.borderLayer.rimOpacity = usesNativeRim ? 1 : 0
        if usesNativeRim {
            panel.gradientStrokeLayer.isHidden = true
        }
        panel.applyFrame(targetFrame: geometry.targetFrame, surfaceFrame: geometry.surfaceFrame)
    }

    private func capture(_ panel: BorderLayerPanel, label: String) async throws -> Bitmap {
        CATransaction.flush()
        let content = try await SCShareableContent.currentProcess
        let window = try XCTUnwrap(content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }))
        let capture = SCStreamConfiguration()
        capture.width = Int(panel.frame.width * 2)
        capture.height = Int(panel.frame.height * 2)
        capture.pixelFormat = kCVPixelFormatType_32BGRA
        capture.showsCursor = false
        capture.ignoreShadowsSingleWindow = true
        capture.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: capture
        )
        if let directory = ProcessInfo.processInfo.environment["OMNIWM_SURFACE_MEASUREMENT_OUTPUT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("border-\(label).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: url)
        }
        return try XCTUnwrap(Bitmap(image: image))
    }

    private func assertEffectOutline(
        _ effects: Bitmap,
        matches native: Bitmap,
        geometry: BorderConfig.ResolvedGeometry,
        panelFrame: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(effects.width, native.width, file: file, line: line)
        XCTAssertEqual(effects.height, native.height, file: file, line: line)
        guard effects.width == native.width, effects.height == native.height else { return }
        let target = geometry.targetFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        var missingCorePixels = 0
        var excessCorePixels = 0
        for y in 1 ..< native.height - 1 {
            for x in 1 ..< native.width - 1 {
                if native.hasUniformAlpha(255, x: x, y: y), effects.alpha(x: x, y: y) < 250 {
                    missingCorePixels += 1
                }
                let point = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                if !target.contains(point), native.hasUniformAlpha(0, x: x, y: y),
                   effects.alpha(x: x, y: y) > 128
                {
                    excessCorePixels += 1
                }
            }
        }
        XCTAssertEqual(missingCorePixels, 0, "Gradient is missing native rim core pixels", file: file, line: line)
        XCTAssertEqual(excessCorePixels, 0, "Gradient extends outside the native rim outline", file: file, line: line)
        XCTAssertEqual(effects.alpha(x: effects.width / 2, y: effects.height / 2), 0, file: file, line: line)
        let haloX = Int((target.minX - geometry.width - 4) * 2)
        let haloAlpha = effects.alpha(x: haloX, y: effects.height / 2)
        XCTAssertGreaterThan(haloAlpha, 0, file: file, line: line)
        XCTAssertLessThan(haloAlpha, 128, file: file, line: line)
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(image: CGImage) {
            width = image.width
            height = image.height
            var storage = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let rendered = storage.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard rendered else { return nil }
            bytes = storage
        }

        func alpha(x: Int, y: Int) -> UInt8 {
            bytes[(y * width + x) * 4 + 3]
        }

        func green(x: Int, y: Int) -> UInt8 {
            bytes[(y * width + x) * 4 + 1]
        }

        func hasUniformAlpha(_ value: UInt8, x: Int, y: Int) -> Bool {
            for row in y - 1 ... y + 1 {
                for column in x - 1 ... x + 1 where alpha(x: column, y: row) != value {
                    return false
                }
            }
            return true
        }

        var cornerInsets: [Int]? {
            let topLeft = (0 ..< width / 2).first { isRed(x: $0, y: 1) }
            let topRight = (0 ..< width / 2).first { isRed(x: width - 1 - $0, y: 1) }
            let bottomRight = (0 ..< width / 2).first { isRed(x: width - 1 - $0, y: height - 2) }
            let bottomLeft = (0 ..< width / 2).first { isRed(x: $0, y: height - 2) }
            guard let topLeft, let topRight, let bottomRight, let bottomLeft else { return nil }
            return [topLeft, topRight, bottomRight, bottomLeft]
        }

        private func isRed(x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return bytes[offset] > 200 && bytes[offset + 1] < 30 && bytes[offset + 2] < 30
                && bytes[offset + 3] > 200
        }
    }
}
