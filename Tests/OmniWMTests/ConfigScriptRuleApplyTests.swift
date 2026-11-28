// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptRuleApplyTests: XCTestCase {
    private let display = NiriGatherFixture.monitor(displayId: UInt32(getpid()))
    private let callbackName = "Apply rules"
    private let originName = "1"
    private let destinationName = "2"
    private let laterWorkspace = "3"
    private let focusedWindow = Int(pid_t.max) / 2
    private var otherWindow: Int {
        focusedWindow + 1
    }

    func testFocusedDefaultAndWindowIDApplyOnlyToTheChosenWindow() async throws {
        for defaultArgument in [nil, "nil"] as [String?] {
            let scene = try makeScene()
            let base = scene.fixture.base
            base.add([focusedWindow, otherWindow], to: scene.origin)
            let focused = base.token(focusedWindow)
            let other = base.token(otherWindow)
            scene.evidence.windows = [focused, other]
            try await scene.fixture.focus(focusedWindow, on: originName)
            scene.install([scene.rule(layout: .tile, workspace: destinationName)])
            let saved = scene.savedRules

            let later = "omniwm.dispatch(omniwm.cmd.switchWorkspace('\(laterWorkspace)'))"
            try await invoke([apply(defaultArgument), later], in: scene)
            XCTAssertNil(scene.fixture.script.diagnostic)
            XCTAssertEqual(scene.evidence.evaluated, [focused])
            XCTAssertEqual(base.manager.workspace(for: focused), scene.destination)
            XCTAssertEqual(base.manager.workspace(for: other), scene.origin)
            XCTAssertEqual(base.controller.activeWorkspace()?.id, base.workspace(laterWorkspace))

            try await invoke([apply(windowArgument(other, in: scene))], in: scene)
            XCTAssertNil(scene.fixture.script.diagnostic)
            XCTAssertEqual(scene.evidence.evaluated, [focused, other])
            XCTAssertEqual(base.manager.workspace(for: other), scene.destination)
            XCTAssertEqual(scene.savedRules, saved)
        }
    }

    func testPIDUsesTheSameManagedSetAndRulesAsCLIApply() async throws {
        let scene = try makeScene()
        scene.controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen = true
        let token = WindowToken(pid: pid_t.max, windowId: scene.fixture.base.token(focusedWindow).windowId)
        let peer = WindowToken(pid: token.pid, windowId: scene.fixture.base.token(otherWindow).windowId)
        let inventoried = WindowToken(pid: token.pid, windowId: peer.windowId + 1)
        let unrelated = WindowToken(pid: token.pid - 1, windowId: inventoried.windowId + 1)
        let members = [token, peer, inventoried]
        for window in [token, peer, unrelated] { scene.track(window, mode: .floating) }
        scene.evidence.windows.insert(inventoried)
        XCTAssertNil(scene.controller.workspaceManager.entry(for: inventoried))
        var inventoryRequests: [pid_t] = []
        scene.controller.axEventHandler.ruleReevaluation.pidInventoryForTests = { pid in
            inventoryRequests.append(pid)
            return [WindowAdmissionTestSupport.axRef(for: inventoried)]
        }
        scene.install([scene.rule(layout: .float, workspace: destinationName)])
        let savedRules = scene.savedRules
        let manager = scene.controller.workspaceManager
        let ledger = scene.controller.intentLedger
        let pending = ledger.beginManagedRequest(token: token, workspaceId: scene.origin).requestId
        XCTAssertTrue(manager.beginManagedFocusRequest(token, in: scene.origin, requestId: pending))

        try await invoke([apply("{ pid = \(token.pid) }")], in: scene)
        XCTAssertNotEqual(manager.focusSessionSnapshot.pendingManagedFocus.requestId, pending)
        XCTAssertNil(ledger.activeManagedRequest(requestId: pending))
        XCTAssertNil(scene.fixture.script.diagnostic)
        XCTAssertEqual(scene.evidence.evaluated, members)
        XCTAssertEqual(scene.evidence.batches, [Set(members.map { UInt32($0.windowId) })])
        let flex = members.map { scene.controller.workspaceManager.workspace(for: $0) }
        XCTAssertEqual(flex, members.map { _ in scene.destination })
        XCTAssertEqual(inventoryRequests, [token.pid])

        for member in members { manager.setWorkspace(for: member, to: scene.origin) }
        let nativePending = ledger.beginManagedRequest(token: token, workspaceId: scene.origin).requestId
        XCTAssertTrue(manager.beginManagedFocusRequest(token, in: scene.origin, requestId: nativePending))
        let router = IPCRuleRouter(controller: scene.controller, sessionToken: "rule-apply")
        let reply = await router.handle(.apply(target: .pid(token.pid)))
        XCTAssertEqual(try reply.get(), savedRules)
        XCTAssertNotEqual(manager.focusSessionSnapshot.pendingManagedFocus.requestId, nativePending)
        XCTAssertNil(ledger.activeManagedRequest(requestId: nativePending))
        XCTAssertEqual(members.map { manager.workspace(for: $0) }, flex)
        XCTAssertEqual(scene.evidence.evaluated, members + members)
        let batch = Set(members.map { UInt32($0.windowId) })
        XCTAssertEqual(scene.evidence.batches, [batch, batch])
        XCTAssertEqual(inventoryRequests, [token.pid, token.pid])
        XCTAssertEqual(manager.workspace(for: unrelated), scene.origin)
        XCTAssertEqual(scene.savedRules, savedRules)
    }

    func testExplicitApplyKeepsAnExistingSpanAndCanAssignToScratchpad() async throws {
        let scene = try makeScene()
        let base = scene.fixture.base
        base.add([focusedWindow], to: scene.origin)
        let token = base.token(focusedWindow)
        scene.evidence.windows.insert(token)
        let node = try XCTUnwrap(base.node(focusedWindow, in: scene.origin))
        let column = try XCTUnwrap(base.engine.findColumn(containing: node, in: scene.origin))
        let existingSpan: CGFloat = 0.4
        let requestedSpan = 0.75
        base.manager.withEngineMutationScope(in: scene.origin) {
            column.width = .proportion(existingSpan)
        }
        scene.install([scene.rule(layout: .tile, initialSpan: requestedSpan)])

        let call = apply(windowArgument(token, in: scene))
        try await invoke([call], in: scene)
        XCTAssertNil(scene.fixture.script.diagnostic)
        XCTAssertEqual(column.width, .proportion(existingSpan))
        XCTAssertIdentical(base.node(focusedWindow, in: scene.origin), node)

        let slot = try XCTUnwrap(ScratchpadIndex(ScratchpadIndex.range.lowerBound))
        let saved = scene.savedRules
        try await scene.fixture.load("""
        omniwm.rule { bundleId = '\(scene.evidence.bundle)', scratchpad = \(slot.rawValue) }
        omniwm.command('\(callbackName)', function() \(call) end)
        """)
        scene.controller.windowRuleEngine.rebuild(rules: scene.controller.settings.effectiveAppRules)
        let queue = try enqueue(in: scene)
        await queue.waitUntilParked()
        XCTAssertNil(scene.fixture.script.diagnostic)
        XCTAssertEqual(base.manager.scratchpadIndex(for: token), slot)
        XCTAssertEqual(scene.savedRules, saved)
    }

    func testMalformedCallsAndPreApplyRefusalsStopLaterEffects() async throws {
        let scene = try makeScene()
        let base = scene.fixture.base
        base.add([focusedWindow, otherWindow], to: scene.origin)
        let focused = base.token(focusedWindow)
        let other = base.token(otherWindow)
        scene.evidence.windows = [focused, other]
        scene.install([scene.rule(layout: .tile, workspace: destinationName)])
        try await scene.fixture.focus(focusedWindow, on: originName)
        let later = "omniwm.dispatch(omniwm.cmd.switchWorkspace('\(laterWorkspace)'))"
        let missing = WindowToken(pid: .max, windowId: other.windowId + 1)
        func refused(
            _ call: String,
            _ reason: String,
            _ invalidate: @escaping @MainActor () -> Void = {}
        ) -> PreApplyRefusal {
            PreApplyRefusal(call: call, reason: "rule apply: \(reason).", invalidate: invalidate)
        }
        let requests = malformedCalls(for: focused, in: scene) + [
            refused(apply(windowArgument(missing, in: scene)), "no managed window was evaluated"),
            refused(apply("{ pid = \(missing.pid) }"), "the process has no managed windows"),
            refused(apply(), "the captured managed focus changed") {
                _ = base.manager.confirmManagedFocus(
                    other, in: scene.origin, onMonitor: self.display.id, activateWorkspaceOnMonitor: false
                )
            },
            refused(apply(windowArgument(focused, in: scene)), "OmniWM is disabled") {
                scene.controller.isEnabled = false
            },
            refused(apply(windowArgument(focused, in: scene)), "the callback belongs to an earlier session") {
                scene.controller.scriptSession = ConfigScriptSessionToken()
            }
        ]
        for request in requests {
            defer { scene.controller.isEnabled = true }
            let lines = try await load([request.call, later], in: scene)
            let queue = try enqueue(in: scene)
            request.invalidate()
            await queue.waitUntilParked()
            let diagnostic = try XCTUnwrap(scene.fixture.script.diagnostic)
            let sourceLine = try XCTUnwrap(lines.firstIndex { $0.contains(request.call) }) + 1
            XCTAssertTrue(diagnostic.contains("init.luau:\(sourceLine):"), diagnostic)
            XCTAssertTrue(diagnostic.contains(request.reason), diagnostic)
            XCTAssertTrue(scene.evidence.evaluated.isEmpty)
            XCTAssertTrue(scene.evidence.batches.isEmpty)
            XCTAssertEqual(base.manager.workspace(for: focused), scene.origin)
            XCTAssertEqual(scene.controller.activeWorkspace()?.id, scene.origin)
        }
    }

    func testRetirementOrDisableDuringFactsWaitSkipsTheExplicitApply() async throws {
        for retire in [true, false] {
            try await assertInvalidatedApply(retire: retire)
        }
    }

    private func assertInvalidatedApply(retire: Bool) async throws {
        let scene = try makeScene()
        let token = scene.fixture.base.token(focusedWindow)
        scene.track(token, mode: .floating)
        scene.install([scene.rule(layout: .tile, workspace: destinationName)])
        let started = expectation(description: "Rule application is waiting for its WindowServer facts")
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        scene.controller.axEventHandler.windowInfoBatchProvider = { ids in
            XCTAssertEqual(ids, [UInt32(token.windowId)])
            started.fulfill()
            _ = await gate.wait()
            return [:]
        }
        let later = "omniwm.dispatch(omniwm.cmd.switchWorkspace('\(laterWorkspace)'))"
        _ = try await load([apply(windowArgument(token, in: scene)), later], in: scene)
        let queue = try enqueue(in: scene)
        let worker = try XCTUnwrap(queue.worker)
        await fulfillment(of: [started], timeout: failureBound)

        if retire {
            try await scene.fixture.load("omniwm.command('After reload', function() end)")
            gate.resume()
            await worker.value
            XCTAssertNil(scene.fixture.script.diagnostic)
        } else {
            scene.controller.isEnabled = false
            gate.resume()
            await queue.waitUntilParked()
            let diagnostic = try XCTUnwrap(scene.fixture.script.diagnostic)
            XCTAssertTrue(diagnostic.contains("rule apply: OmniWM is disabled."), diagnostic)
        }
        XCTAssertTrue(scene.evidence.evaluated.isEmpty)
        XCTAssertNil(scene.controller.axEventHandler.admissionRetryStateByWindowId[UInt32(token.windowId)])
        XCTAssertEqual(scene.controller.workspaceManager.workspace(for: token), scene.origin)
        XCTAssertEqual(scene.controller.activeWorkspace()?.id, scene.origin)
    }

    func testReloadStopAndFocusChangeDemoteAnInFlightGeometryRetry() async throws {
        for invalidation in RetryInvalidation.allCases {
            try await assertInFlightGeometryRetry(invalidation)
        }
    }
}

