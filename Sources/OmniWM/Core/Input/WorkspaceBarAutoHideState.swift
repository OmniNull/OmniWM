// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct WorkspaceBarAutoHideTarget {
    let id: Monitor.ID
    let monitorFrame: CGRect
    let activationRegions: [CGRect]
    let retentionRegions: [CGRect]
    var isVisible: Bool
    var isPinned: Bool

    init(monitor: Monitor, frames: [CGRect], resolved: ResolvedBarSettings, isVisible: Bool, isPinned: Bool) {
        id = monitor.id
        monitorFrame = monitor.frame
        self.isVisible = isVisible
        self.isPinned = isPinned
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        let regions = frames.map { geometry.autoHideRegions(frame: $0, monitor: monitor, resolved: resolved) }
        activationRegions = regions.map(\.activation)
        retentionRegions = regions.map(\.retention)
    }

    func activates(_ pointer: CGPoint) -> Bool {
        contains(pointer, in: activationRegions)
    }

    func retains(_ pointer: CGPoint) -> Bool {
        contains(pointer, in: retentionRegions)
    }

    private func contains(_ pointer: CGPoint, in regions: [CGRect]) -> Bool {
        guard (monitorFrame.minX ..< monitorFrame.maxX).contains(pointer.x),
              pointer.y > monitorFrame.minY, pointer.y <= monitorFrame.maxY
        else { return false }
        return regions.contains {
            !$0.isEmpty && ($0.minX ... $0.maxX).contains(pointer.x) && ($0.minY ... $0.maxY).contains(pointer.y)
        }
    }
}

struct WorkspaceBarAutoHideState {
    private(set) var revealed: Set<Monitor.ID> = []

    func desired(targets: [WorkspaceBarAutoHideTarget], pointer: CGPoint) -> Set<Monitor.ID> {
        Set(targets.filter { target in
            target.activates(pointer)
                || ((revealed.contains(target.id) || target.isVisible)
                    && (target.isPinned || target.retains(pointer)))
        }.map(\.id))
    }

    mutating func update(targets: [WorkspaceBarAutoHideTarget], pointer: CGPoint) {
        revealed = desired(targets: targets, pointer: pointer)
    }

    mutating func setRevealed(_ isRevealed: Bool, for id: Monitor.ID) {
        if isRevealed {
            revealed.insert(id)
        } else {
            revealed.remove(id)
        }
    }

    mutating func reset() {
        revealed = []
    }
}

@MainActor
final class WorkspaceBarAutoHideDelays {
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var pending: [Monitor.ID: (revealing: Bool, task: Task<Void, Never>)] = [:]

    var pendingIds: some Collection<Monitor.ID> {
        pending.keys
    }

    func schedule(
        revealing: Bool,
        for id: Monitor.ID,
        afterMilliseconds milliseconds: Double,
        fire: @escaping @MainActor () -> Void
    ) {
        guard pending[id]?.revealing != revealing else { return }
        cancel(id)
        let sleep = sleep
        let task = Task { [weak self] in
            do { try await sleep(.milliseconds(Int64(milliseconds.rounded()))) } catch { return }
            guard let self, !Task.isCancelled else { return }
            pending[id] = nil
            fire()
        }
        pending[id] = (revealing, task)
    }

    func cancel(_ id: Monitor.ID) {
        pending.removeValue(forKey: id)?.task.cancel()
    }

    func cancelAll() {
        for entry in pending.values {
            entry.task.cancel()
        }
        pending = [:]
    }
}
