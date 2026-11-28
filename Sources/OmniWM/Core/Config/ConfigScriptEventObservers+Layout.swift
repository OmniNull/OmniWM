// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ConfigScriptLayoutBaseline {
    case waitingForServices
    case initial([WorkspaceDescriptor.ID: NiriColumnSummary])
    case applied
}

extension ConfigScriptEventObservers {
    func installLayoutObserver(on controller: WMController) {
        if controller.hasStartedServices {
            let world = WorldView(controller: controller)
            layoutBaseline = .initial(world.niriColumnSummaries(usesLiveBackingScale: world.publishesNiriColumnsToIPC))
        }
        controller.scriptLayoutObserver = self
    }

    static func publishLayoutChange(
        from previous: borrowing [WorkspaceDescriptor.ID: NiriColumnSummary],
        to current: borrowing [WorkspaceDescriptor.ID: NiriColumnSummary],
        controller: WMController
    ) {
        let client = borrowRegistration(&controller.scriptLayoutObserver) { observer in
            observer.compareLayout(from: previous, to: current, controller: controller)
        }
        if let client {
            client.compareLayout(from: previous, to: current, controller: controller)
        }
    }

    private func compareLayout(
        from previous: borrowing [WorkspaceDescriptor.ID: NiriColumnSummary],
        to current: borrowing [WorkspaceDescriptor.ID: NiriColumnSummary],
        controller: WMController
    ) {
        guard controller.hasStartedServices else {
            layoutBaseline = .waitingForServices
            return
        }
        let changed: Bool
        switch layoutBaseline {
        case .waitingForServices:
            changed = false
        case let .initial(initial):
            changed = !Self.layoutColumnsMatch(initial, current)
        case .applied:
            changed = !Self.layoutColumnsMatch(previous, current)
        }
        layoutBaseline = .applied
        if changed {
            publishNative(.layoutChanged, .init(), controller: controller)
        }
    }

    private static func layoutColumnsMatch(
        _ previous: borrowing [WorkspaceDescriptor.ID: NiriColumnSummary],
        _ current: borrowing [WorkspaceDescriptor.ID: NiriColumnSummary]
    ) -> Bool {
        guard previous.count == current.count else { return false }
        var index = previous.startIndex
        while index != previous.endIndex {
            guard let match = current.index(forKey: previous.keys[index]),
                  summariesMatch(previous.values[index], current.values[match])
            else { return false }
            previous.formIndex(after: &index)
        }
        return true
    }

    private static func summariesMatch(_ left: borrowing NiriColumnSummary, _ right: borrowing NiriColumnSummary)
        -> Bool
    {
        left.columnIndexByToken == right.columnIndexByToken
            && left.viewport == right.viewport
            && left.displayModes == right.displayModes
    }
}
