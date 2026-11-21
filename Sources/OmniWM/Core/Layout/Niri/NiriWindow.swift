// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

final class NiriWindow: NiriNode {
    var token: WindowToken

    var sizingMode: SizingMode = .normal

    var height: WeightedSize = .default {
        didSet {
            if oldValue != height {
                invalidateAxisSolveInputs()
            }
        }
    }

    var savedHeight: WeightedSize?

    var windowWidth: WeightedSize = .default {
        didSet {
            if oldValue != windowWidth {
                invalidateAxisSolveInputs()
            }
        }
    }

    var constraints: WindowSizeConstraints = .unconstrained {
        didSet {
            if oldValue != constraints {
                invalidateAxisSolveInputs()
            }
        }
    }

    var packingHints: ObservedPackingHints = .none {
        didSet {
            if oldValue != packingHints {
                invalidateAxisSolveInputs()
            }
        }
    }

    var liveSpanOverride: LiveSpanOverride? {
        didSet {
            if oldValue != liveSpanOverride {
                invalidateAxisSolveInputs()
            }
        }
    }

    var deferredMinimumOrientation: Monitor.Orientation?

    var resolvedHeight: CGFloat?

    var resolvedWidth: CGFloat?

    var heightFixedByConstraint: Bool = false

    var widthFixedByConstraint: Bool = false

    var lastFocusedTime: Date?

    var isHiddenInTabbedMode: Bool = false

    var moveXAnimation: MoveAnimation?
    var moveYAnimation: MoveAnimation?
    private enum SizeAnimations {
        case height(MoveAnimation)
        case width(MoveAnimation)
        case both(height: MoveAnimation, width: MoveAnimation)

        func offset(at time: TimeInterval, width: Bool) -> CGFloat {
            switch self {
            case let .height(animation): width ? 0 : animation.currentOffset(at: time)
            case let .width(animation): width ? animation.currentOffset(at: time) : 0
            case let .both(height, widthAnimation):
                if width {
                    widthAnimation.currentOffset(at: time)
                } else {
                    height.currentOffset(at: time)
                }
            }
        }

        func velocity(at time: TimeInterval, width: Bool) -> Double {
            switch self {
            case let .height(animation): width ? 0 : animation.currentVelocity(at: time)
            case let .width(animation): width ? animation.currentVelocity(at: time) : 0
            case let .both(height, widthAnimation):
                if width {
                    widthAnimation.currentVelocity(at: time)
                } else {
                    height.currentVelocity(at: time)
                }
            }
        }

        func completion(at time: TimeInterval) -> (height: Bool?, width: Bool?) {
            switch self {
            case let .height(animation): (animation.isComplete(at: time), nil)
            case let .width(animation): (nil, animation.isComplete(at: time))
            case let .both(height, width): (height.isComplete(at: time), width.isComplete(at: time))
            }
        }
    }

    private var sizeAnimations: SizeAnimations?

    var heightAnimation: MoveAnimation? {
        get {
            switch sizeAnimations {
            case let .height(animation): animation
            case let .both(animation, _): animation
            default: nil
            }
        }
        set { setSizeAnimation(newValue, width: false) }
    }

    var widthAnimation: MoveAnimation? {
        get {
            switch sizeAnimations {
            case let .width(animation): animation
            case let .both(_, animation): animation
            default: nil
            }
        }
        set { setSizeAnimation(newValue, width: true) }
    }

    private(set) var moveYContainmentFrame: CGRect?
    private(set) var columnExitOrientation: Monitor.Orientation?

    init(token: WindowToken) {
        self.token = token
        super.init()
    }

    override var size: CGFloat {
        get {
            switch height {
            case let .auto(weight): weight
            case .fixed,
                 .preset: 1.0
            }
        }
        set {
            height = .auto(weight: newValue)
        }
    }

    var isFullscreen: Bool {
        sizingMode == .fullscreen
    }

    var isMaximized: Bool {
        sizingMode == .maximized
    }

    func renderOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGPoint {
        var offset = CGPoint.zero
        if let moveX = moveXAnimation {
            offset.x = moveX.currentOffset(at: time)
        }
        if let moveY = moveYAnimation {
            offset.y = moveY.currentOffset(at: time)
        }
        return offset
    }

    func animateMoveFrom(
        displacement: CGPoint,
        yContainmentFrame: CGRect? = nil,
        leavingColumnIn orientation: Monitor.Orientation? = nil,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) {
        guard animated else {
            stopMoveAnimations()
            return
        }

        let now = clock?.now() ?? CACurrentMediaTime()
        let currentOffset = renderOffset(at: now)
        let currentVelX = moveXAnimation?.currentVelocity(at: now) ?? 0
        let currentVelY = moveYAnimation?.currentVelocity(at: now) ?? 0

        if displacement.x != 0 {
            let totalOffsetX = displacement.x + currentOffset.x
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVelX,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveXAnimation = MoveAnimation(animation: consume anim, fromOffset: totalOffsetX)
            if orientation == .vertical || columnExitOrientation == .vertical { columnExitOrientation = orientation }
        }
        if displacement.y != 0 {
            let totalOffsetY = displacement.y + currentOffset.y
            let anim = SpringAnimation(
                from: 1,
                to: 0,
                initialVelocity: currentVelY,
                startTime: now,
                config: config,
                displayRefreshRate: displayRefreshRate
            )
            moveYAnimation = MoveAnimation(animation: consume anim, fromOffset: totalOffsetY)
            moveYContainmentFrame = yContainmentFrame
            if orientation == .horizontal || columnExitOrientation ==
                .horizontal { columnExitOrientation = orientation }
        }
    }

