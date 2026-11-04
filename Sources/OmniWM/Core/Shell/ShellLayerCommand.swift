// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore
import QuartzCore

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
    case backingScale(CGFloat)
}
