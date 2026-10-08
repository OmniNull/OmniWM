// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Dispatch
import Foundation

enum TrackpadScrollTrace {
    enum SenderLookup: String, Sendable {
        case notRequested
        case unavailable
        case zero
        case identified
    }

    enum OwnershipAction: String, Sendable {
        case seed
        case retain
        case retire
        case clear
    }

    struct ScrollMetadata: Sendable {
        let eventTimestamp: UInt64
        let observedAt: UInt64
        let senderId: UInt64?
        let senderLookup: SenderLookup
    }

    struct GestureState: Sendable {
        let phase: MouseInputState.GesturePhase
        let mode: TrackpadGestureMode?
        let suppressStart: Bool
        let consumeUntilLift: Bool
        let suppressMomentum: Bool
        let generation: UInt
        let lockedContact: MultitouchContactSession?
        let lockedCurrentSession: UInt64?
        let retainedContact: MultitouchContactSession?
        let retainedCurrentSession: UInt64?
    }

    struct Scroll: Sendable {
        let payload: MouseScrollIntake
        let metadata: ScrollMetadata?
        let decision: MouseEventHandler.ScrollDecision
        let before: GestureState
        let after: GestureState
    }

    struct Gesture: Sendable {
        let timestamp: Double
        let phase: UInt
        let fingers: Int
        let contact: MultitouchContactSession?
        let processed: Bool
        let before: GestureState
        let after: GestureState
    }

    enum Event: Sendable {
        case scroll(Scroll)
        case gesture(Gesture)
        case physical(generation: UInt, slot: Int, session: UInt64, timestamp: Double?, fingers: Int)
        case source(generation: UInt, slot: Int, registryId: UInt64, senderId: UInt64?)
        case ownership(OwnershipAction, contact: MultitouchContactSession, generation: UInt, currentSession: UInt64?)
        case reset(generation: UInt)
        case recognition(mode: TrackpadGestureMode, x: Double, y: Double, dx: Double, dy: Double, interval: Double)
        case termination(reason: String, required: Int, fingers: Int, held: Double)
        case workspacePresentation(
            renderer: String, action: String, progress: Double, velocity: Double? = nil,
            projectedProgress: Double? = nil, target: Double? = nil, allowFlick: Bool? = nil
        )
        case workspaceFallback(cumulative: Double, velocity: Double, allowFlick: Bool, fired: Bool)
        case workspaceHandoff(windowId: UInt32, incoming: Bool, coverage: Double, expected: CGRect, observed: CGRect)
        case overviewMotion(action: String, progress: Double, velocity: Double, target: Double? = nil)
        case overviewScroll(
            phase: UInt, momentum: UInt, precise: Bool, state: String, suppressed: Bool,
            before: Double?, after: Double?
        )
    }

    struct Record: Sendable {
        let observedAt: UInt64
        let event: Event
    }

    static let shared = SessionTraceRecorder<Record>(
        sectionTitle: "Trackpad Scroll Trace",
        capacity: 4096,
        formatter: format
    )

    static func record(_ event: @autoclosure () -> Event) {
        shared.record(Record(observedAt: DispatchTime.now().uptimeNanoseconds, event: event()))
    }

