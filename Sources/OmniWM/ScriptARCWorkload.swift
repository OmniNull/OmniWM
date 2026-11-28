// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMScriptHost
import ScriptARCCounters

struct ScriptARCError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class ScriptARCObject {}

extension ConfigScriptCallbackQueue {
    func waitForAuditPark() async {
        guard let worker, !isParked else { return }
        await withUnsafeContinuation { (observer: UnsafeContinuation<Void, Never>) in
            script_arc_watch_park(
                unsafeBitCast(worker, to: UnsafeRawPointer.self), unsafeBitCast(
                    observer,
                    to: UnsafeMutableRawPointer.self
                )
            )
        }
        precondition(isParked)
    }
}

@MainActor
final class ScriptARCFixture {
    static let workspaceRows = 8
    static let totalRows = 200
    static let decodeSamples = 101
    static let plainChord = "Control+Option+P"
    let controller: WMController
    let script: ConfigScriptController
    let token: WindowToken
    let otherWindow: WindowToken
    private var nextTitle = "ARC fixture renamed window A"
    var scriptSessionSerial: UInt128 = 0
    private(set) var titleReads = 0

    init(directory: URL, snapshotRows: Int? = nil) throws {
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
        settings.animationsEnabled = false
        settings.workspaceBar.enabled = false
        guard let native = settings.hotkeyBindings.first(where: { $0.command == .monitorFocus(.next) }) else {
            throw ScriptARCError("Missing native monitor shortcut")
        }
        settings.hotkeyBindings = [native]
        controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: directory,
            diagnosticsDirectory: directory
        )
        script = ConfigScriptController(
            fileURL: directory.appendingPathComponent("init.luau"),
            settings: settings,
            loader: Self.storeLoader(in: directory),
            wmController: controller
        ) { _ in }
        let pid = getpid()
        token = WindowToken(pid: pid, windowId: Int(pid))
        otherWindow = WindowToken(pid: pid, windowId: token.windowId + 1)
        controller.scriptSession = ConfigScriptSessionToken(identity: ConfigScriptSession(id: scriptSessionSerial))
        try Self.prepareModel(controller, base: token, snapshotRows: snapshotRows)
        controller.surfaceReconciler.controller = nil
        controller.axEventHandler.windowTitleProvider = { [unowned self] _ in
            self.titleReads += 1
            return self.nextTitle
        }
        controller.workspaceManager.flushPersistedWindowRestoreCatalogNow()
    }

    private static func prepareModel(_ controller: WMController, base: WindowToken, snapshotRows: Int?) throws {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "First",
            displayUUID: UUID().uuidString,
            isMain: true
        )
        let manager = controller.workspaceManager
        let settings = controller.settings
        manager.onSessionStateChanged = nil
        manager.onRuntimeInvalidation = nil
        manager.onWindowPresenceObserved = nil
        manager.onWindowRemoved = nil
        manager.onAnimationMotionsWillBeRemoved = nil
        manager.applyMonitorConfigurationChange([monitor])
        let firstName = snapshotRows == nil ? "1" : String(Int.max)
        let names = [firstName, "2"]
        settings.workspaces.configurations = names.map {
            WorkspaceConfiguration(
                name: $0,
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        }
        manager.applySettings()
        guard let first = manager.workspaceId(for: names[0], createIfMissing: true),
              let second = manager.workspaceId(for: names[1], createIfMissing: true)
        else {
            throw ScriptARCError("Missing fixture workspace")
        }
        _ = manager.setActiveWorkspace(first, on: monitor.id)
        _ = manager.setInteractionMonitor(monitor.id)
        if let snapshotRows {
            try admitSnapshotRows(snapshotRows, base: base, workspace: first, controller: controller)
        } else {
            try admitWindows(in: manager, base: base, first: first, second: second)
        }
        guard manager.confirmManagedFocus(base, in: first, onMonitor: monitor.id, activateWorkspaceOnMonitor: false)
        else {
            throw ScriptARCError("Missing fixture focus")
        }
    }

    private static func admitWindows(
        in manager: WorkspaceManager, base: WindowToken, first: WorkspaceDescriptor.ID, second: WorkspaceDescriptor.ID
    ) throws {
        let pid = base.pid
        let ax = AXUIElementCreateApplication(pid)
        for index in 0 ..< Self.totalRows {
            let workspace = index < Self.workspaceRows ? first : second
            let window = AXWindowRef(element: ax, windowId: base.windowId + index)
            let mode: TrackedWindowMode = index.isMultiple(of: 2) ? .floating : .tiling
            guard manager.addWindow(
                window,
                pid: pid,
                windowId: base.windowId + index,
                to: workspace,
                mode: mode,
                managedReplacementMetadata: .init(
                    bundleId: "test.omniwm.snapshot.fixture",
                    workspaceId: workspace,
                    mode: mode,
                    title: "Snapshot fixture window " + String(index)
                )
            ) == WindowToken(pid: pid, windowId: base.windowId + index) else {
                throw ScriptARCError("Missing fixture window")
            }
        }
    }

    static func chord(_ text: String, mask: UInt32) throws -> KeyBinding {
        guard let chord = KeySymbolMapper.fromHumanReadable(text, hyperMask: mask) else {
            throw ScriptARCError("Invalid fixture chord " + text)
        }
        return chord
    }

    func binding(_ text: String) throws -> HotkeyCommand {
        let chord = try Self.chord(text, mask: controller.settings.hyperKeyModifiers.carbonMask)
        guard let binding = script.effectiveBindings.first(where: { $0.binding.chordBinding == chord }) else {
            throw ScriptARCError("Missing fixture shortcut " + text)
        }
        return binding.command
    }

    func loadMissingScript(in directory: URL) async throws {
        let mask = controller.settings.hyperKeyModifiers.carbonMask
        let load = await loader.load(fileURL: directory.appendingPathComponent("init.luau"), hyperMask: mask)
        controller.configScript = script
        guard case .success(nil) = load.result, script.apply(load, hyperMask: mask) else {
            throw ScriptARCError("Dormant control needs an absent init.luau")
        }
    }

    func subscribe(withEventReads: Bool = false) async throws {
        let expected = ConfigScriptWindowID.string(otherWindow, session: controller.scriptSession.identity)
        let reads = withEventReads ? #", {reads={"workspaceWindows"}}"# : ""
        let verifyReads = withEventReads ? "assert(#e.workspaceWindows == \(Self.workspaceRows))" : ""
        let source = """
        local wm = omniwm
        local prebuilt = wm.cmd.focusMonitor("next")
        wm.keymap.set("\(Self.plainChord)", wm.cmd.focusMonitor("next"))
        wm.keymap.set("Control+Option+F", function(c) assert(c.windowId and not c.windows and not c.workspaceWindows) end)
        wm.keymap.set("Control+Option+L", function(c) assert(#c.workspaceWindows == \(Self.workspaceRows) and not c.windows) end, {reads={"workspaceWindows"}})
        wm.keymap.set("Control+Option+A", function(c) assert(#c.windows == \(Self.totalRows) and not c.workspaceWindows) end, {reads={"windows"}})
        wm.keymap.set("Control+Option+D", function(c) wm.dispatch("window", "move-to-workspace", c.windowId, c.workspace) end)
        wm.keymap.set("Control+Option+C", function(c) wm.dispatch(wm.cmd.focusMonitor("next")) end)
        wm.keymap.set("Control+Option+B", function(c) wm.dispatch(prebuilt) end)
        wm.keymap.set("Control+Option+G", function(c) local action = wm.cmd.focus("left") end)
        wm.on("window.title", function(e)
            assert(e.id == "\(expected)" and e.title == "ARC fixture renamed window B")
            \(verifyReads)
        end\(reads))
        """
        let mask = controller.settings.hyperKeyModifiers.carbonMask
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        controller.configScript = script
        if !withEventReads { script_arc_begin() }
        let applied = script.apply(ConfigScriptLoad(versions: [:], result: .success(evaluation)), hyperMask: mask)
        if !withEventReads { script_arc_end() }
        guard applied,
              script.diagnostic == nil else { throw ScriptARCError(script.diagnostic ?? "Could not load fixture") }
        if !withEventReads {
            try await finishWorker(seed: false)
            script_arc_report("setup/activation", "native", 0)
        }
    }

    @inline(never)
    func key(_ command: HotkeyCommand, measured: Bool) -> ExternalCommandResult {
        if measured { script_arc_begin() }
        let result = CommandHandler.handleHotkeyInvocation(HotkeyInvocation(command: command), controller: controller)
        if measured { script_arc_end() }
        return result
    }

    @inline(never)
    func title(_ title: String, native: Bool, measured: Bool) {
        nextTitle = title
        if native {
            let reads = titleReads
            if measured { script_arc_begin() }
            controller.axEventHandler.handleWindowTitleChanged(
                windowId: UInt32(otherWindow.windowId),
                pid: otherWindow.pid
            )
            if measured { script_arc_end() }
            precondition(titleReads == reads + 1)
            precondition(controller.workspaceManager.managedReplacementMetadata(for: otherWindow)?.title == title)
        } else {
            let observer = controller.axEventHandler.scriptWindowTitleObserver
            if measured { script_arc_begin() }
            observer?.titleChanged(title, for: otherWindow, metadataChanged: true, controller: controller)
            if measured { script_arc_end() }
        }
    }

    @inline(never)
    func snapshot(_ reads: ConfigScriptReads, route: String, report: Bool, expectedRows: Int? = nil) {
        let queue = script.callbackQueue!
        script_arc_begin()
        let capture = queue.capture(reads: reads, controller: controller)
        script_arc_end()
        if report {
            script_arc_report(route, reads.isEmpty ? "native/model" : "capture/fixed", 0)
            print("snapshot-bytes \(route) \(capture.snapshot?.withUnsafeBytes(\.count) ?? 0)")
        }
        withUnsafePointer(to: capture) { script_arc_sink($0) }
        if let expectedRows {
            let count = capture.snapshot!.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
            precondition(UInt16(truncatingIfNeeded: count >> 16) == expectedRows)
        }
        precondition(capture.target.token == token && (capture.snapshot == nil) == reads.isEmpty)
    }

    func dormant(report: Bool) {
        let manager = controller.workspaceManager
        precondition(controller.configScript === script && script.callbackQueue == nil && script.eventObservers == nil)
        precondition(controller.axEventHandler.scriptWindowTitleObserver == nil && manager
            .scriptWindowMinimizeObserver == nil)
        precondition(manager.scriptWindowModeObserver == nil && manager.scriptWindowFullscreenObserver == nil)
        precondition(manager.scriptTopologyObserver == nil && controller.scriptModeObserver == nil)
        title("ARC fixture renamed window B", native: false, measured: true)
        if report { script_arc_report("title/no-observer", "native", 0) }
        title("ARC fixture renamed window A", native: true, measured: false)
        title("ARC fixture renamed window B", native: true, measured: true)
        if report { script_arc_report("native/title", "native", 0) }
        script_arc_begin()
        let changed = manager.setWindowMinimized(true, token: otherWindow)
        script_arc_end()
        precondition(changed)
        if report { script_arc_report("native/minimize", "native", 0) }
        precondition(manager.setWindowMinimized(false, token: otherWindow))
        script_arc_begin()
        let floated = manager.setWindowMode(.floating, for: otherWindow)
        script_arc_end()
        precondition(floated)
        if report { script_arc_report("native/float", "native", 0) }
        precondition(manager.setWindowMode(.tiling, for: otherWindow))
        script_arc_begin()
        let suspended = manager.markNativeFullscreenSuspended(otherWindow, ownsNativeFocus: false)
        script_arc_end()
        precondition(suspended)
        if report { script_arc_report("native/fullscreen", "native", 0) }
        precondition(manager.restoreNativeFullscreenRecord(for: otherWindow, clearsNativeFocusOwner: false))
        precondition(script.callbackQueue?.worker == nil)
    }

    func plainKeys(_ settings: HotkeyCommand, _ native: HotkeyCommand, report: Bool) throws {
        let settingsResult = key(settings, measured: true)
        script_arc_save_native_key()
        if report { script_arc_report("settings/key", "native", 0) }
        let scriptResult = key(native, measured: true)
        if report {
            script_arc_check_native_key()
            script_arc_report("script/plain-key", "settings/key", 0)
        }
        guard settings == native, settingsResult == .noChange, settingsResult == scriptResult,
              script.callbackQueue?.isParked == true
        else {
            throw ScriptARCError("Native shortcuts must share their result and leave the queue idle")
        }
    }

    func function(_ command: HotkeyCommand, route: String, busy: Bool, report: Bool) async throws {
        if busy { precondition(key(command, measured: false) == .executed) }
        precondition(script.callbackQueue?.hasPendingWork == busy)
        precondition(key(command, measured: true) == .executed)
        try await finishWorker(seed: busy)
        if report { script_arc_report(route, "settings/key", 1) }
    }

    func ownedKey(_ command: HotkeyCommand) async throws {
        _ = installCapturedIdentity(session: nextScriptSession(), from: controller.activeWorkspace()!.id)
        for report in [false, true] {
            try await function(command, route: "key/owned-busy", busy: true, report: report)
        }
    }

    func refusals(_ command: HotkeyCommand) async throws {
        guard let queue = script.callbackQueue else { throw ScriptARCError("Missing callback queue") }
        script.onDiagnosticChanged = { [weak controller] diagnostic in controller?.configScriptDiagnostic = diagnostic }
        for _ in 0 ..< ConfigScriptCallbackQueue.capacity {
            precondition(key(command, measured: false) == .executed)
        }
        for route in ["key/refusal-first", "key/refusal-repeat"] {
            withObservationTracking { _ = controller.configScriptDiagnostic } onChange: {}
            precondition(key(command, measured: true) == .windowActionFailed)
            script_arc_report(route, "settings/key", 0)
            precondition(script.diagnostic != nil && controller.configScriptDiagnostic == script.diagnostic)
        }
        await queue.waitUntilParked()
    }
}

