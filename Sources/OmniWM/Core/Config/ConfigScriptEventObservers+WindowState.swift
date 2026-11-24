// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
struct ConfigScriptObservedWindowStates {
    struct Request {
        let generation: Int
        let cause: ConfigScriptEventCause
    }

    var minimization: ConfigScriptMinimization?
    var priorModes: [WindowToken: TrackedWindowMode] = [:]
    var priorFullscreen: [WindowToken: Bool] = [:]
    var titlesWithoutMetadata: NSMapTable<WindowHandle, NSString>?
    var fullscreenRequests: [WindowToken: Request] = [:]
    var confirmingFullscreen: ConfigScriptEventCause?
}

extension ConfigScriptEventObservers {
    func installWindowStates(on controller: WMController, kinds: Set<ConfigScriptEventKind>) {
        let manager = controller.workspaceManager
        if kinds.contains(.windowTitle) { controller.axEventHandler.scriptWindowTitleObserver = self }
        if kinds.contains(.windowMinimize) {
            windowStates.minimization = ConfigScriptMinimization()
            manager.scriptWindowMinimizeObserver = self
        }
        if kinds.contains(.windowFullscreen) {
            manager.scriptWindowFullscreenObserver = self
            controller.settings.workspaces.scriptFullscreenObserver = self
            replaceNiri(nil, with: manager.niriEngine)
            replaceDwindle(nil, with: manager.dwindleEngine)
        }
        if kinds.contains(.windowUpdateState) || kinds
            .contains(.windowFullscreen) { manager.scriptWindowModeObserver = self }
    }

    func detachWindowStates(from controller: WMController) {
        let manager = controller.workspaceManager
        windowStates.titlesWithoutMetadata = nil
        if kinds.contains(.windowTitle), controller.axEventHandler.scriptWindowTitleObserver === self {
            controller.axEventHandler.scriptWindowTitleObserver = nil
        }
        if manager.scriptWindowMinimizeObserver === self { manager.scriptWindowMinimizeObserver = nil }
        if manager.scriptWindowFullscreenObserver === self {
            manager.scriptWindowFullscreenObserver = nil
            if controller.settings.workspaces.scriptFullscreenObserver === self {
                controller.settings.workspaces.scriptFullscreenObserver = nil
            }
            replaceNiri(manager.niriEngine, with: nil)
            replaceDwindle(manager.dwindleEngine, with: nil)
        }
        if manager.scriptWindowModeObserver === self { manager.scriptWindowModeObserver = nil }
    }

    func titleChanged(_ title: String, for token: WindowToken, metadataChanged: Bool, controller: WMController) {
        guard var identity = controller.workspaceManager.configWindow(for: token, withoutMetadata: !metadataChanged)
        else { return }
        if !metadataChanged {
            guard let handle = controller.workspaceManager.handle(for: token) else { return }
            let cache: NSMapTable<WindowHandle, NSString>
            if let existing = windowStates.titlesWithoutMetadata {
                cache = existing
            } else {
                cache = NSMapTable(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
                windowStates.titlesWithoutMetadata = cache
            }
            guard cache.object(forKey: handle) as String? != title else { return }
            cache.setObject(title as NSString, forKey: handle)
        }
        var bundle = identity.takeBundle()
        if bundle == nil { bundle = controller.appInfoCache.cachedBundleId(for: token.pid) }
        let event = ConfigScriptWindowTitle(
            token: token, session: controller.scriptSession.identity, epoch: controller.scriptSession.epoch,
            title: title, bundle: consume bundle
        )
        publishTitle(consume event, controller: controller)
    }

    func commitMinimization(
        of token: WindowToken, minimized: Bool, in manager: WorkspaceManager, commit: () -> Void
    ) {
        guard manager.readConfigWindow(token, { $0.target.hostedMetadata?.role == .main }) == true,
              let recorder = windowStates.minimization
        else {
            commit()
            if manager.scriptWindowMinimizeObserver === self { manager.publishWindowState(
                .windowMinimize,
                token: token,
                value: .minimized(minimized)
            ) }
            return
        }
        let outer = recorder.active.take()
        recorder.active = .init(root: token)
        commit()
        let batch = recorder.active.take()
        recorder.active = outer
        batch?.publish(minimized: minimized, observer: self, in: manager)
    }

    func recordMinimizedChild(_ token: WindowToken, of root: WindowToken, previous: Bool, minimized: Bool) {
        guard previous != minimized, let recorder = windowStates.minimization,
              recorder.active?.root == root else { return }
        recorder.active?.append(token, observer: self)
    }

    func recordFullscreenRequest(
        for token: WindowToken?, since generation: Int, cause: ConfigScriptEventCause, manager: WorkspaceManager
    ) {
        guard let token, let record = manager.nativeFullscreenRecord(for: token),
              record.transitionGeneration > generation, record.transition != .suspended else { return }
        windowStates.fullscreenRequests = windowStates.fullscreenRequests.filter { original, request in
            manager.nativeFullscreenRecord(originalToken: original)?.transitionGeneration == request.generation
        }
        windowStates.fullscreenRequests[record.originalToken] = .init(
            generation: record.transitionGeneration, cause: cause
        )
    }

    func nativeFullscreenChanged(
        _ fullscreen: Bool,
        for token: WindowToken,
        confirming record: WorkspaceNativeFullscreenRecord?, in manager: WorkspaceManager
    ) {
        guard let (workspace, mode) = manager.readConfigWindow(token, { ($0.workspaceId, $0.mode) }) else { return }
        let previous = windowStates.confirmingFullscreen
        if let record, let issued = windowStates.fullscreenRequests.removeValue(forKey: record.originalToken),
           issued.generation == record.transitionGeneration,
           record.transition == (fullscreen ? .enterRequested : .exitRequested)
        {
            windowStates.confirmingFullscreen = issued.cause
        } else {
            windowStates.confirmingFullscreen = nil
        }
        defer { windowStates.confirmingFullscreen = previous }
        guard mode != .tiling || !managedFullscreen(token, workspaceId: workspace, manager: manager) else { return }
        manager.publishWindowState(.windowFullscreen, token: token, value: .fullscreen(fullscreen))
    }

    func managedFullscreen(
        _ token: WindowToken, workspaceId: WorkspaceDescriptor.ID, manager: WorkspaceManager
    ) -> Bool {
        if let name = manager.workspaceCatalog.name(for: workspaceId),
           manager.settings.workspaces.configScriptLayout(for: name) == .dwindle
        {
            return manager.dwindleEngine?.isWindowFullscreen(token, in: workspaceId) == true
        }
        return manager.niriEngine?.isWindowFullscreen(token, in: workspaceId) == true
    }

    func windowStateChanged(
        _ kind: ConfigScriptEventKind,
        token: WindowToken,
        value: ConfigScriptNativeEvent.Edge,
        in manager: WorkspaceManager
    ) {
        guard var identity = manager.configWindow(for: token) else { return }
        var bundle = identity.takeBundle()
        if bundle == nil { bundle = nativeInput.cachedBundleID(for: token.pid) }
        publishNative(kind, .init(
            id: .window(token, nativeInput.session.identity, nativeInput.session.epoch),
            bundleId: consume bundle, edge: value
        ), in: manager)
    }
}