extension ConfigScriptRuleApplyTests {
    private struct PreApplyRefusal {
        let call: String
        let reason: String
        var invalidate: @MainActor () -> Void = {}
    }

    private func malformedCalls(for window: WindowToken, in scene: Scene) -> [PreApplyRefusal] {
        let oversized = WindowToken(pid: window.pid, windowId: Int(UInt32.max) + 1)
        let id = scene.fixture.id(focusedWindow)
        let malformed: [(String, String)] = [
            ("omniwm.dispatch('rule', 'remove')", "the only rule action is 'apply'"),
            (apply("{ pid = \(window.pid), windowId = '\(id)' }"), "exactly one field"),
            (apply("{ pid = \(window.pid).5 }"), "Expected a positive integer PID."),
            (apply("{ pid = \(Int(pid_t.max) + 1) }"), "Expected a positive integer PID."),
            (apply(windowArgument(oversized, in: scene)), "Expected a Flex window ID.")
        ]
        return malformed.map { PreApplyRefusal(call: $0.0, reason: $0.1) }
    }

    private enum RetryInvalidation: CaseIterable {
        case none, reload, stop, focus
    }

    @MainActor
    private struct RetryFacts {
        let started = XCTestExpectation(description: "Rule retries are waiting for WindowServer facts")
        let gate = LifecycleQueryGate()

