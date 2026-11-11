// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteShellMeasureTests: XCTestCase {
    func testRowMeasurementDoesNotDependOnTheSpacerAboveTheDrawnRows() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("widgets/\(ShellWidgetHost.commandPaletteWidget)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("init.luau")
        let rowHeight = Float(136) / 3
        try """
        function render(ctx) return ui.row{} end
        function popout(ctx)
            local m = ctx.data.commandPalette
            if not m then return ui.column{} end
            local list = { key = "\(CommandPaletteShellPresenter.resultsKey)", w = 200, h = 300, gap = 0, scroll = true }
            if m.before > 0 then list[#list + 1] = ui.box{ key = "results-before", w = 1, h = m.before } end
            for _, row in m.rows do list[#list + 1] = ui.box{ key = row.id, w = 200, h = \(rowHeight) } end
            return ui.column{ ui.input{ key = "\(CommandPaletteShellPresenter.queryKey)", text = m.query },
                ui.column(list) }
        end
        """.write(to: script, atomically: true, encoding: .utf8)
        let widget = try ShellWidgetSourceLoader.build(.init(
            name: ShellWidgetHost.commandPaletteWidget, shellDirectory: root, sourceURL: script,
            directories: [root], profile: "default"
        ))
        let shell = CommandPaletteShellPresenter(
            source: ShellCommandPaletteSource(
                config: ShellConfig(), bundled: true, fingerprint: [:], source: widget, directories: [],
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                permissions: ShellNetworkPermissions()
            ),
            scale: 2,
            fieldFrame: CGRect(x: 0, y: 0, width: 200, height: CommandPalettePanel.searchFieldHeight)
        ) { nil }
        defer { shell.close() }
        try awaitPaletteTree(shell) { shell.hasTree }

        var data = ShellCommandPaletteData()
        data.open = true
        data.rows = (0 ..< 12).map { index in
            .init(
                id: "row-\(index)", kind: .command, title: "Row \(index)", subtitle: "",
                icon: .init(app: nil, pid: nil, symbol: nil), badges: [], marks: [], hint: nil, hintShortcut: nil,
                selected: false, enabled: true
            )
        }
        var spacer = rowHeight * Float(data.rows.count) * Float(data.rows.count)
        let advances = { data.rows.map { shell.rowWindow.advance(of: $0.id) } }
        data.before = Double(spacer)
        shell.publish(data)
        try awaitPaletteTree(shell) { shell.published == data && shell.drawsPublishedList() }
        let measured = advances()
        XCTAssertEqual(Set(measured), [rowHeight])
        for _ in data.rows.indices {
            spacer = spacer.nextUp
            data.before = Double(spacer)
            shell.publish(data)
            try awaitPaletteTree(shell) { shell.published == data && shell.drawsPublishedList() }
            XCTAssertEqual(advances(), measured, "spacer \(spacer)")
        }
    }
}