    private static func format(_ record: Record) -> String {
        let detail: String = switch record.event {
        case let .recognition(mode, x, y, dx, dy, interval):
            "recognition mode=\(mode) x=\(x) y=\(y) dx=\(dx) dy=\(dy) interval=\(interval)"
        case let .termination(reason, required, fingers, held):
            "termination reason=\(reason) required=\(required) fingers=\(fingers) held=\(held)"
        case let .workspacePresentation(renderer, action, progress, velocity, projected, target, allowFlick):
            "workspace-presentation renderer=\(renderer) action=\(action) progress=\(progress)"
                + " velocity=\(decimal(velocity)) projected=\(decimal(projected)) target=\(decimal(target))"
                + " allowFlick=\(allowFlick.map(String.init) ?? "none")"
        case let .workspaceHandoff(windowId, incoming, coverage, expected, observed):
            "workspace-handoff win=\(windowId) side=\(incoming ? "incoming" : "outgoing")"
                + " coverage=\(decimal(coverage)) expected=\(expected) observed=\(observed)"
        case let .workspaceFallback(cumulative, velocity, allowFlick, fired):
            "workspace-fallback cumulative=\(cumulative) velocityUnits=\(velocity) allowFlick=\(allowFlick) fired=\(fired)"
        case let .overviewMotion(action, progress, velocity, target):
            "overview-motion action=\(action) progress=\(progress) velocity=\(velocity) target=\(decimal(target))"
        case let .overviewScroll(phase, momentum, precise, state, suppressed, before, after):
            "overview-scroll phase=\(phase) momentum=\(momentum) precise=\(precise) state=\(state)"
                + " suppressed=\(suppressed) offsetBefore=\(decimal(before)) offsetAfter=\(decimal(after))"
        case let .scroll(scroll):
            format(scroll)
        case let .gesture(gesture):
            "gesture timestamp=\(gesture.timestamp) phase=\(gesture.phase) fingers=\(gesture.fingers)"
                + " contact=\(contact(gesture.contact)) processed=\(gesture.processed)"
                + " before={\(state(gesture.before))} after={\(state(gesture.after))}"
        case let .physical(generation, slot, session, timestamp, fingers):
            "physical generation=\(generation) slot=\(slot) session=\(session)"
                + " timestamp=\(timestamp.map { String($0) } ?? "none") fingers=\(fingers)"
        case let .source(generation, slot, registryId, senderId):
            "source generation=\(generation) slot=\(slot) registry=\(registryId) sender=\(number(senderId))"
        case let .ownership(action, identity, generation, currentSession):
            "ownership action=\(action.rawValue) contact=\(contact(identity))"
                + " generation=\(generation) currentSession=\(number(currentSession))"
        case let .reset(generation):
            "reset generation=\(generation)"
        }
        return "observedNs=\(record.observedAt) \(detail)"
    }

    private static func format(_ scroll: Scroll) -> String {
        let payload = scroll.payload
        let metadata = scroll.metadata
        return "scroll eventNs=\(number(metadata?.eventTimestamp)) tapObservedNs=\(number(metadata?.observedAt))"
            + " phase=\(payload.phase) momentum=\(payload.momentumPhase) continuous=\(payload.isContinuous)"
            + " dx=\(payload.deltaX) dy=\(payload.deltaY) modifiers=\(payload.modifiersRawValue)"
            + " sender=\(number(metadata?.senderId ?? payload.senderId))"
            + " lookup=\(metadata?.senderLookup.rawValue ?? SenderLookup.notRequested.rawValue)"
            + " suppressed=\(scroll.decision.suppresses) reason=\(scroll.decision.rawValue)"
            + " before={\(state(scroll.before))} after={\(state(scroll.after))}"
    }

    private static func state(_ state: GestureState) -> String {
        "phase=\(state.phase) mode=\(state.mode.map { String(describing: $0) } ?? "none")"
            + " suppressStart=\(state.suppressStart) consumeUntilLift=\(state.consumeUntilLift)"
            + " suppressMomentum=\(state.suppressMomentum) generation=\(state.generation)"
            + " locked=\(contact(state.lockedContact)) lockedCurrent=\(number(state.lockedCurrentSession))"
            + " retained=\(contact(state.retainedContact)) retainedCurrent=\(number(state.retainedCurrentSession))"
    }

    private static func contact(_ contact: MultitouchContactSession?) -> String {
        guard let contact else { return "none" }
        return "\(contact.generation):\(contact.slot):\(contact.session):\(number(contact.senderId))"
    }

    private static func number(_ number: UInt64?) -> String {
        number.map(String.init) ?? "none"
    }

    private static func decimal(_ value: Double?) -> String {
        value.map { String($0) } ?? "none"
    }
}
