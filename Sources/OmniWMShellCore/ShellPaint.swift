// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public struct Paint: Equatable, Sendable, BitwiseCopyable {
    public var fill: Color
    public var stroke: Color
    public var strokeWidth: Float
    public var cornerRadius: Float
    public var opacity: Float
    public var scale: Float
    public var shadow: Color
    public var shadowRadius: Float
    public var material: UInt8
    public var blurRadius: Float
    public var saturation: Float
    public var enter: Enter
    public var masks: Bool
    public var rotate: Float
    public var loop: UInt32
    public var loopPaused: Bool
    public var speed: Float
    public var appear: UInt32
    public var exit: UInt32
    public var reveal: UInt32
    public var morph: UInt32
    public var pulse: UInt32
    public var gradientFrom: Color
    public var gradientTo: Color
    public var gradientSpecified: Bool
    public var shadowOffsetX: Float
    public var shadowOffsetY: Float

    public init(
        fill: Color = .clear,
        stroke: Color = .clear,
        strokeWidth: Float = 0,
        cornerRadius: Float = 0,
        opacity: Float = 1,
        scale: Float = 1,
        shadow: Color = .clear,
        shadowRadius: Float = 0,
        material: UInt8 = 0,
        blurRadius: Float = -1,
        saturation: Float = 1.8,
        enter: Enter = .none,
        masks: Bool = false,
        rotate: Float = 0,
        loop: UInt32 = 0,
        loopPaused: Bool = false,
        speed: Float = 1,
        appear: UInt32 = 0,
        exit: UInt32 = 0,
        reveal: UInt32 = 0,
        morph: UInt32 = 0,
        pulse: UInt32 = 0,
        gradientFrom: Color = .clear,
        gradientTo: Color = .clear,
        gradientSpecified: Bool = false,
        shadowOffsetX: Float = 0,
        shadowOffsetY: Float = 0
    ) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.scale = scale
        self.shadow = shadow
        self.shadowRadius = shadowRadius
        self.material = material
        self.blurRadius = blurRadius
        self.saturation = saturation
        self.enter = enter
        self.masks = masks
        self.rotate = rotate
        self.loop = loop
        self.loopPaused = loopPaused
        self.speed = speed
        self.appear = appear
        self.exit = exit
        self.reveal = reveal
        self.morph = morph
        self.pulse = pulse
        self.gradientFrom = gradientFrom
        self.gradientTo = gradientTo
        self.gradientSpecified = gradientSpecified
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
    }

    public static let none = Paint()
}