    func renderHeightOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGFloat {
        sizeAnimations?.offset(at: time, width: false) ?? 0
    }

    func animateHeightFrom(
        delta: CGFloat,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) {
        guard animated else {
            heightAnimation = nil
            return
        }
        guard delta != 0 else { return }
        let now = clock?.now() ?? CACurrentMediaTime()
        let anim = SpringAnimation(
            from: 1,
            to: 0,
            initialVelocity: sizeAnimations?.velocity(at: now, width: false) ?? 0,
            startTime: now,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        heightAnimation = MoveAnimation(animation: consume anim, fromOffset: delta + renderHeightOffset(at: now))
    }

    func renderWidthOffset(at time: TimeInterval = CACurrentMediaTime()) -> CGFloat {
        sizeAnimations?.offset(at: time, width: true) ?? 0
    }

    func animateWidthFrom(
        delta: CGFloat,
        clock: AnimationClock?,
        config: SpringConfig = .default,
        displayRefreshRate: Double = 60.0,
        animated: Bool
    ) {
        guard animated else {
            widthAnimation = nil
            return
        }
        guard delta != 0 else { return }
        let now = clock?.now() ?? CACurrentMediaTime()
        let anim = SpringAnimation(
            from: 1,
            to: 0,
            initialVelocity: sizeAnimations?.velocity(at: now, width: true) ?? 0,
            startTime: now,
            config: config,
            displayRefreshRate: displayRefreshRate
        )
        widthAnimation = MoveAnimation(animation: consume anim, fromOffset: delta + renderWidthOffset(at: now))
    }

    func tickMoveAnimations(at time: TimeInterval) -> Bool {
        var running = false
        let sizeCompletion = sizeAnimations?.completion(at: time)
        if let widthComplete = sizeCompletion?.width {
            if widthComplete {
                widthAnimation = nil
            } else {
                running = true
            }
        }
        if let heightComplete = sizeCompletion?.height {
            if heightComplete {
                heightAnimation = nil
            } else {
                running = true
            }
        }
        if let moveX = moveXAnimation {
            if moveX.isComplete(at: time) {
                moveXAnimation = nil
                if columnExitOrientation == .vertical { columnExitOrientation = nil }
            } else {
                running = true
            }
        }
        if let moveY = moveYAnimation {
            if moveY.isComplete(at: time) {
                moveYAnimation = nil
                moveYContainmentFrame = nil
                if columnExitOrientation == .horizontal { columnExitOrientation = nil }
            } else {
                running = true
            }
        }
        return running
    }

    func stopMoveAnimations() {
        if moveXAnimation != nil {
            moveXAnimation = nil
        }
        if moveYAnimation != nil {
            moveYAnimation = nil
        }
        sizeAnimations = nil
        moveYContainmentFrame = nil
        columnExitOrientation = nil
    }

    var hasMoveAnimationsRunning: Bool {
        moveXAnimation != nil || moveYAnimation != nil || sizeAnimations != nil
    }

    var hasAnyAnimationRunning: Bool {
        hasMoveAnimationsRunning
    }
}

extension NiriWindow {
    private static func sizeAnimations(
        height: consuming MoveAnimation?,
        width: consuming MoveAnimation?
    ) -> SizeAnimations? {
        if let height = consume height {
            if let width = consume width {
                return .both(height: consume height, width: consume width)
            }
            return .height(consume height)
        }
        if let width = consume width {
            return .width(consume width)
        }
        return nil
    }

    private func setSizeAnimation(_ animation: consuming MoveAnimation?, width: Bool) {
        var previous: SizeAnimations?
        swap(&sizeAnimations, &previous)
        switch consume previous {
        case let .height(height):
            if width {
                sizeAnimations = Self.sizeAnimations(height: consume height, width: consume animation)
            } else {
                sizeAnimations = Self.sizeAnimations(height: consume animation, width: nil)
            }
        case let .width(previousWidth):
            if width {
                sizeAnimations = Self.sizeAnimations(height: nil, width: consume animation)
            } else {
                sizeAnimations = Self.sizeAnimations(height: consume animation, width: consume previousWidth)
            }
        case let .both(height, previousWidth):
            if width {
                sizeAnimations = Self.sizeAnimations(height: consume height, width: consume animation)
            } else {
                sizeAnimations = Self.sizeAnimations(height: consume animation, width: consume previousWidth)
            }
        case nil:
            if width {
                sizeAnimations = Self.sizeAnimations(height: nil, width: consume animation)
            } else {
                sizeAnimations = Self.sizeAnimations(height: consume animation, width: nil)
            }
        }
    }
}
