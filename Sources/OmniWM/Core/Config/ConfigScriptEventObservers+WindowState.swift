// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

@MainActor
struct ConfigScriptObservedWindowStates {
    private struct WindowID {
        let token: WindowToken
        let session: String
        let encoded: String
    }

    private var lastID: WindowID?

    mutating func opaqueID(for token: WindowToken, session: String) -> String {
        if let lastID, lastID.token == token, lastID.session == session { return lastID.encoded }
        #if OMNIWM_CONFIG_CALLBACK_TRACE
            ConfigScriptLatencyTrace.windowStateIDEncoded()
        #endif
        let id = IPCWindowOpaqueID.encode(token: token, sessionToken: session)
        lastID = WindowID(token: token, session: session, encoded: id)
        return id
    }

    struct Request {
        let generation: Int
        let cause: ConfigScriptEventCause
    }

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
        if kinds.contains(.windowMinimize) { manager.scriptWindowMinimizeObserver = self }
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

    func titleChanged(_ title: String, for token: WindowToken, metadataChanged: Bool) {
        guard let controller else { return }
        let manager = controller.workspaceManager
        if !metadataChanged {
            guard manager.managedReplacementMetadata(for: token) == nil,
                  let handle = manager.handle(for: token) else { return }
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
        windowStateChanged(.windowTitle, token: token, value: .title(title))
    }

    func commitMinimization(
        of token: WindowToken, minimized: Bool, in manager: WorkspaceManager, commit: () -> Void
    ) {
        let children: [WindowToken]
        if manager.withEntry(token, { $0.target.hostedMetadata?.role == .main }) == true {
            children = manager.hostedFamilyTokens(for: token).dropFirst().filter { child in
                manager.withEntry(child) { $0.observedState.isMinimized != minimized } == true
            }
        } else {
            children = []
        }
        commit()
        windowStateChanged(.windowMinimize, token: token, value: .minimized(minimized))
        for child in children {
            windowStateChanged(.windowMinimize, token: child, value: .minimized(minimized))
        }
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
        confirming record: WorkspaceNativeFullscreenRecord?
    ) {
        guard let manager = controller?.workspaceManager,
              let (workspace, mode) = manager.withEntry(token, { ($0.workspaceId, $0.mode) }) else { return }
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
        windowStateChanged(.windowFullscreen, token: token, value: .fullscreen(fullscreen))
    }

    func managedFullscreen(
        _ token: WindowToken, workspaceId: WorkspaceDescriptor.ID, manager: WorkspaceManager
    ) -> Bool {
        switch manager.activeLayoutKind(for: workspaceId) {
        case .niri: manager.niriEngine?.isWindowFullscreen(token, in: workspaceId) == true
        case .dwindle: manager.dwindleEngine?.isWindowFullscreen(token, in: workspaceId) == true
        }
    }

    func windowStateChanged(_ kind: ConfigScriptEventKind, token: WindowToken, value: ConfigScriptEventPayload.Edge) {
        guard let controller,
              let bundle = controller.workspaceManager.withEntry(token, {
                  $0.target.hostedMetadata?.appId ?? $0.managedReplacementMetadata?.bundleId
              }) else { return }
        emit(kind, .init(
            id: windowStates.opaqueID(for: token, session: controller.automationSessionToken),
            bundleId: bundle ?? controller.appInfoCache.cachedBundleId(for: token.pid), edge: value
        ))
    }
}
