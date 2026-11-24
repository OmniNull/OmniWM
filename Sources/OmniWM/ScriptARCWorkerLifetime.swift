// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMIPC
import OmniWMScriptHost
import ScriptARCCounters

extension ConfigScriptGeneration {
    fileprivate func afterWorkerRelease() {
        precondition(!Thread.isMainThread)
    }
}

@MainActor
extension ScriptARCFixture {
    fileprivate func workerLoad() async throws -> ConfigScriptLoad {
        let source = """
        local wm = omniwm
        local started = false
        local pairs = 0
        wm.command("Begin", function() assert(not started); started = true end)
        wm.command("End", function() assert(started); started = false; pairs += 1 end)
        wm.command("Report", function() error("Completed pairs " .. pairs) end)
        wm.command("Move", function() wm.dispatch(wm.cmd("switch-workspace", "2")) end)
        """
        let mask = controller.settings.hyperKeyModifiers.carbonMask
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        return ConfigScriptLoad(versions: [:], result: .success(evaluation))
    }

    fileprivate func accept(_ load: ConfigScriptLoad) -> ConfigScriptCallbackQueue {
        controller.configScript = script
        precondition(script.apply(load, hyperMask: controller.settings.hyperKeyModifiers.carbonMask))
        return script.callbackQueue!
    }

    func enqueue(_ name: String) {
        let function = script.acceptedCommands.first { $0.name == name }!.function
        precondition(controller.enqueueConfigFunction(function) == .executed)
    }

    func holdInFlight(_ command: String) async {
        await withUnsafeContinuation { (observer: UnsafeContinuation<Void, Never>) in
            script_arc_hold_next_entry(unsafeBitCast(observer, to: UnsafeMutableRawPointer.self))
            enqueue(command)
        }
    }

    fileprivate func checkFailedReloadAndFIFO(_ queue: ConfigScriptCallbackQueue, initialPairs: Int) async {
        var expectedPairs = initialPairs
        let worker = queue.worker!
        let error = ConfigScriptError(line: 1, message: "intentional failed reload")
        let failed = accept(ConfigScriptLoad(versions: [:], result: .failure(error)))
        precondition(failed === queue && failed.worker == worker && failed.isParked)
        let failure = script.diagnostic
        precondition(failure?.contains(error.message) == true)
        for _ in 0 ..< ConfigScriptCallbackQueue.capacity {
            enqueue("Begin")
            enqueue("End")
            await queue.waitForAuditPark()
            expectedPairs += 1
        }
        await holdInFlight("Begin")
        precondition(!queue.hasPendingWork && !queue.isParked)
        enqueue("End")
        script_arc_release_entry()
        await queue.waitForAuditPark()
        script_arc_finish_entry()
        expectedPairs += 1
        precondition(script.diagnostic == failure)
        enqueue("Report")
        await queue.waitForAuditPark()
        precondition(script.diagnostic?.contains("Completed pairs \(expectedPairs)") == true)
    }

    fileprivate func checkCapturedIdentity() async throws {
        let source = """
        local wm = omniwm
        wm.command("Hold", function() end)
        wm.keymap.set("Control+Option+F", function(c)
            error(c.windowId .. "|" .. c.bundleId .. "|" .. c.workspace)
        end)
        """
        let mask = controller.settings.hyperKeyModifiers.carbonMask
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        let queue = accept(ConfigScriptLoad(versions: [:], result: .success(evaluation)))
        let command = try binding("Control+Option+F")
        await queue.waitForAuditPark()
        for makeSession: () -> String in [
            { UUID().uuidString }, { UUID().uuidString.lowercased() }, { "e\u{301}/会:" + UUID().uuidString }
        ] {
            await holdInFlight("Hold")
            let expected = captureIdentity(command, session: makeSession())
            script_arc_release_entry()
            await queue.waitForAuditPark()
            script_arc_finish_entry()
            precondition(script.diagnostic?.contains(expected) == true)
        }
    }

    func acceptTitleScript(_ source: String) async throws -> ConfigScriptCallbackQueue {
        let mask = controller.settings.hyperKeyModifiers.carbonMask
        let evaluation = try await loader.evaluate(Data(source.utf8), hyperMask: mask)
        return accept(ConfigScriptLoad(versions: [:], result: .success(evaluation)))
    }

    fileprivate func reportTitleHistoryStorage() {
        let handle = controller.workspaceManager.handle(for: otherWindow)!
        let current = malloc_size(Unmanaged.passUnretained(handle).toOpaque())
        let titleEnd = class_getInstanceSize(WindowHandle.self) + MemoryLayout<String?>.stride
        print("title/history handle=\(current) with-stored-title=\(malloc_good_size(titleEnd))")
    }

