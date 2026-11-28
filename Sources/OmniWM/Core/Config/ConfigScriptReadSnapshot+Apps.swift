// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WMController {
    func appendScriptApps(to output: inout ConfigScriptSnapshotWriter, scratch: inout TrackedAppGroups) {
        let windows = workspaceManager.windowQueries
        scratch.collect(windows: windows, cache: appInfoCache)
        let apps = scratch.apps.span
        for index in scratch.order {
            let stored = output.row { row in
                writeScriptApp(apps[index], windows: windows, to: &row)
            }
            if !stored { break }
        }
    }

    private func writeScriptApp(
        _ app: borrowing TrackedAppGroups.App, windows: WindowModel.ReadView, to row: inout ConfigScriptSnapshotWriter
    ) -> Bool {
        guard row.string(app.bundleId ?? ""), row.string(app.hasName ? app.displayName : nil) else { return false }
        let size = windows.withEntry(app.token) { entry in
            (entry.observedState.frame ?? axManager.lastAppliedFrame(for: entry.windowId)
                ?? entry.floatingState?.lastFrame ?? entry.managedReplacementMetadata?.frame)?.size
        } ?? nil
        guard let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return row.flag(0)
        }
        return row.flag(1) && row.detailNumber(size.width) && row.detailNumber(size.height)
    }
}
