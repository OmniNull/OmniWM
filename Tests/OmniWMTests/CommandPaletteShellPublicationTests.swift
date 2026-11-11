// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteShellPublicationTests: XCTestCase {
    func testAnImageInANewlyPublishedRowWindowKeepsItsObservation() throws {
        let fixture = CommandPaletteFocusFixture { environment in
            environment.submitApplicationSearch = { _, _, _, _, _ in }
            environment.stopApplicationSearch = {}
        }
        defer { fixture.cleanup() }
        fixture.controller.settings.commandPalette.unifiedSearch = true
        fixture.controller.settings.commandPalette.searchedModes = [.applications]
        let panel = try fixture.show()
        let points = CommandPaletteController.shellIconPoints
        let scale = panel.backingScaleFactor
        let firstImage = try image(color: .red, points: points, scale: scale)
        let nextImage = try image(color: .blue, points: points, scale: scale)
        let boxes = seedRows(fixture, panel: panel, image: firstImage)
        defer { for box in boxes { box.image = nil } }
        fixture.palette.expandResults()
        fixture.palette.publishShellData()
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        let selections = fixture.palette.unifiedResults.selectionOrder
        let ids = selections.compactMap { fixture.palette.shellUnifiedRow($0)?.id }
        XCTAssertEqual(ids.count, boxes.count)
        let lineIDs = ["heading-unified-" + CommandPaletteMode.applications.rawValue] + ids
        try awaitPaletteTree(shell) { settled(shell, ids: lineIDs) }
        let target = try XCTUnwrap(ids.last)
        XCTAssertFalse(try XCTUnwrap(shell.published).rows.contains { $0.id == target })
        try scrollToEnd(shell, ids: lineIDs)
        try awaitPaletteTree(shell) {
            settled(shell, ids: lineIDs) && shell.published?.rows.last?.id == target
        }
        let previous = try XCTUnwrap(shell.published?.rows.first { $0.id == target }?.icon.bitmap)
        XCTAssertNotNil(shell.surface.resources.bitmap(previous))
        boxes[boxes.index(before: boxes.endIndex)].image = nextImage
        try awaitPaletteTree(shell) {
            guard shell.drawsPublishedList(), let row = shell.published?.rows.first(where: { $0.id == target }) else {
                return false
            }
            return row.icon.bitmap != nil && row.icon.bitmap != previous
        }
        let replacement = try XCTUnwrap(shell.published?.rows.first { $0.id == target }?.icon.bitmap)
        XCTAssertNotNil(shell.surface.resources.bitmap(replacement))
        XCTAssertNil(shell.surface.resources.bitmap(previous))
        XCTAssertTrue(fixture.palette.shellImageCache[selections[selections.index(before: selections.endIndex)]]?.image
            === nextImage)
    }

    private func seedRows(
        _ fixture: CommandPaletteFocusFixture, panel: NSPanel, image: NSImage
    ) -> [LauncherIconStore.ImageBox] {
        let items = (0 ..< 200).map { index in
            LauncherApplicationResult(
                bundleURL: fixture.root.appendingPathComponent("Application-\(index).app"),
                bundleIdentifier: nil, displayName: "Application \(index)"
            )
        }
        let boxes = items.map {
            LauncherIconStore.shared.applicationBox(
                for: $0, points: CommandPaletteController.shellIconPoints, scale: panel.backingScaleFactor
            )
        }
        for box in boxes { box.image = image }
        let selections = items.map { CommandPaletteSelectionID.application(.results, $0.id) }
        fixture.palette.searchText = "Application"
        fixture.palette.applicationSections = [.init(id: .results, title: "Applications", items: items)]
        fixture.palette.unifiedResults = .init(groups: [.init(mode: .applications, rows: selections, hasMore: false)])
        fixture.palette.selectedItemID = selections.first
        return boxes
    }

    private func settled(_ shell: CommandPaletteShellPresenter, ids: [String]) -> Bool {
        guard let data = shell.published, shell.drawsPublishedList(), shell.rowWindow.viewport > 0,
              data.total == ids.count
        else { return false }
        let slice = shell.slice(ids: ids, selected: nil, limit: Float(data.height))
        return data.first == slice.range.lowerBound && data.rows.count == slice.range.count
            && Float(data.before) == slice.before && Float(data.after) == slice.after
    }

    private func scrollToEnd(_ shell: CommandPaletteShellPresenter, ids: [String]) throws {
        let container = try XCTUnwrap(shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.resultsKey))
        let frame = CGRect(shell.surface.layout.core.absoluteFrame(of: container))
        let distance = ids.reduce(Float(0)) { $0 + shell.rowWindow.advance(of: $1) }
        XCTAssertTrue(shell.surface.scroll(
            at: CGPoint(x: frame.midX, y: frame.midY), event: ShellEvent(button: .none),
            content: CGPoint(x: 0, y: CGFloat(distance))
        ))
    }

    private func image(color: NSColor, points: CGFloat, scale: CGFloat) throws -> NSImage {
        let pixels = Int(points * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return try NSImage(cgImage: XCTUnwrap(context.makeImage()), size: CGSize(width: points, height: points))
    }
}
