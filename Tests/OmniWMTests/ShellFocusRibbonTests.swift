// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellFocusRibbonTests: XCTestCase {
    private struct Window {
        var id: String
        var bundle = "com.apple.Safari"
        var name = "Safari"
        var title: String
        var column: Int

        var value: ShellServiceValue {
            .object([
                "id": .text(id), "bundle": .text(bundle), "name": .text(name), "title": .text(title),
                "column": .number(Double(column))
            ])
        }
    }

    private struct Timer {
        let owner: omni_owner_token
        let id: UInt64
        let revision: UInt64
        let seconds: Double
        let cancelled: Bool
    }

    @MainActor
    private final class Fixture {
        let widget: ShellRenderedWidget
        var workspace = "workspace-1"
        var name = "1"
        var layout = "niri"
        var focused: String? = "ow_a"
        var windows = [
            Window(id: "ow_a", title: "First tab", column: 1),
            Window(id: "ow_b", title: "Second tab", column: 2),
            Window(id: "ow_c", bundle: "com.apple.Terminal", name: "Terminal", title: "Build", column: 2)
        ]
        let notch: Bool
        var hoverEvents: [ShellEvent] = []

        init(notch: Bool = false) throws {
            self.notch = notch
            let folder = try XCTUnwrap(ShellDefaults.bundledStyles).appendingPathComponent("system")
            let source = try String(
                contentsOf: folder.appendingPathComponent("widgets/focus-ribbon/init.luau"), encoding: .utf8
            )
            widget = try ShellRenderedWidget(
                name: "focus-ribbon", source: source, directories: [folder],
                chunk: "@system/widgets/focus-ribbon/init.luau"
            )
            widget.surface.onAction = { [weak self] click in
                guard let self, click.event.kind == .hover else { return }
                hoverEvents.append(click.event)
                XCTAssertTrue(widget.invoke(click.action, event: click.event).isEmpty)
            }
        }

        var tree: [TreeNode] {
            widget.tree()
        }

        func render(navigation: Bool = true) {
            let value: ShellServiceValue = .object([
                "display": .text("Studio"),
                "size": .object(["w": .number(620), "h": .number(200)]),
                "notch": notch ? .object(["x": .number(220), "w": .number(180), "h": .number(32)]) : .null,
                "menuBar": .number(32), "scale": .number(2), "main": .bool(true), "visible": .bool(true),
                "fullscreen": .bool(false), "focused": .bool(false),
                "navigation": navigation ? .object([
                    "workspace": .text(workspace), "name": .text(name), "layout": .text(layout),
                    "focused": focused.map { .text($0) } ?? .null, "windows": .array(windows.map(\.value))
                ]) : .null
            ])
            widget.set("island") { value.write(to: &$0) }
            widget.render(ShellBarData())
        }

        func panel() throws -> TreeNode {
            try XCTUnwrap(tree.first { $0.paint.fill == Color(packed: 0x08090BFF) })
        }

        func hover(at point: CGPoint?) {
            widget.surface.hover(at: point)
            render()
        }

        func toggle() throws {
            let context = try XCTUnwrap(tree.first { $0.content.action != 0 && $0.layout.height == 36 })
            XCTAssertTrue(widget.invoke(context.content.action).isEmpty)
            render()
        }

        func windowElement(_ window: Window) throws -> ElementHandle {
            try XCTUnwrap(widget.surface.layout.core.elements {
                widget.text.string($0.help) == "\(window.name) — \(window.title)" && $0.action != 0
            }.first)
        }

        func iconFrame(_ window: Window) throws -> CGRect {
            let tile = try windowElement(window)
            let resolved = widget.surface.layout.core.firstDescendant(of: tile) {
                $0.iconSource == .bundle && widget.text.string($0.text) == window.bundle
            }
            let icon = try XCTUnwrap(resolved == .none ? nil : resolved)
            XCTAssertEqual(widget.surface.layout.core.kind(of: icon), .image)
            let frame = CGRect(widget.surface.layout.core.absoluteFrame(of: icon))
            let scale = CGFloat(widget.surface.layout.core.paint(of: icon).scale)
            return CGRect(
                x: frame.midX - frame.width * scale / 2,
                y: frame.midY - frame.height * scale / 2,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }

        func viewportFrame() throws -> CGRect {
            let viewport = try XCTUnwrap(widget.surface.layout.core.elements { _ in true }.first {
                let style = widget.surface.layout.core.layoutStyle(of: $0)
                return widget.surface.layout.core.kind(of: $0) == .path
                    && widget.surface.layout.core.paint(of: $0).masks
                    && style.width == 418 && style.height == 54
            })
            return CGRect(widget.surface.layout.core.absoluteFrame(of: viewport))
        }

        func drain() -> [Timer] {
            var request = omni_service_request()
            var timers: [Timer] = []
            while omni_vm_next_service(widget.vm, &request) {
                XCTAssertEqual(request.kind, OMNI_SERVICE_TIMER)
                timers.append(Timer(
                    owner: request.owner, id: request.id, revision: request.revision,
                    seconds: request.seconds, cancelled: request.cancelled
                ))
            }
            return timers
        }

        @discardableResult
        func complete(_ timer: Timer) -> Bool {
            var writer = ShellValueWriter()
            ShellServiceValue.object(["ok": .bool(true)]).write(to: &writer)
            var handled = false
            var error = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
                omni_vm_complete_service(
                    widget.vm, timer.owner, timer.id, timer.revision, $0.baseAddress, $0.count,
                    25_000_000, &handled, &error, error.count
                )
            }, OMNI_OK, String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            return handled
        }

        func openingTimer() throws -> Timer {
            let timers = drain().filter { !$0.cancelled }
            XCTAssertEqual(timers.count, 1)
            let timer = try XCTUnwrap(timers.first)
            XCTAssertEqual(timer.seconds, 2.6)
            return timer
        }
    }

    func testBaselineIsCompactAndNiriFocusExpandsWithNativeMotionWithoutKeyboardFocus() throws {
        for notch in [false, true] {
            let fixture = try Fixture(notch: notch)
            fixture.render()
            let compact = try fixture.panel()
            XCTAssertEqual(compact.layout.width, notch ? 400 : 256)
            XCTAssertEqual(compact.layout.height, 36)
            XCTAssertTrue(fixture.tree.allSatisfy {
                !$0.content.focusable && $0.content.keyAction == 0 && $0.content.keys == 0
            })
            XCTAssertTrue(fixture.drain().isEmpty)
            let icons = fixture.widget.surface.layout.core.elements { $0.iconSource == .bundle }
                .filter { fixture.widget.surface.layout.core.kind(of: $0) == .image }
            let icon = try XCTUnwrap(icons.first)
            let frame = CGRect(fixture.widget.surface.layout.core.absoluteFrame(of: icon))
            XCTAssertEqual(frame.midY, 18)
            if notch { XCTAssertFalse(frame.intersects(CGRect(x: 220, y: 0, width: 180, height: 32))) }
            try export(fixture, state: "compact-\(notch ? "notch" : "plain")")
            fixture.focused = "ow_b"
            fixture.render()
            let expanded = try fixture.panel()
            XCTAssertEqual(expanded.key, compact.key)
            XCTAssertEqual(expanded.layout.width, 450)
            XCTAssertEqual(expanded.layout.height, 130)
            try export(fixture, state: "expanded-\(notch ? "notch" : "plain")")
            XCTAssertGreaterThanOrEqual(fixture.tree.filter { $0.kind == .path && $0.paint.masks }.count, 2)
            for node in [compact, expanded] {
                XCTAssertNotEqual(node.content.motion, 0)
                XCTAssertEqual(node.content.motionCurve, UInt8(OMNI_CURVE_CUSTOM))
                let curve = fixture.widget.text.string(node.content.motionCurveRef).split(separator: ":")
                XCTAssertEqual(curve.count, 3)
                XCTAssertEqual(curve.first, "spring")
                if curve.count == 3 {
                    XCTAssertEqual(try XCTUnwrap(Double(curve[1])), 0.38, accuracy: 0.000001)
                    XCTAssertEqual(try XCTUnwrap(Double(curve[2])), 0.14, accuracy: 0.000001)
                }
            }
            XCTAssertTrue(fixture.tree.allSatisfy {
                !$0.content.focusable && $0.content.keyAction == 0 && $0.content.keys == 0
            })
            XCTAssertTrue(fixture.complete(try fixture.openingTimer()))
            fixture.render()
            XCTAssertEqual(try fixture.panel().layout.height, compact.layout.height)
            XCTAssertTrue(fixture.drain().isEmpty)
        }
    }

    func testRibbonKeepsSeparateWindowsForOneAppAndUsesTheOpaqueFocusAction() throws {
        let fixture = try Fixture()
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        let previousTimer = try fixture.openingTimer()
        let icons = fixture.tree.filter {
            $0.kind == .image && $0.content.iconSource == .bundle && $0.layout.width == 30
        }
        XCTAssertEqual(icons.count, fixture.windows.count)
        XCTAssertEqual(icons.filter { fixture.widget.text.string($0.content.text) == "com.apple.Safari" }.count, 2)
        var priorTimer = previousTimer
        var targets: Set<ElementHandle> = []
        for window in fixture.windows {
            let tile = try XCTUnwrap(fixture.tree.first {
                fixture.widget.text.string($0.content.help) == "\(window.name) — \(window.title)" && $0.content
                    .action != 0
            })
            targets.insert(try fixture.windowElement(window))
            XCTAssertNotEqual(tile.content.action & OMNI_ACTION_HANDLER, 0)
            XCTAssertEqual(fixture.widget.invoke(tile.content.action), ["window focus \(window.id)"])
            let timers = fixture.drain()
            XCTAssertEqual(timers.filter(\.cancelled).map(\.id), [priorTimer.id])
            XCTAssertEqual(timers.filter { !$0.cancelled }.count, 1)
            priorTimer = try XCTUnwrap(timers.first { !$0.cancelled })
        }
        XCTAssertEqual(targets.count, fixture.windows.count)
    }

    func testWorkspaceSwitchExpandsForDwindleAndEmptyWorkspaces() throws {
        let fixture = try Fixture()
        fixture.layout = "dwindle"
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.workspace = "workspace-2"
        fixture.name = "2"
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        XCTAssertTrue(fixture.complete(try fixture.openingTimer()))
        fixture.render()
        fixture.workspace = "workspace-3"
        fixture.name = "3"
        fixture.focused = nil
        fixture.windows = []
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        XCTAssertTrue(fixture.widget.strings().contains(ShellLocalizer.string("No windows", [])))
        XCTAssertFalse(fixture.tree.contains { $0.kind == .image })
        try export(fixture, state: "empty")
        XCTAssertTrue(fixture.complete(try fixture.openingTimer()))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
    }

    func testMetadataAndWindowListUpdatesNeitherResetTheDeadlineNorReopenTheRibbon() throws {
        let fixture = try Fixture()
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        let timer = try fixture.openingTimer()
        fixture.windows[1].title = "Updated title"
        fixture.windows.append(Window(id: "ow_d", title: "Another tab", column: 3))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        XCTAssertTrue(fixture.tree.contains {
            $0.kind == .label && fixture.widget.text.string($0.content.text) == "Updated title"
        })
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertTrue(fixture.complete(timer))
        fixture.render()
        fixture.windows.removeFirst()
        fixture.windows[0].title = "Final title"
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testHoverPausesCollapseAcrossChildrenAndRestartsTheDeadlineOnExit() throws {
        let fixture = try Fixture()
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        let original = try fixture.openingTimer()
        fixture.hover(at: CGPoint(x: 310, y: 18))
        let entered = fixture.drain()
        XCTAssertEqual(entered.map(\.id), [original.id])
        XCTAssertTrue(entered.allSatisfy(\.cancelled))
        XCTAssertFalse(fixture.complete(original))
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        for window in fixture.windows {
            let frame = try fixture.iconFrame(window)
            fixture.hover(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        let caption = try XCTUnwrap(fixture.widget.surface.layout.core.elements {
            fixture.widget.text.string($0.text) == "Second tab"
        }.first)
        let frame = CGRect(fixture.widget.surface.layout.core.absoluteFrame(of: caption))
        fixture.hover(at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertEqual(fixture.hoverEvents.map(\.phase), [.began])
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.hover(at: nil)
        XCTAssertEqual(fixture.hoverEvents.map(\.phase), [.began, .ended])
        let resumed = try fixture.openingTimer()
        fixture.hover(at: CGPoint(x: 310, y: 18))
        let reentered = fixture.drain()
        XCTAssertEqual(reentered.map(\.id), [resumed.id])
        XCTAssertTrue(reentered.allSatisfy(\.cancelled))
        XCTAssertFalse(fixture.complete(resumed))
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        fixture.hover(at: nil)
        XCTAssertTrue(fixture.complete(try fixture.openingTimer()))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testNavigationAndWindowActionsKeepTheHoveredRibbonOpenWithoutTimers() throws {
        let fixture = try Fixture()
        fixture.render()
        fixture.hover(at: CGPoint(x: 310, y: 18))
        XCTAssertEqual(try fixture.panel().layout.height, 36)
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.focused = "ow_b"
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.workspace = "workspace-2"
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        XCTAssertTrue(fixture.drain().isEmpty)
        let target = try fixture.windowElement(fixture.windows[2])
        XCTAssertEqual(
            fixture.widget.invoke(fixture.widget.surface.layout.core.content(of: target).action),
            ["window focus ow_c"]
        )
        fixture.focused = "ow_c"
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        XCTAssertEqual(fixture.hoverEvents.map(\.phase), [.began])
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.hover(at: nil)
        XCTAssertTrue(fixture.complete(try fixture.openingTimer()))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
    }

    func testManualCollapseWhileHoveredStaysClosedOnExitAndCanReopen() throws {
        let fixture = try Fixture()
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        let original = try fixture.openingTimer()
        fixture.hover(at: CGPoint(x: 310, y: 18))
        let entered = fixture.drain()
        XCTAssertEqual(entered.map(\.id), [original.id])
        XCTAssertTrue(entered.allSatisfy(\.cancelled))
        try fixture.toggle()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
        XCTAssertEqual(fixture.hoverEvents.map(\.phase), [.began])
        fixture.hover(at: nil)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertFalse(fixture.complete(original))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
        fixture.hover(at: CGPoint(x: 310, y: 18))
        try fixture.toggle()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        XCTAssertTrue(fixture.drain().isEmpty)
        fixture.hover(at: nil)
        XCTAssertTrue(fixture.complete(try fixture.openingTimer()))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
    }

    func testCaptionUsesTheWindowTitleOrAppFallbackWithoutRepeatingPosition() throws {
        let fixture = try Fixture()
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        let timer = try fixture.openingTimer()
        for title in ["Second tab", "", "Safari"] {
            fixture.windows[1].title = title
            fixture.render()
            XCTAssertEqual(
                fixture.tree.filter { $0.kind == .label }.map { fixture.widget.text.string($0.content.text) },
                ["Safari", "1 · 2/2", title.isEmpty ? "Safari" : title]
            )
            XCTAssertTrue(fixture.drain().isEmpty)
        }
        XCTAssertTrue(fixture.complete(timer))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
    }

    func testNilFocusAndRestoringTheSameFocusDoNotReopenOrResetTheDeadline() throws {
        let fixture = try Fixture()
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        let timer = try fixture.openingTimer()
        fixture.focused = nil
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        XCTAssertTrue(fixture.drain().isEmpty)
        XCTAssertTrue(fixture.complete(timer))
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
        XCTAssertTrue(fixture.drain().isEmpty)
    }

    func testShortRibbonsStayCenteredAndLongRibbonsClampTheFocusedWindowAtTheEdges() throws {
        for notch in [false, true] {
            for count in [1, 3, 18] {
                let fixture = try Fixture(notch: notch)
                fixture.windows = (0 ..< count).map {
                    Window(id: "ow_\($0)", title: "Document \($0)", column: $0 + 1)
                }
                fixture.focused = nil
                fixture.render()
                var identities: [String: ElementHandle] = [:]
                var previousTimer: Timer?
                for selected in Set([0, count / 2, count - 1]).sorted() {
                    fixture.focused = fixture.windows[selected].id
                    fixture.render()
                    let requests = fixture.drain()
                    XCTAssertEqual(requests.filter(\.cancelled).map(\.id), previousTimer.map { [$0.id] } ?? [])
                    XCTAssertEqual(requests.filter { !$0.cancelled }.count, 1)
                    previousTimer = try XCTUnwrap(requests.first { !$0.cancelled })
                    XCTAssertEqual(previousTimer?.seconds, 2.6)
                    let viewport = try fixture.viewportFrame()
                    let frames = try fixture.windows.map { try fixture.iconFrame($0) }
                    if count < 18 {
                        XCTAssertEqual(
                            (try XCTUnwrap(frames.first).midX + XCTUnwrap(frames.last).midX) / 2,
                            viewport.midX
                        )
                        if count == 3 {
                            XCTAssertEqual(frames[0].midX, viewport.midX - 56)
                            XCTAssertEqual(frames[1].midX, viewport.midX)
                            XCTAssertEqual(frames[2].midX, viewport.midX + 56)
                        }
                    } else if selected == 0 {
                        XCTAssertEqual(frames[selected].midX, viewport.minX + 23)
                    } else if selected == count - 1 {
                        XCTAssertEqual(frames[selected].midX, viewport.maxX - 23)
                    } else {
                        XCTAssertEqual(frames[selected].midX, viewport.midX)
                    }
                    XCTAssertTrue(viewport.contains(frames[selected]))
                    for (index, window) in fixture.windows.enumerated() {
                        let target = try fixture.windowElement(window)
                        if let previous = identities[window.id] {
                            XCTAssertEqual(target, previous)
                        } else {
                            identities[window.id] = target
                        }
                        XCTAssertEqual(frames[index].width, 30)
                        XCTAssertEqual(frames[index].width, frames[index].height)
                        if index > 0 {
                            XCTAssertEqual(frames[index].midX - frames[index - 1].midX, 56)
                        }
                    }
                    XCTAssertEqual(fixture.widget.surface.size, CGSize(width: 620, height: 200))
                    XCTAssertEqual(fixture.tree.filter { $0.kind == .image && $0.layout.width == 30 }.count, count)
                    XCTAssertGreaterThanOrEqual(fixture.tree.filter { $0.kind == .path && $0.paint.masks }.count, 2)
                    if count == 18, selected > 0 {
                        XCTAssertTrue(fixture.tree.contains { $0.layout.width > 450 && $0.layout.dx < 0 })
                    }
                    XCTAssertTrue(fixture.tree.allSatisfy {
                        !$0.content.focusable && $0.content.keyAction == 0 && $0.content.keys == 0
                    })
                    try export(fixture, state: "restored-\(count)-\(selected)-\(notch ? "notch" : "plain")")
                }
                XCTAssertEqual(Set(identities.values).count, count)
                let last = try XCTUnwrap(fixture.windows.last)
                let target = try fixture.windowElement(last)
                let action = fixture.widget.surface.layout.core.content(of: target).action
                XCTAssertEqual(fixture.widget.invoke(action), ["window focus \(last.id)"])
                let requests = fixture.drain()
                XCTAssertEqual(requests.filter(\.cancelled).map(\.id), [try XCTUnwrap(previousTimer).id])
                XCTAssertEqual(requests.filter { !$0.cancelled }.count, 1)
                XCTAssertTrue(fixture.complete(try XCTUnwrap(requests.first { !$0.cancelled })))
                fixture.render()
                XCTAssertEqual(try fixture.panel().layout.height, 36)
                XCTAssertTrue(fixture.drain().isEmpty)
            }
        }
    }

    func testRibbonWithoutSelectionCentersShortListsAndStartsLongListsAtTheLeadingEdge() throws {
        for count in [3, 18] {
            let fixture = try Fixture()
            fixture.windows = (0 ..< count).map {
                Window(id: "ow_\($0)", title: "Document \($0)", column: $0 + 1)
            }
            fixture.focused = nil
            fixture.render()
            fixture.workspace = "workspace-2"
            fixture.render()
            let frames = try fixture.windows.map { try fixture.iconFrame($0) }
            let viewport = try fixture.viewportFrame()
            if count == 3 {
                XCTAssertEqual(
                    (try XCTUnwrap(frames.first).midX + XCTUnwrap(frames.last).midX) / 2,
                    viewport.midX
                )
            } else {
                XCTAssertEqual(try XCTUnwrap(frames.first).midX, viewport.minX + 23)
            }
            XCTAssertTrue(frames.allSatisfy { $0.width == 30 && $0.height == 30 })
            try export(fixture, state: "unselected-\(count)")
            XCTAssertTrue(fixture.complete(try fixture.openingTimer()))
        }
    }

    private func export(_ fixture: Fixture, state: String) throws {
        guard let path = ProcessInfo.processInfo.environment["OMNIWM_SHELL_SNAPSHOTS"] else { return }
        ShellLayerScene.engineQueue.sync {}
        let surface = fixture.widget.surface
        let size = surface.size
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height)))
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 2, y: -2)
        try XCTUnwrap(surface.view.layer).render(in: context)
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("system-focus-ribbon-\(state).png") as CFURL,
            UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), state)
    }

    func testNewNavigationCancelsTheOldTimerAndMissingNavigationResetsTheBaseline() throws {
        let fixture = try Fixture()
        fixture.render()
        fixture.focused = "ow_b"
        fixture.render()
        let old = try fixture.openingTimer()
        fixture.focused = "ow_c"
        fixture.render()
        let requests = fixture.drain()
        XCTAssertEqual(requests.filter(\.cancelled).map(\.id), [old.id])
        let current = try XCTUnwrap(requests.first { !$0.cancelled })
        XCTAssertFalse(fixture.complete(old))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 130)
        fixture.render(navigation: false)
        XCTAssertEqual(fixture.widget.surface.size, .zero)
        XCTAssertEqual(fixture.drain().filter(\.cancelled).map(\.id), [current.id])
        XCTAssertFalse(fixture.complete(current))
        fixture.render()
        XCTAssertEqual(try fixture.panel().layout.height, 36)
        XCTAssertTrue(fixture.drain().isEmpty)
    }
}
