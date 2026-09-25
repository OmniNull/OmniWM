// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Dispatch
import Foundation

enum EventIntakeTrace {
    struct Identity: Sendable {
        let kind: String
        var pid: pid_t = 0
        var windowId: Int = 0
    }

    struct Record: Sendable {
        let sequence: UInt64
        let enqueuedNs: UInt64?
        let startedNs: UInt64
        let endedNs: UInt64
        let identity: Identity
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Event Intake Timing",
        capacity: 16_384
    ) { record in
        let queued = record.enqueuedNs.map {
            String(format: "%.1f", Double(record.startedNs - $0) / 1_000)
        } ?? "unknown"
        let work = String(format: "%.1f", Double(record.endedNs - record.startedNs) / 1_000)
        return "seq=\(record.sequence) kind=\(record.identity.kind)"
            + " pid=\(record.identity.pid) win=\(record.identity.windowId)"
            + " enqueued_ns=\(record.enqueuedNs.map(String.init) ?? "unknown")"
            + " start_ns=\(record.startedNs) end_ns=\(record.endedNs)"
            + " queue_us=\(queued) handler_us=\(work)"
    }

    @MainActor
    static func measure(_ stamped: StampedIntakeEvent, _ body: () -> Void) {
        guard shared.isActive else {
            body()
            return
        }
        let startedNs = DispatchTime.now().uptimeNanoseconds
        body()
        let endedNs = DispatchTime.now().uptimeNanoseconds
        shared.record(Record(
            sequence: stamped.seq,
            enqueuedNs: stamped.enqueuedUptimeNs,
            startedNs: startedNs,
            endedNs: endedNs,
            identity: identity(for: stamped.event)
        ))
    }

    private static func identity(for event: IntakeEvent) -> Identity {
        switch event {
        case let .cgs(event):
            cgsIdentity(event)
        case let .axWindow(event):
            axIdentity(event)
        case let .application(event):
            applicationIdentity(event)
        case let .activationFactsResolved(facts):
            Identity(kind: "activation-facts", pid: facts.pid, windowId: facts.focusedWindow?.axRef.windowId ?? 0)
        case let .focusedAdmissionRetryFactRequestSuperseded(execution):
            Identity(kind: "admission-superseded", windowId: Int(execution.windowId))
        case .activeSpaceChanged: Identity(kind: "active-space")
        case .display: Identity(kind: "display")
        case .hotkeyInvocation: Identity(kind: "hotkey")
        case .intentExpired: Identity(kind: "intent-expired")
        case .ipcCommand: Identity(kind: "ipc-command")
        case .mouseDragged: Identity(kind: "mouse-drag")
        case .mouseMoved: Identity(kind: "mouse-move")
        case .mouseScroll: Identity(kind: "mouse-scroll")
        case let .nativeFullscreenTransitionExpired(token, _):
            Identity(kind: "fullscreen-expired", pid: token.pid, windowId: token.windowId)
        case .systemSleep: Identity(kind: "sleep")
        case .systemWake: Identity(kind: "wake")
        case let .windowConstraintsResolved(fact):
            Identity(kind: "constraints", pid: fact.token.pid, windowId: fact.token.windowId)
        }
    }

    private static func cgsIdentity(_ event: CGSWindowEvent) -> Identity {
        switch event {
        case let .created(windowId, _): Identity(kind: "cgs.created", windowId: Int(windowId))
        case let .destroyed(windowId, _): Identity(kind: "cgs.destroyed", windowId: Int(windowId))
        case let .closed(windowId): Identity(kind: "cgs.closed", windowId: Int(windowId))
        case let .frameChanged(windowId): Identity(kind: "cgs.frame", windowId: Int(windowId))
        case let .orderChanged(windowId): Identity(kind: "cgs.order", windowId: Int(windowId))
        case let .titleChanged(windowId): Identity(kind: "cgs.title", windowId: Int(windowId))
        case let .frontAppChanged(pid): Identity(kind: "cgs.front-app", pid: pid)
        }
    }

    private static func axIdentity(_ event: AXWindowIntakeEvent) -> Identity {
        switch event {
        case let .focusedWindowChanged(pid, _): Identity(kind: "ax.focus", pid: pid)
        case let .windowDestroyed(pid, ref, _): Identity(kind: "ax.destroyed", pid: pid, windowId: ref.windowId)
        case let .windowMiniaturized(pid, ref, _): Identity(kind: "ax.minimized", pid: pid, windowId: ref.windowId)
        case let .windowDeminiaturized(pid, ref, _): Identity(kind: "ax.restored", pid: pid, windowId: ref.windowId)
        }
    }

    private static func applicationIdentity(_ event: ApplicationIntakeEvent) -> Identity {
        switch event {
        case let .activated(pid): Identity(kind: "app.activated", pid: pid)
        case let .deactivated(pid): Identity(kind: "app.deactivated", pid: pid)
        case let .hidden(pid): Identity(kind: "app.hidden", pid: pid)
        case let .launched(pid): Identity(kind: "app.launched", pid: pid)
        case let .terminated(pid, _): Identity(kind: "app.terminated", pid: pid)
        case let .unhidden(pid): Identity(kind: "app.unhidden", pid: pid)
        }
    }
}
