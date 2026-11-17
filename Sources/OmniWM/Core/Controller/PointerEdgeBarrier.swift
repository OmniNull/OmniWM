// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
import Foundation
import Synchronization

struct LiveDragHold: Equatable, Sendable {
    enum Decision: Equatable {
        case pass
        case hold(CGPoint)
        case cross(destination: CGPoint, target: Monitor.ID)
        case letThrough(CGPoint)
    }

    struct Push: Equatable, Sendable {
        var distance: CGFloat = 0
        var heldSince: UInt64?
    }

    static let flickDistance: CGFloat = 40
    static let settleNs: UInt64 = 400_000_000

    let monitorId: Monitor.ID
    let heldDirections: Set<Direction>

    func decide(
        location: CGPoint,
        motionX: CGFloat,
        motionY: CGFloat = 0,
        now: UInt64,
        push: inout Push,
        topology: PointerEdgeTopology
    ) -> Decision {
        let inset = topology.margin + 1
        guard let source = topology.monitor(monitorId),
              let direction = heldDirection(at: location, in: source.frame, inset: inset)
        else {
            push = Push()
            return .pass
        }
        let frame = source.frame
        let horizontal = direction == .left || direction == .right
        let positive = direction == .right || direction == .up
        let primary = horizontal ? location.x : location.y
        let secondary = horizontal ? location.y : location.x
        let minimum = horizontal ? frame.minX : frame.minY
        let maximum = horizontal ? frame.maxX : frame.maxY
        let motion = horizontal ? motionX : motionY
        let overshoot = positive ? primary - maximum : minimum - primary
        guard overshoot <= abs(motion) + inset,
              secondary >= (horizontal ? frame.minY : frame.minX),
              secondary <= (horizontal ? frame.maxY : frame.maxX),
              let target = topology.edges[.init(monitorId: source.id, direction: direction)]?.target,
              topology.warpsPointer || Self.shares(target.frame, frame, direction, at: secondary)
        else {
            push = Push()
            return .pass
        }
        let heldPrimary = positive ? maximum - inset : minimum + inset
        let held = horizontal ? CGPoint(x: heldPrimary, y: secondary) : CGPoint(x: secondary, y: heldPrimary)
        let outward = positive ? motion : -motion
        if let since = push.heldSince {
            if now >= since + Self.settleNs { push.distance = max(0, push.distance + outward) }
        } else {
            push.heldSince = now
            if outward >= Self.flickDistance { push.distance = PointerEdgeTopology.pushDistance }
        }
        guard push.distance >= PointerEdgeTopology.pushDistance else { return .hold(held) }
        push = Push()
        guard topology.warpsPointer else {
            let past = positive ? max(primary, maximum) : min(primary, minimum - 1)
            return .letThrough(horizontal ? CGPoint(x: past, y: secondary) : CGPoint(x: secondary, y: past))
        }
        let zone = MouseWarpGeometry.crossing(toward: direction, location: held, frame: frame)
        return .cross(
            destination: MouseWarpGeometry.destinationPoint(
                on: target.frame, entryEdge: zone.entryEdge, ratio: zone.ratio, margin: topology.margin
            ),
            target: target.id
        )
    }

    private func heldDirection(at location: CGPoint, in frame: CGRect, inset: CGFloat) -> Direction? {
        if location.x >= frame.maxX - inset, heldDirections.contains(.right) { return .right }
        if location.x <= frame.minX + inset, heldDirections.contains(.left) { return .left }
        if location.y >= frame.maxY - inset, heldDirections.contains(.up) { return .up }
        if location.y <= frame.minY + inset, heldDirections.contains(.down) { return .down }
        return nil
    }

    private static func shares(
        _ target: CGRect,
        _ frame: CGRect,
        _ direction: Direction,
        at secondary: CGFloat
    ) -> Bool {
        let horizontal = direction == .left || direction == .right
        let seam = switch direction {
        case .right: target.minX - frame.maxX
        case .left: frame.minX - target.maxX
        case .up: target.minY - frame.maxY
        case .down: frame.minY - target.maxY
        }
        return abs(seam) <= FrameTolerance.screenMatch
            && secondary >= (horizontal ? max(frame.minY, target.minY) : max(frame.minX, target.minX))
            && secondary <= (horizontal ? min(frame.maxY, target.maxY) : min(frame.maxX, target.maxX))
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
        var liveDragHold: LiveDragHold?
        var liveDragPush = LiveDragHold.Push()
        var liveDragHolding = false
        var resizeHold: ResizeHold?
        var isStarted = false
    }

    struct ResizeHold: Equatable {
        var orientation: Monitor.Orientation = .horizontal
        var minimum: CGFloat?
        var maximum: CGFloat?

        func clamped(_ point: CGPoint) -> CGPoint {
            let horizontal = orientation == .horizontal
            let value = horizontal ? point.x : point.y
            let clamped = min(max(value, minimum ?? -.infinity), maximum ?? .infinity)
            return horizontal ? CGPoint(x: clamped, y: point.y) : CGPoint(x: point.x, y: clamped)
        }
    }

    private struct TapState {
        var runLoop: CFRunLoop?
        var running = false
        var installed = false
        var stopRequested = false
        var needsReenable = false
    }

    static let eventsOfInterest: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        | 1 << CGEventType.leftMouseDragged.rawValue

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

