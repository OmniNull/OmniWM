// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

public struct ElementHandle: Hashable, Sendable, BitwiseCopyable {
    public var slot: Int32
    public var generation: UInt32

    public init(slot: Int32, generation: UInt32) {
        self.slot = slot
        self.generation = generation
    }

    public static let none = ElementHandle(slot: -1, generation: 0)
}

public enum ElementKind: UInt8, Sendable, BitwiseCopyable {
    case group
    case box
    case label
    case symbol
    case image
    case bitmap
    case progress
    case shader
    case slider
    case path
    case input
}

public struct Rect: Equatable, Sendable, BitwiseCopyable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)
}

public struct Insets: Equatable, Sendable, BitwiseCopyable {
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float

    public init(left: Float = 0, top: Float = 0, right: Float = 0, bottom: Float = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

public struct Size2: Equatable, Sendable, BitwiseCopyable {
    public var width: Float
    public var height: Float

    public init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }
}

public struct Color: Hashable, Sendable, BitwiseCopyable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float
    public var role: UInt16

    public init(red: Float, green: Float, blue: Float, alpha: Float, role: UInt16 = 0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.role = role
    }

    public init(packed value: UInt32, role: UInt16 = 0) {
        red = Float((value >> 24) & 0xFF) / 255
        green = Float((value >> 16) & 0xFF) / 255
        blue = Float((value >> 8) & 0xFF) / 255
        alpha = Float(value & 0xFF) / 255
        self.role = role
    }

    public var isVisible: Bool {
        role != 0 || alpha > 0
    }

    public static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)
}

public struct Enter: Equatable, Sendable, BitwiseCopyable {
    public var opacity: Float
    public var scale: Float
    public var dx: Float
    public var dy: Float
    public var from: Float
    public var to: Float
    public var curve: UInt8
    public var curveRef: UInt32
    public var path: UInt32
    public var stretch: Float

    public init(
        opacity: Float = 1,
        scale: Float = 1,
        dx: Float = 0,
        dy: Float = 0,
        from: Float = 0,
        to: Float = 1,
        curve: UInt8 = 0,
        curveRef: UInt32 = 0,
        path: UInt32 = 0,
        stretch: Float = 0
    ) {
        self.opacity = opacity
        self.scale = scale
        self.dx = dx
        self.dy = dy
        self.from = from
        self.to = to
        self.curve = curve
        self.curveRef = curveRef
        self.path = path
        self.stretch = stretch
    }

    public static let none = Enter()
}

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
        exit: UInt32 = 0
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
    }

    public static let none = Paint()
}

public enum Axis: UInt8, Sendable, BitwiseCopyable {
    case row
    case column
    case overlay
}

public struct LayoutStyle: Equatable, Sendable, BitwiseCopyable {
    public var axis: Axis
    public var width: Float
    public var height: Float
    public var grow: Float
    public var gap: Float
    public var padding: Float
    public var centerCross: Bool
    public var align: UInt8
    public var dx: Float
    public var dy: Float

    public init(
        axis: Axis = .row,
        width: Float = -1,
        height: Float = -1,
        grow: Float = 0,
        gap: Float = 0,
        padding: Float = 0,
        centerCross: Bool = true,
        align: UInt8 = 0,
        dx: Float = 0,
        dy: Float = 0
    ) {
        self.axis = axis
        self.width = width
        self.height = height
        self.grow = grow
        self.gap = gap
        self.padding = padding
        self.centerCross = centerCross
        self.align = align
        self.dx = dx
        self.dy = dy
    }
}

public enum IconSource: UInt8, Sendable, BitwiseCopyable {
    case bundle
    case window
    case pid
}

public struct Content: Equatable, Sendable, BitwiseCopyable {
    public var text: UInt32
    public var reserve: UInt32
    public var style: UInt32
    public var color: Color
    public var value: UInt32
    public var action: UInt32
    public var hover: Color
    public var motion: UInt8
    public var opensPopout: Bool
    public var params: SIMD4<Float>
    public var rate: UInt8
    public var target: UInt32
    public var menu: Bool
    public var preview: Bool
    public var drag: Bool
    public var drop: Bool
    public var secondaryAction: UInt32
    public var scrollAction: UInt32
    public var maxWidth: Float
    public var iconSource: IconSource
    public var iconRef: UInt32
    public var placeholder: UInt32
    public var hoverScale: Float
    public var hoverOpacity: Float
    public var help: UInt32
    public var hoverMotion: UInt8
    public var motionCurve: UInt8
    public var motionCurveRef: UInt32
    public var trail: Bool
    public var hoverMaterial: UInt8
    public var lines: UInt8
    public var scrolls: Bool
    public var bridges: Bool
    public var openDuration: Float
    public var closeDuration: Float
    public var evenOdd: Bool
    public var attaches: Bool
    public var audio: Bool
    public var hoverAction: UInt32 = 0
    public var pressAction: UInt32 = 0
    public var gestureAction: UInt32 = 0
    public var gestureTrack: UInt32 = 0
    public var keyAction: UInt32 = 0
    public var outsidePressAction: UInt32 = 0
    public var keys: UInt32 = 0
    public var pressScaleSpecified: Bool = false
    public var pressScale: Float = 0
    public var pressOpacity: Float = -1
    public var pressFill: Color = .clear
    public var pressFillSpecified: Bool = false
    public var pressMotion: UInt8 = 0
    public var pressMotionCurve: UInt8 = 0
    public var pressMotionCurveRef: UInt32 = 0
    public var hoverDelay: Float = 0
    public var hoverGrace: Float = 0
    public var focusable: Bool = false
    public var focusRing: Bool = true
    public var scrollMomentum: Bool = false
    public var inputCommitAction: UInt32 = 0
    public var inputCancelAction: UInt32 = 0
    public var inputFocusAction: UInt32 = 0
    public var inputMaxLength: UInt32 = 65536
    public var inputMultiline: Bool = false
    public var inputFocus: Int8 = -1
    public var textureRef: UInt32 = 0
    public var resourceImageRef: UInt32 = 0
    public var thumbnail: Float = 128
    public var resourceDropAction: UInt32 = 0
    public var resourceHoverAction: UInt32 = 0
    public var dragItemsRef: UInt32 = 0
    public var dragOutAction: UInt32 = 0
    public var resourceAccepts: UInt32 = 0
    public var gesture: ShellGestureConfig = ShellGestureConfig()

