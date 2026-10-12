// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class HiddenBarPanelGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testDrawerSitsFlushOnEveryWorkspaceBarEdgeWithEarsWhenItFits() {
        let bars: [(PopupAttachment.Edge, CGRect)] = [
            (.below, CGRect(x: 450, y: 760, width: 300, height: 24)),
            (.above, CGRect(x: 450, y: 16, width: 300, height: 24)),
            (.right, CGRect(x: 16, y: 250, width: 24, height: 300)),
            (.left, CGRect(x: 1160, y: 250, width: 24, height: 300))
        ]
        for (edge, bar) in bars {
            let vertical = edge == .left || edge == .right
            let layout = attachedPlacement(bar: bar, edge: edge)
                .layout(size: vertical ? CGSize(width: 24, height: 80) : CGSize(width: 80, height: 24))
            let body = screenRect(layout.body, in: layout)
            XCTAssertTrue(layout.hasEars, "\(edge)")
            XCTAssertFalse(layout.squaresBar, "\(edge)")
            XCTAssertFalse(body.intersects(bar), "\(edge)")
            switch edge {
            case .below:
                XCTAssertEqual(body.maxY, bar.minY)
                XCTAssertEqual(layout.frame.maxY, bar.minY)
            case .above:
                XCTAssertEqual(body.minY, bar.maxY)
                XCTAssertEqual(layout.frame.minY, bar.maxY)
            case .right:
                XCTAssertEqual(body.minX, bar.maxX)
                XCTAssertEqual(layout.frame.minX, bar.maxX)
            case .left:
                XCTAssertEqual(body.maxX, bar.minX)
                XCTAssertEqual(layout.frame.maxX, bar.minX)
            }
            XCTAssertTrue(screen.contains(layout.frame), "\(edge)")
        }
    }

    func testContourStaysInsidePanelAndOwnsItsJoin() throws {
        for edge in [PopupAttachment.Edge.below, .above, .left, .right] {
            let vertical = edge == .left || edge == .right
            for span in [CGFloat(116), 140, 141, 164, 300] {
                let bar = CGRect(x: 500, y: 350, width: vertical ? 24 : span, height: vertical ? span : 24)
                let size = vertical ? CGSize(width: 24, height: 100) : CGSize(width: 100, height: 24)
                let layout = attachedPlacement(bar: bar, edge: edge).layout(size: size)
                let contour = layout.contour(edge: edge)
                let bounds = CGRect(origin: .zero, size: layout.frame.size)
                let seam = try XCTUnwrap(layout.seam)
                XCTAssertTrue(bounds.contains(contour.boundingRect), "\(edge) \(span)")
                XCTAssertTrue(contour.contains(CGPoint(x: layout.body.midX, y: layout.body.midY)), "\(edge) \(span)")
                XCTAssertTrue(contour.contains(CGPoint(x: seam.midX, y: seam.midY)), "\(edge) \(span)")
                XCTAssertNotEqual(layout.hasEars, layout.squaresBar, "\(edge) \(span)")
            }
        }
    }

    func testEarsCurveIntoTheBarEdge() throws {
        let bar = CGRect(x: 450, y: 760, width: 300, height: 24)
        let layout = attachedPlacement(bar: bar, edge: .below).layout(size: CGSize(width: 80, height: 24))
        let contour = layout.contour(edge: .below)
        let body = layout.body

        XCTAssertTrue(contour.contains(CGPoint(x: body.minX - 1, y: body.minY + 1)))
        XCTAssertTrue(contour.contains(CGPoint(x: body.maxX + 1, y: body.minY + 1)))
        XCTAssertFalse(contour.contains(CGPoint(x: body.minX - 7, y: body.minY + 7)))
        XCTAssertFalse(contour.contains(CGPoint(x: body.maxX + 7, y: body.minY + 7)))
        XCTAssertEqual(try XCTUnwrap(layout.seam).width, body.width + 16)
    }

    func testDrawerTooWideForEarsMergesWithTheBar() throws {
        let bar = CGRect(x: 500, y: 760, width: 116, height: 24)
        let layout = attachedPlacement(bar: bar, edge: .below).layout(size: CGSize(width: 80, height: 24))
        let body = screenRect(layout.body, in: layout)

        XCTAssertFalse(layout.hasEars)
        XCTAssertTrue(layout.squaresBar)
        XCTAssertEqual(body.minX, bar.minX)
        XCTAssertEqual(body.maxX, bar.maxX)
        XCTAssertEqual(screenRect(try XCTUnwrap(layout.seam), in: layout).width, bar.width)
    }

    func testSolidBlackBarKeepsEarsUpToItsSquareEnds() {
        let bar = CGRect(x: 500, y: 760, width: 116, height: 24)
        let layout = attachedPlacement(bar: bar, edge: .below, style: .solidBlack)
            .layout(size: CGSize(width: 80, height: 24))

        XCTAssertTrue(layout.hasEars)
        XCTAssertFalse(layout.squaresBar)
    }

    func testDrawerWiderThanTheBarExtendsPastBothEnds() throws {
        let bar = CGRect(x: 500, y: 760, width: 116, height: 24)
        let reach = WorkspaceBarGeometry.cornerRadius * HiddenBarPanelPlacement.continuousCornerReach
        for (width, expected) in [(CGFloat(130), 116 + reach * 2), (200, 200)] {
            let layout = attachedPlacement(bar: bar, edge: .below).layout(size: CGSize(width: width, height: 24))
            let body = screenRect(layout.body, in: layout)
            XCTAssertTrue(layout.squaresBar)
            XCTAssertEqual(body.width, expected, accuracy: 0.001)
            XCTAssertEqual(body.midX, bar.midX, accuracy: 0.001)
            XCTAssertEqual(screenRect(try XCTUnwrap(layout.seam), in: layout).minX, bar.minX, accuracy: 0.001)
            XCTAssertEqual(screenRect(try XCTUnwrap(layout.seam), in: layout).maxX, bar.maxX, accuracy: 0.001)
        }
    }

    func testDrawerThicknessFollowsTheBar() {
        let top = attachedPlacement(bar: CGRect(x: 450, y: 760, width: 300, height: 28), edge: .below)
        let side = attachedPlacement(bar: CGRect(x: 16, y: 250, width: 30, height: 300), edge: .right)
        XCTAssertEqual(top.cellHeight, 24)
        XCTAssertEqual(side.cellHeight, 26)
        XCTAssertEqual(HiddenBarPanelController.barSize(itemWidths: [31, 34], placement: top).height, 28)
        XCTAssertEqual(HiddenBarPanelController.barSize(itemWidths: [31, 34], placement: side).height, 26 * 2 + 8)
    }

    func testSideAttachmentWrapsLongStripIntoColumnsWithinScreen() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 700)
        let bar = CGRect(x: 20, y: 200, width: 30, height: 300)
        let placement = attachedPlacement(bar: bar, edge: .right, screen: screen)
        let widths = Array(repeating: CGFloat(24), count: 40)
        let size = HiddenBarPanelController.barSize(itemWidths: widths, placement: placement)
        let layout = placement.layout(size: size)
        let body = screenRect(layout.body, in: layout)

        XCTAssertEqual(size, CGSize(width: 54, height: 684))
        XCTAssertEqual(
            HiddenBarPanelController.itemRanges(itemWidths: widths, placement: placement), [0 ..< 26, 26 ..< 40]
        )
        XCTAssertGreaterThanOrEqual(body.minY, screen.minY + 8)
        XCTAssertLessThanOrEqual(body.maxY, screen.maxY - 8)
        XCTAssertEqual(layout.frame.minX, bar.maxX)
        XCTAssertLessThanOrEqual(layout.frame.maxX, screen.maxX - 8)
    }

    func testSideBarsUseUprightVerticalStrips() {
        for (edge, x) in [(PopupAttachment.Edge.right, CGFloat(16)), (.left, CGFloat(1160))] {
            let placement = attachedPlacement(bar: CGRect(x: x, y: 250, width: 24, height: 300), edge: edge)
            XCTAssertTrue(placement.isVertical)
            XCTAssertEqual(
                HiddenBarPanelController.barSize(itemWidths: [24, 40, 24], placement: placement),
                CGSize(width: 44, height: 68)
            )
            XCTAssertEqual(
                HiddenBarPanelController.itemRanges(itemWidths: [24, 40, 24], placement: placement), [0 ..< 3]
            )
        }
    }

    func testTopAndBottomBarsKeepHorizontalRows() {
        for (edge, y) in [(PopupAttachment.Edge.below, CGFloat(760)), (.above, CGFloat(16))] {
            let placement = attachedPlacement(bar: CGRect(x: 450, y: y, width: 300, height: 24), edge: edge)
            XCTAssertFalse(placement.isVertical)
            XCTAssertEqual(
                HiddenBarPanelController.barSize(itemWidths: [24, 40, 24], placement: placement),
                CGSize(width: 96, height: 24)
            )
        }
    }

    func testVerticalColumnsKeepWideItemsAndPartialColumn() {
        let placement = attachedPlacement(
            bar: CGRect(x: 16, y: 16, width: 24, height: 40), edge: .right,
            screen: CGRect(x: 0, y: 0, width: 800, height: 72)
        )
        XCTAssertEqual(
            HiddenBarPanelController.itemRanges(itemWidths: [24, 40, 30], placement: placement),
            [0 ..< 2, 2 ..< 3]
        )
        XCTAssertEqual(
            HiddenBarPanelController.barSize(itemWidths: [24, 40, 30], placement: placement),
            CGSize(width: 76, height: 48)
        )
    }

    func testDetachedPanelKeepsExistingPopupPlacement() {
        let attachment = PopupAttachment(anchor: CGPoint(x: 600, y: 780))
        let placement = HiddenBarPanelPlacement(attachment: attachment, visibleFrame: screen)
        let size = CGSize(width: 140, height: 24)
        let layout = placement.layout(size: size)

        XCTAssertNil(layout.seam)
        XCTAssertFalse(layout.hasEars)
        XCTAssertFalse(layout.squaresBar)
        XCTAssertEqual(layout.frame, attachment.frame(size: size, visibleFrame: screen))
        XCTAssertEqual(layout.body, CGRect(origin: .zero, size: size))
    }

    func testNarrowScreenPinsToMinX() {
        let narrow = CGRect(x: 100, y: 0, width: 150, height: 900)
        let frame = PopupAttachment(anchor: CGPoint(x: 175, y: 900))
            .frame(size: CGSize(width: 200, height: 60), visibleFrame: narrow)
        XCTAssertEqual(frame.minX, narrow.minX + 8, accuracy: 0.5)
    }

    func testBarSizeEmptyIsCompact() {
        let size = HiddenBarPanelController.barSize(itemWidths: [], placement: detachedPlacement(maxContentWidth: 600))
        XCTAssertEqual(size, CGSize(width: 140, height: 24))
    }

    func testBarSizeSingleRowWhenItemsFit() {
        let size = HiddenBarPanelController.barSize(
            itemWidths: [30, 30, 30], placement: detachedPlacement(maxContentWidth: 600)
        )
        XCTAssertEqual(size, CGSize(width: 30 * 3 + 8, height: 20 + 4))
    }

    func testBarSizeWrapsWhenExceedingMaxWidth() {
        let size = HiddenBarPanelController.barSize(
            itemWidths: [30, 30, 30], placement: detachedPlacement(maxContentWidth: 70)
        )
        XCTAssertEqual(size.height, 20 * 2 + 2 + 4)
        XCTAssertEqual(size.width, 30 + 30 + 8)
    }

    func testRowRangesGreedyBoundaries() {
        let ranges = HiddenBarPanelController.rowRanges(itemWidths: [30, 30, 30], maxContentWidth: 70)
        XCTAssertEqual(ranges, [0 ..< 2, 2 ..< 3])
    }

    func testRowRangesOversizeItemGetsOwnRow() {
        let ranges = HiddenBarPanelController.rowRanges(itemWidths: [200, 30], maxContentWidth: 100)
        XCTAssertEqual(ranges, [0 ..< 1, 1 ..< 2])
    }

    func testGlyphDisplayWidthKeepsNativeWidth() {
        XCTAssertEqual(HiddenBarPanelController.glyphDisplayWidth(for: CGSize(width: 40, height: 40)), 40)
        XCTAssertEqual(HiddenBarPanelController.glyphDisplayWidth(for: CGSize(width: 30.2, height: 24)), 31)
    }

    func testGlyphDisplayWidthGuaranteesMinimumTarget() {
        XCTAssertEqual(HiddenBarPanelController.glyphDisplayWidth(for: CGSize(width: 16, height: 16)), 20)
    }

    private func detachedPlacement(maxContentWidth: CGFloat) -> HiddenBarPanelPlacement {
        HiddenBarPanelPlacement(
            attachment: PopupAttachment(anchor: CGPoint(x: 100, y: 800)),
            visibleFrame: CGRect(x: 0, y: 0, width: maxContentWidth + 24, height: 900)
        )
    }

    private func attachedPlacement(
        bar: CGRect,
        edge: PopupAttachment.Edge,
        screen: CGRect? = nil,
        style: WorkspaceBarSnapshot.BackgroundStyle = .material
    ) -> HiddenBarPanelPlacement {
        HiddenBarPanelPlacement(
            attachment: PopupAttachment(sourceFrame: bar, edge: edge), visibleFrame: screen ?? self.screen,
            workspaceBar: HiddenBarPanelPlacement.WorkspaceBar(
                monitorId: .init(displayId: 92_200),
                frame: bar, backgroundStyle: style, backgroundOpacity: 0.6
            )
        )
    }

    private func screenRect(_ local: CGRect, in layout: HiddenBarPanelLayout) -> CGRect {
        CGRect(
            x: layout.frame.minX + local.minX, y: layout.frame.maxY - local.maxY,
            width: local.width, height: local.height
        )
    }
}
