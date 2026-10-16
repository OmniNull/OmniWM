// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreText
import OmniWMShellCore
import QuartzCore

enum ShellMotion: Equatable, Sendable {
    case spring(response: Double, bounce: Double)
    case bouncy
    case smooth
    case ease(seconds: Double)

    static let spring = ShellMotion.spring(response: 0.35, bounce: 0.15)

    var isSpring: Bool {
        if case .ease = self { return false }
        return true
    }

    init?(recipe: String) {
        let values = recipe.split(separator: ":", omittingEmptySubsequences: false)
        guard values.count == 3, values[0] == "spring",
              let response = Double(values[1]), response.isFinite, (0.05 ... 2.5).contains(response),
              let bounce = Double(values[2]), bounce.isFinite, (0 ... 0.95).contains(bounce) else { return nil }
        self = .spring(response: response, bounce: bounce)
    }

    static let ease = ShellMotion.ease(seconds: 0.2)

    init?(wire: UInt8) {
        switch wire {
        case 0: return nil
        case 1: self = .spring
        case 2: self = .bouncy
        case 3: self = .smooth
        default: self = wire == 4 ? .ease : .ease(seconds: Double(wire - 4) / 100)
        }
    }
}

struct ShellAnimation: Sendable {
    let motion: ShellMotion
    let speed: Double
    var curve: ShellCurve?
    var trails = false

    var fadeDuration: CFTimeInterval {
        0.18 / speed
    }

    func make(_ keyPath: String) -> CABasicAnimation {
        let (response, bounce): (Double, Double)
        switch motion {
        case .bouncy: (response, bounce) = (0.45, 0.3)
        case .smooth: (response, bounce) = (0.4, 0)
        case let .spring(value, amount): (response, bounce) = (value, amount)
        case let .ease(seconds):
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = seconds / speed
            animation.timingFunction = curve?.timing() ?? CAMediaTimingFunction(name: .easeInEaseOut)
            return animation
        }
        let animation = CASpringAnimation(perceptualDuration: response / speed, bounce: bounce)
        animation.keyPath = keyPath
        animation.duration = animation.settlingDuration
        return animation
    }
}

struct ShellLayerPaint: Sendable {
    let fill: CGColor?
    let border: CGColor?
    let borderWidth: CGFloat
    let radius: CGFloat
    let opacity: Float
    let scale: CGFloat
    let shadow: CGColor?
    let shadowRadius: CGFloat
    var material: UInt8 = 0
    var blurRadius: CGFloat = -1
    var saturation: CGFloat = 1.8
    var enter: ShellEnter?
    var masks = false
    var rotation: CGFloat = 0
    var quarter = false
    var loop: ShellLoop?
    var playback: ShellPlayback?
    var appear: ShellPresence?
    var exit: ShellPresence?
    var frameSize: CGSize?
}

struct ShellLayerMask {
    let layer: CALayer
    let host: CALayer
}

struct ShellLayerPath: Equatable, Sendable {
    let path: ShellPathData?
    let viewBox: CGRect?
    let evenOdd: Bool

    func fitted(to size: CGSize) -> CGPath? {
        path?.path(fitting: viewBox, into: size)
    }
}

enum ShellLayerCommand: Sendable {
    case insert(slot: Int32, parent: Int32, kind: ElementKind, after: Int32, identity: ShellLayerIdentity? = nil)
    case remove(slot: Int32)
    case move(slot: Int32, after: Int32)
    case frame(slot: Int32, rect: CGRect, animation: ShellAnimation?)
    case paint(slot: Int32, ShellLayerPaint, animation: ShellAnimation?)
    case text(
        slot: Int32,
        text: String,
        style: UInt32,
        color: CGColor,
        maxWidth: CGFloat,
        lines: Int,
        animation: ShellAnimation?
    )
    case image(slot: Int32, image: CGImage?, animation: ShellAnimation?, frames: ShellImageFrames? = nil)
    case value(slot: Int32, fraction: CGFloat, color: CGColor, track: CGColor?, animation: ShellAnimation?)
    case scroll(slot: Int32, origin: CGPoint)
    case shader(slot: Int32, program: ShellShaderProgram?, input: ShellShaderInput)
    case path(slot: Int32, ShellLayerPath, animation: ShellAnimation?)
    case transition(ShellShaderTransition)
    case stage(ShellShaderStage?)
    case clearExits
    case visibility(Bool)
    case gesture(slot: Int32, token: UInt64, value: ShellGestureTransform)
    case settleGesture(slot: Int32, token: UInt64, velocity: ShellGestureTransform, animation: ShellAnimation?)
}

final class ShellLayerScene: @unchecked Sendable {
    static let engineQueue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.engine", qos: .userInteractive)

    struct Progress {
        let fill: CALayer
        var track: CALayer?
        var knob: CALayer?
        var fraction: CGFloat = 0
    }

