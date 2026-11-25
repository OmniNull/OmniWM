// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import ScriptARCCounters

@MainActor
extension ScriptARCFixture {
    func windowEvents(in directory: URL) async throws {
        let manager = controller.workspaceManager
        let entry = manager.entry(for: otherWindow)!
        let previous = manager.workspaceId(named: "2")!
        let move = WindowModel.MembershipChange(token: otherWindow, source: previous, destination: entry.workspaceId)
        let kinds: [ConfigScriptEventKind] = [
            .windowOpen, .windowClose, .windowMoveToWorkspace, .windowMinimize, .windowFullscreen, .windowUpdateState
        ]
        for kind in kinds {
            let control = "absent/" + kind.rawValue
            try await loadMissingScript(in: directory)
            script_arc_begin()
            publishWindowEvent(kind, entry, move, manager)
            script_arc_end()
            script_arc_report(control, "native", 0)
            let id = ConfigScriptWindowID.string(otherWindow, session: controller.scriptSession.identity)
            let queue = try await acceptTitleScript("""
            omniwm.on("\(kind.rawValue)", function(e)
                assert(e.id == "\(id)" and e.bundleId == "test.omniwm.snapshot.fixture" and e.missed == 0)
            end)
            """)
            await queue.waitForAuditPark()
            for report in [false, true] {
                script_arc_begin()
                publishWindowEvent(kind, entry, move, manager)
                script_arc_end()
                try await finishWorker(seed: false)
                if report { script_arc_report("event/" + kind.rawValue, control, 1) }
            }
        }
    }

    func ownedWindowEvents() async throws {
        let manager = controller.workspaceManager
        let previous = manager.workspaceId(named: "2")!
        let session = nextScriptSession()
        let bundle = "app." + UUID().uuidString
        setScriptSession(session)
        setTitleBundle(bundle)
        let entry = manager.entry(for: otherWindow)!
        let move = WindowModel.MembershipChange(token: otherWindow, source: previous, destination: entry.workspaceId)
        let id = ConfigScriptWindowID.string(otherWindow, session: session)
        for kind in [ConfigScriptEventKind.windowOpen, .windowMinimize] {
            let queue =
                try await acceptTitleScript(
                    "omniwm.on('\(kind.rawValue)', function(e) assert(e.id == '\(id)' and e.bundleId == '\(bundle)') end)"
                )
            await queue.waitForAuditPark()
            for report in [false, true] {
                script_arc_begin()
                publishWindowEvent(kind, entry, move, manager)
                script_arc_end()
                try await finishWorker(seed: false)
                if report { script_arc_report("owned/" + kind.rawValue, "event/" + kind.rawValue, 1) }
            }
        }
    }

    @inline(never)
    private func publishWindowEvent(
        _ kind: ConfigScriptEventKind, _ entry: borrowing WindowState,
        _ move: WindowModel.MembershipChange, _ manager: WorkspaceManager
    ) {
        switch kind {
        case .windowOpen: if manager.scriptWindowOpenObserver != nil { manager.publishOpenedWindow(entry.token) }
        case .windowClose: if manager.scriptWindowCloseObserver != nil { manager.publishClosedWindow(
                ConfigScriptWindowIdentity(entry),
                name: manager.workspaceCatalog.name(for: entry.workspaceId)
            ) }
        case .windowMoveToWorkspace:
            manager.withWindowMoveObserver {
                $0.windowMoved(move, previousName: manager.workspaceCatalog.name(for: move.source), in: manager)
            }
        case .windowMinimize: manager.publishWindowState(kind, token: entry.token, value: .minimized(true))
        case .windowFullscreen: manager.publishWindowState(kind, token: entry.token, value: .fullscreen(true))
        case .windowUpdateState: manager.publishWindowState(kind, token: entry.token, value: .floating(true))
        default: preconditionFailure()
        }
    }
}

@MainActor
extension ScriptARCFixture {
    func checkWindowDeliveryLifetime() async throws {
        let count = UInt64.bitWidth
        let codes = [
            "local rows = {}",
            "for i=1,\(count) do omniwm.on('window.close', function() end) end",
            "omniwm.on('window.minimize', function(e) table.insert(rows, e.id .. '|' .. e.bundleId .. '|' .. tostring(e.minimized)) end)",
            "omniwm.command('Inspect', function() error(table.concat(rows, ';')) end)"
        ]
        let queue = try await acceptTitleScript(codes.joined(separator: "\n"))
        await queue.waitForAuditPark()
        let observer = script.eventObservers!
        let initial = nextScriptSession()
        var expected: [String] = []
        for session in [initial, nextScriptSession(), initial] {
            setScriptSession(session)
            observer.windowStateChanged(
                .windowMinimize,
                token: otherWindow,
                value: .minimized(false),
                in: controller.workspaceManager
            )
            let bundle = "app." + UUID().uuidString
            setTitleBundle(bundle)
            observer.windowStateChanged(
                .windowMinimize,
                token: otherWindow,
                value: .minimized(true),
                in: controller.workspaceManager
            )
            expected
                .append(ConfigScriptWindowID.string(otherWindow, session: session) + "|" + bundle + "|true")
        }
        precondition(controller.enqueueConfigFunction(script.acceptedCommands.first!.function) == .executed)
        await queue.waitForAuditPark()
        precondition(script.diagnostic?.contains(expected.joined(separator: ";")) == true)
        checkDeferredMaskLifetime()
        try await checkMoveFrames()
    }

