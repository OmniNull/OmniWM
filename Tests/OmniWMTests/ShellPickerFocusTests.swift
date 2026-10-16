// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class ShellPickerFocusTests: XCTestCase {
    @MainActor
    private final class Window: ShellFocusPanel {
        var shown = true
        var key = false
        var keyCalls = 0
        weak var selectedResponder: NSResponder?

        init() {
            _ = NSApplication.shared
            super.init(
                contentRect: CGRect(x: 20, y: 20, width: 120, height: 60),
                styleMask: [],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
        }

        override var isVisible: Bool {
            shown
        }

        override var occlusionState: NSWindow.OcclusionState {
            shown ? [.visible] : []
        }

        override var isKeyWindow: Bool {
            key
        }

        override func makeKey() {
            key = true
            keyCalls += 1
        }

        override func resignKey() {
            key = false
            onBlur?()
        }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            selectedResponder = responder
            return true
        }
    }

    @MainActor
    private final class Origin {
        var generation = 1
    }

    @MainActor
    private final class Fixture {
        let widget: ShellRenderedWidget
        let parent = Window()
        let child = Window()
        let origin = Origin()
        let policy = FocusPolicyEngine()
        let host: ShellWidgetHost

        init(focusable: Bool = true) throws {
            _ = NSApplication.shared
            widget = try ShellRenderedWidget(name: "picker-focus", source: """
            function render()
                return ui.box{key='source',w=120,h=60,focusable=\(focusable ? "true" : "false")}
            end
            """)
            host = ShellWidgetHost(
                configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)), focusPolicyEngine: policy,
                world: { ShellWorldData() }, vars: { [:] }, bars: { [:] }, onLayoutChange: {},
                onCommand: { _, _ in }, onMenu: { _ in }, onPreview: { _ in }, onDrag: { _ in },
                onPopoutChange: {}, onTitleDemandChange: { _ in }
            )
            widget.surface.view.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
            widget.render(ShellBarData())
            parent.contentView = widget.surface.view
            OwnedWindowRegistry.shared.register(
                parent, surfaceId: "picker-parent-\(ObjectIdentifier(parent))",
                policy: SurfacePolicy(
                    kind: .workspaceBar,
                    hitTestPolicy: .interactive,
                    capturePolicy: .excluded,
                    suppressesManagedFocusRecovery: false
                )
            )
            host.connectSurfaceFocus(widget.surface) { true }
        }

        func source() throws -> ShellDesktopSource {
            let generation = origin.generation
            return try XCTUnwrap(host.desktopSource(for: widget.surface) { [origin] in
                origin.generation == generation
            })
        }

        func focus() {
            widget.surface.focusDeclared(widget.surface.layout.core.rootHandle)
        }

        func close() {
            origin.generation += 1
            host.releaseShellFocus(from: widget.surface, restore: false)
            if let focus = host.pickerFocus { host.finishPickerFocus(focus, current: nil, appActive: false) }
            host.stopIslandInputMonitoring()
            OwnedWindowRegistry.shared.unregister(parent)
            child.close()
            parent.close()
        }
    }

    func testSourceChecksGenerationVisibilityAndOriginalWindowBeforePresentation() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try fixture.source()
        XCTAssertTrue(source.isCurrent())
        fixture.parent.shown = false
        XCTAssertFalse(source.isCurrent())
        fixture.parent.shown = true
        fixture.widget.surface.setVisible(false)
        XCTAssertFalse(source.isCurrent())
        fixture.widget.surface.setVisible(true)
        XCTAssertTrue(source.isCurrent())
        fixture.origin.generation += 1
        XCTAssertFalse(source.isCurrent())
        XCTAssertThrowsError(try source.beginFocus(fixture.child))
        XCTAssertNil(fixture.host.pickerFocus)
        XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: fixture.child))
        let current = try fixture.source()
        fixture.parent.contentView = nil
        XCTAssertFalse(current.isCurrent())
        XCTAssertNil(fixture.host.desktopSource(for: fixture.widget.surface) { true })
    }

    func testChildKeepsOneLeaseReturnTargetAndDismissalExemptionUntilActualEnd() throws {
        let fixture = try Fixture()
        let dismissal = PanelDismissalMonitor()
        defer { dismissal.stop()
            fixture.close()
        }
        var leaseChanges = 0
        fixture.policy.onLeaseChanged = { _ in leaseChanges += 1 }
        fixture.focus()
        let previous = Window()
        let responder = NSView()
        fixture.host.shellPreviousKeyWindow = previous
        fixture.host.shellPreviousFirstResponder = responder
        let end = try fixture.source().beginFocus(fixture.child)
        let presentation = try XCTUnwrap(fixture.host.pickerFocus)
        XCTAssertTrue(OwnedWindowRegistry.shared.contains(window: fixture.child))
        XCTAssertTrue(OwnedWindowRegistry.shared.visibleWindows(suppressesManagedFocusRecovery: true)
            .contains { $0 === fixture.child })
        fixture.parent.resignKey()
        fixture.widget.surface.blurDeclaredFocus()
        fixture.host.handleIslandOutsidePress(
            at: CGPoint(x: -1000, y: -1000), event: ShellEvent(kind: .outsidePress),
            generation: fixture.host.islandInputGeneration
        )
        var dismissals = 0
        dismissal.start(panels: [fixture.parent], isExemptWindow: { _ in false }, onDismiss: { dismissals += 1 })
        dismissal.handlePointer(location: CGPoint(x: -1000, y: -1000))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: fixture.child.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        XCTAssertFalse(dismissal.handleLocalEvent(escape))
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(fixture.host.focusedSurface === fixture.widget.surface)
        XCTAssertTrue(fixture.host.shellPreviousKeyWindow === previous)
        XCTAssertTrue(fixture.host.shellPreviousFirstResponder === responder)
        XCTAssertEqual(fixture.policy.activeLease?.owner, .shellIsland)
        XCTAssertEqual(leaseChanges, 1)
        fixture.child.shown = false
        fixture.host.finishPickerFocus(presentation, current: fixture.child, appActive: true)
        XCTAssertNil(fixture.host.pickerFocus)
        XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: fixture.child))
        XCTAssertNil(fixture.parent.hasOwnedChildPresentation)
        XCTAssertTrue(fixture.widget.surface.declaredFocus)
        XCTAssertTrue(fixture.parent.selectedResponder === fixture.widget.surface.preferredFirstResponder)
        XCTAssertTrue(fixture.host.shellPreviousKeyWindow === previous)
        XCTAssertEqual(leaseChanges, 1)
        end(true)
        XCTAssertEqual(leaseChanges, 1)
        dismissal.handlePointer(location: CGPoint(x: -1000, y: -1000))
        XCTAssertEqual(dismissals, 1)
    }

    func testNonFocusablePickerSourceUsesSameLeaseAndWaitsForNativeCompletion() throws {
        let fixture = try Fixture(focusable: false)
        defer { fixture.close() }
        var leaseChanges = 0
        fixture.policy.onLeaseChanged = { _ in leaseChanges += 1 }
        let end = try fixture.source().beginFocus(fixture.child)
        let presentation = try XCTUnwrap(fixture.host.pickerFocus)
        XCTAssertFalse(fixture.widget.surface.declaredFocus)
        XCTAssertTrue(fixture.host.focusedSurface === fixture.widget.surface)
        XCTAssertEqual(fixture.policy.activeLease?.owner, .shellIsland)
        fixture.parent.resignKey()
        XCTAssertTrue(OwnedWindowRegistry.shared.contains(window: fixture.child))
        XCTAssertEqual(leaseChanges, 1)
        fixture.host.shellPreviousKeyWindow = nil
        fixture.child.shown = false
        fixture.host.finishPickerFocus(presentation, current: nil, appActive: true)
        XCTAssertNil(fixture.host.focusedSurface)
        XCTAssertNil(fixture.policy.activeLease)
        XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: fixture.child))
        XCTAssertEqual(leaseChanges, 2)
        end(true)
        XCTAssertEqual(leaseChanges, 2)
    }

    func testRetiredSourceReleasesWithoutRestoringUnderChildAndOldEndCannotReleaseNewSession() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.focus()
        let previous = Window()
        fixture.host.shellPreviousKeyWindow = previous
        let source = try fixture.source()
        let end = try source.beginFocus(fixture.child)
        let presentation = try XCTUnwrap(fixture.host.pickerFocus)
        fixture.origin.generation += 1
        fixture.widget.surface.setVisible(false)
        XCTAssertFalse(source.isCurrent())
        XCTAssertNil(fixture.host.focusedSurface)
        XCTAssertNil(fixture.policy.activeLease)
        XCTAssertEqual(previous.keyCalls, 0)
        XCTAssertTrue(OwnedWindowRegistry.shared.contains(window: fixture.child))
        XCTAssertNotNil(fixture.parent.hasOwnedChildPresentation)
        fixture.widget.surface.setVisible(true)
        let next = try fixture.source()
        XCTAssertThrowsError(try next.beginFocus(Window()))
        fixture.child.shown = false
        fixture.host.finishPickerFocus(presentation, current: fixture.child, appActive: true)
        XCTAssertEqual(previous.keyCalls, 0)
        fixture.focus()
        XCTAssertEqual(fixture.policy.activeLease?.owner, .shellIsland)
        end(true)
        XCTAssertTrue(fixture.host.focusedSurface === fixture.widget.surface)
        XCTAssertEqual(fixture.policy.activeLease?.owner, .shellIsland)
    }

    func testCompletionNeverRestoresOverForeignFocusOrAnInactiveApplication() throws {
        for active in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.focus()
            let previous = Window()
            let foreign = Window()
            fixture.host.shellPreviousKeyWindow = previous
            _ = try fixture.source().beginFocus(fixture.child)
            let presentation = try XCTUnwrap(fixture.host.pickerFocus)
            fixture.parent.resignKey()
            let keyCalls = fixture.parent.keyCalls
            fixture.child.shown = false
            fixture.host.finishPickerFocus(presentation, current: active ? foreign : fixture.child, appActive: active)
            XCTAssertNil(fixture.host.focusedSurface)
            XCTAssertNil(fixture.policy.activeLease)
            XCTAssertEqual(fixture.parent.keyCalls, keyCalls)
            XCTAssertEqual(previous.keyCalls, 0)
            XCTAssertFalse(OwnedWindowRegistry.shared.contains(window: fixture.child))
        }
    }

    func testChooserUsesOneSourceLeaseWithoutInventingAChildWindow() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.focus()
        let end = try fixture.source().beginFocus(nil)
        let focus = try XCTUnwrap(fixture.host.pickerFocus)
        XCTAssertNil(focus.child)
        XCTAssertTrue(fixture.host.retainsPickerFocus(on: fixture.widget.surface))
        let calls = fixture.parent.keyCalls
        fixture.host.finishPickerFocus(focus, current: fixture.parent, appActive: true, resume: false)
        XCTAssertNil(fixture.host.pickerFocus)
        XCTAssertNil(fixture.host.focusedSurface)
        XCTAssertEqual(fixture.parent.keyCalls, calls)
        end(false)
        XCTAssertNil(fixture.host.focusedSurface)
    }
}
