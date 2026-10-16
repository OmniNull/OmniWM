// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMShellCore

struct ShellGestureTrackRecipe {
    let source: String
    let track: ShellGestureTrack?
}

struct ShellTrackedGesture {
    let handle: ElementHandle
    let token: UInt64
    let track: ShellGestureTrack
    let configuration: ShellGestureConfig
    let animation: ShellAnimation?
    var velocity = ShellGestureTransform.zero
    var holding = false
    var invocationID: UInt64?
}

extension ShellWidgetSurface {
    func trackGesture(_ sample: ShellPointerGesture.Sample) {
        var commands: [ShellLayerCommand] = []
        if sample.phase == .began {
            if let existing = gestureTracking {
                commands.append(gestureSettleCommand(existing))
                gestureTracking = nil
            }
            if let capture = gestureCapture, let track = gestureTrackRecipes[capture.content.gestureTrack]?.track {
                gestureTracking = ShellTrackedGesture(
                    handle: capture.handle,
                    token: ShellInvocation.next(),
                    track: track,
                    configuration: capture.content.gesture,
                    animation: motionPolicy.animationsEnabled
                        ? animation(for: capture.handle) ?? ShellAnimation(
                            motion: .spring,
                            speed: motionPolicy.animationSpeed
                        )
                        : nil
                )
            }
        }
        appendGestureSample(sample, into: &commands)
        scene.submit(commands, animated: false)
    }

    func finishGestureTrack(_ sample: ShellPointerGesture.Sample, invokesAction: Bool) -> UInt64? {
        var commands: [ShellLayerCommand] = []
        appendGestureSample(sample, into: &commands)
        guard var tracking = gestureTracking, tracking.handle == sample.handle, !tracking.holding else { return nil }
        let token: UInt64?
        if sample.committed, invokesAction {
            tracking.holding = true
            gestureTracking = tracking
            token = tracking.token
        } else {
            commands.append(gestureSettleCommand(tracking))
            gestureTracking = nil
            token = nil
        }
        scene.submit(commands, animated: false)
        return token
    }

    private func appendGestureSample(_ sample: ShellPointerGesture.Sample, into commands: inout [ShellLayerCommand]) {
        guard var tracking = gestureTracking, tracking.handle == sample.handle, !tracking.holding else { return }
        let mapped = tracking.track.sample(
            translation: sample.translation,
            velocity: sample.velocity,
            axis: sample.axis,
            configuration: tracking.configuration
        )
        tracking.velocity = mapped.velocity
        gestureTracking = tracking
        commands.append(.gesture(slot: tracking.handle.slot, token: tracking.token, value: mapped.value))
    }

    func bindGestureInvocation(trackToken: UInt64, invocationID: UInt64) {
        guard var tracking = gestureTracking, tracking.holding, tracking.token == trackToken else { return }
        tracking.invocationID = invocationID
        gestureTracking = tracking
    }

    func appendGestureAcknowledgement(_ through: UInt64, into commands: inout [ShellLayerCommand]) {
        guard let tracking = gestureTracking, tracking.holding,
              let invocation = tracking.invocationID, invocation <= through else { return }
        commands.append(gestureSettleCommand(tracking))
        gestureTracking = nil
    }

    func acknowledgeGesture(through: UInt64) {
        var commands: [ShellLayerCommand] = []
        appendGestureAcknowledgement(through, into: &commands)
        scene.submit(commands, animated: false)
    }

    func cancelHeldGestureTrack() {
        guard let tracking = gestureTracking, tracking.holding else { return }
        gestureTracking = nil
        scene.submit(
            [.settleGesture(slot: tracking.handle.slot, token: tracking.token, velocity: .zero, animation: nil)],
            animated: false
        )
    }

    func reconcileGestureTrack() {
        if let tracking = gestureTracking, tracking.holding, !layout.core.contains(tracking.handle) {
            gestureTracking = nil
        }
    }

    private func gestureSettleCommand(_ tracking: ShellTrackedGesture) -> ShellLayerCommand {
        .settleGesture(
            slot: tracking.handle.slot,
            token: tracking.token,
            velocity: tracking.velocity,
            animation: motionPolicy.animationsEnabled ? tracking.animation : nil
        )
    }
}
