// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension MouseEventHandler {
    func trackpadTraceState(senderId: UInt64?) -> TrackpadScrollTrace.GestureState {
        let locked = state.lockedGestureContext?.contactSession
        let retained = senderId.flatMap { state.consumedTrackpadSessions[$0] }
        return TrackpadScrollTrace.GestureState(
            phase: tapInputs.gesturePhase,
            mode: state.activeGestureMode,
            suppressStart: state.suppressGestureStartUntilAllTouchesLift,
            consumeUntilLift: tapInputs.consumeTrackpadScrollUntilAllTouchesLift,
            suppressMomentum: tapInputs.suppressTrackpadMomentumScroll,
            generation: state.contactSessions.generation,
            lockedContact: locked,
            lockedCurrentSession: currentTrackpadSession(for: locked),
            retainedContact: retained,
            retainedCurrentSession: currentTrackpadSession(for: retained)
        )
    }

    func traceTrackpadOwnership(_ action: TrackpadScrollTrace.OwnershipAction, contact: MultitouchContactSession) {
        TrackpadScrollTrace.record(.ownership(
            action, contact: contact, generation: state.contactSessions.generation,
            currentSession: currentTrackpadSession(for: contact)
        ))
    }

    private func currentTrackpadSession(for contact: MultitouchContactSession?) -> UInt64? {
        guard let contact, state.contactSessions.sessions.indices.contains(contact.slot) else { return nil }
        return state.contactSessions.sessions[contact.slot]
    }
}