    private func checkDeferredMaskLifetime() {
        var feedback = ConfigScriptEventFeedback()
        let count = UInt64.bitWidth
        let handle = controller.workspaceManager.handle(for: otherWindow)!
        let ancestors: ConfigScriptListenerMask = [0, count]
        for listener in [count + 1, count * 2] {
            let cause = ConfigScriptEventCause(function: listener, ancestors: ancestors)
            feedback.begin(cause, controller: controller)
            feedback.recordClose(handle, outcome: .executed, controller: controller)
            feedback.end(controller: controller)
        }
        let excluded = feedback.closeExclusions(token: otherWindow)!
        for member in [0, count, count + 1, count * 2] { precondition(excluded.contains(member)) }
        precondition(!excluded.contains(count - 1) && !ancestors.contains(count + 1))
        precondition(feedback.closeExclusions(token: otherWindow) == nil)
    }

    private func checkMoveFrames() async throws {
        let manager = controller.workspaceManager
        let source = manager.workspace(for: otherWindow)!
        let destination = manager.workspaceId(named: "2")!
        let cap = ConfigScriptCallbackQueue.edgeCapacity
        let ids = (0 ... cap).map { WindowToken(pid: token.pid, windowId: token.windowId + $0) }
        let session = controller.scriptSession.identity
        let ordered = ids.dropFirst().map { "'" + ConfigScriptWindowID.string($0, session: session) + "'" }
            .joined(separator: ",")
        let queue = try await acceptTitleScript("""
        local ids, seen = {\(ordered)}, 0
        omniwm.on('window.move_to_workspace', function(e)
            seen += 1
            assert(e.id == ids[seen] and e.missed == (if seen == #ids then 1 else 0))
        end)
        omniwm.command('Inspect', function() assert(seen == #ids) end)
        """)
        await queue.waitForAuditPark()
        let observer = script.eventObservers!
        let batch = ConfigScriptWindowMoves.Frame()
        for child in Array(ids.dropFirst()) + [ids.last!] {
            batch.append(
                .init(token: token, source: source, destination: destination),
                primary: token,
                catalog: manager.workspaceCatalog
            )
            batch.append(
                .init(token: child, source: source, destination: destination),
                primary: token,
                catalog: manager.workspaceCatalog
            )
        }
        batch.publish(to: observer, in: manager, firstAdmission: true, hydrated: false)
        precondition(controller.enqueueConfigFunction(script.acceptedCommands.first!.function) == .executed)
        await queue.waitForAuditPark()
        precondition(script.diagnostic == nil)
    }
}

@MainActor
extension ScriptARCFixture {
    func callbackDispatchKeys(report: Bool) async throws {
        try await function(binding("Control+Option+D"), route: "key/dispatch-window", busy: false, report: report)
        try await function(binding("Control+Option+C"), route: "key/cmd-in-callback", busy: false, report: report)
        try await function(binding("Control+Option+B"), route: "key/cmd-prebuilt", busy: false, report: report)
        try await function(binding("Control+Option+G"), route: "key/cmd-build-argument", busy: false, report: report)
    }

    func ownedTitles() async throws {
        setScriptSession(nextScriptSession())
        setTitleBundle("app." + UUID().uuidString)
        let queue = try await acceptTitleScript("""
        omniwm.on("window.title", function(e) assert(e.id and e.bundleId and e.title and e.missed == 0) end)
        """)
        await queue.waitForAuditPark()
        for report in [false, true] {
            for replace in [false, true] {
                if replace { title("previous " + UUID().uuidString, native: false, measured: false) }
                title("latest " + UUID().uuidString, native: false, measured: true)
                try await finishWorker(seed: false)
                if report {
                    script_arc_report(replace ? "title/owned-replacement" : "title/owned-fresh", "title/no-observer", 1)
                }
            }
        }
    }

    func events(report: Bool) async throws {
        let older = "ARC fixture renamed window A"
        let latest = "ARC fixture renamed window B"
        for replace in [false, true] {
            if replace { title(older, native: false, measured: false) }
            title(latest, native: false, measured: true)
            try await finishWorker(seed: false)
            if report { script_arc_report(replace ? "title/replacement" : "title/fresh", "title/no-observer", 1) }
        }
        _ = controller.workspaceManager.updateManagedReplacementTitle(older, for: otherWindow)
        controller.requestWorkspaceBarRefresh()
        title(latest, native: true, measured: true)
        try await finishWorker(seed: false)
        if report { script_arc_report("native/title+script", "native/title", 1) }
    }
}
