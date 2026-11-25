// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMIPC
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

@MainActor
func measureDisplayMoves(in directory: URL) async throws {
    for (route, byName) in [("move/by-name", true), ("move/neighbor", false)] {
        let location = directory.appendingPathComponent(route.replacingOccurrences(of: "/", with: "-"))
        try await ScriptARCFixture(directory: location).displayMove(route: route, byName: byName)
    }
}

@MainActor
extension ScriptARCFixture {
    fileprivate func displayMove(route: String, byName: Bool) async throws {
        let manager = controller.workspaceManager
        let first = manager.monitors.first!
        let frame = first.frame.offsetBy(dx: first.frame.width, dy: 0)
        let second = Monitor(
            id: .init(displayId: first.displayId + 1), displayId: first.displayId + 1, frame: frame,
            visibleFrame: frame, hasNotch: false, name: "Audit right", displayUUID: UUID().uuidString, isMain: false
        )
        manager.applyMonitorConfigurationChange([first, second])
        let name = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.workspaces.map(\.name))
        manager.settings.workspaces.configurations.append(
            WorkspaceConfiguration(name: name, monitorAssignment: .specificDisplay(OutputId(from: second)))
        )
        manager.applySettings()
        let source = manager.workspace(for: otherWindow)!
        let destination = manager.workspaceId(named: name)!
        precondition(manager.setActiveWorkspace(destination, on: second.id))
        let resident = WindowToken(pid: otherWindow.pid, windowId: token.windowId + Self.totalRows)
        let residentWindow = AXWindowRef(
            element: AXUIElementCreateApplication(resident.pid),
            windowId: resident.windowId
        )
        precondition(manager.addWindow(
            residentWindow, pid: resident.pid, windowId: resident.windowId, to: destination, mode: .tiling
        ) == resident)
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = controller.niriEngine!
        manager.withEngineMutationScope {
            _ = engine.addWindow(token: otherWindow, to: source, afterSelection: nil)
            _ = engine.addWindow(token: resident, to: destination, afterSelection: nil)
        }
        precondition(manager.windowMode(for: otherWindow) == .tiling && manager.windowMode(for: resident) == .tiling)
        let id = ConfigScriptWindowID.string(otherWindow, session: controller.scriptSession.identity)
        let place = byName ? "\"\(name)\"" : "{ neighbor = \"right\" }"
        let queue = try await acceptTitleScript("""
        omniwm.keymap.set("Control+Option+J", function() omniwm.dispatch("window", "move-to-workspace", "\(id)", \(place)) end)
        """)
        await queue.waitForAuditPark()
        try await function(binding("Control+Option+J"), route: route, busy: false, report: true)
        let column = engine.findNode(for: otherWindow, in: destination).flatMap(engine.column(of:))
        precondition(manager.workspace(for: otherWindow) == destination && column?.windowNodes.count == 1)
        precondition(engine.columns(in: destination).count == 2)
    }
}

@MainActor
func measurePlacement(in directory: URL) async throws {
    let fixture = try ScriptARCFixture(directory: directory.appendingPathComponent("placement"))
    try await fixture.placement()
}

@MainActor
extension ScriptARCFixture {
    private var placementWindows: [WindowToken] {
        let manager = controller.workspaceManager
        return (0 ..< Self.workspaceRows).map { WindowToken(pid: token.pid, windowId: token.windowId + $0) }
            .filter { manager.windowMode(for: $0) == .tiling }
    }

    fileprivate func placement() async throws {
        let manager = controller.workspaceManager
        let workspace = manager.workspace(for: otherWindow)!
        let windows = placementWindows
        precondition(windows.count == Self.workspaceRows / 2 && windows.first == otherWindow)
        precondition(windows.allSatisfy { manager.workspace(for: $0) == workspace })
        controller.niriLayoutHandler.enableNiriLayout()
        manager.withEngineMutationScope {
            for window in windows {
                _ = controller.niriEngine!.addWindow(token: window, to: workspace, afterSelection: nil)
            }
        }
        regroupPlacementWindows(in: workspace)
        _ = manager.confirmManagedFocus(
            otherWindow, in: workspace, onMonitor: manager.monitorId(for: workspace), activateWorkspaceOnMonitor: false
        )
        precondition(manager.nativeManagedFocusToken == otherWindow)
        let session = controller.scriptSession.identity
        let (sibling, neighbor) = (
            ConfigScriptWindowID.string(windows[1], session: session),
            ConfigScriptWindowID.string(windows[2], session: session)
        )
        _ = try await acceptTitleScript("""
        local wm = omniwm
        wm.keymap.set("Control+Option+J", function(c) assert(c.placement and #c.placement.members == 2) end, { reads = { "placement" } })
        wm.keymap.set("Control+Option+K", function(c) assert(c.windowId and c.placement == nil) end)
        wm.keymap.set("Control+Option+D", function() wm.dispatch("window", "place-in-own-column", "\(sibling)", "\(windows.count)") end)
        wm.keymap.set("Control+Option+M", function() wm.dispatch("window", "place-in-own-column", "\(neighbor)", "1") end)
        wm.keymap.set("Control+Option+F", function() wm.dispatch("window", "move-column-to-first", "\(neighbor)") end)
        wm.keymap.set("Control+Option+I", function() wm.dispatch("window", "move-column-to-index", "\(neighbor)", "2") end)
        """)
        await script.callbackQueue!.waitForAuditPark()
        for report in [false, true] {
            placementCapture([], route: "capture/no-placement", members: nil, report: report)
            placementCapture(.placement, route: "capture/placement", members: 2, report: report)
            try await function(binding("Control+Option+K"), route: "key/no-placement", busy: false, report: report)
            try await function(binding("Control+Option+J"), route: "key/placement", busy: false, report: report)
        }
        try await placementActions(in: workspace)
        try await function(binding("Control+Option+F"), route: "setup/first", busy: false, report: false)
        precondition(controller.niriEngine!.columns(in: workspace).first?.windowNodes.map(\.token) == [windows[2]])
        placementCapture(.placement, route: "capture/placement-mutated", members: 2, report: true)
        try await restorePlacementNeighbor(in: workspace)
        heldTabCaptures(in: workspace)
        precondition(manager.setWindowMinimized(true, token: windows[1]))
        for report in [false, true] {
            placementCapture(.placement, route: "capture/placement-excluded", members: 1, report: report)
        }
    }