    public var hasPressEffect: Bool {
        pressScaleSpecified || pressScale > 0 || pressOpacity >= 0 || pressFillSpecified
    }

    public var acceptsPointer: Bool {
        action != 0 || secondaryAction != 0 || scrollAction != 0 || opensPopout || menu || drag || scrolls
            || pressAction != 0 || hoverAction != 0 || gesture
            .axis != .none || focusable || hasPressEffect || dragItemsRef != 0
    }

    public var hasHoverEffect: Bool {
        hover.isVisible || hoverScale > 0 || hoverOpacity >= 0 || hoverMaterial > 0
    }

    public init(
        text: UInt32 = 0,
        reserve: UInt32 = 0,
        style: UInt32 = 0,
        color: Color = .clear,
        value: UInt32 = 0,
        action: UInt32 = 0,
        hover: Color = .clear,
        motion: UInt8 = 0,
        opensPopout: Bool = false,
        params: SIMD4<Float> = .zero,
        rate: UInt8 = 0,
        target: UInt32 = 0,
        menu: Bool = false,
        preview: Bool = false,
        drag: Bool = false,
        drop: Bool = false,
        secondaryAction: UInt32 = 0,
        scrollAction: UInt32 = 0,
        maxWidth: Float = 0,
        iconSource: IconSource = .bundle,
        iconRef: UInt32 = 0,
        placeholder: UInt32 = 0,
        hoverScale: Float = 0,
        hoverOpacity: Float = -1,
        help: UInt32 = 0,
        hoverMotion: UInt8 = 0,
        motionCurve: UInt8 = 0,
        motionCurveRef: UInt32 = 0,
        trail: Bool = false,
        hoverMaterial: UInt8 = 0,
        lines: UInt8 = 0,
        scrolls: Bool = false,
        bridges: Bool = false,
        openDuration: Float = -1,
        closeDuration: Float = -1,
        evenOdd: Bool = false,
        attaches: Bool = false,
        audio: Bool = false
    ) {
        self.text = text
        self.reserve = reserve
        self.style = style
        self.color = color
        self.value = value
        self.action = action
        self.hover = hover
        self.motion = motion
        self.opensPopout = opensPopout
        self.params = params
        self.rate = rate
        self.target = target
        self.menu = menu
        self.preview = preview
        self.drag = drag
        self.drop = drop
        self.secondaryAction = secondaryAction
        self.scrollAction = scrollAction
        self.maxWidth = maxWidth
        self.iconSource = iconSource
        self.iconRef = iconRef
        self.placeholder = placeholder
        self.hoverScale = hoverScale
        self.hoverOpacity = hoverOpacity
        self.help = help
        self.hoverMotion = hoverMotion
        self.motionCurve = motionCurve
        self.motionCurveRef = motionCurveRef
        self.trail = trail
        self.hoverMaterial = hoverMaterial
        self.lines = lines
        self.scrolls = scrolls
        self.bridges = bridges
        self.openDuration = openDuration
        self.closeDuration = closeDuration
        self.evenOdd = evenOdd
        self.attaches = attaches
        self.audio = audio
    }
}

public struct TreeNode: Sendable, BitwiseCopyable {
    public var kind: ElementKind
    public var subtreeEnd: Int32
    public var key: UInt64
    public var layout: LayoutStyle
    public var paint: Paint
    public var content: Content

    public init(
        kind: ElementKind,
        subtreeEnd: Int32,
        key: UInt64 = 0,
        layout: LayoutStyle = LayoutStyle(),
        paint: Paint = .none,
        content: Content = Content()
    ) {
        self.kind = kind
        self.subtreeEnd = subtreeEnd
        self.key = key
        self.layout = layout
        self.paint = paint
        self.content = content
    }
}

public enum PatchOp: Sendable, BitwiseCopyable {
    case insert(ElementHandle, parent: ElementHandle, kind: ElementKind, after: ElementHandle)
    case remove(ElementHandle)
    case move(ElementHandle, parent: ElementHandle, after: ElementHandle)
    case setFrame(ElementHandle, Rect)
    case setPaint(ElementHandle, Paint)
    case setText(ElementHandle, text: UInt32, style: UInt32, color: Color, maxWidth: Float, lines: UInt8)
    case setValue(ElementHandle, value: UInt32, color: Color)
    case setShader(ElementHandle)
    case setPath(ElementHandle)
    case setScroll(ElementHandle, offset: Float, vertical: Bool)
}

public typealias MeasureText = @convention(c) (
    UnsafeMutableRawPointer?,
    UInt32,
    UInt32,
    Float,
    UInt8,
    UnsafeMutablePointer<Float>,
    UnsafeMutablePointer<Float>
) -> Void