@inline(never)
private func exerciseScriptARCHooks() {
    let marker = NSString(string: "script arc calibration")
    let object = Unmanaged.passRetained(ScriptARCObject())
    let multipleReferences: UInt32 = 3
    script_arc_calibration_calls(object.toOpaque(), Unmanaged.passUnretained(marker).toOpaque(), multipleReferences)
    object.release()
}

extension ConfigScriptGeneration {
    fileprivate func calibrateScriptARCExecutor() {
        exerciseScriptARCHooks()
        script_arc_config_return()
    }
}

@MainActor
private func calibrateScriptARC() async {
    script_arc_begin()
    exerciseScriptARCHooks()
    script_arc_end()
    let generation = ConfigScriptLoader().makeGeneration()
    let task = Task { @MainActor in
        exerciseScriptARCHooks()
        await generation.calibrateScriptARCExecutor()
        exerciseScriptARCHooks()
    }
    script_arc_follow(unsafeBitCast(task, to: UnsafeRawPointer.self), false)
    await task.value
    script_arc_finish()
    script_arc_check_calibration()
}

@MainActor
private func observeEventDelivery(_ fixture: ScriptARCFixture, directory: URL) async throws {
    try await fixture.loadMissingScript(in: directory)
    fixture.dormant(report: false)
    script_arc_checkpoint()
    try await fixture.subscribe(withEventReads: true)
    let titles = ["ARC fixture renamed window A", "ARC fixture renamed window B"]
    for title in titles { fixture.title(title, native: true, measured: false) }
    print("delivery-expect dormant=0 subscribed=\(titles.count)")
    await fixture.script.callbackQueue!.waitForAuditPark()
    precondition(fixture.script.diagnostic == nil)
    script_arc_checkpoint()
}

