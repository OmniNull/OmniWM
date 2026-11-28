// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
import ScriptARCCounters

@MainActor
func measureRuleApply(in directory: URL) async throws {
    for kind in RuleApplyAudit.Kind.allCases {
        let audit = try RuleApplyAudit(in: directory, kind: kind)
        defer {
            audit.fixture.script.stop()
            audit.fixture.controller.layoutRefreshController.resetState()
        }
        if kind == .focused { try await audit.measureScriptControl() }
        try await audit.measureScript()
        await audit.measureNative()
    }
}

@MainActor
private final class RuleApplyAudit {
    enum Kind: String, CaseIterable {
        case focused
        case byID = "by-id"
        case pid
        case refused
    }

    private final class Counts {
        var inventory = 0
        var batches = 0
        var evaluations = 0

        func reset() {
            inventory = 0
            batches = 0
            evaluations = 0
        }
    }

    private static let chord = "Control+Option+R"
    private static let pid = pid_t.max
    private static let missingPID = pid - 1
    private static let bundle = "test.omniwm.rule-apply"
    let fixture: ScriptARCFixture
    private let kind: Kind
    private let windows: [WindowToken]
    private let affected: [WindowToken]
    private let workspace: WorkspaceDescriptor.ID
    private let frame: CGRect
    private let rule: AppRule
    private let counts = Counts()

    private var scriptRoute: String {
        "rule/apply-" + kind.rawValue
    }

    private var nativeRoute: String {
        "native/rule-apply-" + kind.rawValue
    }

    init(in directory: URL, kind: Kind) throws {
        self.kind = kind
        fixture = try ScriptARCFixture(
            directory: directory.appendingPathComponent("rule-apply-" + kind.rawValue),
            snapshotRows: 1
        )
        let manager = fixture.controller.workspaceManager
        guard let workspace = manager.workspace(for: fixture.token),
              let monitor = manager.monitor(for: workspace)
        else { throw ScriptARCError("Missing rule application workspace") }
        self.workspace = workspace
        frame = monitor.visibleFrame.insetBy(dx: monitor.visibleFrame.width / 4, dy: monitor.visibleFrame.height / 4)
        rule = AppRule(bundleId: Self.bundle, layout: .tile, minWidth: Double(frame.width / 2))

        let focused = WindowToken(pid: Self.pid, windowId: Int(Self.pid))
        let sibling = WindowToken(pid: focused.pid, windowId: focused.windowId + 1)
        let tracked = [focused, sibling]
        windows = tracked
        affected = switch kind {
        case .focused: [focused]
        case .byID: [sibling]
        case .pid: tracked
        case .refused: []
        }

        let controller = fixture.controller
        controller.settings.appRules = [rule]
        controller.windowRuleEngine.rebuild(rules: controller.settings.effectiveAppRules)
        controller.layoutRefreshController.layoutState.isRefreshSuspendedForLockScreen = true
        controller.axManager.managedWindowBindingRetryDelayProvider = { _ in nil }
        installProviders()
        reset()
        precondition(manager.confirmManagedFocus(
            focused, in: workspace, onMonitor: monitor.id, activateWorkspaceOnMonitor: false
        ))
    }

    private static func axRef(_ token: WindowToken) -> AXWindowRef {
        AXWindowRef(element: AXUIElementCreateApplication(token.pid), windowId: token.windowId)
    }

    private func installProviders() {
        let controller = fixture.controller
        let counts = self.counts
        let frame = self.frame
        let engine = controller.windowRuleEngine
        let evidence = Dictionary(uniqueKeysWithValues: affected.map { token in
            let id = UInt32(token.windowId)
            return (
                id,
                WindowServerInfo(id: id, pid: token.pid, level: CGWindowLevelForKey(.normalWindow), frame: frame)
            )
        })
        let expectedIDs = Set(evidence.keys)
        let inventory = windows.map(Self.axRef)
        let ax = AXWindowFacts(
            role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String,
            title: "Rule application", hasCloseButton: true, hasFullscreenButton: true,
            fullscreenButtonEnabled: true, hasZoomButton: true, hasMinimizeButton: true,
            appPolicy: .regular, bundleId: Self.bundle, attributeFetchSucceeded: true
        )
        controller.axEventHandler.ruleReevaluation.pidInventoryForTests = { pid in
            precondition(pid == Self.pid)
            counts.inventory += 1
            return inventory
        }
        controller.axEventHandler.ruleReevaluation.axWindowRefProvider = { _ in
            preconditionFailure("Rule application should use the fixture's tracked AX window")
        }
        controller.axEventHandler.windowInfoBatchProvider = { ids in
            precondition(ids == expectedIDs)
            counts.batches += 1
            return evidence
        }
        controller.axEventHandler.windowInfoProvider = { _ in
            preconditionFailure("Rule application should use batched window-server evidence")
        }
        controller.windowDispositionEvaluationForTests = { token in
            let info = evidence[UInt32(token.windowId)]!
            precondition(info.pid == token.pid)
            counts.evaluations += 1
            let facts = WindowRuleFacts(
                appName: "Rule application", ax: ax, sizeConstraints: .unconstrained, windowServer: info
            )
            return WMController.WindowDecisionEvaluation(
                token: token, facts: facts,
                decision: engine.decision(for: facts, token: token, appFullscreen: false),
                appFullscreen: false, manualOverride: nil,
                admissionGeometry: WindowAdmissionGeometryEvidence(isSizeSettable: true, frame: frame)
            )
        }
    }