    func setTitleBundle(_ bundle: String) {
        let manager = controller.workspaceManager
        let workspace = manager.workspace(for: otherWindow)!
        precondition(manager.setManagedReplacementMetadata(
            .init(bundleId: bundle, workspaceId: workspace, mode: .tiling), for: otherWindow
        ))
    }

    fileprivate func checkTitleEpochs() async throws {
        let queue = try await acceptTitleScript("""
        local rows = {}
        omniwm.on("window.title", function(e)
            assert(e.missed == 0)
            table.insert(rows, e.id .. "|" .. e.title .. "|" .. e.bundleId)
        end)
        omniwm.command("Report", function() error(table.concat(rows, ";")) end)
        """)
        await queue.waitForAuditPark()
        let initial = UUID().uuidString
        let decomposed = "e\u{301}/" + initial
        let epochs = [initial, decomposed, decomposed.precomposedStringWithCanonicalMapping, initial, initial]
        let expected = epochs.enumerated().map { index, text in
            controller.automationSessionToken = text
            title("superseded", native: false, measured: false)
            let bundle = "app." + UUID().uuidString
            setTitleBundle(bundle)
            let latest = index == epochs.startIndex ? "static title" : "renamed " + UUID().uuidString
            title(latest, native: false, measured: false)
            let window = IPCWindowOpaqueID.encode(token: otherWindow, sessionToken: text)
            return window + "|" + latest + "|" + bundle
        }
        enqueue("Report")
        await queue.waitForAuditPark()
        precondition(script.diagnostic?.contains(expected.joined(separator: ";")) == true)
    }

    fileprivate func checkTitleRetirement() async throws {
        let replaced = try await workerLoad()
        let old = try await acceptTitleScript("""
        omniwm.on("window.title", function() error("replace this generation") end)
        omniwm.on("window.title", function() omniwm.dispatch(omniwm.cmd("switch-workspace", "1")) end)
        """)
        await old.waitForAuditPark()
        let worker = old.worker!
        let workspace = controller.activeWorkspace()!.id
        let observer = script.eventObservers!
        var installed = false
        script.onDiagnosticChanged = { diagnostic in
            guard !installed, diagnostic?.contains("replace this generation") == true else { return }
            installed = true
            _ = self.accept(replaced)
        }
        await withUnsafeContinuation { (entered: UnsafeContinuation<Void, Never>) in
            script_arc_hold_next_entry(unsafeBitCast(entered, to: UnsafeMutableRawPointer.self))
            title("in flight", native: false, measured: false)
        }
        title("queued before replacement", native: false, measured: false)
        script_arc_release_entry()
        await worker.value
        script_arc_finish_entry()
        script.onDiagnosticChanged = nil
        observer.titleChanged("retired", for: otherWindow, metadataChanged: true, controller: controller)
        precondition(installed && !old.hasPendingWork && old.worker == nil)
        precondition(controller.activeWorkspace()!.id == workspace && script.diagnostic == nil)
        precondition(script.callbackQueue?.hasPendingWork == false)
    }

    private func captureIdentity(_ command: HotkeyCommand, session: String) -> String {
        let previous = controller.activeWorkspace()!.id
        let expected = installCapturedIdentity(session: session, from: previous)
        precondition(key(command, measured: false) == .executed)
        controller.automationSessionToken = UUID().uuidString
        let manager = controller.workspaceManager
        precondition(manager.setManagedReplacementMetadata(nil, for: token))
        precondition(manager.setActiveWorkspace(previous, on: manager.interactionMonitorId!))
        return expected
    }

    func installCapturedIdentity(session: String, from previous: WorkspaceDescriptor.ID) -> String {
        let manager = controller.workspaceManager
        let monitor = manager.interactionMonitorId!
        let workspace = manager.createDynamicWorkspace(named: String(Int.max), on: monitor)!
        precondition(manager.setActiveWorkspace(workspace.id, on: monitor))
        let bundle = "fixture." + UUID().uuidString
        precondition(manager.setManagedReplacementMetadata(
            .init(bundleId: bundle, workspaceId: previous, mode: .tiling), for: token
        ))
        controller.automationSessionToken = session
        let id = IPCWindowOpaqueID.encode(token: token, sessionToken: session)
        return id + "|" + bundle + "|" + workspace.name
    }

    fileprivate func assertRetirementDuringInvocation(_ replacement: ConfigScriptLoad) async {
        let queue = script.callbackQueue!
        let running = queue.worker!
        let workspace = controller.activeWorkspace()?.name
        precondition(workspace == "1" && queue.isParked)
        await holdInFlight("Move")
        enqueue("Move")
        let current = accept(replacement)
        queue.retire()
        script_arc_release_entry()
        await running.value
        script_arc_finish_entry()
        await current.waitForAuditPark()
        precondition(queue.worker == nil && !queue.hasPendingWork)
        precondition(controller.activeWorkspace()?.name == workspace && script.diagnostic == nil)
    }
}