    private func placementActions(in workspace: WorkspaceDescriptor.ID) async throws {
        let engine = controller.niriEngine!
        let windows = placementWindows
        for report in [false, true] {
            try await function(binding("Control+Option+D"), route: "place/detach", busy: false, report: report)
            let detached = [windows[0]] + windows.dropFirst(2) + [windows[1]]
            precondition(engine.columns(in: workspace).map { $0.windowNodes.map(\.token) } == detached.map { [$0] })
            regroupPlacementWindows(in: workspace)
        }
        for report in [false, true] {
            try await function(binding("Control+Option+M"), route: "place/column", busy: false, report: report)
            precondition(engine.columns(in: workspace).first?.windowNodes.map(\.token) == [windows[2]])
            try await restorePlacementNeighbor(in: workspace)
        }
    }

    private func restorePlacementNeighbor(in workspace: WorkspaceDescriptor.ID) async throws {
        try await function(binding("Control+Option+I"), route: "setup/index", busy: false, report: false)
        precondition(controller.niriEngine!.columns(in: workspace).dropFirst().first?.windowNodes
            .map(\.token) == [placementWindows[2]])
    }

    private func heldTabCaptures(in workspace: WorkspaceDescriptor.ID) {
        let manager = controller.workspaceManager
        let engine = controller.niriEngine!
        let monitor = manager.monitor(for: workspace)!
        let window = engine.findNode(for: otherWindow, in: workspace)!
        let column = engine.column(of: window)!
        let context = NiriInteractionContext(
            workspaceId: workspace, motion: .disabled, workingFrame: controller.niriWorkingFrame(for: monitor),
            gaps: controller.innerGap(for: monitor), orientation: .horizontal
        )
        manager.withEngineMutationScope(in: workspace) {
            column.displayMode = .tabbed
            manager.withNiriViewportState(for: workspace) { state in
                precondition(engine.liveColumnMoveBegin(
                    windowId: window.id, windowToken: otherWindow, context: context, state: &state
                ))
            }
            engine.liveColumnMove?.heldTabs = column.windowNodes.filter { $0 !== window }
        }
        precondition(engine.isLiveHeldTab(placementWindows[1], in: workspace))
        for report in [false, true] {
            placementCapture(.placement, route: "capture/placement-held-tab", members: 1, report: report)
        }
        manager.withEngineMutationScope(in: workspace) {
            engine.liveColumnMove = nil
            column.displayMode = .normal
        }
    }

    private func regroupPlacementWindows(in workspace: WorkspaceDescriptor.ID) {
        let engine = controller.niriEngine!
        let windows = placementWindows
        controller.workspaceManager.withEngineMutationScope(in: workspace) {
            let node = engine.findNode(for: windows[1], in: workspace)!
            let source = engine.column(of: node)!
            let group = engine.findNode(for: otherWindow, in: workspace).flatMap(engine.column(of:))!
            if source !== group {
                engine.moveWindowToColumn(node, from: source, to: group, in: workspace)
                source.remove()
            }
        }
        precondition(engine.columns(in: workspace).map { $0.windowNodes.map(\.token) }
            == [[windows[0], windows[1]]] + windows.dropFirst(2).map { [$0] })
    }

    @inline(never)
    private func placementCapture(_ reads: ConfigScriptReads, route: String, members: Int?, report: Bool) {
        let queue = script.callbackQueue!
        script_arc_begin()
        let capture = queue.capture(reads: reads, controller: controller)
        script_arc_end()
        if report {
            script_arc_report(route, "capture/fixed", 0)
            print("snapshot-bytes \(route) \(capture.snapshot?.withUnsafeBytes(\.count) ?? 0)")
        }
        withUnsafePointer(to: capture) { script_arc_sink($0) }
        precondition(capture.target.token == otherWindow && (capture.snapshot == nil) == reads.isEmpty)
        guard let members else { return }
        capture.snapshot!.withUnsafeBytes { bytes in
            let header = bytes.loadUnaligned(as: UInt64.self).littleEndian
            precondition(UInt16(truncatingIfNeeded: header >> 16) == 1)
            var offset = MemoryLayout<UInt64>.size
            for _ in ["workspace", "display"] {
                let length = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                offset += MemoryLayout<UInt32>.size + (length == .max ? 0 : Int(length))
            }
            offset += MemoryLayout<UInt8>.size + 2 * MemoryLayout<UInt16>.size
            precondition(Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian) == members)
        }
    }
}
