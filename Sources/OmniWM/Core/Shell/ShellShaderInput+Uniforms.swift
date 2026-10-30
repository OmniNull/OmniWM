// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import QuartzCore

extension ShellShaderInput {
    func uniforms(
        size: CGSize,
        scale: CGFloat,
        elapsed: CFTimeInterval,
        now: CFTimeInterval,
        transition: ShellShaderTransition,
        stage: ShellShaderStage? = nil,
        audio: ShellSpectrumBands.Bars = .init(repeating: 0)
    ) -> ShellShaderUniforms {
        let animates = rate > 0
        let stage = stage ?? ShellShaderStage(
            anchor: CGPoint(x: size.width / 2, y: size.height / 2),
            content: CGRect(origin: .zero, size: size)
        )
        return ShellShaderUniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            scale: Float(scale),
            time: animates ? Float(elapsed.truncatingRemainder(dividingBy: ShellShaderDrawer.timeWrap)) : 0,
            values: values,
            colors: colors,
            progress: animates || transition.forced ? transition.progress(at: now) : transition.to,
            anchor: SIMD2(Float(stage.anchor.x), Float(stage.anchor.y)),
            content: SIMD4(
                Float(stage.content.minX),
                Float(stage.content.minY),
                Float(stage.content.width),
                Float(stage.content.height)
            ),
            audio: audio
        )
    }
}
