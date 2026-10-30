// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class ShellManipulationGeometryTests: XCTestCase {
    private func recipe(
        mode: ShellManipulationRecipe.Mode = .move,
        resizeMask: UInt8 = 0,
        maximum: CGSize = CGSize(width: 600, height: 400)
    ) throws -> ShellManipulationRecipe {
        try XCTUnwrap(ShellManipulationRecipe(
            mode: mode,
            target: 42,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400),
            minimum: CGSize(width: 80, height: 60),
            maximum: maximum,
            resizeMask: resizeMask
        ))
    }

    func testMovementUsesIndependentSignedAxesAndKeepsCapturedOrigin() throws {
        let recipe = try recipe()
        let start = CGRect(x: 100, y: 100, width: 150, height: 100)
        XCTAssertEqual(
            ShellManipulationGeometry.sample(start: start, translation: CGPoint(x: 40, y: -30), recipe: recipe),
            CGRect(x: 140, y: 70, width: 150, height: 100)
        )
        XCTAssertEqual(ShellManipulationGeometry.sample(start: start, translation: .zero, recipe: recipe), start)
        XCTAssertEqual(
            ShellManipulationGeometry.sample(start: start, translation: CGPoint(x: -40, y: 30), recipe: recipe),
            CGRect(x: 60, y: 130, width: 150, height: 100)
        )
    }

    func testMovementClampsAllFourCanvasEdges() throws {
        let recipe = try recipe()
        let start = CGRect(x: 100, y: 100, width: 150, height: 100)
        XCTAssertEqual(
            ShellManipulationGeometry.moved(start: start, translation: CGPoint(x: -1000, y: -1000), recipe: recipe),
            CGRect(x: 0, y: 0, width: 150, height: 100)
        )
        XCTAssertEqual(
            ShellManipulationGeometry.moved(start: start, translation: CGPoint(x: 1000, y: 1000), recipe: recipe),
            CGRect(x: 450, y: 300, width: 150, height: 100)
        )
    }

    func testEightResizeHandlesKeepOppositeAnchors() throws {
        let start = CGRect(x: 100, y: 80, width: 200, height: 120)
        let cases: [(UInt8, CGRect)] = [
            (1, CGRect(x: 130, y: 80, width: 170, height: 120)),
            (2, CGRect(x: 100, y: 80, width: 230, height: 120)),
            (4, CGRect(x: 100, y: 100, width: 200, height: 100)),
            (8, CGRect(x: 100, y: 80, width: 200, height: 140)),
            (5, CGRect(x: 130, y: 100, width: 170, height: 100)),
            (6, CGRect(x: 100, y: 100, width: 230, height: 100)),
            (9, CGRect(x: 130, y: 80, width: 170, height: 140)),
            (10, CGRect(x: 100, y: 80, width: 230, height: 140))
        ]
        for (mask, expected) in cases {
            XCTAssertEqual(
                ShellManipulationGeometry.sample(
                    start: start,
                    translation: CGPoint(x: 30, y: 20),
                    recipe: try recipe(mode: .resize, resizeMask: mask)
                ),
                expected,
                String(mask)
            )
        }
    }

    func testResizeRespectsMinimumMaximumAndCanvasWithoutFlippingAnchor() throws {
        let start = CGRect(x: 100, y: 80, width: 200, height: 120)
        let northwest = try recipe(mode: .resize, resizeMask: 5, maximum: CGSize(width: 260, height: 180))
        XCTAssertEqual(
            ShellManipulationGeometry.resized(start: start, translation: CGPoint(x: 1000, y: 1000), recipe: northwest),
            CGRect(x: 220, y: 140, width: 80, height: 60)
        )
        XCTAssertEqual(
            ShellManipulationGeometry.resized(
                start: start,
                translation: CGPoint(x: -1000, y: -1000),
                recipe: northwest
            ),
            CGRect(x: 40, y: 20, width: 260, height: 180)
        )
        XCTAssertEqual(
            ShellManipulationGeometry.resized(
                start: start,
                translation: CGPoint(x: 1000, y: 1000),
                recipe: try recipe(mode: .resize, resizeMask: 10)
            ),
            CGRect(x: 100, y: 80, width: 500, height: 320)
        )
    }

    func testResizeReleaseNearAnEdgeKeepsItsOppositeAnchorAndExactPreview() throws {
        let top = try XCTUnwrap(ShellManipulationRecipe(
            mode: .resize,
            target: 42,
            bounds: CGRect(x: 0, y: 32, width: 1400, height: 868),
            minimum: CGSize(width: 300, height: 270),
            maximum: CGSize(width: 520, height: 440),
            resizeMask: 4
        ))
        let preview = try XCTUnwrap(ShellManipulationGeometry.resized(
            start: CGRect(x: 530, y: 32, width: 340, height: 290),
            translation: CGPoint(x: 0, y: 10),
            recipe: top
        ))
        XCTAssertEqual(preview, CGRect(x: 530, y: 42, width: 340, height: 280))
        let proposal = try XCTUnwrap(ShellManipulationGeometry.proposal(rect: preview, recipe: top))
        XCTAssertEqual(proposal.rect, preview)
        XCTAssertEqual(proposal.rect.maxY, 322)
        let left = try recipe(mode: .resize, resizeMask: 1)
        let leftPreview = try XCTUnwrap(ShellManipulationGeometry.resized(
            start: CGRect(x: 30, y: 100, width: 200, height: 120),
            translation: CGPoint(x: -10, y: 0),
            recipe: left
        ))
        let leftProposal = try XCTUnwrap(ShellManipulationGeometry.proposal(rect: leftPreview, recipe: left))
        XCTAssertEqual(leftProposal.rect, CGRect(x: 20, y: 100, width: 210, height: 120))
        XCTAssertEqual(leftProposal.rect.maxX, 230)
    }

    func testMoveReleaseNearAnEdgeStaysWhereDropped() throws {
        let recipe = try recipe()
        for rect in [
            CGRect(x: 24, y: 100, width: 100, height: 80),
            CGRect(x: 10, y: 10, width: 100, height: 80),
            CGRect(x: 0, y: 0, width: 100, height: 400)
        ] {
            XCTAssertEqual(
                ShellManipulationGeometry.proposal(rect: rect, recipe: recipe),
                ShellManipulationProposal(rect: rect)
            )
        }
    }

    func testClampHandlesShiftedBoundsAndOversizedRestoreGeometry() {
        XCTAssertEqual(
            ShellManipulationGeometry.clamped(
                CGRect(x: -100, y: 900, width: 900, height: 600),
                to: CGRect(x: 20, y: 30, width: 600, height: 400)
            ),
            CGRect(x: 20, y: 30, width: 600, height: 400)
        )
    }

    func testInvalidGeometryAndWrongModeAreRejected() throws {
        let recipe = try recipe()
        let start = CGRect(x: 100, y: 100, width: 150, height: 100)
        XCTAssertNil(ShellManipulationGeometry.sample(
            start: start,
            translation: CGPoint(x: CGFloat.infinity, y: 0),
            recipe: recipe
        ))
        XCTAssertNil(ShellManipulationGeometry.sample(start: .zero, translation: .zero, recipe: recipe))
        XCTAssertNil(ShellManipulationGeometry.sample(
            start: CGRect(x: 100, y: 100, width: -150, height: 100), translation: .zero, recipe: recipe
        ))
        XCTAssertNil(ShellManipulationGeometry.clamped(
            CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
            to: recipe.bounds
        ))
        XCTAssertNil(ShellManipulationGeometry.proposal(rect: .null, recipe: recipe))
        XCTAssertNil(ShellManipulationGeometry.resized(start: start, translation: .zero, recipe: recipe))
        XCTAssertNil(ShellManipulationGeometry.moved(
            start: start, translation: .zero, recipe: try self.recipe(mode: .resize, resizeMask: 1)
        ))
    }
}