@MainActor
package func runScriptARCAudit(directory: URL, observeDelivery: Bool) async throws {
    _ = NSApplication.shared
    script_arc_install()
    if !observeDelivery { await calibrateScriptARC() }
    let fixture = try ScriptARCFixture(directory: directory)
    defer { fixture.script.stop() }
    if observeDelivery {
        try await observeEventDelivery(fixture, directory: directory)
        return
    }
    print(
        "Controls: key routes use settings/key and script/plain-key. Native title uses native/title. The title adapter uses title/no-observer. List captures use capture/fixed."
    )
    print(
        "Counts: Swift retains/releases (weighted), objects, allocation events; weak Swift/unknown/ObjC; ObjC retain/release/retain-return/autorelease-return; CF retain/release; unknown and bridge retain/release; VM entries."
    )
    print(
        "route                native-control    phase          R     L obj heap  wS  wU  wO  oR  oL oRV oAV  cR  cL  uR  uL  bR  bL VM"
    )
    try await fixture.loadMissingScript(in: directory)
    for report in [false, true] { fixture.dormant(report: report) }
    try await fixture.subscribe()
    let plain = try fixture.resolvePlainKeyControls()
    let fixed = try fixture.binding("Control+Option+F")
    let local = try fixture.binding("Control+Option+L")
    let all = try fixture.binding("Control+Option+A")
    try await fixture.function(fixed, route: "key/cold", busy: false, report: true)
    for report in [false, true] {
        try fixture.plainKeys(plain.settings, plain.script, report: report)
        try await fixture.function(fixed, route: "key/idle", busy: false, report: report)
        try await fixture.function(fixed, route: "key/busy", busy: true, report: report)
        try await fixture.function(local, route: "key/workspace-8", busy: false, report: report)
        try await fixture.function(all, route: "key/windows-200", busy: false, report: report)
        try await fixture.callbackDispatchKeys(report: report)
        try await fixture.events(report: report)
        fixture.snapshot([], route: "capture/fixed", report: report)
        fixture.snapshot(.workspaceWindows, route: "capture/workspace-8", report: report)
        fixture.snapshot(.windows, route: "capture/windows-200", report: report)
    }
    try runScriptARCWorkspaceKeys(directory: directory)
    try await measureSnapshotRows(in: directory)
    try await fixture.ownedKey(fixed)
    try await fixture.refusals(fixed)
    try await fixture.ownedTitles()
    try await fixture.ownedFocusEvents()
    try await fixture.commandSelectorKeys()
    try await measureEventFamilies(in: directory)
    try await measureWindowDetailReads(in: directory)
    try await measureWholeReads(in: directory)
}

