// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import SwiftUI
import XCTest

@MainActor
final class WorkspaceBarThemedStripTests: XCTestCase {
    private let inset: CGFloat = 4
    private let tight = WorkspaceBarZoneLayout.tightSpacing
    private let neighbour: CGFloat = 24
    private let windows = [2, 1, 3, 0, 1, 2, 1, 1]
    private var shell: URL!

    override func setUp() async throws {
        shell = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertEqual(try ShellStyleFixture.prepare(into: shell), [])
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: shell)
    }

    func testAWaylineStripShortOfRoomScrollsToItsLastWorkspace() throws {
        try assertEveryWorkspaceComesIntoView(profile: "wayline")
    }

    func testACelestialStripShortOfRoomScrollsInsteadOfDisappearing() throws {
        try assertEveryWorkspaceComesIntoView(profile: "celestial")
    }

    func testThemedStripsOnAVerticalBarAreCutByJustTheOverflow() throws {
        for profile in ["wayline", "celestial"] {
            for shortage: CGFloat in [1, 200] {
                let label = "\(profile) \(shortage) pt short"
                let widget = try makeWidget(profile)
                widget.render(try bar(profile, vertical: true))
                let natural = widget.surface.naturalSize.height
                XCTAssertNil(widget.surface.layout.rootScroll, label)
                let host = try hostBar(widget, shown: natural - shortage, vertical: true)
                let clip = try XCTUnwrap(widget.surface.view.superview as? ShellWidgetClipView)
                XCTAssertEqual(clip.frame.height, natural - shortage, accuracy: 0.01, label)
                widget.surface.view.removeFromSuperview()
                withExtendedLifetime(host) {}
            }
        }
    }

    func testAScrollingColumnCutByAVerticalBarKeepsItsEndInTrailingWithoutScrolling() throws {
        let widget = try ShellRenderedWidget(name: "workspaces", source: """
        function render(ctx)
            return ui.column{scroll=true, gap=4, ui.box{w=20,h=60}, ui.box{w=20,h=60}, ui.box{w=20,h=60}}
        end
        """)
        widget.render(ShellBarData())
        let natural = widget.surface.naturalSize.height
        let host = try hostBar(widget, shown: natural - 40, vertical: true, lane: .trailing)
        let clip = try XCTUnwrap(widget.surface.view.superview as? ShellWidgetClipView)

        XCTAssertEqual(clip.frame.height, natural - 40, accuracy: 0.01)
        XCTAssertEqual(widget.surface.view.frame.minY, -40, accuracy: 0.01)
        XCTAssertNil(clip.layer?.mask)
        XCTAssertEqual(widget.surface.rootScroll?.limit ?? 0, 0, accuracy: 0.01)
        widget.surface.view.removeFromSuperview()
        withExtendedLifetime(host) {}
    }

    private func assertEveryWorkspaceComesIntoView(profile: String) throws {
        for shortage: CGFloat in [1, 160] {
            let label = "\(profile) \(shortage) pt short"
            let widget = try makeWidget(profile)
            let shown = try fit(widget, profile: profile, short: shortage)
            let host = try hostBar(widget, shown: shown, vertical: false)
            let surface = widget.surface
            let clip = try XCTUnwrap(surface.view.superview as? ShellWidgetClipView)
            XCTAssertEqual(clip.frame.width, shown, label)
            XCTAssertEqual(surface.rootScroll?.limit ?? 0, shortage, accuracy: 0.01, label)
            for id in ["8", "1", "5", "8"] {
                surface.followedTarget = "workspace \(id)"
                let pill = try pillFrame(id, in: widget)
                let clear = unfaded(clip)
                XCTAssertGreaterThanOrEqual(pill.minX, clear.lowerBound - 0.01, "\(label) workspace \(id)")
                XCTAssertLessThanOrEqual(pill.maxX, clear.upperBound + 0.01, "\(label) workspace \(id)")
            }

            XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, shortage, accuracy: 0.01, label)
            XCTAssertTrue(surface.scroll(
                at: CGPoint(x: shown / 2, y: surface.naturalSize.height / 2),
                event: ShellEvent(button: .none, modifiers: []),
                content: CGPoint(x: -shortage, y: 0)
            ), label)
            XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, 0, accuracy: 0.01, label)
            widget.render(try data(profile, room: shown))
            XCTAssertEqual(try XCTUnwrap(surface.rootScroll).offset, 0, accuracy: 0.01, label)
            XCTAssertEqual(unfaded(clip).lowerBound, 0, label)
            let fade = min(ShellWidgetSurface.scrollFade, shortage)
            XCTAssertEqual(unfaded(clip).upperBound, shown - fade, accuracy: 0.01, label)
            surface.view.removeFromSuperview()
            withExtendedLifetime(host) {}
        }
    }

    private func makeWidget(_ profile: String) throws -> ShellRenderedWidget {
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(profile: profile, shellDirectory: shell, problems: &problems))
        XCTAssertEqual(problems, [])
        let source = try ShellWidgetSourceLoader.build(.init(
            name: "workspaces", shellDirectory: shell,
            sourceURL: try XCTUnwrap(config.widget("workspaces") ?? ShellConfig.bundledWidget("workspaces")),
            directories: config.directories, profile: config.profile
        ))
        return try ShellRenderedWidget(source: source)
    }

    private func bar(_ profile: String, vertical: Bool = false) throws -> ShellBarData {
        var problems: [String] = []
        let config = try XCTUnwrap(ShellConfig.load(profile: profile, shellDirectory: shell, problems: &problems))
        let settings = config.barOverride?.settings
        var data = ShellBarData()
        data.style.height = try XCTUnwrap(settings?.height)
        data.style.labels = settings?.showLabels ?? true
        data.style.backgrounds = settings?.showItemBackgrounds ?? true
        data.style.accents = settings?.showAccentHighlights ?? true
        data.style.vertical = vertical
        data.style.position = vertical ? "left" : "top"
        data.workspaces = windows.enumerated().map { offset, count in
            let id = "\(offset + 1)"
            return ShellBarWorkspace(
                id: id, name: id, focused: offset == 0,
                windows: (0 ..< count).map { index in
                    ShellBarItem(
                        id: "app\(offset)_\(index)", bundle: "com.example.app\(index)", name: "App", focused: false,
                        count: 1, hidden: 0, floating: false,
                        windows: [ShellBarWindow(
                            id: "app\(offset)_\(index)_0", title: "Window", focused: false, hidden: false
                        )]
                    )
                }
            )
        }
        return data
    }

    private func data(_ profile: String, room: CGFloat) throws -> ShellBarData {
        var data = try bar(profile)
        data.workspacesRoom = Double(room)
        return data
    }

    private func fit(_ widget: ShellRenderedWidget, profile: String, short shortage: CGFloat) throws -> CGFloat {
        widget.render(try data(profile, room: 1))
        let shown = widget.surface.naturalSize.width - shortage
        widget.render(try data(profile, room: shown))
        XCTAssertEqual(widget.surface.naturalSize.width, shown + shortage, accuracy: 0.01, profile)
        return shown
    }

    private func hostBar(
        _ widget: ShellRenderedWidget, shown: CGFloat, vertical: Bool, lane: ShellLane = .leading
    ) throws -> NSView {
        let surface = widget.surface
        let natural = surface.naturalSize
        let neighbourSize = vertical
            ? CGSize(width: 20, height: neighbour)
            : CGSize(width: neighbour, height: 20)
        let model = WorkspaceBarModel(snapshot: WorkspaceBarSnapshot(
            projection: WorkspaceBarProjection(items: [], scratchpads: []),
            backgroundOpacity: 0.1,
            barHeight: vertical ? natural.width : natural.height,
            orientation: vertical ? .vertical : .horizontal,
            shellWidgets: [
                WorkspaceBarShellWidget(
                    id: "workspaces", size: natural, lane: lane, priority: 1,
                    stops: surface.layout.parts.stops(in: natural, vertical: vertical, keepsEnd: lane == .trailing)
                ),
                WorkspaceBarShellWidget(
                    id: "system-stats", size: neighbourSize, lane: lane == .trailing ? .leading : .trailing, priority: 0
                )
            ]
        ))
        model.zones = WorkspaceBarZones(notch: nil, mode: .off)
        let stats = NSView()
        let host = NSHostingView(rootView: WorkspaceBarView(
            model: model,
            motionPolicy: MotionPolicy(animationsEnabled: false),
            shellSurface: { $0 == "workspaces" ? surface.view : stats }
        ))
        let length = shown + inset * 2 + tight + neighbour
        host.frame = vertical
            ? CGRect(x: 0, y: 0, width: natural.width, height: length)
            : CGRect(x: 0, y: 0, width: length, height: natural.height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func pillFrame(_ id: String, in widget: ShellRenderedWidget) throws -> CGRect {
        let layout = widget.surface.layout
        let frame = layout.core.absoluteFrame(of: try XCTUnwrap(layout.handle(forKey: id), "workspace \(id)"))
        return CGRect(
            x: CGFloat(frame.x) + widget.surface.view.frame.minX,
            y: CGFloat(frame.y),
            width: CGFloat(frame.width),
            height: CGFloat(frame.height)
        )
    }

    private func unfaded(_ clip: ShellWidgetClipView) -> ClosedRange<CGFloat> {
        guard let stops = (clip.layer?.mask as? CAGradientLayer)?.locations?.map({ CGFloat($0.doubleValue) })
        else { return 0 ... clip.bounds.width }
        return stops[1] * clip.bounds.width ... stops[2] * clip.bounds.width
    }
}
