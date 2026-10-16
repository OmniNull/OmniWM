// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

public struct ShellGestureConfig: Equatable, Sendable, BitwiseCopyable {
    public enum Axis: UInt8, Sendable, BitwiseCopyable {
        case none, x, y, free, auto
    }

    public enum Source: UInt8, Sendable, BitwiseCopyable {
        case pointer, scroll, both
    }

    public enum Direction: UInt8, Sendable, BitwiseCopyable {
        case any, left, right, up, down
    }

    public var axis: Axis
    public var source: Source
    public var direction: Direction
    public var threshold: Float
    public var lockDistance: Float
    public var dominance: Float
    public var commitDistance: Float
    public var commitVelocity: Float
    public var eventsAll: Bool

    public init(
        axis: Axis = .none,
        source: Source = .pointer,
        direction: Direction = .any,
        threshold: Float = 4,
        lockDistance: Float = 1,
        dominance: Float = 1.25,
        commitDistance: Float = 0,
        commitVelocity: Float = 0,
        eventsAll: Bool = false
    ) {
        self.axis = axis
        self.source = source
        self.direction = direction
        self.threshold = threshold
        self.lockDistance = lockDistance
        self.dominance = dominance
        self.commitDistance = commitDistance
        self.commitVelocity = commitVelocity
        self.eventsAll = eventsAll
    }
}