    var isStarted: Bool {
        state.withLock { $0.isStarted }
    }

    func publish(_ topology: PointerEdgeTopology) {
        state.withLock { $0.topology = topology }
    }

    func reset() {
        state.withLock { $0.recognizer.reset() }
    }

    var resizeHold: ResizeHold? {
        state.withLock { $0.resizeHold }
    }

    func publishResizeHold(_ hold: ResizeHold?) {
        let changed = state.withLock { current -> Bool in
            defer { current.resizeHold = hold }
            return hold != current.resizeHold
        }
        guard changed else { return }
        MouseTrace.record(
            "edge-resize-hold publish min=\(hold?.minimum.map { "\(Int($0))" } ?? "-") "
                + "max=\(hold?.maximum.map { "\(Int($0))" } ?? "-")"
        )
    }

    func noteProgrammaticMove(to location: CGPoint) {
        let now = clock()
        state.withLock { current in
            let monitor = current.topology.monitor(containing: location)?.id
            current.recognizer.noteCursorMoved(to: location, monitor: monitor, at: now)
        }
    }

    func start() {
        state.withLock { $0.isStarted = true }
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
            current.isStarted = false
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
                  eventsOfInterest: Self.eventsOfInterest,
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
        if type == .leftMouseDragged {
            return handleLeftDrag(event)
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

    private func handleLeftDrag(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let (resizeHold, holdsLiveDrag) = state.withLock { ($0.resizeHold, $0.liveDragHold != nil) }
        if let resizeHold {
            let location = event.location
            let clamped = resizeHold.clamped(location)
            if clamped != location {
                event.location = clamped
            }
        }
        return holdsLiveDrag ? handleLiveDragEvent(event) : Unmanaged.passUnretained(event)
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

extension PointerEdgeBarrier {
    var liveDragHold: LiveDragHold? {
        state.withLock { $0.liveDragHold }
    }

    func publishLiveDragHold(_ hold: LiveDragHold?) {
        let changed = state.withLock { current -> Bool in
            if hold?.monitorId != current.liveDragHold?.monitorId { current.liveDragPush = .init() }
            defer { current.liveDragHold = hold }
            return hold != current.liveDragHold
        }
        guard changed else { return }
        MouseTrace.record(
            "live-drag-hold publish monitor=\(hold.map { "\($0.monitorId)" } ?? "nil") "
                + "held=\(hold.map { "\($0.heldDirections.sorted { "\($0)" < "\($1)" })" } ?? "-")"
        )
    }

    private func handleLiveDragEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let cgLocation = event.location
        let motionX = event.getDoubleValueField(.mouseEventDeltaX)
        let now = clock()
        let (decision, flipY) = state.withLock { current -> (LiveDragHold.Decision, CGFloat) in
            let flipY = current.topology.flipY
            guard current.topology.isEnabled, let hold = current.liveDragHold else {
                current.liveDragPush = .init()
                return (.pass, flipY)
            }
            let motionY = hold.heldDirections.contains(.up) || hold.heldDirections.contains(.down)
                ? -event.getDoubleValueField(.mouseEventDeltaY)
                : 0
            let decision = hold.decide(
                location: CGPoint(x: cgLocation.x, y: flipY - cgLocation.y),
                motionX: motionX,
                motionY: motionY,
                now: now,
                push: &current.liveDragPush,
                topology: current.topology
            )
            switch decision {
            case .cross,
                 .letThrough:
                current.liveDragHold = nil
                current.liveDragPush = .init()
            case .pass,
                 .hold:
                break
            }
            let holding = if case .hold = decision { true } else { false }
            if holding != current.liveDragHolding {
                current.liveDragHolding = holding
                MouseTrace.record(
                    "live-drag-hold \(holding ? "hold" : "release") monitor=\(hold.monitorId) "
                        + "held=\(hold.heldDirections) at=\(TraceFormat.point(cgLocation))"
                )
            }
            return (decision, flipY)
        }
        return applyLiveDragDecision(decision, to: event, flipY: flipY)
    }

    private func applyLiveDragDecision(
        _ decision: LiveDragHold.Decision,
        to event: CGEvent,
        flipY: CGFloat
    ) -> Unmanaged<CGEvent>? {
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case let .letThrough(point):
            event.location = CGPoint(x: point.x, y: flipY - point.y)
            MouseTrace.record("live-drag-hold let through at=\(TraceFormat.point(event.location))")
            return Unmanaged.passUnretained(event)
        case let .hold(point):
            event.location = CGPoint(x: point.x, y: flipY - point.y)
            return Unmanaged.passUnretained(event)
        case let .cross(destination, target):
            let warpPoint = CGPoint(x: destination.x, y: flipY - destination.y)
            let error = warpCursor(warpPoint)
            MouseTrace.record(
                "live-drag-hold cross to=\(target) warp=\(TraceFormat.point(warpPoint)) raw=\(error.rawValue)"
            )
            guard error == .success else { return Unmanaged.passUnretained(event) }
            state.withLock {
                $0.recognizer.noteCursorMoved(to: destination, monitor: target, at: clock())
            }
            EventIntake.post(.pointerEdgeCrossed(target: target))
            event.location = warpPoint
            return Unmanaged.passUnretained(event)
        }
    }
}
