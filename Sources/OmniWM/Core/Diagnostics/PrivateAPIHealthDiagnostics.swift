// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OmniWMLauncherSPI

enum PrivateAPISelfTestOutcome: String, Sendable {
    case works
    case failed
    case inconclusive
}

struct PrivateAPISelfTest: Sendable {
    let api: String
    let outcome: PrivateAPISelfTestOutcome
    let detail: String
}

extension PrivateAPISelfTest {
    init(_ api: String, _ outcome: PrivateAPISelfTestOutcome, _ detail: String) {
        self.init(api: api, outcome: outcome, detail: detail)
    }
}

struct ForeignWindowProbeResult: Sendable {
    let targetPid: pid_t
    let targetWid: UInt32
    let movedDelta: CGPoint?
    let skylightMoved: Bool
    let restored: Bool
    let outcome: PrivateAPISelfTestOutcome
    let detail: String
}

struct ForeignWindowProbeOperations {
    let queryWindowInfo: (UInt32) -> WindowServerInfo?
    let windowBounds: (UInt32) -> CGRect?
    let independentOrigin: (UInt32, pid_t) -> CGPoint?
    let batchMove: (UInt32, CGPoint) -> SkyLight.TransactionSubmissionResult
    let directMove: (UInt32, CGPoint) -> Bool
    let waitForOrigin: (UInt32, pid_t, CGPoint) async -> CGPoint?
}

struct ForeignWindowRestoreResult {
    let transactionSubmission: SkyLight.TransactionSubmissionResult?
    let directMoveResult: Bool?
    let restoredOrigin: CGPoint?
    let interfered: Bool
}

struct PrivateAPIProbeReport: Sendable {
    let ranAt: Date
    let selfTests: [PrivateAPISelfTest]
    let foreign: ForeignWindowProbeResult?
}

@MainActor
final class PrivateAPIProbeStore {
    static let shared = PrivateAPIProbeStore()
    var last: PrivateAPIProbeReport?
}

struct PrivateAPIHealthSnapshot: Sendable {
    let connectionId: Int32
    let symbols: [String]
    let displayUUIDResolved: Bool
    let multitouchSymbols: [(name: String, resolved: Bool)]
    let cgsRegistration: String
    let cgsWindowSubscription: String
    let launcherSPIStatus: UInt32
    let fallbackDump: String
    let lastProbe: PrivateAPIProbeReport?