extension ShellManipulationGeometryTests {
    private var envelope: CGSize {
        CGSize(width: 353 * 1.242, height: 460 * 1.242)
    }

    private var deskInset: CGSize {
        CGSize(width: 6.5 / 353, height: 0)
    }

    private var southeast: UInt8 {
        ShellManipulationEdge.right.mask | ShellManipulationEdge.bottom.mask
    }

    private var northwest: UInt8 {
        ShellManipulationEdge.left.mask | ShellManipulationEdge.top.mask
    }

    private var northeast: UInt8 {
        ShellManipulationEdge.right.mask | ShellManipulationEdge.top.mask
    }

    private func scaleRecipe(_ corner: UInt8, inset: CGSize? = nil) -> ShellManipulationRecipe? {
        ShellManipulationRecipe(
            mode: .scale,
            target: 42,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            minimum: CGSize(width: envelope.width / 2, height: envelope.height / 2),
            maximum: envelope,
            resizeMask: corner,
            inset: inset ?? deskInset
        )
    }

    private func content(_ rect: CGRect, _ recipe: ShellManipulationRecipe) -> CGRect {
        ShellManipulationGeometry.content(of: rect, recipe: recipe)
    }

    func testScaleGainUsesTheContentBasisAndKeepsTheOppositeContentCorner() throws {
        let start = CGRect(origin: CGPoint(x: 1400, y: 60), size: envelope)
        let recipe = try XCTUnwrap(scaleRecipe(southeast))
        let shrunk = try XCTUnwrap(ShellManipulationGeometry.sample(
            start: start, translation: CGPoint(x: -100, y: -100), recipe: recipe
        ))
        let factor = shrunk.width / start.width
        XCTAssertEqual(factor, 0.7987, accuracy: 0.0001)
        XCTAssertEqual(shrunk.height / start.height, factor, accuracy: 1e-12)
        XCTAssertEqual(content(shrunk, recipe).minX, content(start, recipe).minX, accuracy: 1e-9)
        XCTAssertEqual(content(shrunk, recipe).minY, content(start, recipe).minY, accuracy: 1e-9)
        let proposal = try XCTUnwrap(ShellManipulationGeometry.proposal(rect: shrunk, recipe: recipe)).rect
        XCTAssertEqual(proposal.minX, shrunk.minX, accuracy: 1e-9)
        XCTAssertEqual(proposal.minY, shrunk.minY, accuracy: 1e-9)
        XCTAssertEqual(proposal.width, shrunk.width, accuracy: 1e-9)
        XCTAssertEqual(proposal.height, shrunk.height, accuracy: 1e-9)

        let envelopeBasis = try XCTUnwrap(ShellManipulationGeometry.scaled(
            start: start, translation: CGPoint(x: -100, y: -100), recipe: try XCTUnwrap(scaleRecipe(
                southeast,
                inset: .zero
            ))
        ))
        XCTAssertEqual(envelopeBasis.width / start.width, 0.8019, accuracy: 0.0001)

        let opposite = try XCTUnwrap(scaleRecipe(northwest))
        let pulled = try XCTUnwrap(ShellManipulationGeometry.scaled(
            start: start, translation: CGPoint(x: 100, y: 100), recipe: opposite
        ))
        XCTAssertEqual(pulled.width / start.width, factor, accuracy: 1e-12)
        XCTAssertEqual(content(pulled, opposite).maxX, content(start, opposite).maxX, accuracy: 1e-9)
        XCTAssertEqual(content(pulled, opposite).maxY, content(start, opposite).maxY, accuracy: 1e-9)
    }