        func hold() async {
            started.fulfill()
            _ = await gate.wait()
        }
    }

    private func assertInFlightGeometryRetry(_ invalidation: RetryInvalidation) async throws {
        let scene = try makeScene()
        let token = scene.fixture.base.token(focusedWindow)
        let nextFocus = scene.fixture.base.token(otherWindow)
        let id = UInt32(token.windowId)
        let handler = scene.controller.axEventHandler
        scene.track(token, mode: .floating)
        scene.track(nextFocus, mode: .floating)
        let manager = scene.controller.workspaceManager
        _ = manager.confirmManagedFocus(
            token,
            in: scene.origin,
            onMonitor: display.id,
            activateWorkspaceOnMonitor: false
        )
        XCTAssertEqual(manager.nativeManagedFocusToken, token)
        scene.evidence.missingGeometry.insert(token)
        scene.install([scene.rule(layout: .tile, workspace: destinationName)])
        let (explicit, fallback) = holdRetryFacts(for: id, in: handler, expectsFallback: invalidation == .focus)
        defer {
            explicit.gate.resume()
            fallback.gate.resume()
        }
        let target = invalidation == .focus ? nil : windowArgument(token, in: scene)
        try await invoke([apply(target)], in: scene)
        XCTAssertNil(scene.fixture.script.diagnostic)
        guard case let .ruleReevaluation(_, _, .script(owner))? = handler.admissionRetryStateByWindowId[id]?.trigger
        else {
            return XCTFail("The deferred retry did not carry explicit placement authority")
        }
        XCTAssertIdentical(owner.currentQueue(in: scene.controller), scene.fixture.script.callbackQueue)
        XCTAssertEqual(manager.workspace(for: token), scene.origin)
        let retry = try await startRetry(for: id, in: handler, waitingFor: explicit)
        try await invalidate(invalidation, in: scene, nextFocus: nextFocus)
        scene.evidence.missingGeometry.remove(token)
        explicit.gate.resume()
        await retry.value
        if invalidation == .focus {
            try await finishAutomaticRetry(for: id, in: handler, waitingFor: fallback)
        }
        XCTAssertEqual(manager.entry(for: token)?.mode, .tiling)
        XCTAssertEqual(manager.workspace(for: token), invalidation == .none ? scene.destination : scene.origin)
        XCTAssertNil(handler.admissionRetryStateByWindowId[id])
    }

