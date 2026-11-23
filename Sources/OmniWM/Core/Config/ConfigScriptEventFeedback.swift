// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC
import OmniWMScriptHost

struct ConfigScriptEventCause {
    let function: Int
    let ancestors: Set<Int>

    fileprivate var excludingSelf: Set<Int> {
        var result = ancestors
        result.insert(function)
        return result
    }
}

@MainActor
struct ConfigScriptEventFeedback {
    private struct IssuedFocus {
        let id: UInt64
        let token: WindowToken
        let cause: ConfigScriptEventCause
    }

    static let launchLimit = Int(OMNI_CONFIG_COMMAND_LIMIT)
    static let launchQuietPeriod: Duration = .seconds(1)

    private var applying: ConfigScriptEventCause?
    private var priorFocusRequest: UInt64?
    private var deferredFocus: IssuedFocus?
    private var deferredCloses: [WindowHandle: Set<Int>] = [:]
    private var launches: [Int: (last: ContinuousClock.Instant, count: Int)] = [:]

    mutating func checkLaunch(
        _ dispatch: ConfigScriptDispatch, from function: Int, at now: ContinuousClock.Instant? = nil
    ) throws(ConfigScriptError) {
        switch dispatch.operation {
        case .native(.openApp),
             .native(.runProgram): break
        default: return
        }
        let now = now ?? .now
        if let burst = launches[function], now - burst.last < Self.launchQuietPeriod {
            guard burst.count < Self.launchLimit else {
                throw ConfigScriptError(
                    line: dispatch.line, message: "Repeated event launches reached the limit of \(Self.launchLimit).",
                    source: dispatch.source
                )
            }
            launches[function] = (now, burst.count + 1)
        } else {
            launches[function] = (now, 1)
        }
    }

    mutating func begin(_ cause: ConfigScriptEventCause, controller: WMController) {
        applying = cause
        priorFocusRequest = controller.workspaceManager.focusSessionSnapshot.pendingManagedFocus.requestId
    }

    mutating func end(controller: WMController) {
        let pending = controller.workspaceManager.focusSessionSnapshot.pendingManagedFocus
        if let id = pending.requestId, id != priorFocusRequest, let token = pending.token, let applying {
            deferredFocus = IssuedFocus(id: id, token: token, cause: applying)
        } else if deferredFocus?.id != pending.requestId {
            deferredFocus = nil
        }
        applying = nil
        priorFocusRequest = nil
    }

    mutating func recordClose(_ handle: WindowHandle, outcome: ExternalCommandResult, controller: WMController) {
        guard outcome == .executed, let applying,
              controller.workspaceManager.handle(for: handle.token) === handle else { return }
        deferredCloses[handle, default: []].formUnion(applying.excludingSelf)
    }

    mutating func closeExclusions(id: String?, controller: WMController) -> Set<Int> {
        var excluded = applying?.excludingSelf ?? []
        guard !deferredCloses.isEmpty, let id,
              let decoded = IPCWindowOpaqueID.decode(id, expectingSessionToken: controller.automationSessionToken)
        else { return excluded }
        let token = WindowToken(pid: decoded.pid, windowId: decoded.windowId)
        if let handle = deferredCloses.keys.first(where: { $0.token == token }),
           let issued = deferredCloses.removeValue(forKey: handle)
        {
            excluded.formUnion(issued)
        }
        return excluded
    }

    mutating func exclusions(for kind: ConfigScriptEventKind, controller: WMController) -> Set<Int> {
        if let applying { return applying.excludingSelf }
        guard let focus = deferredFocus else { return [] }
        switch kind {
        case .windowActive,
             .workspaceActive,
             .monitorFocused:
            let manager = controller.workspaceManager
            guard manager.focusSessionSnapshot.pendingManagedFocus.requestId != focus.id else { return [] }
            guard manager.nativeManagedFocusToken == focus.token,
                  controller.intentLedger.activeManagedRequest(requestId: focus.id)?.token == focus.token
            else {
                deferredFocus = nil
                return []
            }
            return focus.cause.excludingSelf
        default:
            return []
        }
    }
}
