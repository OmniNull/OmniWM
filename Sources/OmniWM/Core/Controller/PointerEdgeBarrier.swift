// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
import Foundation
import Synchronization

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