@MainActor
private func measureWholeReads(in directory: URL) async throws {
    try await measureMarkReads(in: directory)
    try await measureAppAndRuleReads(in: directory)
    try await measureWorkspaceBarReads(in: directory)
    try await measureShellReads(in: directory)
}

@MainActor
private func measureEventFamilies(in directory: URL) async throws {
    let events = try ScriptARCFixture(directory: directory)
    try await events.checkMultiwordPublication(report: true)
    try await events.measureMatchedTitleTransactions(in: directory)
    try await events.focusEvents(directory: directory)
    try await events.topologyEvents(in: directory)
    try await events.windowEvents(in: directory)
    for subscribed in [false, true] {
        let location = directory.appendingPathComponent(subscribed ? "observed-windows" : "native-windows")
        let transactions = try ScriptARCFixture(directory: location)
        try await transactions.windowTransactions(in: location, subscribed: subscribed)
    }
    try await events.ownedWindowEvents()
    let timers = try ScriptARCFixture(directory: directory)
    try await timers.timerEvents(in: directory)
    try await measureDisplayMoves(in: directory)
    try await measurePlacement(in: directory)
    try await measureFocusTarget(in: directory)
    try await measureMixedFrames(in: directory)
    try await measureSnapshotRows(
        in: directory.appendingPathComponent("row-limit"), counts: [ConfigScriptSnapshot.rowLimit]
    ) { fixture, count in
        try await fixture.measureDecode(rows: count, of: ["frames"], reads: .windowFrames)
    }
    try await measureColumnReads(in: directory)
    try await measureDwindleReads(in: directory)
    try await measureGather(in: directory)
    try await measureDwindleReplace(in: directory)
    try await measureNamedModes(in: directory)
    try await measureStore(in: directory)
    try await measureWindowMarks(in: directory)
    try await measureWorkspaceActions(in: directory)
    try await measureWorkspaceScrolls(in: directory)
    try await measureRuleApply(in: directory)
    try measureOrdinaryNiriReconcile(in: directory)
}
