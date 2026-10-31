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
        case letThrough
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
        now: UInt64,
        push: inout Push,
        topology: PointerEdgeTopology
    ) -> Decision {
        guard let source = topology.monitor(monitorId) else {
            push = Push()
            return .pass
        }
        let frame = source.frame
        let inset = topology.margin + 1
        let direction: Direction? = if location.x >= frame.maxX - inset {
            .right
        } else if location.x <= frame.minX + inset {
            .left
        } else {
            nil
        }
        let overshoot = direction == .right ? location.x - frame.maxX : frame.minX - location.x
        guard let direction,
              heldDirections.contains(direction),
              overshoot <= abs(motionX) + inset,
              location.y >= frame.minY, location.y <= frame.maxY,
              let target = topology.edges[.init(monitorId: source.id, direction: direction)]?.target,
              topology.warpsPointer || Self.shares(target.frame, frame, direction, at: location.y)
        else {
            push = Push()
            return .pass
        }
        let held = CGPoint(x: direction == .right ? frame.maxX - inset : frame.minX + inset, y: location.y)
        let outward = PointerEdgeRecognizer.outward(CGVector(dx: motionX, dy: 0), direction)
        if let since = push.heldSince {
            if now >= since + Self.settleNs { push.distance = max(0, push.distance + outward) }
        } else {
            push.heldSince = now
            if outward >= Self.flickDistance { push.distance = PointerEdgeTopology.pushDistance }
        }
        guard push.distance >= PointerEdgeTopology.pushDistance else { return .hold(held) }
        push = Push()
        guard topology.warpsPointer else { return .letThrough }
        let zone = MouseWarpGeometry.crossing(toward: direction, location: held, frame: frame)
        return .cross(
            destination: MouseWarpGeometry.destinationPoint(
                on: target.frame, entryEdge: zone.entryEdge, ratio: zone.ratio, margin: topology.margin
            ),
            target: target.id
        )
    }

    private static func shares(_ target: CGRect, _ frame: CGRect, _ direction: Direction, at y: CGFloat) -> Bool {
        let seam = direction == .right ? target.minX - frame.maxX : frame.minX - target.maxX
        return abs(seam) <= FrameTolerance.screenMatch
            && y >= max(frame.minY, target.minY) && y <= min(frame.maxY, target.maxY)
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
    }

    private struct TapState {
        var runLoop: CFRunLoop?
        var running = false
        var installed = false
        var stopRequested = false
        var needsReenable = false
        var needsRecreate = false
    }

    private enum TapLoopStep {
        case stop
        case recreate
        case run(reenable: Bool)
    }

    private let state = Mutex(State())
    private let tapState = Mutex(TapState())
    private let tracksLiveDrags = Mutex(false)
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
        var installed = false
        while let (port, source) = makeTap() {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            tapState.withLock { current in
                current.runLoop = CFRunLoopGetCurrent()
                current.installed = true
            }
            if !installed {
                installed = true
                EventIntake.post(.pointerEdgeOwnershipChanged)
            }
            let recreates = runTapLoop(port)
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(port)
            guard recreates else {
                EventIntake.post(.pointerEdgeOwnershipChanged)
                return
            }
        }
        MouseTrace.record("pointer-edge tap unavailable")
        tapState.withLock { $0 = TapState() }
        if installed {
            EventIntake.post(.pointerEdgeOwnershipChanged)
        }
    }

    func handleTapEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapState.withLock { $0.needsReenable = true }
            CFRunLoopStop(CFRunLoopGetCurrent())
            reset()
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDragged { return handleLiveDragEvent(event) }
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
            let decision = hold.decide(
                location: CGPoint(x: cgLocation.x, y: flipY - cgLocation.y),
                motionX: motionX,
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
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .letThrough:
            MouseTrace.record("live-drag-hold let through at=\(TraceFormat.point(cgLocation))")
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
    nonisolated static func eventsOfInterest(tracksLiveDrags: Bool) -> CGEventMask {
        let moved: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        return tracksLiveDrags ? moved | 1 << CGEventType.leftMouseDragged.rawValue : moved
    }

    func setTracksLiveDrags(_ tracks: Bool) {
        let changed = tracksLiveDrags.withLock { current -> Bool in
            defer { current = tracks }
            return current != tracks
        }
        guard changed else { return }
        tapState.withLock { current in
            current.needsRecreate = true
            guard let runLoop = current.runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    fileprivate func makeTap() -> (CFMachPort, CFRunLoopSource)? {
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<PointerEdgeBarrier>.fromOpaque(info).takeUnretainedValue().handleTapEvent(type, event)
        }
        guard let port = CGEvent.tapCreate(
                  tap: .cghidEventTap,
                  place: .headInsertEventTap,
                  options: .defaultTap,
                  eventsOfInterest: Self.eventsOfInterest(tracksLiveDrags: tracksLiveDrags.withLock { $0 }),
                  callback: callback,
                  userInfo: Unmanaged.passUnretained(self).toOpaque()
              ),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else { return nil }
        return (port, source)
    }

    fileprivate func runTapLoop(_ port: CFMachPort) -> Bool {
        while true {
            let step = tapState.withLock { current -> TapLoopStep in
                if current.stopRequested {
                    current = TapState()
                    return .stop
                }
                defer {
                    current.needsReenable = false
                    current.needsRecreate = false
                }
                return current.needsRecreate ? .recreate : .run(reenable: current.needsReenable)
            }
            switch step {
            case .stop: return false
            case .recreate: return true
            case let .run(reenable):
                if reenable {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                CFRunLoopRun()
            }
        }
    }
}
