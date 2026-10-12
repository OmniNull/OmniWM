// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceSwipePresentation {
    static let handoffTimeout: Duration = .milliseconds(250)

    @MainActor
    final class Handoff {
        let incoming: [UInt32: CGRect]
        let outgoing: [UInt32: CGRect]
        var readback: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var reportedWaiting = false

        var windowIds: Set<UInt32> {
            Set(incoming.keys).union(outgoing.keys)
        }

        init(flight: Flight) {
            let incoming = Self.frames(of: flight.destination.items)
            self.incoming = incoming
            let visibleArea = flight.preparation.frame
            outgoing = Self.frames(of: flight.preparation.source.items).filter {
                incoming[$0.key] == nil && Self.coverage(of: $0.value, by: visibleArea) >= 0.5
            }
        }

        func shortfalls(in windows: [UInt32: WindowServerInfo]) -> [TrackpadScrollTrace.Event] {
            Self.shortfalls(incoming, in: windows, incoming: true) + Self.shortfalls(
                outgoing,
                in: windows,
                incoming: false
            )
        }

        func cancel() {
            readback?.cancel()
            deadline?.cancel()
        }

        private static func frames(of items: [WorkspaceSwipePreview.Item]) -> [UInt32: CGRect] {
            Dictionary(items.map { (UInt32($0.token.windowId), $0.frame) }, uniquingKeysWith: { first, _ in first })
        }

        private static func shortfalls(
            _ expectations: [UInt32: CGRect],
            in windows: [UInt32: WindowServerInfo],
            incoming: Bool
        ) -> [TrackpadScrollTrace.Event] {
            expectations.compactMap { id, expected in
                guard let window = windows[id] else { return nil }
                let observed = ScreenCoordinateSpace.toAppKit(rect: window.frame)
                let coverage = coverage(of: expected, by: observed)
                guard (coverage >= 0.5) != incoming else { return nil }
                return .workspaceHandoff(
                    windowId: id, incoming: incoming, coverage: coverage, expected: expected, observed: observed
                )
            }
        }

        private static func coverage(of expected: CGRect, by observed: CGRect) -> Double {
            let overlap = observed.intersection(expected)
            guard !overlap.isNull, expected.width > 0, expected.height > 0 else { return 0 }
            return overlap.width * overlap.height / (expected.width * expected.height)
        }
    }

    func confirmHandoff(_ flight: Flight) {
        guard flight.handoff == nil else { return }
        let handoff = Handoff(flight: flight)
        guard !handoff.windowIds.isEmpty else {
            finishHandoff(flight, confirmed: true)
            return
        }
        flight.handoff = handoff
        handoff.deadline = Task { [weak self, weak flight] in
            do { try await self?.handoffSleep(Self.handoffTimeout) } catch { return }
            guard let self, let flight else { return }
            finishHandoff(flight, confirmed: false)
        }
        readHandoffGeometry(flight)
    }

    func windowFrameChanged(_ windowId: UInt32) {
        guard let flight, flight.handoff?.windowIds.contains(windowId) == true else { return }
        readHandoffGeometry(flight)
    }

    private func readHandoffGeometry(_ flight: Flight) {
        guard let handoff = flight.handoff else { return }
        handoff.readback?.cancel()
        handoff.readback = Task { [weak self, weak flight] in
            let windows = try? await self?.handoffWindowInfo(handoff.windowIds)
            guard !Task.isCancelled, let self, let flight else { return }
            guard let windows else {
                finishHandoff(flight, confirmed: false)
                return
            }
            let shortfalls = handoff.shortfalls(in: windows)
            guard !shortfalls.isEmpty else {
                finishHandoff(flight, confirmed: true)
                return
            }
            if !handoff.reportedWaiting {
                handoff.reportedWaiting = true
                trace("handoff-waiting", progress: flight.progress)
            }
            if TrackpadScrollTrace.shared.isActive {
                for shortfall in shortfalls { TrackpadScrollTrace.record(shortfall) }
            }
        }
    }

    private func finishHandoff(_ flight: Flight, confirmed: Bool) {
        guard self.flight === flight else { return }
        let failed = flight.settlement?.failed == true
        cancel(reason: failed ? "placement-failed" : confirmed ? "completed" : "handoff-unconfirmed")
    }
}
