// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class BorderEffectsTests: XCTestCase {
    private let target = CGRect(x: 16, y: 16, width: 100, height: 80)

    private func makePanel() throws -> BorderLayerPanel {
        guard let panel = BorderLayerPanel(frame: CGRect(x: 0, y: 0, width: 164, height: 144)) else {
            throw XCTSkip("Native rim bridge is unavailable in this environment")
        }
        return panel
    }

    private func geometry(width: CGFloat, padding: CGFloat) -> BorderConfig.ResolvedGeometry {
        let inset = width + padding
        return BorderConfig.ResolvedGeometry(
            targetFrame: CGRect(origin: CGPoint(x: inset, y: inset), size: target.size),
            surfaceFrame: CGRect(
                origin: .zero,
                size: CGSize(width: target.width + 2 * inset, height: target.height + 2 * inset)
            ),
            width: width,
            surfacePadding: padding
        )
    }

    private func updateEffects(
        _ panel: BorderLayerPanel,
        geometry: BorderConfig.ResolvedGeometry,
        gradient: Bool,
        glowOpacity: CGFloat
    ) {
        let config = config(gradient: gradient, glowOpacity: Double(glowOpacity))
        panel.updateEffects(
            geometry: geometry, cornerRadii: WindowCornerRadii(uniform: 9),
            config: config, baseColor: BorderLayerPanel.cgColor(config.color), scale: 1
        )
    }

    func testGradientHidesRimAndInstallsRingMask() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 0), gradient: true, glowOpacity: 0)

        XCTAssertEqual(panel.borderLayer.rimOpacity, 0)
        XCTAssertFalse(panel.gradientStrokeLayer.isHidden)
        XCTAssertNotNil(panel.gradientRingMaskLayer.path)
    }

    func testSolidUsesRoundedRingWithoutNativeRim() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 0), gradient: false, glowOpacity: 0)

        XCTAssertEqual(panel.borderLayer.rimOpacity, 0)
        XCTAssertFalse(panel.gradientStrokeLayer.isHidden)
        let path = try XCTUnwrap(panel.gradientRingMaskLayer.path)
        let shape = geometry(width: 4, padding: 0)
        XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5), using: .evenOdd))
        XCTAssertTrue(path.contains(CGPoint(x: shape.surfaceFrame.midX, y: 2), using: .evenOdd))
        XCTAssertFalse(path.contains(
            CGPoint(x: shape.targetFrame.midX, y: shape.targetFrame.midY), using: .evenOdd
        ))
    }

    func testGlowInstallsBandMask() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 12), gradient: false, glowOpacity: 0.6)

        XCTAssertFalse(panel.glowColorLayer.isHidden)
        XCTAssertEqual(panel.glowMaskLayer.sublayers?.count, 12)
    }

    func testNoGlowHidesColorLayer() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 0), gradient: false, glowOpacity: 0)

        XCTAssertTrue(panel.glowColorLayer.isHidden)
    }

    func testGlowBandCountCapsAtMaximum() throws {
        let panel = try makePanel()
        updateEffects(panel, geometry: geometry(width: 4, padding: 48), gradient: false, glowOpacity: 0.6)

        XCTAssertEqual(panel.glowMaskLayer.sublayers?.count, 48)
    }

    func testGlowColorOverrideWinsOverGradient() throws {
        let panel = try makePanel()
        var config = config(gradient: true, glowOpacity: 0.6)
        config.glow?.color = SettingsColor(red: 0, green: 1, blue: 0, alpha: 1)
        let override = BorderLayerPanel.cgColor(try XCTUnwrap(config.glow?.color))
        panel.updateEffects(
            geometry: geometry(width: 4, padding: 12), cornerRadii: WindowCornerRadii(uniform: 9),
            config: config, baseColor: BorderLayerPanel.cgColor(config.color), scale: 1
        )

        XCTAssertFalse(panel.glowColorLayer.isHidden)
        XCTAssertEqual(panel.glowColorLayer.colors as? [CGColor], [override, override])
    }

    func testGradientSquareAndMixedCornersPreserveNativeOutlineWhileGlowStaysRounded() throws {
        let panel = try makePanel()
        defer { panel.close() }
        let config = config(gradient: true, glowOpacity: 0.6)
        let geometry = geometry(width: 4, padding: 12)
        let ringFrame = geometry.targetFrame.insetBy(dx: -geometry.width, dy: -geometry.width)
        let outerCorner = CGPoint(x: ringFrame.minX + 0.1, y: ringFrame.minY + 0.1)
        for radii in [
            WindowCornerRadii.zero,
            WindowCornerRadii(topLeft: 9, topRight: 0, bottomLeft: 0, bottomRight: 0)
        ] {
            panel.updateEffects(
                geometry: geometry, cornerRadii: radii, config: config,
                baseColor: BorderLayerPanel.cgColor(config.color), scale: 1
            )
            let path = try XCTUnwrap(panel.gradientRingMaskLayer.path)
            XCTAssertEqual(path.contains(outerCorner, using: .evenOdd), radii == .zero)
            XCTAssertFalse(path.contains(
                CGPoint(x: geometry.targetFrame.midX, y: geometry.targetFrame.midY),
                using: .evenOdd
            ))
            let band = try XCTUnwrap(panel.glowMaskLayer.sublayers?.first as? CAShapeLayer)
            let bandPath = try XCTUnwrap(band.path)
            let bounds = bandPath.boundingBoxOfPath
            XCTAssertFalse(bandPath.contains(CGPoint(x: bounds.minX + 0.1, y: bounds.minY + 0.1)))
        }
    }

    private func config(gradient: Bool, glowOpacity: Double) -> BorderConfig {
        let red = SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        return BorderConfig(
            enabled: true, width: 4, color: red,
            gradient: gradient ? BorderGradient(
                enabled: true, start: red, end: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1),
                direction: .topLeftToBottomRight
            ) : nil,
            glow: BorderGlow(enabled: glowOpacity > 0, radius: 8, opacity: glowOpacity)
        )
    }
}
