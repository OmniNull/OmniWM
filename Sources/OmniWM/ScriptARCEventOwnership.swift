// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC
import OmniWMScriptHost
import ScriptARCCounters

@MainActor
extension ScriptARCFixture {
    func measureMatchedTitleTransactions(in directory: URL) async throws {
        try await loadMissingScript(in: directory)
        let manager = controller.workspaceManager
        for subscribed in [false, true] {
            if subscribed {
                let queue =
                    try await acceptTitleScript(
                        "omniwm.on('window.title', function(e) assert(e.title == 'changed') end)"
                    )
                await queue.waitForAuditPark()
            }
            for pending in [false, true] {
                let control = pending ? "native/title-pending" : "native/title-ready"
                for report in [false, true] {
                    _ = manager.updateManagedReplacementTitle("original", for: otherWindow)
                    if pending { controller.requestWorkspaceBarRefresh() }
                    else { controller.surfaceReconciler.reconcileNow() }
                    title("changed", native: true, measured: true)
                    if subscribed { try await finishWorker(seed: false) }
                    if report {
                        script_arc_report(
                            subscribed ? control + "+script" : control,
                            subscribed ? control : "native",
                            subscribed ? 1 : 0
                        )
                    }
                }
            }
        }
    }

    @inline(never)
    func checkAncestryOwnership(last: Int, report: Bool) {
        let boundary = UInt64.bitWidth
        var ancestors: ConfigScriptListenerMask = [0, boundary]
        var additional: ConfigScriptListenerMask = [boundary - 1, boundary + 1]
        additional.insert(last)
        if report { script_arc_begin() }
        let cause = ConfigScriptEventCause(function: last, ancestors: ancestors)
        if report { script_arc_end()
            script_arc_report("ancestry/extend", "native", 0)
        }
        precondition(!ancestors.contains(last) && cause.excludingSelf.contains(last))
        if report { script_arc_begin() }
        ancestors.formUnion(additional)
        if report { script_arc_end()
            script_arc_report("ancestry/union", "native", 0)
        }
        for member in [0, boundary - 1, boundary, boundary + 1, last] { precondition(ancestors.contains(member)) }
        precondition(!cause.excludingSelf.contains(boundary + 1) && !additional.contains(0))
    }

    func checkQueuedEdgeEpoch() async throws {
        let original = "window/e\u{301}/" + UUID().uuidString
        controller.automationSessionToken = original
        let expected = IPCWindowOpaqueID.encode(token: otherWindow, sessionToken: original)
        let bundle = "window.open/" + UUID().uuidString
        setTitleBundle(bundle)
        let queue = try await acceptTitleScript("""
        local events = 0
        omniwm.on("window.open", function(e)
            events += 1
            assert(e.id == "\(expected)" and e.bundleId == "\(bundle)" and #e.windows > 0)
        end, {reads={"windows"}})
        omniwm.command("Check edge", function() assert(events == 1) end)
        """)
        await queue.waitForAuditPark()
        controller.workspaceManager.publishOpenedWindow(otherWindow)
        controller.automationSessionToken = original.precomposedStringWithCanonicalMapping
        setTitleBundle("replacement")
        precondition(controller.enqueueConfigFunction(script.acceptedCommands.first!.function) == .executed)
        await queue.waitForAuditPark()
        precondition(script.diagnostic == nil)
    }
}
