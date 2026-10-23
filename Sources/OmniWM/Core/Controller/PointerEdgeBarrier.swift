// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
import Foundation
import Synchronization

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
        if !coolingDown, let key, let direction, let target = edge?.target, continuing || starting {
            return holdDecision(
                location: location, motion: motion, timestamp: timestamp, source: source, inside: inside,
                key: key, direction: direction, target: target, starting: starting, margin: topology.margin
            )
        }

        hold = nil
        if !inside,
           let wall = containmentDecision(location: location, source: source, timestamp: timestamp, topology: topology)
        {
            return wall
        }
        lastLocation = location
        let current = inside ? source : topology.monitor(containing: location)
        if let current {
            lastMonitorId = current.id
            lastSampleAt = timestamp
        }
        let warpSource = current ?? source
        guard !coolingDown, let zone = MouseWarpGeometry.crossing(
                  location: location,
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
        location: CGPoint,
        motion: CGVector,
        timestamp: UInt64,
        source: Monitor,
        inside: Bool,
        key: PointerEdgeTopology.EdgeKey,
        direction: Direction,
        target: Monitor,
        starting: Bool,
        margin: CGFloat
    ) -> Decision {
        let accepted = inside ? location : Self.edgePoint(location, in: source.frame, direction: direction)
        let outward = Self.outward(accepted, direction)
        lastMonitorId = source.id
        lastLocation = accepted
        lastSampleAt = timestamp
        if starting {
            hold = Hold(key: key, pressure: 0, outward: outward)
        } else if var current = hold {
            let push = Self.outward(motion, direction) - max(0, outward - current.outward)
            current.pressure = max(0, current.pressure + push)
            current.outward = outward
            hold = current
            if current.pressure >= PointerEdgeTopology.pushDistance {
                let zone = MouseWarpGeometry.crossing(toward: direction, location: accepted, frame: source.frame)
                return .cross(Crossing(
                    source: source.id,
                    target: target,
                    direction: direction,
                    destination: MouseWarpGeometry.destinationPoint(
                        on: target.frame, entryEdge: zone.entryEdge, ratio: zone.ratio, margin: margin
                    ),
                    pushed: true
                ))
            }
        }
        return accepted == location ? .pass : .clamp(accepted)
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

final class PointerEdgeBarrier: Sendable {
    typealias DisplayBounds = @Sendable (CGDirectDisplayID) -> CGRect?
    typealias WarpCursor = @Sendable (CGPoint) -> CGError
    typealias PostMove = @Sendable (CGPoint) -> Void
    typealias Clock = @Sendable () -> UInt64

    private struct State {
        var topology = PointerEdgeTopology()
        var recognizer = PointerEdgeRecognizer()
    }

    private struct TapState {
        var runLoop: CFRunLoop?
        var running = false
        var installed = false
        var stopRequested = false
        var needsReenable = false
    }

    private let state = Mutex(State())
    private let tapState = Mutex(TapState())
    private let installsTap: Bool
    private let displayBounds: DisplayBounds
    private let warpCursor: WarpCursor
    private let postMove: PostMove
    private let clock: Clock

    init(
        installsTap: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        displayBounds: @escaping DisplayBounds = PointerEdgeBarrier.activeDisplayBounds,
        warpCursor: @escaping WarpCursor = { CGWarpMouseCursorPosition($0) },
        postMove: @escaping PostMove = PointerEdgeBarrier.postSyntheticMove,
        clock: @escaping Clock = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    ) {
        self.installsTap = installsTap
        self.displayBounds = displayBounds
        self.warpCursor = warpCursor
        self.postMove = postMove
        self.clock = clock
    }

    var ownsCrossings: Bool {
        tapState.withLock { $0.installed && !$0.stopRequested }
    }

    func publish(_ topology: PointerEdgeTopology) {
        state.withLock { $0.topology = topology }
    }

    func reset() {
        state.withLock { $0.recognizer.reset() }
    }

    func noteProgrammaticMove(to location: CGPoint) {
        let now = clock()
        state.withLock { current in
            let monitor = current.topology.monitor(containing: location)?.id
            current.recognizer.noteCursorMoved(to: location, monitor: monitor, at: now)
        }
    }

    func start() {
        guard installsTap else { return }
        let shouldStart = tapState.withLock { current -> Bool in
            current.stopRequested = false
            guard !current.running else { return false }
            current.running = true
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [self] in runTap() }
        thread.name = "OmniWM.PointerEdge"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        state.withLock { current in
            current.topology.isEnabled = false
            current.recognizer.reset()
        }
        tapState.withLock { current in
            current.stopRequested = true
            guard let runLoop = current.runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func runTap() {
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<PointerEdgeBarrier>.fromOpaque(info).takeUnretainedValue().handleTapEvent(type, event)
        }
        guard let port = CGEvent.tapCreate(
                  tap: .cghidEventTap,
                  place: .headInsertEventTap,
                  options: .defaultTap,
                  eventsOfInterest: 1 << CGEventType.mouseMoved.rawValue,
                  callback: callback,
                  userInfo: Unmanaged.passUnretained(self).toOpaque()
              ),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else {
            MouseTrace.record("pointer-edge tap unavailable")
            tapState.withLock { $0 = TapState() }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapState.withLock { current in
            current.runLoop = CFRunLoopGetCurrent()
            current.installed = true
        }
        EventIntake.post(.pointerEdgeOwnershipChanged)
        while true {
            let (stop, reenable) = tapState.withLock { current -> (Bool, Bool) in
                if current.stopRequested {
                    current = TapState()
                    return (true, false)
                }
                defer { current.needsReenable = false }
                return (false, current.needsReenable)
            }
            if stop { break }
            if reenable {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            CFRunLoopRun()
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMachPortInvalidate(port)
        EventIntake.post(.pointerEdgeOwnershipChanged)
    }

    func handleTapEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapState.withLock { $0.needsReenable = true }
            CFRunLoopStop(CFRunLoopGetCurrent())
            reset()
            return Unmanaged.passUnretained(event)
        }
        guard type == .mouseMoved else { return Unmanaged.passUnretained(event) }
        let receivedAt = clock()
        let cgLocation = event.location
        let cgDeltaX = event.getDoubleValueField(.mouseEventDeltaX)
        let cgDeltaY = event.getDoubleValueField(.mouseEventDeltaY)
        let (decision, flipY) = state.withLock { current in
            let flipY = current.topology.flipY
            let decision = current.recognizer.handle(
                location: CGPoint(x: cgLocation.x, y: flipY - cgLocation.y),
                motion: CGVector(dx: cgDeltaX, dy: -cgDeltaY),
                timestamp: receivedAt,
                topology: current.topology
            )
            return (decision, flipY)
        }
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case let .clamp(point):
            event.location = CGPoint(x: point.x, y: flipY - point.y)
            return Unmanaged.passUnretained(event)
        case let .wall(point, source, blocked):
            event.location = CGPoint(x: point.x, y: flipY - point.y)
            MouseTrace.record("containment-wall from=\(source) blocked=\(blocked) dest=\(TraceFormat.point(point))")
            return Unmanaged.passUnretained(event)
        case let .cross(crossing):
            return cross(crossing, event: event, flipY: flipY, receivedAt: receivedAt)
        }
    }

    private func cross(
        _ crossing: PointerEdgeRecognizer.Crossing,
        event: CGEvent,
        flipY: CGFloat,
        receivedAt: UInt64
    ) -> Unmanaged<CGEvent>? {
        let warpPoint = CGPoint(x: crossing.destination.x, y: flipY - crossing.destination.y)
        guard let bounds = displayBounds(crossing.target.displayId), bounds.contains(warpPoint) else {
            state.withLock { $0.recognizer.crossFailed() }
            MouseTrace.record("edge-warp suppressed (invalid-target-bounds) \(Self.traceRoute(crossing, warpPoint))")
            return Unmanaged.passUnretained(event)
        }
        let error = warpCursor(warpPoint)
        guard error == .success else {
            state.withLock { $0.recognizer.crossFailed() }
            MouseTrace.record(
                "edge-warp failed (cursor-warp raw=\(error.rawValue)) \(Self.traceRoute(crossing, warpPoint))"
            )
            return Unmanaged.passUnretained(event)
        }
        let now = clock()
        state.withLock {
            $0.recognizer.noteCursorMoved(to: crossing.destination, monitor: crossing.target.id, at: now)
        }
        MouseTrace.record(
            "edge-warp \(Self.traceRoute(crossing, warpPoint))\(crossing.pushed ? " pushed" : "") "
                + "callbackUs=\((now - receivedAt) / 1000)"
        )
        EventIntake.post(.pointerEdgeCrossed(target: crossing.target.id))
        postMove(warpPoint)
        return nil
    }

    private static func traceRoute(_ crossing: PointerEdgeRecognizer.Crossing, _ warpPoint: CGPoint) -> String {
        "from=\(crossing.source) to=\(crossing.target.id) dir=\(crossing.direction) "
            + "dest=\(TraceFormat.point(crossing.destination)) warp=\(TraceFormat.point(warpPoint))"
    }

    static func activeDisplayBounds(_ displayId: CGDirectDisplayID) -> CGRect? {
        guard CGDisplayIsActive(displayId) != 0 else { return nil }
        let bounds = CGDisplayBounds(displayId)
        return bounds.isNull || bounds.isEmpty ? nil : bounds
    }

    static func postSyntheticMove(_ point: CGPoint) {
        DispatchQueue.global(qos: .userInteractive).async {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
}
