// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellDesktopOriginTests: XCTestCase {
    @MainActor
    private final class Window: ShellFocusPanel {
        var shown = true
        override var isVisible: Bool {
            shown
        }

        override var occlusionState: NSWindow.OcclusionState {
            shown ? [.visible] : []
        }

        init() {
            _ = NSApplication.shared
            super.init(
                contentRect: CGRect(x: 0, y: 0, width: 120, height: 60),
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
        }
    }

    @MainActor
    private final class Fixture {
        let host: ShellWidgetHost
        let package: ShellWidgetPackage
        let state: ShellWidgetHost.WidgetState
        let window = Window()
        let key = ShellBarKey(monitor: .init(displayId: 96671), placement: .island)
        let first: ShellWidgetSurface

        init() {
            let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
            host = ShellWidgetHost(
                configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                resources: resources, world: { ShellWorldData() }, vars: { [:] }, bars: { [:] },
                onLayoutChange: {}, onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in },
                onDrag: { _ in }, onPopoutChange: {}, onTitleDemandChange: { _ in }
            )
            package = ShellWidgetPackage(name: "source", generation: 8, outbox: ShellWidgetOutbox { _ in })
            state = ShellWidgetHost.WidgetState(name: "source", sourceURL: URL(fileURLWithPath: "/unused/source.luau"))
            state.package = package
            state.renderedGeneration = 8
            first = ShellWidgetSurface(scale: 2, resources: resources, directories: [])
            let instance = ShellWidgetHost.InstanceState()
            instance.surface = first
            state.instances[key] = instance
            host.widgets[state.name] = state
            window.contentView = first.view
        }

        func origin(
            _ surface: ShellWidgetSurface,
            generation: Int = 8,
            view: ShellWidgetView = .bar
        ) -> ShellDesktopOrigin {
            ShellDesktopOrigin(
                widget: state.name,
                generation: generation,
                key: ShellTreeKey(bar: key, view: view),
                sourceID: surface.sourceID
            )
        }

        func close() async {
            await package.close()
            window.contentView = nil
            host.widgets.removeAll()
            window.close()
        }
    }

    func testClosedSourceCannotResolveAReplacementAtTheSameLogicalKey() async throws {
        let fixture = Fixture()
        let acceptedOrigin = fixture.origin(fixture.first)
        let acceptedSource = try XCTUnwrap(fixture.host.desktopSource(for: acceptedOrigin))
        XCTAssertTrue(acceptedSource.isCurrent())
        fixture.first.setVisible(false)
        let replacement = ShellWidgetSurface(scale: 2, resources: fixture.host.resources, directories: [])
        fixture.state.instances[fixture.key]?.surface = replacement
        fixture.window.contentView = replacement.view
        XCTAssertNotEqual(fixture.first.sourceID, replacement.sourceID)
        XCTAssertFalse(acceptedSource.isCurrent())
        XCTAssertNil(fixture.host.desktopSource(for: acceptedOrigin))
        XCTAssertNotNil(fixture.host.desktopSource(for: fixture.origin(replacement)))
        await fixture.close()
    }

    func testNormalTreeUpdatesKeepSourceButGenerationViewAndWindowChangesRejectIt() async throws {
        let fixture = Fixture()
        let origin = fixture.origin(fixture.first)
        let source = try XCTUnwrap(fixture.host.desktopSource(for: origin))
        fixture.first.sequence += 1
        fixture.first.reset(text: fixture.state.text)
        XCTAssertTrue(source.isCurrent())
        XCTAssertNotNil(fixture.host.desktopSource(for: origin))
        XCTAssertNil(fixture.host.desktopSource(for: fixture.origin(fixture.first, generation: 7)))
        XCTAssertNil(fixture.host.desktopSource(for: fixture.origin(fixture.first, view: .popout)))
        fixture.window.shown = false
        XCTAssertFalse(source.isCurrent())
        XCTAssertNil(fixture.host.desktopSource(for: origin))
        fixture.window.shown = true
        fixture.state.renderedGeneration = 9
        XCTAssertFalse(source.isCurrent())
        await fixture.close()
    }

    func testSourceMetadataIsNotLuaDataAndCannotCoalesceAcrossSurfaceReplacement() {
        let ordinary = ShellEvent()
        var sourced = ordinary
        sourced.sourceID = 0x1_0000_0001
        XCTAssertEqual(ordinary.bytes, sourced.bytes)
        let key = ShellBarKey(monitor: .init(displayId: 96672))
        func gesture(_ source: UInt64) -> ShellGestureBox.Gesture {
            var event = ShellEvent(button: .none)
            event.kind = .scroll
            event.phase = .changed
            event.sourceID = source
            event.dy = 1
            return ShellGestureBox.Gesture(bar: key, view: .popout, action: 42, sequence: 1, event: event)
        }
        let box = ShellGestureBox()
        let first = box.post(gesture(1))
        XCTAssertNil(box.post(gesture(1)))
        let second = box.post(gesture(2))
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.take()?.event.dy, 2)
        XCTAssertEqual(second?.take()?.event.sourceID, 2)
    }
}