    private func invalidate(_ invalidation: RetryInvalidation, in scene: Scene, nextFocus: WindowToken) async throws {
        switch invalidation {
        case .none: break
        case .reload: try await scene.fixture.load("omniwm.command('After reload', function() end)")
        case .stop: scene.controller.stopConfigScript()
        case .focus:
            let manager = scene.controller.workspaceManager
            _ = manager.confirmManagedFocus(
                nextFocus, in: scene.origin, onMonitor: display.id, activateWorkspaceOnMonitor: false
            )
            XCTAssertEqual(manager.nativeManagedFocusToken, nextFocus)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(scene.controller)
        }
    }

    private func startRetry(for id: UInt32, in handler: AXEventHandler, waitingFor facts: RetryFacts) async throws
        -> Task<Void, Never>
    {
        let pending = try XCTUnwrap(handler.admissionRetryStateByWindowId[id])
        if case .waiting = pending.executionPhase {
            XCTAssertTrue(handler.dispatchAdmissionRetry(windowId: id))
        }
        await fulfillment(of: [facts.started], timeout: failureBound)
        return try XCTUnwrap(handler.admissionRetryStateByWindowId[id]?.task)
    }

    private func finishAutomaticRetry(
        for id: UInt32,
        in handler: AXEventHandler,
        waitingFor facts: RetryFacts
    ) async throws {
        guard case .ruleReevaluation(_, _, .automatic)? = handler.admissionRetryStateByWindowId[id]?.trigger else {
            return XCTFail("The stale focus retry kept explicit placement authority")
        }
        let retry = try await startRetry(for: id, in: handler, waitingFor: facts)
        facts.gate.resume()
        await retry.value
    }

