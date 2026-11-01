// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreHID
import Foundation
import IOKit
import os
import Synchronization

private let multitouchTouchStride = 96
private let multitouchPathIdByteOffset = 16
private let multitouchStateByteOffset = 20
private let multitouchFingerIdByteOffset = 24
private let multitouchPositionXByteOffset = 32
private let multitouchPositionYByteOffset = 36
private let multitouchMajorAxisByteOffset = 60
private let multitouchTouchingState: Int32 = 4

struct MultitouchContactSession: Equatable, Sendable {
    let generation: UInt
    let slot: Int
    let session: UInt64
    let senderId: UInt64?
}

struct MultitouchContactSessions: Sendable {
    var generation: UInt = 0
    var sessions = InlineArray<64, UInt64>(repeating: 0)

    func contains(_ contact: MultitouchContactSession) -> Bool {
        generation != 0 && contact.generation == generation
            && contact.slot >= 0 && contact.slot < sessions.count
            && contact.session != 0 && sessions[contact.slot] == contact.session
    }
}

extension MultitouchGestureSource {
    struct RawTouch: Sendable {
        let x: Float
        let y: Float
    }

    struct RawTouchBuffer: RandomAccessCollection, Sendable {
        private var inline = InlineArray<16, RawTouch>(repeating: RawTouch(x: 0, y: 0))
        private var overflow: [RawTouch] = []
        private(set) var count = 0

        var startIndex: Int {
            0
        }

        var endIndex: Int {
            count
        }

        init() {}

        init(_ touches: [RawTouch]) {
            for touch in touches {
                append(touch)
            }
        }

        mutating func append(_ touch: RawTouch) {
            if count < inline.count {
                inline[count] = touch
            } else {
                overflow.append(touch)
            }
            count += 1
        }

        subscript(index: Int) -> RawTouch {
            index < inline.count ? inline[index] : overflow[index - inline.count]
        }
    }

    struct RawFrame: Sendable {
        let touches: RawTouchBuffer
        let timestamp: Double

        init(touches: [RawTouch], timestamp: Double) {
            self.touches = RawTouchBuffer(touches)
            self.timestamp = timestamp
        }

        init(touches: consuming RawTouchBuffer, timestamp: Double) {
            self.touches = consume touches
            self.timestamp = timestamp
        }
    }

    static func makeSnapshot(
        frame: RawFrame,
        location: CGPoint,
        previousActiveCount: Int,
        terminalPhase: NSEvent.Phase = .ended,
        contactSession: MultitouchContactSession? = nil
    ) -> (snapshot: MouseEventHandler.GestureEventSnapshot?, activeCount: Int) {
        let activeCount = frame.touches.count
        if activeCount == 0 {
            guard previousActiveCount > 0 else { return (nil, 0) }
            return (
                liftSnapshot(
                    terminalPhase,
                    location: location,
                    timestamp: frame.timestamp,
                    contactSession: contactSession
                ),
                0
            )
        }

        let phase: NSEvent.Phase = previousActiveCount == 0 ? .began : .changed
        let touches = frame.touches.map { touch in
            MouseEventHandler.GestureTouchSample(
                phase: .moved,
                normalizedPosition: normalizedPosition(x: touch.x, y: touch.y)
            )
        }
        let snapshot = MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: frame.timestamp,
            touches: touches,
            contactSession: contactSession
        )
        return (snapshot, activeCount)
    }

    static func liftSnapshot(
        _ phase: NSEvent.Phase,
        location: CGPoint,
        timestamp: Double,
        contactSession: MultitouchContactSession? = nil
    ) -> MouseEventHandler.GestureEventSnapshot {
        MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: timestamp,
            touches: [],
            contactSession: contactSession
        )
    }

    private static func normalizedPosition(x: Float, y: Float) -> CGPoint? {
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    nonisolated static func buildRawFrame(
        fingers: UnsafeMutableRawPointer?,
        count: Int32,
        timestamp: Double,
        palmFilter: inout MultitouchPalmFilter
    ) -> RawFrame {
        defer { palmFilter.finishFrame() }
        guard let fingers, count > 0 else { return RawFrame(touches: [], timestamp: timestamp) }
        var touches = RawTouchBuffer()
        for index in 0 ..< Int(count) {
            let base = index * multitouchTouchStride
            let state = fingers.load(fromByteOffset: base + multitouchStateByteOffset, as: Int32.self)
            let isPalm = palmFilter.isPalm(
                pathId: fingers.load(fromByteOffset: base + multitouchPathIdByteOffset, as: Int32.self),
                fingerId: fingers.load(fromByteOffset: base + multitouchFingerIdByteOffset, as: Int32.self),
                majorAxis: fingers.load(fromByteOffset: base + multitouchMajorAxisByteOffset, as: Float.self)
            )
            guard state == multitouchTouchingState, !isPalm else { continue }
            let x = fingers.load(fromByteOffset: base + multitouchPositionXByteOffset, as: Float.self)
            let y = fingers.load(fromByteOffset: base + multitouchPositionYByteOffset, as: Float.self)
            touches.append(RawTouch(x: x, y: y))
        }
        return RawFrame(touches: touches, timestamp: timestamp)
    }
}