    private func reset() {
        let controller = fixture.controller
        let manager = controller.workspaceManager
        for token in windows {
            manager.addWindow(
                manager.entry(for: token)?.axRef ?? Self.axRef(token),
                pid: token.pid, windowId: token.windowId, to: workspace,
                managedReplacementMetadata: ManagedReplacementMetadata(
                    bundleId: Self.bundle, workspaceId: workspace, mode: .tiling
                )
            )
            precondition(manager.entry(for: token)?.ruleEffects == ManagedWindowRuleEffects.none)
        }
        controller.layoutRefreshController.layoutState.pendingRefresh = nil
        controller.axManager.managedWindowBindings.clearManagedWindowBindingRetry(for: Self.pid)
        counts.reset()
    }

    private func traceSequence() -> UInt64 {
        let last = fixture.controller.workspaceManager.reconcileTraceDump(limit: 1)
        return UInt64(last.dropFirst().prefix(while: \.isNumber))!
    }

    private func checkWork(from previous: UInt64, route: String, report: Bool) {
        let commits = traceSequence() - previous
        precondition(counts.inventory == (kind == .pid ? 1 : 0))
        precondition(counts.batches == (affected.isEmpty ? 0 : 1))
        precondition(counts.evaluations == affected.count && commits == UInt64(affected.count))

        let controller = fixture.controller
        precondition(controller.settings.appRules == [rule])
        for token in windows {
            let expected = affected.contains(token) ? rule.minWidth : nil
            precondition(controller.workspaceManager.entry(for: token)?.ruleEffects.minWidth == expected)
        }
        if report {
            print(
                "rule-apply-work \(route) inventory=\(counts.inventory) batches=\(counts.batches) "
                    + "evaluations=\(counts.evaluations) commits=\(commits)"
            )
        }
    }

    private func windowIDForApply() -> String {
        ConfigScriptWindowID.string(affected[0], session: fixture.controller.scriptSession.identity)
    }

    func measureScriptControl() async throws {
        let queue = try await fixture.acceptTitleScript("omniwm.keymap.set('\(Self.chord)', function() end)")
        await queue.waitForAuditPark()
        let command = try fixture.binding(Self.chord)
        for report in [false, true] {
            reset()
            let previous = traceSequence()
            try await fixture.function(command, route: "rule/apply-absent", busy: false, report: report)
            precondition(traceSequence() == previous)
            precondition(counts.inventory == 0 && counts.batches == 0 && counts.evaluations == 0)
        }
    }

    func measureScript() async throws {
        let targetArg = switch kind {
        case .focused: ""
        case .byID: ", { windowId = '\(windowIDForApply())' }"
        case .pid: ", { pid = \(Self.pid) }"
        case .refused: ", { pid = \(Self.missingPID) }"
        }
        let queue = try await fixture.acceptTitleScript("""
        omniwm.keymap.set("\(Self.chord)", function()
            omniwm.dispatch("rule", "apply"\(targetArg))
        end)
        """)
        await queue.waitForAuditPark()
        let command = try fixture.binding(Self.chord)
        for report in kind == .refused ? [true] : [false, true] {
            reset()
            let previous = traceSequence()
            precondition(fixture.key(command, measured: true) == .executed)
            try await fixture.measureWorker(seed: false)
            if kind == .refused {
                precondition(fixture.script.diagnostic?
                    .contains("rule apply: the process has no managed windows.") == true)
            } else if let diagnostic = fixture.script.diagnostic {
                throw ScriptARCError(diagnostic)
            }
            if report { script_arc_report(scriptRoute, nativeRoute, 1) }
            checkWork(from: previous, route: scriptRoute, report: report)
        }
    }

    func measureNative() async {
        let target: WindowRuleReevaluationTarget = switch kind {
        case .focused,
             .byID: .window(affected[0])
        case .pid: .pid(Self.pid)
        case .refused: .pid(Self.missingPID)
        }
        let controller = fixture.controller
        for report in [false, true] {
            reset()
            let previous = traceSequence()
            script_arc_begin()
            let outcome: WindowRuleReevaluationOutcome = if case let .pid(pid) = target,
                                                            !controller.workspaceManager.hasEntries(forPid: pid)
            {
                .none
            } else {
                await controller.reevaluateWindowRules(for: [target], context: .explicitRuleApply)
            }
            script_arc_end()
            precondition(outcome.evaluatedAnyWindow == !affected.isEmpty && !outcome.stale)
            if report { script_arc_report(nativeRoute, "native", 0) }
            checkWork(from: previous, route: nativeRoute, report: report)
        }
    }
}