    private func holdRetryFacts(
        for id: UInt32, in handler: AXEventHandler, expectsFallback: Bool
    ) -> (explicit: RetryFacts, fallback: RetryFacts) {
        let explicit = RetryFacts()
        let fallback = RetryFacts()
        var fetchedInitialFacts = false
        var heldRetry = false
        handler.windowInfoBatchProvider = { ids in
            XCTAssertEqual(ids, [id])
            if !fetchedInitialFacts {
                fetchedInitialFacts = true
            } else if !heldRetry {
                heldRetry = true
                await explicit.hold()
            } else if expectsFallback {
                await fallback.hold()
            } else {
                XCTFail("Unexpected retry after applying recovered geometry")
            }
            return [:]
        }
        return (explicit, fallback)
    }

    private func apply(_ target: String? = nil) -> String {
        let argument = target.map { ", \($0)" } ?? ""
        return "omniwm.dispatch('rule', 'apply'\(argument))"
    }

    private func windowArgument(_ token: WindowToken, in scene: Scene) -> String {
        let id = ConfigScriptWindowID.string(token, session: scene.controller.scriptSession.identity)
        return "{ windowId = '\(id)' }"
    }

    private func load(_ statements: [String], in scene: Scene) async throws -> [String] {
        let lines = ["omniwm.command('\(callbackName)', function()"] + statements.map { "    \($0)" } + ["end)"]
        try await scene.fixture.load(lines.joined(separator: "\n"))
        return lines
    }

    private func enqueue(in scene: Scene) throws -> ConfigScriptCallbackQueue {
        let script = scene.fixture.script
        let function = try XCTUnwrap(script.acceptedCommands.first { $0.name == callbackName }?.function)
        let queue = try XCTUnwrap(script.callbackQueue)
        XCTAssertEqual(
            scene.controller.commandHandler.handleHotkeyInvocation(.init(command: .configFunction(function))),
            .executed
        )
        return queue
    }

    private func invoke(_ statements: [String], in scene: Scene) async throws {
        _ = try await load(statements, in: scene)
        try await enqueue(in: scene).waitUntilParked()
    }

