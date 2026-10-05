// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeAppHideTests: XCTestCase {
    func testActivationBeforeHideInvalidatesFallbackFactsInBothLayouts() throws {
        for layout: LayoutType in [.niri, .dwindle] {
            let fixture = try Fixture(layout: layout)
            defer { fixture.stop() }

            fixture.frontmostPID = fixture.other.pid
            fixture.enqueue(.activated(pid: fixture.other.pid))
            fixture.enqueue(.hidden(pid: fixture.hidden.pid))
            fixture.drain()
            fixture.drain()

            fixture.assertStayed()
            XCTAssertEqual(fixture.requestedPIDs, [fixture.other.pid])
            XCTAssertEqual(fixture.activatedPIDs, [getpid()])
        }
    }

    func testHideBeforeActivationWaitsForNativeHandoffAcknowledgmentInBothLayouts() throws {
        for layout: LayoutType in [.niri, .dwindle] {
            let fixture = try Fixture(layout: layout)
            defer { fixture.stop() }

            fixture.frontmostPID = fixture.other.pid
            fixture.send(.hidden(pid: fixture.hidden.pid))
            fixture.send(.activated(pid: fixture.other.pid))
            fixture.drain()

            fixture.assertStayed()
            XCTAssertTrue(fixture.requestedPIDs.isEmpty)
            XCTAssertEqual(fixture.frontmostPID, fixture.other.pid)
            fixture.acknowledgeHandoff()
            fixture.send(.activated(pid: fixture.other.pid))
            fixture.drain()
            fixture.assertStayed()
            XCTAssertEqual(fixture.requestedPIDs, [getpid()])
        }
    }

    func testNativeHiddenStateBeforeNotificationPreventsFallbackLookup() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.nativeHiddenPIDs.insert(fixture.hidden.pid)
        fixture.frontmostPID = fixture.other.pid

        fixture.send(.activated(pid: fixture.other.pid))
        fixture.drain()

        fixture.assertStayed()
        XCTAssertTrue(fixture.requestedPIDs.isEmpty)
        XCTAssertTrue(fixture.controller.workspaceManager.isAppHidden(fixture.hidden))
        XCTAssertEqual(fixture.activatedPIDs, [getpid()])
        fixture.send(.hidden(pid: fixture.hidden.pid))
        XCTAssertEqual(fixture.activatedPIDs, [getpid()])
    }

    func testNativeHideDuringFactLookupPreventsWorkspaceSwitch() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.frontmostPID = fixture.other.pid
        fixture.send(.activated(pid: fixture.other.pid))
        fixture.nativeHiddenPIDs.insert(fixture.hidden.pid)

        fixture.drain()

        fixture.assertStayed()
        XCTAssertEqual(fixture.requestedPIDs, [fixture.other.pid])
        XCTAssertEqual(fixture.activatedPIDs, [getpid()])
    }

    func testLaterDeliberateAppActivationStillSwitchesWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.send(.hidden(pid: fixture.hidden.pid))
        fixture.acknowledgeHandoff()

        fixture.frontmostPID = fixture.other.pid
        fixture.send(.activated(pid: fixture.other.pid))
        fixture.drain()

        fixture.assertOtherFocused()
    }

    func testDockUnhideCanSupersedePendingEmptyWorkspaceHandoff() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.send(.hidden(pid: fixture.hidden.pid))
        fixture.controller.workspaceManager.setAppHidden(true, pid: fixture.other.pid, source: .service)
        fixture.frontmostPID = fixture.other.pid

        fixture.send(.unhidden(pid: fixture.other.pid))
        fixture.drain()

        fixture.assertOtherFocused()
    }

    func testNewManagedFocusRequestSupersedesPendingHandoff() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.send(.hidden(pid: fixture.hidden.pid))
        fixture.controller.focusWindow(fixture.other)
        fixture.frontmostPID = fixture.other.pid

        fixture.send(.activated(pid: fixture.other.pid))
        fixture.drain()

        fixture.assertOtherFocused()
    }

    func testHandoffDeadlineExpiresWithoutClaimingNativeActivation() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.frontmostPID = fixture.other.pid
        fixture.send(.hidden(pid: fixture.hidden.pid))
        let intent = try XCTUnwrap(fixture.controller.intentLedger.entries.last {
            $0.kind == .activateApp(pid: getpid())
        })

        fixture.controller.axEventHandler.handleIntentExpired(intent.id)

        XCTAssertEqual(fixture.controller.intentLedger.intent(id: intent.id)?.phase, .expired)
        XCTAssertEqual(fixture.frontmostPID, fixture.other.pid)
        fixture.assertStayed()
        fixture.send(.activated(pid: fixture.other.pid))
        fixture.drain()
        fixture.assertOtherFocused()
    }

    func testRemainingWindowAcceptsSuccessorActivationInBothLayoutsAndEventOrders() throws {
        for layout: LayoutType in [.niri, .dwindle] {
            for mode: TrackedWindowMode in [.tiling, .floating] {
                for nativeHideFirst in [false, true] {
                    let fixture = try Fixture(layout: layout)
                    defer { fixture.stop() }
                    let sibling = fixture.addSibling(mode: mode)
                    fixture.frontmostPID = sibling.pid
                    if nativeHideFirst {
                        fixture.nativeHiddenPIDs.insert(fixture.hidden.pid)
                    }
                    fixture.enqueue(.activated(pid: sibling.pid))
                    if !nativeHideFirst {
                        fixture.enqueue(.hidden(pid: fixture.hidden.pid))
                    }
                    fixture.drain()
                    fixture.drain()

                    XCTAssertTrue(fixture.activatedPIDs.isEmpty)
                    XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, sibling)
                    XCTAssertEqual(
                        fixture.controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
                        fixture.activeWorkspace
                    )
                }
            }
        }
    }

    func testBackgroundHideDoesNotCancelNormalAppActivation() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.frontmostPID = fixture.other.pid
        fixture.enqueue(.activated(pid: fixture.other.pid))
        fixture.enqueue(.hidden(pid: 970_699))
        fixture.drain()
        fixture.drain()

        fixture.assertOtherFocused()
        XCTAssertTrue(fixture.activatedPIDs.isEmpty)
    }

    func testActivationWithoutHandoffPreservesExistingFocusPolicy() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.controller.workspaceManager.setAppHidden(true, pid: fixture.hidden.pid, source: .service)
        _ = fixture.controller.resolveAndSetWorkspaceFocusToken(for: fixture.activeWorkspace)
        fixture.frontmostPID = getpid()

        fixture.send(.activated(pid: fixture.other.pid))
        fixture.drain()

        fixture.assertOtherFocused()
        XCTAssertTrue(fixture.activatedPIDs.isEmpty)
    }

    func testConfirmedHandoffDoesNotOutliveNewerFocusAuthority() throws {
        for managed in [false, true] {
            let fixture = try Fixture()
            defer { fixture.stop() }
            fixture.send(.hidden(pid: fixture.hidden.pid))
            fixture.acknowledgeHandoff()
            if managed {
                fixture.controller.focusWindow(fixture.other)
                _ = fixture.controller.intentLedger.cancelManagedRequest()
                _ = fixture.controller.workspaceManager.cancelCurrentManagedFocusRequest()
            } else {
                _ = fixture.controller.workspaceManager.recordExternalFocus(pid: fixture.other.pid)
            }

            fixture.send(.activated(pid: fixture.other.pid))
            fixture.drain()

            fixture.assertOtherFocused()
        }
    }

    @MainActor
    private final class Fixture {
        private final class Effects {
            var activatedPIDs: [pid_t] = []
        }

        private let effects = Effects()
        let controller: WMController
        let hidden = WindowToken(pid: 970_601, windowId: 970_701)
        let other = WindowToken(pid: 970_602, windowId: 970_702)
        let monitor: Monitor
        let activeWorkspace: WorkspaceDescriptor.ID
        let otherWorkspace: WorkspaceDescriptor.ID
        var frontmostPID: pid_t? = 970_601
        var nativeHiddenPIDs: Set<pid_t> = []
        var requestedPIDs: [pid_t] = []
        var activatedPIDs: [pid_t] {
            effects.activatedPIDs
        }

        init(layout: LayoutType = .niri) throws {
            let effects = effects
            controller = WindowAdmissionTestSupport.controller(
                prefix: "NativeAppHideTests",
                windowFocusOperations: WindowFocusOperations(
                    activateApp: { effects.activatedPIDs.append($0) },
                    focusSpecificWindow: { _, _, _ in },
                    raiseWindow: { _ in }
                )
            )
            controller.settings.animationsEnabled = false
            controller.settings.focus.moveMouseToFocusedWindow = false
            monitor = Monitor(
                id: .init(displayId: 970_600), displayId: 970_600,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
                hasNotch: false, name: "Native App Hide Test"
            )
            controller.workspaceManager.applyMonitorConfigurationChange([monitor])
            activeWorkspace = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
                named: "91", layoutType: layout, controller: controller
            ))
            otherWorkspace = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
                named: "92", layoutType: layout, controller: controller
            ))
            _ = controller.workspaceManager.focusWorkspace(id: activeWorkspace)
            controller.niriLayoutHandler.enableNiriLayout()
            controller.dwindleLayoutHandler.enableDwindleLayout()
            for (token, workspace) in [(hidden, activeWorkspace), (other, otherWorkspace)] {
                _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
                controller.workspaceManager.withEngineMutationScope(in: workspace) {
                    switch controller.workspaceManager.activeLayoutKind(for: workspace) {
                    case .niri:
                        _ = controller.niriEngine?.addWindow(token: token, to: workspace, afterSelection: nil)
                    case .dwindle:
                        _ = controller.dwindleEngine?.addWindow(token: token, to: workspace, activeWindowFrame: nil)
                    }
                }
            }
            _ = controller.workspaceManager.setManagedFocus(hidden, in: activeWorkspace, onMonitor: monitor.id)
            controller.layoutRefreshController.resetState()
            controller.axEventHandler.frontmostApplicationPIDProvider = { [weak self] in self?.frontmostPID }
            controller.axEventHandler.applicationIsHiddenProvider = { [weak self] in
                self?.nativeHiddenPIDs.contains($0) == true
            }
            controller.axEventHandler.windowInfoProvider = { _ in nil }
            controller.factResolver.factProvider = { [weak self] pid in
                guard let self else { return nil }
                requestedPIDs.append(pid)
                guard let entry = controller.workspaceManager.entries(forPid: pid).first else { return nil }
                return FocusedWindowFact(axRef: entry.axRef, isFullscreen: false, isSystemModalSurface: false)
            }
            controller.hasStartedServices = true
            controller.eventIntake.open(sink: controller.eventInterpreter)
        }

        func enqueue(_ event: ApplicationIntakeEvent) {
            XCTAssertTrue(controller.eventIntake.enqueue(.application(event)))
        }

        func addSibling(mode: TrackedWindowMode) -> WindowToken {
            let token = WindowToken(pid: 970_603, windowId: 970_703)
            _ = WindowAdmissionTestSupport.track(token, in: activeWorkspace, controller: controller)
            controller.workspaceManager.setWindowMode(mode, for: token)
            if mode == .tiling {
                controller.workspaceManager.withEngineMutationScope(in: activeWorkspace) {
                    switch controller.workspaceManager.activeLayoutKind(for: activeWorkspace) {
                    case .niri:
                        _ = controller.niriEngine?.addWindow(token: token, to: activeWorkspace, afterSelection: nil)
                    case .dwindle:
                        _ = controller.dwindleEngine?.addWindow(
                            token: token,
                            to: activeWorkspace,
                            activeWindowFrame: nil
                        )
                    }
                }
            }
            return token
        }

        func drain() {
            controller.eventIntake.drainNow()
        }

        func send(_ event: ApplicationIntakeEvent) {
            enqueue(event)
            drain()
        }

        func acknowledgeHandoff() {
            frontmostPID = getpid()
            send(.activated(pid: getpid()))
            drain()
        }

        func assertStayed(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id,
                activeWorkspace,
                file: file,
                line: line
            )
            XCTAssertNil(controller.workspaceManager.nativeManagedFocusToken, file: file, line: line)
        }

        func assertOtherFocused(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(
                controller.workspaceManager.activeWorkspace(on: monitor.id)?.id,
                otherWorkspace,
                file: file,
                line: line
            )
            XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, other, file: file, line: line)
        }

        func stop() {
            controller.eventIntake.close()
            controller.deadlineWheel.stop()
            controller.factResolver.stop()
            controller.layoutRefreshController.resetState()
        }
    }
}