    func formatted() -> String {
        let trackpad = multitouchSymbols.map { "\($0.name)=\($0.resolved)" }.joined(separator: " ")
        var lines = [
            "skylightConnection=\(connectionId)\(connectionId == 0 ? " (UNAVAILABLE)" : "")",
            "skylightSymbols=\(symbols.count) resolved",
            "displayUUID=\(displayUUIDResolved ? "resolved" : "MISSING")",
            "multitouchSymbols: \(trackpad)",
            "cgsEventRegistration=\(cgsRegistration)",
            "cgsWindowSubscription=\(cgsWindowSubscription)",
            "launcherSPICapabilities=0x\(String(launcherSPIStatus, radix: 16))",
            "",
            "Fallback / failure firings since launch (by subsystem):",
            fallbackDump,
            "",
            "On-demand probe:"
        ]
        if let lastProbe {
            lines.append(contentsOf: Self.formatProbe(lastProbe))
        } else {
            lines.append("  not run — use Settings ▸ Diagnostics ▸ Run Private-API Probe")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatProbe(_ report: PrivateAPIProbeReport) -> [String] {
        var lines = ["  ranAt=\(report.ranAt.ISO8601Format())"]
        for test in report.selfTests {
            lines.append("  [\(test.outcome.rawValue)] \(test.api) — \(test.detail)")
        }
        if let foreign = report.foreign {
            lines.append(
                "  foreignTransactionMove: outcome=\(foreign.outcome.rawValue)"
                    + " moved=\(foreign.skylightMoved ? "YES" : "NO")"
                    + " restored=\(foreign.restored) delta=\(TraceFormat.point(foreign.movedDelta)) \(foreign.detail)"
            )
        } else {
            lines.append(
                "  foreignTransactionMove: inconclusive — no eligible unmanaged foreign window to probe"
            )
        }
        return lines
    }
}

@MainActor
enum PrivateAPIHealthDiagnostics {
    static func snapshot() -> PrivateAPIHealthSnapshot {
        PrivateAPIHealthSnapshot(
            connectionId: SkyLight.shared.getMainConnectionID(),
            symbols: SkyLight.shared.capabilityReport(),
            displayUUIDResolved: SkyLight.displayUUIDResolved,
            multitouchSymbols: MultitouchBinding.resolvedSymbols(),
            cgsRegistration: CGSEventObserver.shared.lastRegistrationSummary,
            cgsWindowSubscription: CGSEventObserver.shared.lastWindowSubscriptionSummary,
            launcherSPIStatus: omniwm_launcher_spi_status(),
            fallbackDump: FallbackFiringRecorder.shared.dump(),
            lastProbe: PrivateAPIProbeStore.shared.last
        )
    }

    @discardableResult
    static func runProbe(
        foreignWindowEligibility: (WindowServerInfo) -> Bool
    ) async -> PrivateAPIProbeReport {
        var tests = await skylightTests()
        tests.append(contentsOf: SystemAPIProbes.axProbes())
        tests.append(contentsOf: SystemAPIProbes.inputProbes())
        tests.append(contentsOf: SystemAPIProbes.multitouchProbes())
        tests.append(await SystemAPIProbes.captureProbe())
        tests.append(contentsOf: SystemAPIProbes.monitorProbes())
        tests.append(contentsOf: SystemAPIProbes.systemProbes())
        let visibleWindows = SkyLight.shared.queryAllVisibleWindows()
        let sample = visibleWindows.first(where: isEligibleForeignWindow)
        let foreignSample = visibleWindows.first {
            isEligibleForeignWindow($0) && foreignWindowEligibility($0)
        }
        tests.append(contentsOf: sampleWindowTests(sample))
        tests.append(silgenAXWindowTest(sample))
        let foreign = await ForeignWindowProbe.run(sample: foreignSample)
        let report = PrivateAPIProbeReport(
            ranAt: Date(),
            selfTests: tests,
            foreign: foreign
        )
        PrivateAPIProbeStore.shared.last = report
        return report
    }

    private static func skylightTests() async -> [PrivateAPISelfTest] {
        let sky = SkyLight.shared
        let cid = sky.getMainConnectionID()
        var tests = [PrivateAPISelfTest("SLSMainConnectionID", cid != 0 ? .works : .failed, "cid=\(cid)")]
        let wid = sky.createBorderWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        guard wid != 0 else {
            tests.append(PrivateAPISelfTest(
                "SLSNewWindow/CGSNewRegionWithRect",
                .failed,
                "createBorderWindow returned 0"
            ))
            return tests
        }
        defer { sky.releaseBorderWindow(wid) }
        tests.append(PrivateAPISelfTest("SLSNewWindow/CGSNewRegionWithRect", .works, "wid=\(wid)"))
        let target = CGPoint(x: 137, y: 213)
        _ = sky.moveWindow(wid, to: target)
        if let bounds = sky.getWindowBounds(wid) {
            let ok = abs(bounds.origin.x - target.x) < 2 && abs(bounds.origin.y - target.y) < 2
            tests.append(PrivateAPISelfTest(
                "SLSMoveWindow+SLSGetWindowBounds",
                ok ? .works : .failed,
                TraceFormat.rect(bounds)
            ))
        } else {
            tests.append(PrivateAPISelfTest("SLSMoveWindow+SLSGetWindowBounds", .inconclusive, "getWindowBounds nil"))
        }
        if let info = sky.queryWindowInfo(wid) {
            tests.append(PrivateAPISelfTest(
                "SLSWindowQuery* iterator",
                info.id == wid ? .works : .failed,
                "id=\(info.id)"
            ))
        } else {
            tests.append(PrivateAPISelfTest("SLSWindowQuery* iterator", .inconclusive, "queryWindowInfo nil"))
        }
        tests.append(await skylightTransactionMoveTest(wid))
        tests.append(contentsOf: skylightMutationTests(wid))
        tests.append(contentsOf: spaceTests())
        return tests
    }

    private static func skylightTransactionMoveTest(_ wid: UInt32) async -> PrivateAPISelfTest {
        let sky = SkyLight.shared
        guard let initialBounds = sky.getWindowBounds(wid) else {
            return PrivateAPISelfTest("SLSTransactionMoveWindowWithGroup", .inconclusive, "initial bounds unavailable")
        }
        defer { _ = sky.moveWindow(wid, to: initialBounds.origin) }
        let target = CGPoint(x: initialBounds.origin.x + 8, y: initialBounds.origin.y + 8)
        let result = sky.batchMoveWindows([(windowId: wid, origin: target)])
        guard result == .submitted else {
            return PrivateAPISelfTest("SLSTransactionMoveWindowWithGroup", .failed, "submission=\(result)")
        }
        let movedBounds = await waitForWindowBounds(wid, matching: target)
        let restoreIssued = sky.moveWindow(wid, to: initialBounds.origin)
        let restoredBounds = await waitForWindowBounds(wid, matching: initialBounds.origin)
        let restored = restoreIssued && restoredBounds != nil
        guard let movedBounds else {
            return PrivateAPISelfTest(
                "SLSTransactionMoveWindowWithGroup",
                .failed,
                "submission=\(result) bounds=nil restored=\(restored)"
            )
        }
        guard movedBounds.size == initialBounds.size else {
            return PrivateAPISelfTest(
                "SLSTransactionMoveWindowWithGroup",
                .failed,
                "submission=\(result) size=\(movedBounds.width)x\(movedBounds.height) restored=\(restored)"
            )
        }
        return PrivateAPISelfTest(
            "SLSTransactionMoveWindowWithGroup",
            restored ? .works : .inconclusive,
            "submission=\(result) bounds=\(TraceFormat.rect(movedBounds)) restored=\(restored)"
        )
    }

    private static func waitForWindowBounds(_ wid: UInt32, matching origin: CGPoint) async -> CGRect? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        repeat {
            if let bounds = SkyLight.shared.getWindowBounds(wid),
               abs(bounds.origin.x - origin.x) < 2,
               abs(bounds.origin.y - origin.y) < 2
            {
                return bounds
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return nil
            }
        } while clock.now < deadline
        return nil
    }

    private static func skylightMutationTests(_ wid: UInt32) -> [PrivateAPISelfTest] {
        let sky = SkyLight.shared
        let shapeOk = sky.setWindowShape(wid, frame: CGRect(x: 137, y: 213, width: 12, height: 12))
        let configure = sky.configureWindow(wid, resolution: 1, opaque: false)
        let tagsOk = sky.setWindowTags(wid, tags: 0)
        let flushOk = sky.flushWindow(wid)
        let resolutionDetail = configure.resolution
            ? "applied=true"
            : "non-success on macOS 27; return historically ignored, borders functional"
        return [
            PrivateAPISelfTest("SLSSetWindowShape", shapeOk ? .works : .failed, "applied=\(shapeOk)"),
            PrivateAPISelfTest(
                "SLSSetWindowOpacity",
                configure.opacity ? .works : .failed,
                "applied=\(configure.opacity)"
            ),
            PrivateAPISelfTest(
                "SLSSetWindowResolution",
                configure.resolution ? .works : .inconclusive,
                resolutionDetail
            ),
            PrivateAPISelfTest("SLSSetWindowTags", tagsOk ? .works : .failed, "applied=\(tagsOk)"),
            PrivateAPISelfTest("SLSFlushWindowContentRegion", flushOk ? .works : .failed, "applied=\(flushOk)"),
            screencaptureSelectionExclusionTest(wid)
        ]
    }

    private static func spaceTests() -> [PrivateAPISelfTest] {
        let sky = SkyLight.shared
        let active = sky.activeSpace()
        let managed = sky.managedSpaces()
        let mode = sky.displaysHaveSeparateSpaces
        return [
            PrivateAPISelfTest(
                "SLSGetActiveSpace",
                (active ?? 0) != 0 ? .works : .failed,
                "space=\(active.map(String.init) ?? "nil")"
            ),
            PrivateAPISelfTest(
                "SLSCopyManagedDisplaySpaces",
                managed.isEmpty ? .failed : .works,
                "displays=\(managed.count)"
            ),
            PrivateAPISelfTest("SLSGetSpaceManagementMode", mode == .unavailable ? .failed : .works, "mode=\(mode)")
        ]
    }

    private static func sampleWindowTests(_ sample: WindowServerInfo?) -> [PrivateAPISelfTest] {
        guard let sample else {
            return [
                PrivateAPISelfTest(
                    "SLSWindowIteratorGetResolvedCornerRadii",
                    .inconclusive,
                    "no foreign sample window"
                ),
                PrivateAPISelfTest("SLSWindowIteratorGetCornerRadii", .inconclusive, "no foreign sample window"),
                PrivateAPISelfTest("SLSCopySpacesForWindows", .inconclusive, "no foreign sample window")
            ]
        }
        let sky = SkyLight.shared
        let cornerSamples = sky.diagnosticCornerSamples(forWindowId: Int(sample.id))
        let spaces = sky.spacesForWindow(sample.id)
        let detail: (WindowCornerSample?) -> String = { cornerSample in
            cornerSample.map {
                "radii=\($0.radii.topLeft),\($0.radii.topRight),\($0.radii.bottomLeft),\($0.radii.bottomRight) size=\($0.observedSize.width)x\($0.observedSize.height)"
            } ?? "nil (window may have square corners)"
        }
        let resolvedTest: PrivateAPISelfTest = if !sky.resolvedCornerRadiiAvailable {
            PrivateAPISelfTest("SLSWindowIteratorGetResolvedCornerRadii", .inconclusive, "symbol unavailable")
        } else if let resolved = cornerSamples.resolved {
            PrivateAPISelfTest("SLSWindowIteratorGetResolvedCornerRadii", .works, detail(resolved))
        } else {
            PrivateAPISelfTest(
                "SLSWindowIteratorGetResolvedCornerRadii",
                .inconclusive,
                "returned no usable value"
            )
        }
        let rawTest = if let raw = cornerSamples.raw {
            PrivateAPISelfTest("SLSWindowIteratorGetCornerRadii", .works, detail(raw))
        } else {
            PrivateAPISelfTest("SLSWindowIteratorGetCornerRadii", .inconclusive, "returned no usable value")
        }
        return [
            resolvedTest,
            rawTest,
            PrivateAPISelfTest(
                "SLSCopySpacesForWindows",
                spaces.isEmpty ? .inconclusive : .works,
                "spaces=\(spaces.count)"
            )
        ]
    }

    private static func silgenAXWindowTest(_ sample: WindowServerInfo?) -> PrivateAPISelfTest {
        var psn = ProcessSerialNumber()
        let status = getProcessForPID(getpid(), &psn)
        guard status == noErr else {
            return PrivateAPISelfTest(
                "GetProcessForPID/_AXUIElementGetWindow",
                .failed,
                "GetProcessForPID status=\(status)"
            )
        }
        guard let sample else {
            return PrivateAPISelfTest("_AXUIElementGetWindow", .inconclusive, "no sample window")
        }
        let app = AXUIElementCreateApplication(sample.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let first = windows.first
        else {
            return PrivateAPISelfTest("_AXUIElementGetWindow", .inconclusive, "no AX windows (permission?)")
        }
        guard let wid = getWindowId(from: first) else {
            return PrivateAPISelfTest("_AXUIElementGetWindow", .failed, "returned nil")
        }
        return PrivateAPISelfTest("_AXUIElementGetWindow", wid != 0 ? .works : .failed, "wid=\(wid)")
    }
}

@MainActor
extension PrivateAPIHealthDiagnostics {
    private static func screencaptureSelectionExclusionTest(_ wid: UInt32) -> PrivateAPISelfTest {
        let sky = SkyLight.shared
        let api = "SLSSetWindowProperty(IgnoreForScreencaptureWindowSelection)"
        guard sky.excludeFromScreencaptureWindowSelection(wid) else {
            return PrivateAPISelfTest(
                api,
                .failed,
                "applied=false — border stays selectable by the screenshot window picker"
            )
        }
        let readback = sky.isExcludedFromScreencaptureWindowSelection(wid)
        guard readback == true else {
            return PrivateAPISelfTest(api, .inconclusive, "applied=true readback=\(readback.map(String.init) ?? "nil")")
        }
        return PrivateAPISelfTest(api, .works, "applied=true readback=true")
    }

    private static func isEligibleForeignWindow(_ info: WindowServerInfo) -> Bool {
        info.pid != getpid() && info.frame.width > 1 && info.frame.height > 1
    }
}

@MainActor
extension WMController {
    @discardableResult
    func runPrivateAPIProbe() async -> PrivateAPIProbeReport {
        let report = await PrivateAPIHealthDiagnostics.runProbe {
            workspaceManager.entry(forWindowId: Int($0.id)) == nil
        }
        if let wid = report.foreign?.targetWid,
           let entry = workspaceManager.entry(forWindowId: Int(wid))
        {
            layoutRefreshController.requestRelayout(
                reason: .axWindowChanged,
                affectedWorkspaceIds: [entry.workspaceId]
            )
        }
        return report
    }
}