    private func makeScene() throws -> Scene {
        let base = try NiriGatherFixture(
            prefix: "config-rule-apply", monitors: [display],
            workspaces: [originName, destinationName, laterWorkspace].map { .init(name: $0, monitor: display) }
        )
        let controller = base.controller
        controller.settings.animationsEnabled = false
        let origin = base.workspace(originName)
        _ = base.manager.setActiveWorkspace(origin, on: display.id)
        let evidence = RuleEvidence(frame: display.frame.insetBy(
            dx: display.frame.width / 4,
            dy: display.frame.height / 4
        ))
        controller.layoutRefreshController.fastFrameProvider = { _, _ in evidence.frame }
        controller.axEventHandler.windowInfoProvider = { _ in nil }
        controller.axEventHandler.ruleReevaluation.axWindowRefProvider = { _ in nil }
        controller.axEventHandler.windowInfoBatchProvider = { ids in
            evidence.batches.append(ids)
            return [:]
        }
        controller.windowDispositionEvaluationForTests = { [weak controller] token in
            guard let controller, evidence.windows.contains(token) else { return nil }
            return evidence.evaluation(for: token, controller: controller)
        }
        addTeardownBlock { @MainActor in
            controller.stopConfigScript()
            controller.axEventHandler.cleanup()
            controller.layoutRefreshController.resetState()
            controller.axManager.cleanup()
        }
        return Scene(
            fixture: ConfigScriptWindowFixture(base: base),
            evidence: evidence, origin: origin, destination: base.workspace(destinationName)
        )
    }

    @MainActor
    private struct Scene {
        let fixture: ConfigScriptWindowFixture
        let evidence: RuleEvidence
        let origin: WorkspaceDescriptor.ID
        let destination: WorkspaceDescriptor.ID

        var controller: WMController {
            fixture.base.controller
        }

        var savedRules: IPCRulesQueryResult {
            IPCRuleProjection.result(settings: controller.settings, windowRuleEngine: controller.windowRuleEngine)
        }

        func rule(layout: WindowRuleLayoutAction, workspace: String? = nil, initialSpan: Double? = nil) -> AppRule {
            AppRule(
                bundleId: evidence.bundle,
                layout: layout,
                assignToWorkspace: workspace,
                initialContainerPrimarySpan: initialSpan
            )
        }

        func install(_ rules: [AppRule]) {
            controller.settings.appRules = rules
            controller.windowRuleEngine.rebuild(rules: controller.settings.effectiveAppRules)
        }

        func track(_ token: WindowToken, mode: TrackedWindowMode) {
            evidence.windows.insert(token)
            _ = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token), pid: token.pid, windowId: token.windowId,
                to: origin, mode: mode
            )
        }
    }

    @MainActor
    private final class RuleEvidence {
        let frame: CGRect
        let bundle = "org.example.rule-apply"
        var windows: Set<WindowToken> = []
        var missingGeometry: Set<WindowToken> = []
        var evaluated: [WindowToken] = []
        var batches: [Set<UInt32>] = []

        init(frame: CGRect) {
            self.frame = frame
        }

        func evaluation(for token: WindowToken, controller: WMController) -> WMController.WindowDecisionEvaluation {
            evaluated.append(token)
            let facts = WindowRuleFacts(
                appName: "Rule apply tests",
                ax: AXWindowFacts(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "Document",
                    hasCloseButton: true,
                    hasFullscreenButton: true,
                    fullscreenButtonEnabled: true,
                    hasZoomButton: true,
                    hasMinimizeButton: true,
                    appPolicy: .regular,
                    bundleId: bundle,
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: .unconstrained,
                windowServer: WindowServerInfo(
                    id: UInt32(token.windowId), pid: token.pid, level: CGWindowLevelForKey(.normalWindow), frame: frame
                )
            )
            let manual = controller.workspaceManager.manualLayoutOverride(for: token)
            let decision = controller.windowRuleEngine.decision(for: facts, token: token, appFullscreen: false)
            return WMController.WindowDecisionEvaluation(
                token: token, facts: facts,
                decision: WindowRuleEngine.applyingManualOverride(decision, manualOverride: manual),
                appFullscreen: false, manualOverride: manual,
                admissionGeometry: .init(isSizeSettable: missingGeometry.contains(token) ? nil : true, frame: frame)
            )
        }
    }
}