    func testScaleFactorClampsToHalfAndFullSize() throws {
        let start = CGRect(origin: CGPoint(x: 1400, y: 60), size: envelope)
        let recipe = try XCTUnwrap(scaleRecipe(southeast))
        let smallest = try XCTUnwrap(ShellManipulationGeometry.scaled(
            start: start, translation: CGPoint(x: -1000, y: -1000), recipe: recipe
        ))
        XCTAssertEqual(smallest.width, envelope.width / 2, accuracy: 1e-9)
        XCTAssertEqual(smallest.height, envelope.height / 2, accuracy: 1e-9)
        XCTAssertEqual(content(smallest, recipe).minX, content(start, recipe).minX, accuracy: 1e-9)
        let largest = try XCTUnwrap(ShellManipulationGeometry.scaled(
            start: start, translation: CGPoint(x: 300, y: 300), recipe: recipe
        ))
        XCTAssertEqual(largest.width, envelope.width, accuracy: 1e-9)
        XCTAssertEqual(largest.height, envelope.height, accuracy: 1e-9)
    }

    func testScaleUpperClampNeverFallsBelowTheMinimumWhenRoomIsSmall() throws {
        let recipe = try XCTUnwrap(scaleRecipe(southeast))
        let start = CGRect(
            origin: CGPoint(x: 1820 - envelope.width * deskInset.width, y: 60),
            size: envelope
        )
        XCTAssertEqual(content(start, recipe).minX, 1820, accuracy: 1e-9)
        for translation in [CGPoint(x: 50, y: 50), .zero, CGPoint(x: -50, y: -50)] {
            let result = try XCTUnwrap(ShellManipulationGeometry.scaled(
                start: start, translation: translation, recipe: recipe
            ))
            XCTAssertEqual(result.width / start.width, 0.5, accuracy: 1e-12, "\(translation)")
            XCTAssertEqual(content(result, recipe).minX, 1820, accuracy: 1e-9)
            XCTAssertEqual(content(result, recipe).minY, content(start, recipe).minY, accuracy: 1e-9)
        }
    }

