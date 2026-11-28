// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@MainActor
final class ConfigScriptWindowMoves {
    struct Row {
        let index: Int
        let change: WindowModel.MembershipChange
        let previousName: String?
    }

    @MainActor
    final class Frame {
        private var primary: [Row] = []
        private var others: [Row] = []
        private var count = 0
        private var otherCount = 0

        init() {
            primary.reserveCapacity(ConfigScriptCallbackQueue.edgeCapacity)
            others.reserveCapacity(ConfigScriptCallbackQueue.edgeCapacity)
        }

        func append(_ change: WindowModel.MembershipChange, primary token: WindowToken?, catalog: WorkspaceCatalog) {
            let index = count
            count += 1
            if change.token == token {
                if primary.count < ConfigScriptCallbackQueue.edgeCapacity {
                    primary.append(Row(index: index, change: change, previousName: catalog.name(for: change.source)))
                }
            } else {
                otherCount += 1
                if others.count < ConfigScriptCallbackQueue.edgeCapacity {
                    others.append(Row(index: index, change: change, previousName: catalog.name(for: change.source)))
                }
            }
        }

        func publish(
            to observer: ConfigScriptEventObservers, in manager: WorkspaceManager, firstAdmission: Bool, hydrated: Bool
        ) {
            var rootCount = primary.count
            var rootIndex = 0
            var memberIndex = 0
            var final = count
            var settled: WindowModel.MembershipChange?
            if firstAdmission {
                rootCount = 0
                final = otherCount
            } else if hydrated, let root = primary.first?.change {
                if let workspace = manager.workspace(for: root.token),
                   root.source != workspace
                {
                    settled = .init(token: root.token, source: root.source, destination: workspace)
                }
                rootCount = settled == nil ? 0 : 1
                final = otherCount + rootCount
            }
            let kept = min(final, ConfigScriptCallbackQueue.edgeCapacity)
            for _ in 0 ..< kept {
                if memberIndex < others.count,
                   rootIndex == rootCount || others[memberIndex].index < primary[rootIndex].index
                {
                    observer.windowMoved(
                        others[memberIndex].change,
                        previousName: others[memberIndex].previousName,
                        in: manager
                    )
                    memberIndex += 1
                } else {
                    observer.windowMoved(
                        settled ?? primary[rootIndex].change,
                        previousName: primary[rootIndex].previousName,
                        in: manager
                    )
                    rootIndex += 1
                }
            }
            if final > kept { observer.recordMissedEdges(final - kept, kind: .windowMoveToWorkspace) }
        }

        func reset() {
            primary.removeAll(keepingCapacity: true)
            others.removeAll(keepingCapacity: true)
            count = 0
            otherCount = 0
        }
    }

    private var active: [Int: Frame] = [:]
    private var available = [Frame()]

    init() {
        active.reserveCapacity(1)
    }

    func hasMoves(at depth: Int) -> Bool {
        active[depth] != nil
    }

    func record(_ change: WindowModel.MembershipChange, depth: Int, primary: WindowToken?, catalog: WorkspaceCatalog) {
        if let frame = active[depth] {
            frame.append(change, primary: primary, catalog: catalog)
        } else {
            let frame = available.popLast() ?? Frame()
            frame.append(change, primary: primary, catalog: catalog)
            active[depth] = frame
        }
    }

    func publish(
        depth: Int,
        to observer: ConfigScriptEventObservers, in manager: WorkspaceManager,
        admission: Bool, hydrated: Bool
    ) {
        guard let frame = active.removeValue(forKey: depth) else { return }
        frame.publish(to: observer, in: manager, firstAdmission: admission, hydrated: hydrated)
        frame.reset()
        available.append(frame)
    }
}
