// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceNavigationHandler {
    private struct DwindleWindowTransferResult {
        var firstMoved: WindowToken?
        var selectedMoved: WindowToken?
        var sourceFocus: WindowToken?
    }

    func transferDwindleWindow(
        _ token: WindowToken,
        from source: WorkspaceDescriptor.ID,
        to target: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowTransferResult {
        let result = transferDwindleWindows(CollectionOfOne(token), from: source, to: target, controller: controller)
        return WindowTransferResult(succeeded: result.firstMoved != nil, newSourceFocusToken: result.sourceFocus)
    }

    func moveDwindleWindowsFromBar(
        _ tokens: [WindowToken],
        to target: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> Bool? {
        guard let first = tokens.first,
              let source = controller.workspaceManager.workspace(for: first), source != target,
              controller.workspaceManager.activeLayoutKind(for: source) == .dwindle,
              controller.workspaceManager.activeLayoutKind(for: target) == .dwindle,
              tokens.allSatisfy({
                  controller.workspaceManager.workspace(for: $0) == source
                      && controller.workspaceManager.windowMode(for: $0) == .tiling
              })
        else { return nil }
        let result = transferDwindleWindows(tokens, from: source, to: target, controller: controller)
        guard let firstMoved = result.firstMoved else { return false }
        let selected = result.selectedMoved ?? firstMoved
        applySessionPatch(workspaceId: target, rememberedFocusToken: selected)
        controller.recoverSourceFocusAfterMove(in: source, preferredToken: result.sourceFocus)
        let follows = result.selectedMoved != nil || controller.settings.focus.followsWindowToMonitor
        finishWorkspaceMove(
            StructuralMutation(
                sourceWorkspaceId: source,
                destinationWorkspaceId: target,
                selectedHandle: WindowHandle(id: selected),
                scrollWorkspaceId: nil
            ),
            focusPolicy: follows ? .configured : .retainCurrent,
            focusOrigin: .pointerSelection
        )
        return true
    }

    private func transferDwindleWindows<Tokens: Collection>(
        _ tokens: Tokens,
        from source: WorkspaceDescriptor.ID,
        to target: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> DwindleWindowTransferResult where Tokens.Element == WindowToken {
        guard let engine = controller.dwindleEngine,
              let monitor = controller.workspaceManager.monitor(for: target)
        else { return DwindleWindowTransferResult() }
        let manager = controller.workspaceManager
        let selected = manager.selectedManagedToken
        return manager.withEngineMutationScope(in: source, label: "dwindle_workspace_move") {
            let beforeSource = engine.layoutSnapshot(in: source)
            let beforeTarget = engine.layoutSnapshot(in: target)
            controller.dwindleLayoutHandler.applyResolvedSettings(
                controller.resolvedDwindleSettings(for: monitor),
                to: engine
            )
            let bootstrap = engine.hasCurrentFrames(in: target)
                ? nil : controller.layoutRefreshController.buildMonitorSnapshot(for: monitor)
            if let bootstrap, engine.windowCount(in: target) > 0 {
                calculateTransferBootstrap(bootstrap, in: target, engine: engine)
            }
            var result = DwindleWindowTransferResult()
            for token in tokens {
                guard let entry = manager.entry(for: token), entry.workspaceId == source, entry.mode == .tiling,
                      entry.target.hostedMetadata?.role.parent == nil,
                      !manager.isWindowSuppressedByMacOS(token),
                      let transferred = engine.detachForTransfer(token: token, wholeTile: false, from: source)
                else { continue }
                transferred.tile.setFullscreen(false, for: token)
                let activeFrame = engine.selectedNode(in: target)?.cachedFrame
                    ?? engine.root(for: target)?.descendToFirstLeaf().cachedFrame
                engine.attachTransferredTile(
                    transferred, placement: .defaultPlacement, in: target, activeWindowFrame: activeFrame
                )
                if let bootstrap { calculateTransferBootstrap(bootstrap, in: target, engine: engine) }
                manager.setWorkspace(for: token, to: target)
                if result.firstMoved == nil { result.firstMoved = token }
                if token == selected { result.selectedMoved = token }
            }
            if result.firstMoved != nil {
                engine.recordLayoutTransfer(
                    from: source, to: target, sourceBefore: consume beforeSource, targetBefore: consume beforeTarget
                )
                result.sourceFocus = engine.projectedActiveToken(in: source)
            }
            return result
        }
    }

    private func calculateTransferBootstrap(
        _ monitor: LayoutMonitorSnapshot,
        in workspaceId: WorkspaceDescriptor.ID,
        engine: DwindleLayoutEngine
    ) {
        _ = engine.calculateLayout(
            for: workspaceId,
            screen: monitor.workingFrame,
            borderSafeFillScreen: monitor.borderSafeFillFrame,
            fullscreenScreen: monitor.fullscreenLayoutFrame
        )
    }
}