    let container: CALayer
    let scale: CGFloat
    var layers: [Int32: CALayer] = [:]
    var gestureLayers: [Int32: ShellGestureLayer] = [:]
    private var children: [Int32: Set<Int32>] = [:]
    var parents: [Int32: Int32] = [:]
    var progress: [Int32: Progress] = [:]
    var fonts: [UInt32: CTFont] = [:]
    var textContext: CGContext?
    var framed: Set<Int32> = []
    var exitAnimations: [Int32: ShellAnimation] = [:]
    var scales: [Int32: CGFloat] = [:]
    var rotations: [Int32: CGFloat] = [:]
    var quarters: Set<Int32> = []
    var loops: [Int32: (loop: ShellLoop, size: CGSize)] = [:]
    var imageFrames: [Int32: ShellImageFrames] = [:]
    var playbackSettings: [Int32: ShellPlayback] = [:]
    var playbacks: [Int32: ShellPlaybackState] = [:]
    var scrollOrigins: [Int32: CGPoint] = [:]
    var backdrops: [Int32: (backdrop: CALayer, tint: CALayer)] = [:]
    let presence = ShellPresenceState()
    var enters: [Int32: ShellEnter] = [:]
    var masks: [Int32: ShellLayerMask] = [:]
    var paths: [Int32: ShellLayerPath] = [:]
    static let enterPathKey = "omni.enter.path"
    var maskable: Set<Int32> = []
    var bitmaps: Set<Int32> = []
    static let enterOpacityKey = "omni.enter.opacity"
    static let enterTransformKey = "omni.enter.transform"
    static let framesKey = "omni.image.frames"
    var shaders: ShellShaderDrawer?
    var transition = ShellShaderTransition.settled
    private var stage: ShellShaderStage?
    private var visible = true
    static let clear = CGColor(gray: 0, alpha: 0)

    init(container: CALayer, scale: CGFloat) {
        self.container = container
        self.scale = scale
    }

    func sampleAlpha(_ slot: Int32, at point: CGPoint, reply: @escaping @Sendable (Float?) -> Void) {
        Self.engineQueue.async { [self] in
            reply(shaders?.alpha(slot, at: point))
        }
    }

    func submit(_ commands: [ShellLayerCommand], animated: Bool) {
        guard !commands.isEmpty else { return }
        let trace = ShellFrameTrace.current
        ShellFrameTrace.shared.record(.engineSubmit, context: trace)
        Self.engineQueue.async { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for command in commands {
                apply(command, animated: animated)
            }
            CATransaction.commit()
            if trace != nil {
                ShellFrameTrace.shared.commit(trace, time: CACurrentMediaTime())
            }
        }
    }

    private func apply(_ command: ShellLayerCommand, animated: Bool) {
        switch command {
        case let .insert(slot, parent, kind, after, identity):
            insert(slot: slot, parent: parent, kind: kind, after: after, identity: identity)
        case let .remove(slot):
            remove(slot, animated: animated)
        case let .move(slot, after):
            guard let layer = displayedLayer(slot), let host = layer.superlayer else { return }
            layer.removeFromSuperlayer()
            place(layer, in: host, after: after)
        case let .frame(slot, rect, preset):
            applyFrame(slot, rect, preset: preset, animated: animated)
        case let .paint(slot, paint, preset):
            applyPaint(slot, paint, preset: preset, animated: animated)
        case let .text(slot, text, style, color, maxWidth, lines, preset):
            replaceContents(
                slot,
                rasterize(text, style: style, color: color, maxWidth: maxWidth, lines: lines),
                preset: preset,
                animated: animated
            )
        case let .image(slot, image, preset, frames):
            applyImage(slot, image, frames: frames, preset: preset, animated: animated)
        case let .value(slot, fraction, color, track, preset):
            exitAnimations[slot] = preset
            applyValue(slot, fraction, color: color, track: track, animation: framedAnimation(preset, slot, animated))
        case let .shader(slot, program, input):
            guard let layer = layers[slot] else { return }
            shaderDrawer().update(slot, layer: layer, program: program, input: input, mask: masks[slot])
        case let .path(slot, path, preset):
            exitAnimations[slot] = preset
            applyPath(slot, path, animation: framedAnimation(preset, slot, animated))
        case let .scroll(slot, origin):
            applyScroll(slot, origin: origin)
        case let .transition(next):
            applyTransition(next)
        case let .stage(next):
            stage = next
            shaders?.setStage(next)
        case let .gesture(slot, token, value):
            applyGesture(slot, token: token, value: value)
        case let .settleGesture(slot, token, velocity, animation):
            settleGesture(slot, token: token, velocity: velocity, animation: animation)
        case .clearExits:
            finishAllPresenceExits()
        case let .visibility(isVisible):
            visible = isVisible
            if !isVisible { finishAllPresenceExits() }
            shaders?.setVisible(isVisible)
        }
    }

