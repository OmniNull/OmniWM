// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class InputDiagnosticsTests: XCTestCase {
    func testInputHealthSnapshotFormatsAndOmitsKeyIdentities() {
        let facts = HotkeyHealthFacts(
            isRunning: true,
            isHyperTriggerActive: true,
            hyperTriggerTapInstalled: true,
            capsLockHyperRemapActive: false,
            systemHyperTriggerEnabled: true,
            systemHyperTriggerName: "CapsLock",
            systemHyperTriggerFailure: nil,
            suppressedHotkeyCount: 2,
            registrationFailureCount: 1,
            sideSpecificCount: 0,
            bindingCount: 42,
            bindings: []
        )
        let snapshot = InputHealthSnapshot(
            hotkey: facts,
            mouseTapInstalled: true,
            secureInputActive: false,
            liveModifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            mouseTapDisableCount: 3,
            hyperTapDisableCount: 0,
            lastTapDisable: nil
        )

        let text = snapshot.formatted()
        XCTAssertTrue(text.contains("hyperActive=true"))
        XCTAssertTrue(text.contains("systemHyperTrigger=CapsLock enabled=true failure=none"))
        XCTAssertTrue(text.contains("bindings=42 sideSpecific=0 registrationFailures=1 suppressedKeys=2"))
        XCTAssertTrue(text.contains("modifierFlags=cmd+shift"))
        XCTAssertTrue(text.contains("tapDisables mouse=3 hyper=0 last=never"))
        XCTAssertFalse(text.lowercased().contains("keycode"), "snapshot must not leak raw key identities")
    }

    func testOwnedSurfaceSnapshotFormatsKeyStateWithoutTitles() {
        let window = OwnedSurfaceSnapshot.Window(
            id: "utility-1",
            kind: "utility",
            hitTestPolicy: "frontmostInteractive",
            capturePolicy: "included",
            suppressesManagedFocusRecovery: true,
            frame: CGRect(x: 0, y: 0, width: 900, height: 680),
            isKeyWindow: false,
            isMainWindow: false,
            canBecomeKey: true,
            canBecomeMain: true,
            firstResponder: "NSView"
        )
        let snapshot = OwnedSurfaceSnapshot(
            windows: [window],
            appActive: true,
            activationPolicy: "accessory",
            keyWindowKind: "nil",
            mainWindowKind: "nil",
            hasFrontmostSuppressingWindow: false,
            hasVisibleSuppressingWindow: true
        )

        let text = snapshot.formatted()
        XCTAssertTrue(text.contains("appActive=true activationPolicy=accessory keyWindow=nil mainWindow=nil"))
        XCTAssertTrue(text.contains("[utility-1] kind=utility"))
        XCTAssertTrue(text.contains("key=false main=false canKey=true canMain=true firstResponder=NSView"))
        XCTAssertTrue(text.contains("hasVisibleSuppressing=true"))
    }

    func testOwnedSurfaceSnapshotFormatsEmptyWindowList() {
        let snapshot = OwnedSurfaceSnapshot(
            windows: [],
            appActive: false,
            activationPolicy: "accessory",
            keyWindowKind: "nil",
            mainWindowKind: "nil",
            hasFrontmostSuppressingWindow: false,
            hasVisibleSuppressingWindow: false
        )
        XCTAssertTrue(snapshot.formatted().contains("windows: none"))
    }

    func testModifierLabelRendersEmptyAndCombined() {
        XCTAssertEqual(InputDiagnostics.modifierLabel(0), "[]")
        let combined = NSEvent.ModifierFlags([.control, .option]).rawValue
        XCTAssertEqual(InputDiagnostics.modifierLabel(combined), "ctrl+opt")
    }

    func testInputTapHealthCountersIncrementPerTap() {
        let before = InputTapHealth.counters
        InputTapHealth.recordTapDisabled(mouse: true, byTimeout: true)
        InputTapHealth.recordTapDisabled(mouse: false, byTimeout: false)
        let after = InputTapHealth.counters
        XCTAssertEqual(after.mouseDisableCount, before.mouseDisableCount + 1)
        XCTAssertEqual(after.hyperDisableCount, before.hyperDisableCount + 1)
        XCTAssertNotNil(after.lastDisable)
    }

    @MainActor
    func testHyperDecisionLabels() {
        XCTAssertEqual(HotkeyCenter.decisionLabel(.suppress), "suppress")
        XCTAssertEqual(HotkeyCenter.decisionLabel(.passThrough), "passThrough")
        XCTAssertEqual(HotkeyCenter.decisionLabel(.inject), "inject")
        XCTAssertEqual(HotkeyCenter.decisionLabel(.toggleCapsLock), "toggleCapsLock")
    }

    @MainActor
    func testInputTraceRecordsOnlyDuringCaptureAndAppearsInArtifact() async {
        InputTrace.record("before")
        XCTAssertFalse(InputTrace.shared.dump().contains("before"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMInputTrace-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = RuntimeTraceCaptureCoordinator(diagnosticsDirectory: directory)
        guard case .started = await coordinator.toggle(desiredState: .active, reportProvider: { "report" }) else {
            return XCTFail("expected capture to start")
        }

        InputTrace.record("hyper apply decision=inject")
        XCTAssertTrue(InputTrace.shared.dump().contains("decision=inject"))
        XCTAssertTrue(InputTrace.shared.dump().contains("t_ns="))
        EventIntakeTrace.shared.record(EventIntakeTrace.Record(
            sequence: 21,
            enqueuedNs: 1_000,
            startedNs: 2_000,
            endedNs: 3_000,
            identity: .init(kind: "hotkey")
        ))

        let outcome = await coordinator.toggle(desiredState: .inactive, reportProvider: { "report" })
        guard case let .stopped(artifact) = outcome else {
            return XCTFail("expected capture to stop with an artifact")
        }
        let body = (try? String(contentsOf: artifact.url, encoding: .utf8)) ?? ""
        XCTAssertTrue(body.contains("== Input Trace =="))
        XCTAssertTrue(body.contains("decision=inject"))
        XCTAssertTrue(body.contains("== Event Intake Timing =="))
        XCTAssertTrue(body.contains("seq=21 kind=hotkey"))
        try? FileManager.default.removeItem(at: artifact.url)

        InputTrace.record("after")
        XCTAssertFalse(InputTrace.shared.dump().contains("after"))
    }

    func testInputHealthSnapshotListsBindings() {
        let facts = HotkeyHealthFacts(
            isRunning: true,
            isHyperTriggerActive: false,
            hyperTriggerTapInstalled: false,
            capsLockHyperRemapActive: false,
            systemHyperTriggerEnabled: false,
            systemHyperTriggerName: "None",
            systemHyperTriggerFailure: nil,
            suppressedHotkeyCount: 0,
            registrationFailureCount: 0,
            sideSpecificCount: 1,
            bindingCount: 1,
            bindings: [HotkeyBindingFact(command: "Focus Left", display: "L⌃L⌥L⇧L⌘1", route: "sided")]
        )
        let snapshot = InputHealthSnapshot(
            hotkey: facts,
            mouseTapInstalled: false,
            secureInputActive: false,
            liveModifierFlags: 0,
            mouseTapDisableCount: 0,
            hyperTapDisableCount: 0,
            lastTapDisable: nil
        )

        let text = snapshot.formatted()
        XCTAssertTrue(text.contains("bindings:"))
        XCTAssertTrue(text.contains("Focus Left L⌃L⌥L⇧L⌘1 route=sided"))
    }

    func testBindingFactsClassifyRegistrationRoutes() {
        let carbon = HotkeyBinding(
            id: "toggleFullscreen",
            command: .fullscreen(.managed),
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(optionKey))
        )
        let sided = HotkeyBinding(
            id: "focusPrevious",
            command: .focusNavigation(.previous),
            binding: KeyBinding(
                keyCode: UInt32(kVK_ANSI_K),
                modifiers: KeySymbolMapper.hyperModifiers,
                sidedModifiers: SidedModifiers(left: KeySymbolMapper.hyperModifiers)
            )
        )
        let dupA = HotkeyBinding(
            id: "focusMonitorNext",
            command: .monitorFocus(.next),
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey))
        )
        let dupB = HotkeyBinding(
            id: "focusMonitorLast",
            command: .monitorFocus(.last),
            binding: KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey))
        )

        let facts = HotkeyCenter.bindingFacts(for: [carbon, sided, dupA, dupB])
        let routeByCommand = Dictionary(facts.map { ($0.command, $0.route) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(routeByCommand[HotkeyCommand.fullscreen(.managed).displayName], "carbon")
        XCTAssertEqual(routeByCommand[HotkeyCommand.focusNavigation(.previous).displayName], "sided")
        XCTAssertEqual(routeByCommand[HotkeyCommand.monitorFocus(.next).displayName], "unregistered(duplicateBinding)")
        XCTAssertTrue(facts.contains { $0.display.contains("L⌃") })
    }

    func testSidedModifierLabelRendersSidedAndGeneric() {
        let leftControl = CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK)
        XCTAssertEqual(KeySymbolMapper.sidedModifierLabel(leftControl), "L⌃")
        XCTAssertEqual(KeySymbolMapper.sidedModifierLabel(CGEventFlags.maskControl.rawValue), "⌃")
        XCTAssertEqual(KeySymbolMapper.sidedModifierLabel(0), "")
    }
}
