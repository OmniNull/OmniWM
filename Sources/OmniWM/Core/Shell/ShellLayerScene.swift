// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
    var reveal: ShellRevealRecipe?
    var morph: ShellMorphRecipe?
    var frameSize: CGSize?
    var pulse: ShellPulseRecipe?
    var shadowOffset: CGSize = .zero
    var gradient: [CGColor]?
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
    case effect(slot: Int32, input: ShellGroupEffectInput?)
    case effectNeutral(slot: Int32, Bool)
    case path(slot: Int32, ShellLayerPath, animation: ShellAnimation?)
    case glass(slot: Int32, ShellGlassContent, animation: ShellAnimation?)
    case transition(ShellShaderTransition)
    case spectrumMotion(MotionSnapshot)
    case stage(ShellShaderStage?)
    case clearExits
    case visibility(Bool)
    case gesture(slot: Int32, token: UInt64, value: ShellGestureTransform)
    case settleGesture(slot: Int32, token: UInt64, velocity: ShellGestureTransform, animation: ShellAnimation?)
    case manipulation(slot: Int32, token: UInt64, presentation: ShellManipulationPresentation, active: Bool)
    case shapeFollow(slot: Int32, binding: ShellShapeFollowBinding, presentation: ShellManipulationPresentation)
    case retainedFollowers(
        target: Int32, frame: CGRect, presentation: ShellManipulationPresentation,
        time: CFTimeInterval
    )
    case followExit(target: Int32, followers: [ShellFollowExitBinding])
    case boundTrack(slot: Int32, ShellBoundInput)
    case raise(slot: Int32, Bool)
    case reveal(slot: Int32, token: UInt64, ShellReveal)
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
    var clock: (() -> CFTimeInterval)?
    var submitTime: CFTimeInterval?
    var layers: [Int32: CALayer] = [:]
    var gestureLayers: [Int32: ShellGestureLayer] = [:]
    var onManipulationSettled: (@MainActor @Sendable (Int32, UInt64, UInt64) -> Void)?
    private(set) var children: [Int32: Set<Int32>] = [:]
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
    var pulseKeys: [Int32: UInt64] = [:]
    var imageFrames: [Int32: ShellImageFrames] = [:]
    var playbackSettings: [Int32: ShellPlayback] = [:]
    var playbacks: [Int32: ShellPlaybackState] = [:]
    var scrollOrigins: [Int32: CGPoint] = [:]
    var backdrops: [Int32: (backdrop: CALayer, tint: CALayer)] = [:]
    var glassBodies: [Int32: ShellGlassBody] = [:]
    var glassShapes: [Int32: ShellGlassShape] = [:]
    var glassStyles: [Int32: (recipe: ShellGlassRecipe, paint: ShellLayerPaint)] = [:]
    var glassShapeSlots: [ObjectIdentifier: Int32] = [:]
    var dirtyGlass: Set<Int32> = []
    var glassAnimations: [Int32: ShellAnimation] = [:]
    var rasterCompletions: [UUID: (ShellScriptFailure?) -> Void] = [:]
    let glassNativeEnabled: Bool
    let presence = ShellPresenceState()
    let spectrum = ShellSpectrumShapeStore()
    let shapeTracks = ShellShapeTrackStore()
    var enters: [Int32: ShellEnter] = [:]
    var masks: [Int32: ShellLayerMask] = [:]
    var paths: [Int32: ShellLayerPath] = [:]
    static let enterPathKey = "omni.enter.path"
    var maskable: Set<Int32> = []
    var bitmaps: Set<Int32> = []
    static let enterOpacityKey = "omni.enter.opacity"
    static let enterTransformKey = "omni.enter.transform"
    var shaders: ShellShaderDrawer?
    var effects: [Int32: ShellGroupEffect] = [:]
    var transition = ShellShaderTransition.settled
    private var stage: ShellShaderStage?
    private var visible = true
    static let clear = CGColor(gray: 0, alpha: 0)

    init(container: CALayer, scale: CGFloat, glassNativeEnabled: Bool = true) {
        self.container = container
        self.scale = scale
        self.glassNativeEnabled = glassNativeEnabled
    }

    func sampleAlpha(_ slot: Int32, at point: CGPoint, reply: @escaping @Sendable (Float?) -> Void) {
        Self.engineQueue.async { [self] in
            reply(shaders?.alpha(slot, at: point))
        }
    }

    func submit(_ commands: [ShellLayerCommand], animated: Bool, completion: (@Sendable () -> Void)? = nil) {
        guard !commands.isEmpty || completion != nil else { return }
        let trace = ShellFrameTrace.current
        ShellFrameTrace.shared.record(.engineSubmit, context: trace)
        let time = clock?()
        Self.engineQueue.async { [self] in
            submitTime = time
            defer { submitTime = nil }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for command in commands {
                apply(command, animated: animated)
            }
            flushGlass(animated: animated)
            flushReveals(animated: animated)
            flushPulses()
            CATransaction.commit()
            if !effects.isEmpty { shaders?.redrawGroups() }
            completion?()
            if trace != nil {
                ShellFrameTrace.shared.commit(trace, time: CACurrentMediaTime())
            }
        }
    }

    private func apply(_ command: ShellLayerCommand, animated: Bool) {
        if applyFollowCommand(command) || applyShaderCommand(command) { return }
        switch command {
        case let .insert(slot, parent, kind, after, identity):
            insert(slot: slot, parent: parent, kind: kind, after: after, identity: identity)
        case let .remove(slot):
            invalidateContainingEffect(slot)
            remove(slot, animated: animated && visible)
        case let .move(slot, after):
            guard move(slot, after: after) else { return }
        case let .frame(slot, rect, preset):
            applyFrame(slot, rect, preset: preset, animated: animated)
        case let .paint(slot, paint, preset):
            applyPaint(slot, paint, preset: preset, animated: animated)
        case let .text(slot, text, style, color, maxWidth, lines, preset):
            let image = rasterize(text, style: style, color: color, maxWidth: maxWidth, lines: lines)
            replaceContents(slot, image, preset: preset, animated: animated)
        case let .image(slot, image, preset, frames):
            applyImage(slot, image, frames: frames, preset: preset, animated: animated)
        case let .value(slot, fraction, color, track, preset):
            exitAnimations[slot] = preset
            applyValue(slot, fraction, color: color, track: track, animation: framedAnimation(preset, slot, animated))
        case let .path(slot, path, preset):
            exitAnimations[slot] = preset
            applyPath(slot, path, animation: framedAnimation(preset, slot, animated))
        case let .glass(slot, content, preset):
            applyGlass(slot, content, preset: preset, animated: animated)
        case let .scroll(slot, origin):
            applyScroll(slot, origin: origin)
        case let .gesture(slot, token, value):
            applyGesture(slot, token: token, value: value)
        case let .settleGesture(slot, token, velocity, animation):
            settleGesture(slot, token: token, velocity: velocity, animation: animation)
        case .shader,
             .effect,
             .effectNeutral,
             .transition,
             .spectrumMotion,
             .stage,
             .visibility,
             .clearExits,
             .manipulation,
             .raise,
             .shapeFollow,
             .retainedFollowers,
             .followExit,
             .boundTrack,
             .reveal:
            break
        }
        invalidateEffect(for: command)
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

    func shaderDrawer() -> ShellShaderDrawer {
        if let shaders {
            return shaders
        }
        let drawer = ShellShaderDrawer(
            scale: scale,
            container: container,
            queue: Self.engineQueue,
            published: { [weak self] slot in
                guard let self, effects[slot] == nil, invalidateContainingEffect(slot) else { return }
                Self.engineQueue.async { [weak self] in self?.shaders?.redrawGroups() }
            },
            completion: { [weak self] frame in
                Self.engineQueue.async { [weak self] in
                    self?.shaders?.finish(frame)
                }
            }
        )
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
        case .input:
            layer.contentsGravity = .topLeft
            layer.masksToBounds = true
        case .group,
             .box:
            break
        case .glass,
             .shape:
            insertGlass(slot, kind: kind, layer: layer)
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

    private func move(_ slot: Int32, after: Int32) -> Bool {
        guard let layer = displayedLayer(slot), let host = layer.superlayer else { return false }
        layer.removeFromSuperlayer()
        place(layer, in: host, after: after)
        markGlassDirty(slot)
        return true
    }

    private func place(_ layer: CALayer, in host: CALayer, after: Int32) {
        if after >= 0, let previous = displayedLayer(after), previous.superlayer === host {
            host.insertSublayer(layer, above: previous)
        } else {
            host.insertSublayer(layer, at: 0)
        }
    }

    func forget(_ slot: Int32) {
        if let parent = parents[slot] { children[parent]?.remove(slot) }
        forgetPulse(slot)
        forgetGlass(slot)
        forgetPresence(slot)
        gestureLayers.removeValue(forKey: slot)
        shaders?.remove(slot)
        effects.removeValue(forKey: slot)
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

extension ShellLayerScene {
    private func applyShaderCommand(_ command: ShellLayerCommand) -> Bool {
        switch command {
        case let .shader(slot, program, input):
            if let layer = layers[slot] {
                shaderDrawer().update(slot, layer: layer, program: program, input: input, mask: masks[slot])
            }
        case let .effect(slot, input):
            applyEffect(slot, input: input)
        case let .effectNeutral(slot, value):
            if let effect = effects[slot], effect.neutral != value {
                effect.setNeutral(value)
                shaderDrawer().updateGroup(slot, group: effect)
            }
        case let .spectrumMotion(motion):
            setSpectrumMotion(motion)
        case let .followExit(target, followers):
            shapeTracks.departures[target] = followers
        case let .boundTrack(slot, input):
            shapeTracks.pendingBounds[slot] = input
        case let .transition(next):
            applyTransition(next)
        case let .stage(next):
            stage = next
            shaders?.setStage(next)
        case let .visibility(isVisible):
            visible = isVisible
            setSpectrumVisible(isVisible)
            if !isVisible {
                finishAllPresenceExits()
                finishShapeTracks()
            }
            shaders?.setVisible(isVisible)
        case .clearExits:
            finishAllPresenceExits()
            finishShapeTracks()
        case let .reveal(slot, token, plan):
            presence.revealPlans[slot] = (plan, token)
            if plan.target != 0 { presence.dirtyReveals.insert(slot) }
        default:
            return false
        }
        invalidateEffect(for: command)
        return true
    }
}
