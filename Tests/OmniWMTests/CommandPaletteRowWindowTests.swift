// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class CommandPaletteRowWindowTests: XCTestCase {
    private let ids = (0 ..< 200).map { "row-\($0)" }
    private let viewport: Float = 300

    func testUnmeasuredRowsCoverTheLimitWithTheShortestRow() {
        let window = CommandPaletteRowWindow()
        let limit = viewport
        let slice = window.slice(ids: ids, selected: 0, limit: limit)
        let reach = 2 * limit
        let expected = Int((reach / CommandPaletteRowWindow.shortestRow).rounded(.up))
        XCTAssertEqual(slice.range, 0 ..< expected)
        XCTAssertEqual(slice.before, 0)
        XCTAssertEqual(
            slice.after,
            Float(ids.count - expected) * CommandPaletteRowWindow.shortestRow
        )
    }

    func testMeasuredAdvancesSizeTheSpacersAroundTheSlice() {
        var window = CommandPaletteRowWindow()
        let advance: Float = 50
        let gap: Float = 4
        _ = window.record(viewport: viewport, offset: 0, gap: gap)
        XCTAssertTrue(window.record(advance: advance, for: ids[0]))
        for id in ids.dropFirst() {
            XCTAssertFalse(window.record(advance: advance, for: id))
        }
        XCTAssertEqual(window.typical, advance)
        XCTAssertEqual(window.advances.count, ids.count)
        let middle = ids.count / 2
        _ = window.record(viewport: viewport, offset: Float(middle) * advance, gap: gap)
        let slice = window.slice(ids: ids, selected: nil, limit: viewport)
        let low = Float(middle) * advance - viewport
        let high = Float(middle) * advance + 2 * viewport
        let first = Int((low / advance).rounded(.down))
        let last = Int((high / advance).rounded(.up))
        XCTAssertEqual(slice.range, first ..< last)
        XCTAssertEqual(slice.before, Float(first) * advance - gap)
        XCTAssertEqual(slice.after, Float(ids.count - last) * advance - gap)
    }

    func testSelectionOutsideTheViewMovesTheSliceToWhereRevealWillScroll() {
        var window = CommandPaletteRowWindow()
        let advance: Float = 40
        _ = window.record(viewport: viewport, offset: 0, gap: 0)
        for id in ids {
            _ = window.record(advance: advance, for: id)
        }
        let last = ids.count - 1
        let slice = window.slice(ids: ids, selected: last, limit: viewport)
        XCTAssertEqual(slice.range.upperBound, ids.count)
        XCTAssertTrue(slice.range.contains(last))
        XCTAssertEqual(slice.after, 0)
        let revealedTop = Float(ids.count) * advance - viewport
        XCTAssertEqual(slice.range.lowerBound, Int(((revealedTop - viewport) / advance).rounded(.down)))
        XCTAssertEqual(slice.before, Float(slice.range.lowerBound) * advance)
    }

    func testAnOffsetBeyondAShorterListSlicesItsEnd() {
        var window = CommandPaletteRowWindow()
        let advance: Float = 40
        for id in ids {
            _ = window.record(advance: advance, for: id)
        }
        _ = window.record(viewport: viewport, offset: Float(ids.count) * advance - viewport, gap: 0)
        let fits = Array(ids.prefix(Int((viewport / advance).rounded(.down))))
        XCTAssertEqual(window.slice(ids: fits, selected: nil, limit: viewport).range, fits.indices)
        let longer = Array(ids.prefix(Int((4 * viewport / advance).rounded(.up))))
        let slice = window.slice(ids: longer, selected: nil, limit: viewport)
        let lastTop = Float(longer.count) * advance - viewport
        XCTAssertEqual(slice.range, Int(((lastTop - viewport) / advance).rounded(.down)) ..< longer.count)
        XCTAssertEqual(slice.after, 0)
    }

    func testTheFirstVisibleRowKeepsTheSliceAroundItWhenEstimatesChange() {
        var window = CommandPaletteRowWindow()
        let short: Float = 40
        let tall: Float = 60
        let measured = ids.count / 10
        for id in ids.prefix(measured) {
            _ = window.record(advance: short, for: id)
        }
        _ = window.record(viewport: viewport, offset: 0, gap: 0)
        let anchorIndex = ids.count * 3 / 4
        let anchorTop = -short / 2
        XCTAssertTrue(window.record(anchor: ids[anchorIndex], top: anchorTop))
        XCTAssertTrue(window.record(advance: tall, for: ids[ids.count - 1]))
        let typical = (Float(measured) * short + tall) / Float(measured + 1)
        XCTAssertEqual(window.typical, typical)
        let viewTop = Float(measured) * short + Float(anchorIndex - measured) * typical - anchorTop
        let slice = window.slice(ids: ids, selected: nil, limit: viewport)
        XCTAssertTrue(slice.range.contains(anchorIndex))
        XCTAssertLessThanOrEqual(slice.before, viewTop - viewport)
        XCTAssertGreaterThan(slice.before + typical, viewTop - viewport)
    }

    func testRecordingReportsOnlyRealChangesAndResetForgetsMeasurements() {
        var window = CommandPaletteRowWindow()
        XCTAssertTrue(window.record(viewport: viewport, offset: 0, gap: 0))
        XCTAssertFalse(window.record(viewport: viewport, offset: 0, gap: 0))
        XCTAssertTrue(window.record(viewport: viewport, offset: 1, gap: 0))
        XCTAssertFalse(window.record(advance: CommandPaletteRowWindow.shortestRow, for: ids[0]))
        XCTAssertTrue(window.record(advance: 2 * CommandPaletteRowWindow.shortestRow, for: ids[0]))
        XCTAssertTrue(window.record(advance: 4 * CommandPaletteRowWindow.shortestRow, for: ids[1]))
        XCTAssertEqual(window.typical, 3 * CommandPaletteRowWindow.shortestRow)
        XCTAssertTrue(window.record(anchor: ids[1], top: 0))
        XCTAssertFalse(window.record(anchor: ids[1], top: 0))
        XCTAssertTrue(window.record(anchor: nil, top: 0))
        window.reset()
        XCTAssertEqual(window, CommandPaletteRowWindow())
    }
}
