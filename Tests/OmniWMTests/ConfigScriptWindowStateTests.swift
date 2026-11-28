// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptWindowStateTests: XCTestCase {
    func testTitleUsesTheNativeReadAndSuppressesMissingAndRepeatedValues() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        _ = WindowAdmissionTestSupport.track(token, in: workspace.id, controller: controller)
        let source = TitleSource()
        let handler = controller.axEventHandler
        handler.windowTitleProvider = { _ in source.read() }
        let id = ConfigScriptWindowID.string(token, session: controller.scriptSession.identity)
        var titles: [String] = []
        let observer = ConfigScriptEventObservers(controller: controller, kinds: [.windowTitle]) { kind, payload in
            XCTAssertEqual(kind, .windowTitle)
            XCTAssertEqual(payload.id, id)
            if case let .title(title) = payload.edge { titles.append(title) }
        }
        let inputs: [String?] = [nil, "first", "first", "", nil, "last"]
        for value in inputs {
            source.title = value
            handler.handleWindowTitleChanged(windowId: UInt32(token.windowId), pid: token.pid)
        }
        observer.stop()
        source.title = "unsubscribed"
        handler.handleWindowTitleChanged(windowId: UInt32(token.windowId), pid: token.pid)
        XCTAssertEqual(titles, ["first", "", "last"])
        XCTAssertEqual(source.reads, inputs.count + 1)
    }

    func testTitleHistoryFollowsTheHandleThroughRekeyAndEndsOnDetach() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let original = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let updated = WindowToken(pid: original.pid, windowId: original.windowId + 1)
        _ = WindowAdmissionTestSupport.track(original, in: workspace.id, controller: controller)
        let title = "one stable title"
        var titles: [String] = []
        func observe() -> ConfigScriptEventObservers {
            ConfigScriptEventObservers(controller: controller, kinds: [.windowTitle]) { _, payload in
                if case let .title(value) = payload.edge { titles.append(value) }
            }
        }
        let observer = observe()
        observer.titleChanged(title, for: original, metadataChanged: false, controller: controller)
        XCTAssertNotNil(manager.rekeyWindow(
            from: original, to: updated, newAXRef: WindowAdmissionTestSupport.axRef(for: updated)
        ))
        observer.titleChanged(title, for: updated, metadataChanged: false, controller: controller)
        XCTAssertEqual(titles, [title])
        observer.stop()
        XCTAssertNil(observer.windowStates.titlesWithoutMetadata)
        let successor = observe()
        defer { successor.stop() }
        successor.titleChanged(title, for: updated, metadataChanged: false, controller: controller)
        XCTAssertEqual(titles, [title, title])
    }

    func testFirstMinimizedAdmissionAndReadmittedWindowModeUseCommittedState() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let manager = controller.workspaceManager
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let ax = WindowAdmissionTestSupport.axRef(for: token)
        var events: [ConfigScriptEventKind] = []
        var states: [ConfigScriptEventPayload.Edge] = []
        let observer = ConfigScriptEventObservers(
            controller: controller,
            kinds: [.windowOpen, .windowUpdateState, .windowMinimize]
        ) { kind, payload in
            events.append(kind)
            if kind == .windowUpdateState || kind == .windowMinimize, let state = payload.edge { states.append(state) }
            if kind ==
                .windowMinimize { XCTAssertEqual(manager.withEntry(token, { $0.observedState.isMinimized }), true) }
        }
        defer { observer.stop() }
        _ = manager.addWindow(ax, pid: token.pid, windowId: token.windowId, to: workspace.id, isMinimized: true)
        for mode: TrackedWindowMode in [.floating, .floating, .tiling] {
            _ = manager.addWindow(ax, pid: token.pid, windowId: token.windowId, to: workspace.id, mode: mode)
        }
        manager.withEngineMutationScope {
            _ = manager.setWindowMode(.floating, for: token)
            _ = manager.setWindowMode(.tiling, for: token)
        }
        XCTAssertEqual(events, [.windowOpen, .windowMinimize, .windowUpdateState, .windowUpdateState])
        XCTAssertEqual(states, [.minimized(true), .floating(true), .floating(false)])
    }

    func testHostedMinimizePublishesAllChangedMembersOnceAfterCommit() throws {
        let fixture = try HostedFamilyStateFixture()
        defer { fixture.close() }
        let controller = fixture.base.controller
        let expected = fixture.family
            .map { ConfigScriptWindowID.string($0, session: controller.scriptSession.identity) }
        var ids: [String] = []
        let observer = ConfigScriptEventObservers(controller: controller, kinds: [.windowMinimize]) { _, payload in
            if let id = payload.id { ids.append(id) }
            if case let .minimized(state) = payload.edge {
                XCTAssertTrue(fixture.family
                    .allSatisfy { fixture.manager.withEntry($0) { $0.observedState.isMinimized } == state })
            } else { XCTFail("Expected the committed minimize state") }
        }
        defer { observer.stop() }
        XCTAssertTrue(fixture.manager.setWindowMinimized(true, token: fixture.main))
        XCTAssertFalse(fixture.manager.setWindowMinimized(true, token: fixture.main))
        XCTAssertTrue(fixture.manager.setWindowMinimized(false, token: fixture.main))
        XCTAssertEqual(ids, expected + expected)
    }

    func testNativeFullscreenPublishesConfirmationsAndUsesOnlyMatchingRequestGeneration() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        _ = WindowAdmissionTestSupport.track(token, in: workspace.id, controller: controller)
        var states: [Bool] = []
        var issuers: [Int?] = []
        let observer = ConfigScriptEventObservers(controller: controller, kinds: [.windowFullscreen]) { _, payload in
            if case let .fullscreen(value) = payload.edge { states.append(value) }
            issuers.append(manager.scriptWindowFullscreenObserver?.windowStates.confirmingFullscreen?.function)
        }
        defer { observer.stop() }
        let cause = ConfigScriptEventCause(function: #line, ancestors: [])
        func request() {
            let generation = manager.nativeFullscreenTransitionGenerationCounter
            XCTAssertTrue(manager.requestNativeFullscreenEnter(token, in: workspace.id))
            observer.recordFullscreenRequest(for: token, since: generation, cause: cause, manager: manager)
        }
        request()
        let first = try XCTUnwrap(manager.nativeFullscreenRecord(for: token))
        XCTAssertTrue(states.isEmpty)
        XCTAssertTrue(manager.expireNativeFullscreenTransition(
            originalToken: first.originalToken,
            generation: first.transitionGeneration
        ))
        XCTAssertTrue(manager.markNativeFullscreenSuspended(token, ownsNativeFocus: false))
        XCTAssertTrue(manager.restoreNativeFullscreenRecord(for: token))
        request()
        XCTAssertTrue(manager.markNativeFullscreenSuspended(token, ownsNativeFocus: false))
        _ = manager.markNativeFullscreenSuspended(token, ownsNativeFocus: false)
        XCTAssertTrue(manager.restoreNativeFullscreenRecord(for: token))
        XCTAssertEqual(states, [true, false, true, false])
        XCTAssertEqual(issuers, [nil, nil, cause.function, nil])
    }

    func testManagedFullscreenTogglesImplicitExitAndHistoryUseFinalLayout() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        controller.settings.workspaces.defaultLayoutType = .dwindle
        let manager = controller.workspaceManager
        let engine = DwindleLayoutEngine()
        manager.dwindleEngine = engine
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        try switchLayout(.defaultLayout, workspace: workspace, controller: controller)
        XCTAssertEqual(manager.activeLayoutKind(for: workspace.id), .dwindle)
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let other = WindowToken(pid: token.pid, windowId: token.windowId + 1)
        for tracked in [token, other] {
            _ = WindowAdmissionTestSupport.track(tracked, in: workspace.id, controller: controller)
        }
        manager.withEngineMutationScope { _ = engine.addWindow(token: token, to: workspace.id, activeWindowFrame: nil) }
        var states: [Bool] = []
        let observer = ConfigScriptEventObservers(controller: controller, kinds: [.windowFullscreen]) { _, payload in
            if case let .fullscreen(value) = payload.edge { states.append(value) }
            let managed = manager.withEntry(token) { $0.mode == .tiling } == true
                && manager.activeLayoutKind(for: workspace.id) == .dwindle && engine.isWindowFullscreen(
                    token,
                    in: workspace.id
                )
            let effective = manager.isNativeFullscreenSuspended(token) || managed
            XCTAssertEqual(states.last, effective)
        }
        defer { observer.stop() }
        manager.withEngineMutationScope { XCTAssertTrue(engine.toggleFullscreen(for: token, in: workspace.id)) }
        let saved = try XCTUnwrap(manager.withEngineMutationScope { engine.layoutSnapshot(in: workspace.id) })
        manager.withEngineMutationScope {
            _ = engine.syncWindows([token, other], in: workspace.id, focusedToken: token)
        }
        manager.withEngineMutationScope { engine.restoreLayoutSnapshot(saved, in: workspace.id) }
        manager.withEngineMutationScope {
            XCTAssertTrue(engine.toggleFullscreen(for: token, in: workspace.id))
            XCTAssertTrue(engine.toggleFullscreen(for: token, in: workspace.id))
        }
        controller.settings.workspaces.defaultLayoutType = .niri
        controller.settings.workspaces.defaultLayoutType = .dwindle
        try switchLayout(.niri, workspace: workspace, controller: controller)
        XCTAssertEqual(states, [true, false, true, false, true, false])
        try switchLayout(.dwindle, workspace: workspace, controller: controller)
        XCTAssertTrue(manager.setWindowMode(.floating, for: token))
        XCTAssertTrue(engine.isWindowFullscreen(token, in: workspace.id))
        states.removeAll()
        try switchLayout(.niri, workspace: workspace, controller: controller)
        try switchLayout(.dwindle, workspace: workspace, controller: controller)
        XCTAssertTrue(manager.markNativeFullscreenSuspended(token, ownsNativeFocus: false))
        XCTAssertTrue(manager.restoreNativeFullscreenRecord(for: token))
        XCTAssertEqual(states, [true, false])
    }

    private func switchLayout(_ layout: LayoutType, workspace: WorkspaceDescriptor, controller: WMController) throws {
        var configurations = controller.settings.workspaces.configurations
        let index = try XCTUnwrap(configurations.firstIndex { $0.name == workspace.name })
        configurations[index].layoutType = layout
        controller.settings.workspaces.configurations = configurations
    }
}

@MainActor
private final class TitleSource {
    var reads = 0
    var title: String?

    func read() -> String? {
        reads += 1
        return title
    }
}
