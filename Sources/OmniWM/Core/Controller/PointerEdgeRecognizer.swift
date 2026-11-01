// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct PointerEdgeTopology: Sendable {
    struct EdgeKey: Hashable, Sendable {
        let monitorId: Monitor.ID
        let direction: Direction
    }

    struct Edge: Sendable {
        let target: Monitor?
        let finSpan: CGRect?
    }

    static let pushDistance: CGFloat = 96
    static let warpCooldownNs: UInt64 = 50_000_000
    static let containmentFreshnessNs: UInt64 = 1_000_000_000

    var isEnabled = false
    var margin: CGFloat = 1
    var flipY: CGFloat = 0
    var monitors: [Monitor] = []
    var edges: [EdgeKey: Edge] = [:]
    var containment: MouseContainment?

    func monitor(_ id: Monitor.ID) -> Monitor? {
        monitors.first { $0.id == id }
    }

    func monitor(containing point: CGPoint) -> Monitor? {
        monitors.first { $0.frame.contains(point) }
    }
}

struct PointerEdgeRecognizer: Sendable {
    struct Hold: Equatable, Sendable {
        let key: PointerEdgeTopology.EdgeKey
        var pressure: CGFloat
        var outward: CGFloat
    }

    struct Crossing: Equatable, Sendable {
        let source: Monitor.ID
        let target: Monitor
        let direction: Direction
        let destination: CGPoint
        let pushed: Bool
    }

    enum Decision: Equatable {
        case pass
        case clamp(CGPoint)
        case wall(CGPoint, source: Monitor.ID, blocked: Monitor.ID)
        case cross(Crossing)
    }

    private struct Sample {
        let location: CGPoint
        let motion: CGVector
        let timestamp: UInt64
    }

    private struct HoldBoundary {
        let sourceFrame: CGRect
        let key: PointerEdgeTopology.EdgeKey
        let margin: CGFloat
    }

    private(set) var hold: Hold?
    private var lastLocation: CGPoint?
    private var lastMonitorId: Monitor.ID?
    private var lastSampleAt: UInt64?
    private var cooldownUntil: UInt64 = 0

    mutating func reset() {
        hold = nil
        lastLocation = nil
        lastMonitorId = nil
        lastSampleAt = nil
        cooldownUntil = 0
    }

    mutating func noteCursorMoved(to location: CGPoint, monitor: Monitor.ID?, at timestamp: UInt64) {
        hold = nil
        lastLocation = location
        lastMonitorId = monitor
        lastSampleAt = timestamp
        cooldownUntil = timestamp + PointerEdgeTopology.warpCooldownNs
    }

    mutating func crossFailed() {
        hold?.pressure = 0
    }

    mutating func handle(
        location: CGPoint,
        motion: CGVector,
        timestamp: UInt64,
        topology: PointerEdgeTopology
    ) -> Decision {
        guard topology.isEnabled else {
            reset()
            return .pass
        }
        let coolingDown = timestamp < cooldownUntil
        if let last = lastLocation {
            let moved = hypot(motion.dx, motion.dy)
            if hypot(location.x - last.x, location.y - last.y) > moved + max(3, moved * 0.3) {
                hold = nil
                lastLocation = nil
                lastMonitorId = nil
            }
        }
        guard let source = lastMonitorId.flatMap(topology.monitor) ?? topology.monitor(containing: location) else {
            lastLocation = location
            return .pass
        }
        let inside = source.frame.contains(location)
        let direction = heldDirection(at: location, in: source, inside: inside, margin: topology.margin)
            ?? (inside
                ? MouseWarpGeometry.crossing(location: location, frame: source.frame, margin: topology.margin)?
                .direction
                : Self.exitDirection(of: location, from: source.frame))
        let key = direction.map { PointerEdgeTopology.EdgeKey(monitorId: source.id, direction: $0) }
        let edge = key.flatMap { topology.edges[$0] }
        let continuing = hold != nil && hold?.key == key && edge?.target != nil
        let starting = !continuing && edge?.target != nil
            && edge?.finSpan.map { Self.spans($0, location, direction) } == true
        let sample = Sample(location: location, motion: motion, timestamp: timestamp)
        if !coolingDown, let key, let target = edge?.target, continuing || starting {
            return holdDecision(
                sample: sample,
                boundary: HoldBoundary(sourceFrame: source.frame, key: key, margin: topology.margin),
                target: target, inside: inside, starting: starting
            )
        }

        return unheldDecision(
            sample: sample,
            source: source,
            topology: topology,
            inside: inside,
            coolingDown: coolingDown
        )
    }

