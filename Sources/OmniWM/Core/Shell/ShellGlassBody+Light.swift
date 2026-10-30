// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellGlassBody {
    func applyLight(_ light: CGPoint, shine: Bool) {
        let angle = atan2(light.x, -light.y)
        let opacity: Float = shine ? 1 : 0
        sdfLayers[2].opacity = opacity
        sdfLayers[2].setValue(0.055, forKey: ShellGlassCapability.BodyProperty.effectOffset.rawValue)
        setEffect(.highlight, on: sdfLayers[2], values: [
            .keyColor: CGColor(gray: 1, alpha: 0.989),
            .keyAngle: angle,
            .keyHeight: 2.118,
            .keySpread: 1.485,
            .keyAmount: 0.319,
            .fillColor: CGColor(gray: 1, alpha: 0.428),
            .fillAngle: angle + .pi,
            .fillHeight: 2.243,
            .fillSpread: 2.324,
            .fillAmount: 0.376,
            .curvature: 0.628,
            .diffuseHeightScale: 1.756,
            .diffuseAmountScale: 0.694,
            .diffuseSpreadScale: 1.126
        ])
        sdfLayers[3].opacity = 0.0534 * opacity
        sdfLayers[3].setValue(-0.092, forKey: ShellGlassCapability.BodyProperty.effectOffset.rawValue)
        setEffect(.highlight, on: sdfLayers[3], values: [
            .keyColor: CGColor(gray: 1, alpha: 1),
            .keyAngle: angle,
            .keyHeight: 13.33,
            .keySpread: CGFloat.pi,
            .keyAmount: 0.5,
            .fillColor: CGColor(gray: 1, alpha: 1),
            .fillAngle: angle + .pi,
            .fillHeight: 13.33,
            .fillSpread: CGFloat.pi,
            .fillAmount: 0.5,
            .curvature: 1,
            .diffuseHeightScale: 2.53,
            .diffuseAmountScale: 1,
            .diffuseSpreadScale: 1
        ])
    }
}