@MainActor
private func checkTitleOwnerRelease(directory: URL) async throws {
    var fixture: ScriptARCFixture? = try ScriptARCFixture(directory: directory)
    let controller = fixture!.controller
    weak let owner = fixture?.script
    weak let queue = try await fixture!.acceptTitleScript("omniwm.on('window.title', function() end)")
    let worker = queue!.worker!
    await queue!.waitForAuditPark()
    controller.configScript = nil
    fixture = nil
    await worker.value
    precondition(owner == nil && queue == nil && controller.axEventHandler.scriptWindowTitleObserver == nil)
}

@MainActor
private func checkOrphanedEventDelivery(directory: URL) async throws {
    var fixture: ScriptARCFixture? = try ScriptARCFixture(directory: directory)
    let manager = fixture!.controller.workspaceManager
    weak let controller = fixture?.controller
    let owner = fixture!.script
    let token = fixture!.otherWindow
    let queue = try await fixture!.acceptTitleScript("omniwm.on('window.minimize', function() error('orphan') end)")
    let worker = queue.worker!
    await queue.waitForAuditPark()
    fixture = nil
    precondition(controller == nil)
    manager.scriptWindowMinimizeObserver?.windowStateChanged(
        .windowMinimize,
        token: token,
        value: .minimized(true),
        in: manager
    )
    precondition(queue.hasPendingWork || worker.isCancelled)
    await worker.value
    precondition(queue.worker == nil && !queue.hasPendingWork && owner.diagnostic == nil)
    owner.stop()
}

@MainActor
private func checkOwnerRelease(directory: URL) async throws {
    var fixture: ScriptARCFixture? = try ScriptARCFixture(directory: directory)
    let executorFence = fixture!.loader.makeGeneration()
    weak let owner = fixture?.script
    weak let controller = fixture?.controller
    weak let queue = fixture!.accept(try await fixture!.workerLoad())
    weak let generation = queue?.generation
    let worker = queue!.worker!
    await queue!.waitForAuditPark()
    fixture!.enqueue("Begin")
    fixture!.enqueue("End")
    await queue!.waitForAuditPark()
    fixture = nil
    await worker.value
    await executorFence.afterWorkerRelease()
    precondition(owner == nil && controller == nil && queue == nil && generation == nil)
}

@MainActor
package func runScriptARCWorkerLifetime(directory: URL) async throws {
    _ = NSApplication.shared
    let fixture = try ScriptARCFixture(directory: directory)
    let load = try await fixture.workerLoad()
    let next = try await fixture.workerLoad()
    let replacement = try await fixture.workerLoad()
    let abandoned = fixture.accept(try await fixture.workerLoad())
    let neverStarted = abandoned.worker!
    fixture.enqueue("Move")
    let queue = fixture.accept(load)
    let worker = queue.worker!
    precondition(!queue.isParked)
    fixture.enqueue("Begin")
    fixture.enqueue("End")
    await queue.waitForAuditPark()
    await neverStarted.value
    precondition(abandoned.worker == nil && fixture.controller.activeWorkspace()?.name == "1")
    precondition(queue.worker == worker && fixture.script.diagnostic == nil)

    await fixture.checkFailedReloadAndFIFO(queue, initialPairs: 1)
    let parked = fixture.accept(next)
    await worker.value
    await parked.waitForAuditPark()
    precondition(queue.worker == nil && parked.isParked)
    await fixture.assertRetirementDuringInvocation(replacement)
    let final = fixture.script.callbackQueue!
    let stopped = final.worker!
    fixture.enqueue("Move")
    await final.waitForAuditPark()
    precondition(fixture.controller.activeWorkspace()?.name == "2" && fixture.script.diagnostic == nil)
    fixture.script.stop()
    final.retire()
    fixture.script.stop()
    await stopped.value
    precondition(final.worker == nil && !final.hasPendingWork && fixture.script.callbackQueue == nil)
    try await fixture.checkCapturedIdentity()
    fixture.reportTitleHistoryStorage()
    try await fixture.checkTitleEpochs()
    try await fixture.checkTitleRetirement()
    try await fixture.checkMultiwordPublication(report: false)
    try await fixture.checkQueuedEdgeEpoch()
    try await fixture.checkFocusEpochAndRetirement()
    try await fixture.checkNestedQueueReplacement()
    try await fixture.checkCatalogRemovalLifetime()
    try await fixture.checkWindowDeliveryLifetime()
    fixture.script.stop()
    try await checkOwnerRelease(directory: directory)
    try await checkTitleOwnerRelease(directory: directory)
    try await checkOrphanedEventDelivery(directory: directory)
    print(
        "lifetime passed: pre-arm, queued, FIFO and ring reuse, captured session and names after replacement, title replacement across epochs and reentrant retirement, parked, in-flight replacement, failed reload, successful reload, repeated stop and cancellation, weak owner/controller/queue release"
    )
}