    private mutating func unheldDecision(
        sample: Sample,
        source: Monitor,
        topology: PointerEdgeTopology,
        inside: Bool,
        coolingDown: Bool
    ) -> Decision {
        hold = nil
        if !inside,
           let wall = containmentDecision(
               location: sample.location,
               source: source,
               timestamp: sample.timestamp,
               topology: topology
           )
        {
            return wall
        }
        lastLocation = sample.location
        let current = inside ? source : topology.monitor(containing: sample.location)
        if let current {
            lastMonitorId = current.id
            lastSampleAt = sample.timestamp
        }
        let warpSource = current ?? source
        guard !coolingDown, let zone = MouseWarpGeometry.crossing(
                  location: sample.location,
                  frame: warpSource.frame,
                  margin: topology.margin
              ),
              let target = topology.edges[.init(monitorId: warpSource.id, direction: zone.direction)]?.target
        else { return .pass }
        return .cross(Crossing(
            source: warpSource.id,
            target: target,
            direction: zone.direction,
            destination: MouseWarpGeometry.destinationPoint(
                on: target.frame, entryEdge: zone.entryEdge, ratio: zone.ratio, margin: topology.margin
            ),
            pushed: false
        ))
    }

    private mutating func holdDecision(
        sample: Sample,
        boundary: HoldBoundary,
        target: Monitor,
        inside: Bool,
        starting: Bool
    ) -> Decision {
        let direction = boundary.key.direction
        let accepted = inside ? sample.location : Self.edgePoint(
            sample.location, in: boundary.sourceFrame, direction: direction
        )
        let outward = Self.outward(accepted, direction)
        lastMonitorId = boundary.key.monitorId
        lastLocation = accepted
        lastSampleAt = sample.timestamp
        if starting {
            hold = Hold(key: boundary.key, pressure: 0, outward: outward)
        } else if var current = hold {
            let push = Self.outward(sample.motion, direction) - max(0, outward - current.outward)
            current.pressure = max(0, current.pressure + push)
            current.outward = outward
            hold = current
            if current.pressure >= PointerEdgeTopology.pushDistance {
                let zone = MouseWarpGeometry.crossing(
                    toward: direction, location: accepted, frame: boundary.sourceFrame
                )
                return .cross(Crossing(
                    source: boundary.key.monitorId,
                    target: target,
                    direction: direction,
                    destination: MouseWarpGeometry.destinationPoint(
                        on: target.frame, entryEdge: zone.entryEdge, ratio: zone.ratio, margin: boundary.margin
                    ),
                    pushed: true
                ))
            }
        }
        return accepted == sample.location ? .pass : .clamp(accepted)
    }

    private mutating func containmentDecision(
        location: CGPoint,
        source: Monitor,
        timestamp: UInt64,
        topology: PointerEdgeTopology
    ) -> Decision? {
        guard let containment = topology.containment,
              let destination = topology.monitors.first(where: { $0.id != source.id && $0.frame.contains(location) })
        else { return nil }
        let fresh = lastSampleAt.map {
            timestamp >= $0 && timestamp - $0 <= PointerEdgeTopology.containmentFreshnessNs
        } == true
        lastSampleAt = timestamp
        guard fresh,
              case let .wall(clamped) = containment.evaluate(
                  location: location, source: source, destination: destination, margin: topology.margin
              )
        else {
            lastMonitorId = destination.id
            lastLocation = location
            return .pass
        }
        lastLocation = clamped
        return .wall(clamped, source: source.id, blocked: destination.id)
    }

    private func heldDirection(at point: CGPoint, in source: Monitor, inside: Bool, margin: CGFloat) -> Direction? {
        guard let held = hold?.key, held.monitorId == source.id else { return nil }
        let frame = source.frame
        let reach = inside ? margin : 0
        let reached = switch held.direction {
        case .right: point.x >= frame.maxX - reach
        case .left: point.x <= frame.minX + reach
        case .up: point.y >= frame.maxY - reach
        case .down: point.y <= frame.minY + reach
        }
        return reached ? held.direction : nil
    }

    static func exitDirection(of point: CGPoint, from frame: CGRect) -> Direction? {
        let right = point.x - frame.maxX
        let left = frame.minX - point.x
        let up = point.y - frame.maxY
        let down = frame.minY - point.y
        let farthest = max(max(right, left), max(up, down))
        guard farthest >= 0 else { return nil }
        if right == farthest { return .right }
        if left == farthest { return .left }
        return up == farthest ? .up : .down
    }

    static func edgePoint(_ point: CGPoint, in frame: CGRect, direction: Direction) -> CGPoint {
        let x = min(max(point.x, frame.minX), frame.maxX - 0.5)
        let y = min(max(point.y, frame.minY + 0.5), frame.maxY - 0.5)
        switch direction {
        case .right: return CGPoint(x: frame.maxX - 0.5, y: y)
        case .left: return CGPoint(x: frame.minX, y: y)
        case .up: return CGPoint(x: x, y: frame.maxY - 0.5)
        case .down: return CGPoint(x: x, y: frame.minY + 0.5)
        }
    }

    static func outward(_ point: CGPoint, _ direction: Direction) -> CGFloat {
        switch direction {
        case .right: point.x
        case .left: -point.x
        case .up: point.y
        case .down: -point.y
        }
    }

    static func outward(_ vector: CGVector, _ direction: Direction) -> CGFloat {
        outward(CGPoint(x: vector.dx, y: vector.dy), direction)
    }

    private static func spans(_ span: CGRect, _ point: CGPoint, _ direction: Direction?) -> Bool {
        switch direction {
        case .left,
             .right: point.y >= span.minY && point.y <= span.maxY
        case .up,
             .down: point.x >= span.minX && point.x <= span.maxX
        case nil: false
        }
    }
}