    func testScaleOutwardDragPastTheContentBoundIsClampedByRoom() throws {
        let recipe = try XCTUnwrap(scaleRecipe(northeast))
        let size = CGSize(width: envelope.width * 0.6, height: envelope.height * 0.6)
        let start = CGRect(
            origin: CGPoint(x: 600 - size.width * deskInset.width, y: 0.2 * size.height),
            size: size
        )
        let result = try XCTUnwrap(ShellManipulationGeometry.scaled(
            start: start, translation: CGPoint(x: 300, y: -300), recipe: recipe
        ))
        XCTAssertEqual(result.width / start.width, 1.2, accuracy: 1e-9)
        XCTAssertEqual(content(result, recipe).minY, recipe.bounds.minY, accuracy: 1e-9)
        XCTAssertEqual(content(result, recipe).minX, content(start, recipe).minX, accuracy: 1e-9)
        XCTAssertEqual(content(result, recipe).maxY, content(start, recipe).maxY, accuracy: 1e-9)
    }

    func testScaleAcceptsOnlyCornersAndInsetIsRejectedForResize() throws {
        for mask in [UInt8(0), 1, 2, 3, 4, 7, 8, 12, 15, 16] {
            XCTAssertNil(scaleRecipe(mask), String(mask))
        }
        let southwest = ShellManipulationEdge.left.mask | ShellManipulationEdge.bottom.mask
        for mask in [northwest, northeast, southwest, southeast] {
            XCTAssertNotNil(scaleRecipe(mask), String(mask))
        }
        func make(_ mode: ShellManipulationRecipe.Mode, mask: UInt8, inset: CGSize) -> ShellManipulationRecipe? {
            ShellManipulationRecipe(
                mode: mode,
                target: 42,
                bounds: CGRect(x: 0, y: 0, width: 600, height: 400),
                minimum: CGSize(width: 80, height: 60),
                maximum: CGSize(width: 600, height: 400),
                resizeMask: mask,
                inset: inset
            )
        }
        XCTAssertNil(make(.resize, mask: southeast, inset: CGSize(width: 0.1, height: 0)))
        XCTAssertNil(make(.resize, mask: 4, inset: CGSize(width: 0, height: 0.1)))
        XCTAssertNotNil(make(.resize, mask: southeast, inset: .zero))
        XCTAssertNotNil(make(.move, mask: 0, inset: CGSize(width: 0.49, height: 0.2)))
        XCTAssertNotNil(make(.scale, mask: southeast, inset: CGSize(width: 0.49, height: 0)))
        for value in [0.5, -0.01, .nan, .infinity] {
            XCTAssertNil(make(.move, mask: 0, inset: CGSize(width: value, height: 0)), String(value))
            XCTAssertNil(make(.scale, mask: southeast, inset: CGSize(width: 0, height: value)), String(value))
        }
        XCTAssertNil(ShellManipulationGeometry.scaled(
            start: CGRect(x: 100, y: 100, width: 150, height: 100), translation: .zero, recipe: try self.recipe()
        ))
    }

    func testMoveInsetClampsTheContentRectToBounds() throws {
        let recipe = try XCTUnwrap(ShellManipulationRecipe(
            mode: .move,
            target: 42,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400),
            minimum: CGSize(width: 80, height: 60),
            maximum: CGSize(width: 600, height: 400),
            resizeMask: 0,
            inset: CGSize(width: 0.25, height: 0.25)
        ))
        let start = CGRect(x: 100, y: 100, width: 150, height: 100)
        XCTAssertEqual(
            ShellManipulationGeometry.moved(start: start, translation: CGPoint(x: -1000, y: -1000), recipe: recipe),
            CGRect(x: -37.5, y: -25, width: 150, height: 100)
        )
        XCTAssertEqual(
            ShellManipulationGeometry.moved(start: start, translation: CGPoint(x: 1000, y: 1000), recipe: recipe),
            CGRect(x: 487.5, y: 325, width: 150, height: 100)
        )
        XCTAssertEqual(
            ShellManipulationGeometry.proposal(rect: CGRect(x: -37.5, y: -25, width: 150, height: 100), recipe: recipe),
            ShellManipulationProposal(rect: CGRect(x: -37.5, y: -25, width: 150, height: 100))
        )
    }
}
