// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct MixedLayoutHistoryCapture {
    let niriWorkspaceId: WorkspaceDescriptor.ID
    let dwindleWorkspaceId: WorkspaceDescriptor.ID
    let niri: NiriLayoutSnapshot
    let dwindle: DwindleLayoutSnapshot
}

extension WMController {
    func mixedLayoutHistoryStart(
        from source: WorkspaceDescriptor.ID,
        to target: WorkspaceDescriptor.ID
    ) -> MixedLayoutHistoryCapture? {
        guard source != target, let niriEngine, let dwindleEngine,
              workspaceManager.activeLayoutKind(for: source) != workspaceManager.activeLayoutKind(for: target)
        else { return nil }
        niriEngine.assertSanctionedMutation()
        let niriId = workspaceManager.activeLayoutKind(for: source) == .niri ? source : target
        let dwindleId = niriId == source ? target : source
        let selected = workspaceManager.niriViewportState(for: niriId).selectedNodeId
        let focused = selected.flatMap { niriEngine.findNode(by: $0, in: niriId) as? NiriWindow }?.token
        let niri: NiriLayoutSnapshot
        if niriEngine.root(for: niriId) == nil {
            niri = .empty
        } else {
            guard let snapshot = niriEngine.layoutSnapshot(in: niriId, focused: focused) else { return nil }
            niri = snapshot
        }
        guard let dwindle = dwindleEngine.layoutSnapshot(in: dwindleId) else { return nil }
        return MixedLayoutHistoryCapture(
            niriWorkspaceId: niriId, dwindleWorkspaceId: dwindleId, niri: niri, dwindle: dwindle
        )
    }

    func recordMixedLayoutTransfer(_ capture: consuming MixedLayoutHistoryCapture) {
        guard let niriEngine, let dwindleEngine else { return }
        var niriDeparted: [WindowToken] = []
        for column in capture.niri.columns {
            for token in column.windows
                where niriEngine.findNode(for: token, in: capture.niriWorkspaceId) == nil
                && dwindleEngine.findNode(for: token, in: capture.dwindleWorkspaceId) != nil
            {
                niriDeparted.append(token)
            }
        }
        let dwindleDeparted = capture.dwindle.members.compactMap { member in
            dwindleEngine.findNode(for: member.token, in: capture.dwindleWorkspaceId) == nil
                && niriEngine.findNode(for: member.token, in: capture.niriWorkspaceId) != nil ? member.token : nil
        }
        guard !niriDeparted.isEmpty || !dwindleDeparted.isEmpty else { return }
        let niriAway = niriDeparted.isEmpty ? nil : [NiriLayoutAway(
            workspaceId: capture.niriWorkspaceId, tokens: niriDeparted, snapshot: capture.niri
        )]
        let dwindleAway = dwindleDeparted.isEmpty ? [] : [DwindleLayoutAway(
            workspaceId: capture.dwindleWorkspaceId, tokens: dwindleDeparted, snapshot: capture.dwindle
        )]
        let niri = NiriLayoutSnapshot(
            columns: capture.niri.columns,
            manualWidthColumnCount: capture.niri.manualWidthColumnCount,
            manualHeightColumnCount: capture.niri.manualHeightColumnCount,
            focused: capture.niri.focused,
            foreignTransfer: NiriForeignTransfer(departed: niriDeparted, away: dwindleAway)
        )
        niriEngine.recordForeignLayoutHistory(entry: consume niri, in: capture.niriWorkspaceId)
        dwindleEngine.recordForeignLayoutHistory(
            entry: DwindleLayoutHistoryEntry(
                snapshot: capture.dwindle, departed: dwindleDeparted, niriAway: niriAway
            ),
            in: capture.dwindleWorkspaceId
        )
    }
}