    private func applyImage(
        _ slot: Int32, _ image: CGImage?, frames: ShellImageFrames?, preset: ShellAnimation?, animated: Bool
    ) {
        replaceContents(slot, image, preset: preset, animated: animated)
        imageFrames[slot] = frames
        updatePlayback(slot, contentsReplaced: true)
    }

    private func applyScroll(_ slot: Int32, origin: CGPoint) {
        guard let layer = layers[slot] else { return }
        scrollOrigins[slot] = origin
        layer.masksToBounds = true
        layer.bounds.origin = origin
    }

    func framedAnimation(_ preset: ShellAnimation?, _ slot: Int32, _ animated: Bool) -> ShellAnimation? {
        animated && framed.contains(slot) ? preset : nil
    }

    private func remove(_ slot: Int32, animated: Bool) {
        if let mask = masks[slot], mask.host.mask === mask.layer {
            mask.host.mask = nil
        }
        if let layer = displayedLayer(slot) {
            retirePresence(slot, subtree: layer, animated: animated && visible)
        }
        if let parent = parents[slot] {
            children[parent]?.remove(slot)
        }
        forget(slot)
    }

    private func shaderDrawer() -> ShellShaderDrawer {
        if let shaders {
            return shaders
        }
        let drawer = ShellShaderDrawer(
            scale: scale,
            container: container,
            queue: Self.engineQueue
        ) { [weak self] frame in
            Self.engineQueue.async { [weak self] in
                self?.shaders?.finish(frame)
            }
        }
        drawer.setVisible(visible)
        drawer.setTransition(transition)
        drawer.setStage(stage)
        shaders = drawer
        return drawer
    }

    static func same(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
        (lhs ?? clear) == (rhs ?? clear)
    }

    private func insert(slot: Int32, parent: Int32, kind: ElementKind, after: Int32, identity: ShellLayerIdentity?) {
        insertPresence(slot, identity: identity)
        let layer = kind == .path ? CAShapeLayer() : CALayer()
        layer.anchorPoint = .zero
        layer.contentsScale = scale
        layer.cornerCurve = .continuous
        switch kind {
        case .label:
            layer.contentsGravity = .left
        case .symbol,
             .image,
             .bitmap:
            layer.contentsGravity = .resizeAspect
        case .shader:
            layer.contentsGravity = .resize
            layer.masksToBounds = true
            maskable.insert(slot)
        case .progress:
            let fill = CALayer()
            fill.anchorPoint = .zero
            fill.contentsScale = scale
            layer.addSublayer(fill)
            layer.masksToBounds = true
            progress[slot] = Progress(fill: fill)
        case .slider:
            insertSlider(in: layer, slot: slot)
        case .path:
            maskable.insert(slot)
        case .group,
             .box,
             .input:
            break
        }
        layers[slot] = layer
        if kind == .bitmap { bitmaps.insert(slot) }
        let host = parent >= 0 ? layers[parent] : container
        guard let host else { return }
        if parent >= 0 {
            children[parent, default: []].insert(slot)
            parents[slot] = parent
        }
        place(layer, in: host, after: after)
    }

    private func insertSlider(in layer: CALayer, slot: Int32) {
        let parts = (0 ..< 3).map { _ in
            let part = CALayer()
            part.anchorPoint = .zero
            part.contentsScale = scale
            layer.addSublayer(part)
            return part
        }
        parts[2].backgroundColor = CGColor(gray: 1, alpha: 1)
        parts[2].shadowOpacity = 0.3
        parts[2].shadowRadius = 1
        parts[2].shadowOffset = CGSize(width: 0, height: 0.5)
        progress[slot] = Progress(fill: parts[1], track: parts[0], knob: parts[2])
    }

    private func place(_ layer: CALayer, in host: CALayer, after: Int32) {
        if after >= 0, let previous = displayedLayer(after), previous.superlayer === host {
            host.insertSublayer(layer, above: previous)
        } else {
            host.insertSublayer(layer, at: 0)
        }
    }

    private func forget(_ slot: Int32) {
        forgetPresence(slot)
        gestureLayers.removeValue(forKey: slot)
        shaders?.remove(slot)
        enters.removeValue(forKey: slot)
        masks.removeValue(forKey: slot)
        maskable.remove(slot)
        bitmaps.remove(slot)
        paths.removeValue(forKey: slot)
        scales.removeValue(forKey: slot)
        rotations.removeValue(forKey: slot)
        quarters.remove(slot)
        loops.removeValue(forKey: slot)
        imageFrames.removeValue(forKey: slot)
        playbackSettings.removeValue(forKey: slot)
        playbacks.removeValue(forKey: slot)
        scrollOrigins.removeValue(forKey: slot)
        backdrops.removeValue(forKey: slot)
        layers.removeValue(forKey: slot)
        progress.removeValue(forKey: slot)
        parents.removeValue(forKey: slot)
        framed.remove(slot)
        exitAnimations.removeValue(forKey: slot)
        for child in children.removeValue(forKey: slot) ?? [] {
            forget(child)
        }
    }
}
