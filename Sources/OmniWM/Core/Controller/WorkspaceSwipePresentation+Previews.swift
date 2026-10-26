// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceSwipePresentation {
    private var allPreviews: [WorkspaceSwipePreview] {
        Array(previews.values) + (unclaimedPreview.map { [$0] } ?? [])
    }

    func cancelFlights(onDisplay displayId: CGDirectDisplayID, reason: String) {
        for flight in Array(flights.values) where flight.preparation.monitor.displayId == displayId {
            cancel(flight, reason: reason)
        }
        for monitorId in previews.keys where monitorId.displayId == displayId {
            previews.removeValue(forKey: monitorId)?.release()
        }
    }

    func windowRemoved(_ token: WindowToken) {
        for preview in allPreviews {
            preview.remove(token: token)
        }
    }

    func syncAvailability() {
        guard let controller, !allPreviews.isEmpty,
              !controller.motionPolicy.animationsEnabled || !controller.settings.gestures.workspaceSwipeEnabled
        else { return }
        cancelAll(reason: "disabled")
        for preview in allPreviews {
            preview.release()
        }
        previews.removeAll()
        unclaimedPreview = nil
    }

    func previewSurface(_ controller: WMController, for monitorId: Monitor.ID) -> WorkspaceSwipePreview {
        if let preview = previews[monitorId] { return preview }
        let preview = unclaimedPreview ?? previewFactory?(controller)
            ?? WorkspaceSwipePreview(ownedWindowRegistry: controller.ownedWindowRegistry)
        unclaimedPreview = nil
        previews[monitorId] = preview
        return preview
    }

    func present(_ flight: Flight, at timestamp: TimeInterval) {
        flight.progress = flight.motion.progress(at: timestamp)
        flight.carried = flight.carry?(timestamp) ?? .zero
        if flight.carried == .zero { flight.carry = nil }
        previews[flight.preparation.monitor.id]?.update(
            sourceOffset: flight.offset(destination: false),
            destinationOffset: flight.offset(destination: true)
        )
    }

    func trace(_ action: String, progress: Double = 0) {
        guard TrackpadScrollTrace.shared.isActive else { return }
        TrackpadScrollTrace.record(.workspacePresentation(
            renderer: "preview",
            action: action,
            progress: progress,
            velocity: flight?.motion.velocity(at: mediaTimeProvider()),
            target: flight?.motion.target
        ))
    }
}
