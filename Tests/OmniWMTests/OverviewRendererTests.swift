// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
import CoreVideo
import Foundation
@testable import OmniWM
import QuartzCore
import XCTest

final class OverviewRendererTests: XCTestCase {
    func testDefaultPaletteUsesTransparentBackdropAndConfiguredBorderColors() {
        assertColor(OverviewRenderPalette.default.backdrop, equals: [0.05, 0.05, 0.08, 0])
        assertColor(OverviewRenderPalette.default.normalBorder, equals: [0.3, 0.3, 0.35, 0.5])
        assertColor(OverviewRenderPalette.default.hoveredBorder, equals: [0.4, 0.6, 1.0, 1.0])
        assertColor(OverviewRenderPalette.default.selectedBorder, equals: [0.3, 0.8, 0.4, 1.0])
    }

    func testPaletteClampsFiniteComponentsAndFallsBackForNonFiniteComponents() {
        let palette = OverviewRenderPalette(
            backdropColor: SettingsColor(red: .nan, green: -1, blue: 2, alpha: .infinity),
            normalBorderColor: SettingsColor(red: -.infinity, green: 0.4, blue: 0.5, alpha: 0.6),
            hoveredBorderColor: SettingsColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4),
            selectedBorderColor: SettingsColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 0.6)
        )

        assertColor(palette.backdrop, equals: [0.05, 0, 1, 0])
        assertColor(palette.normalBorder, equals: [0.3, 0.4, 0.5, 0.6])
        assertColor(palette.hoveredBorder, equals: [0.1, 0.2, 0.3, 0.4])
        assertColor(palette.selectedBorder, equals: [0.9, 0.8, 0.7, 0.6])
    }

    func testPaletteCarriesResolvedFocusBorderConfiguration() {
        let config = BorderConfig(
            enabled: true,
            width: 8,
            color: SettingsColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1),
            gradient: BorderGradient(
                enabled: true,
                start: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1),
                end: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1),
                direction: .topRightToBottomLeft,
                dark: nil
            ),
            glow: BorderGlow(enabled: true, radius: 12, opacity: 0.5)
        )
        let palette = OverviewRenderPalette(
            backdropColor: SettingsColor(red: 0, green: 0, blue: 0, alpha: 0),
            normalBorderColor: SettingsColor(red: 0, green: 0, blue: 0, alpha: 1),
            hoveredBorderColor: SettingsColor(red: 0, green: 0, blue: 0, alpha: 1),
            selectedBorderColor: config.color,
            focusBorder: config
        )
        XCTAssertEqual(palette.focusBorder, config)
    }

    func testSelectedBorderTakesPrecedenceOverHoveredAndNormalColors() {
        let palette = OverviewRenderPalette(
            backdropColor: SettingsColor(red: 0, green: 0, blue: 0, alpha: 1),
            normalBorderColor: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1),
            hoveredBorderColor: SettingsColor(red: 0, green: 1, blue: 0, alpha: 1),
            selectedBorderColor: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)
        )
        assertColor(
            OverviewRenderer.borderColor(isSelected: false, isHovered: false, palette: palette),
            equals: [1, 0, 0, 1]
        )
        assertColor(
            OverviewRenderer.borderColor(isSelected: false, isHovered: true, palette: palette),
            equals: [0, 1, 0, 1]
        )
        assertColor(
            OverviewRenderer.borderColor(isSelected: true, isHovered: true, palette: palette),
            equals: [0, 0, 1, 1]
        )
    }

    func testVisibleContentRectTracksScrollDuringAnimation() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertEqual(
            OverviewRenderGeometry.visibleContentRect(bounds: bounds, scrollOffset: -320),
            CGRect(x: 0, y: -320, width: 1440, height: 900)
        )
    }

    func testCullingKeepsIntersectingFramesAndRejectsHiddenFrames() {
        let viewport = CGRect(x: 0, y: -320, width: 1440, height: 900)
        let visible = CGRect(x: 100, y: 100, width: 300, height: 200)
        let hidden = CGRect(x: 100, y: -700, width: 300, height: 200)

        XCTAssertTrue(OverviewRenderGeometry.shouldRender(frame: visible, visibleContentRect: viewport))
        XCTAssertFalse(OverviewRenderGeometry.shouldRender(frame: hidden, visibleContentRect: viewport))
    }

    func testSectionCullingIncludesInterpolatedAnimationFrame() {
        let token = WindowToken(pid: 1, windowId: 1)
        let workspaceId = UUID()
        let window = OverviewWindowItem(
            handle: WindowHandle(id: token),
            windowId: token.windowId,
            workspaceId: workspaceId,
            title: "Window",
            appName: "App",
            appIcon: nil,
            originalFrame: CGRect(x: 100, y: 100, width: 300, height: 200),
            overviewFrame: CGRect(x: 100, y: -1000, width: 300, height: 200),
            matchesSearch: true
        )
        let section = OverviewWorkspaceSection(
            workspaceId: workspaceId,
            name: "Workspace",
            windows: [window],
            sectionFrame: CGRect(x: 0, y: -1100, width: 1000, height: 400),
            labelFrame: CGRect(x: 20, y: -700, width: 960, height: 32),
            gridFrame: CGRect(x: 0, y: -1100, width: 1000, height: 400),
            isActive: true
        )
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertFalse(
            OverviewRenderGeometry.shouldRender(
                frame: section.sectionFrame.union(section.labelFrame),
                visibleContentRect: viewport
            )
        )
        XCTAssertTrue(
            OverviewRenderGeometry.shouldRender(
                frame: OverviewRenderGeometry.sectionCullingFrame(section, progress: 0.1),
                visibleContentRect: viewport
            )
        )
    }

    @MainActor
    func testLayoutCachesRasterizedApplicationIcon() {
        let bitmap = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let sourceImage = bitmap.makeImage()!
        let appIcon = NSImage(cgImage: sourceImage, size: NSSize(width: 4, height: 4))
        let workspaceId = UUID()
        let token = WindowToken(pid: 1, windowId: 1)
        let handle = WindowHandle(id: token)
        let data: OverviewWindowLayoutData = OverviewWindowLayoutData(
            token: token,
            workspaceId: workspaceId,
            title: "Window",
            appName: "App",
            appIcon: appIcon,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        let layout = OverviewLayoutCalculator(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scale: 1
        ).calculateLayout(
            workspaces: [OverviewWorkspaceLayoutItem(id: workspaceId, name: "Workspace", isActive: true)],
            windows: [handle: data],
            searchQuery: ""
        )

        XCTAssertEqual(layout.allWindows.first?.appIcon?.width, 4)
        XCTAssertEqual(layout.allWindows.first?.appIcon?.height, 4)
    }

    func testSectionCullingIncludesWorkspaceLabelFrame() {
        let sectionFrame = CGRect(x: 0, y: -500, width: 1000, height: 400)
        let labelFrame = CGRect(x: 20, y: -116, width: 960, height: 32)
        let viewport = CGRect(x: 0, y: -90, width: 1000, height: 800)

        let section = OverviewWorkspaceSection(
            workspaceId: WorkspaceDescriptor.ID(), name: "Label", windows: [],
            sectionFrame: sectionFrame, labelFrame: labelFrame, gridFrame: sectionFrame,
            isActive: false, displayId: nil
        )
        XCTAssertFalse(OverviewRenderGeometry.shouldRender(frame: sectionFrame, visibleContentRect: viewport))
        XCTAssertTrue(
            OverviewRenderGeometry.shouldRender(
                frame: OverviewRenderGeometry.sectionCullingFrame(section, progress: 1),
                visibleContentRect: viewport
            )
        )
    }

    @MainActor
    func testLayoutPublicationCanIncludePaletteInOneUpdate() {
        let palette = OverviewRenderPalette(
            backdropColor: SettingsColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5),
            normalBorderColor: SettingsColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 0.6),
            hoveredBorderColor: SettingsColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 0.7),
            selectedBorderColor: SettingsColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 0.8)
        )
        var layout = OverviewLayout()
        layout.scale = 1.25
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        view.updateLayout(
            layout,
            state: .open,
            searchQuery: "term",
            selectedWindowHandle: nil,
            palette: palette
        )

        XCTAssertEqual(view.layout.scale, 1.25)
        XCTAssertEqual(view.searchQuery, "term")
        assertColor(view.palette.backdrop, equals: [0.2, 0.3, 0.4, 0.5])
    }

    @MainActor
    func testNativeAnimationIsPanelLocalAndSurvivesDiscreteLayoutUpdates() {
        let first = OverviewView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayId: 101
        )
        let second = OverviewView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayId: 202
        )
        let (layout, item) = makeLayerLayout()
        let firstPanel = attach(first)
        let secondPanel = attach(second)
        defer {
            firstPanel.close()
            secondPanel.close()
        }
        let fixture = makeAnimationFixture()
        first.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        second.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        let firstTransition = OverviewNativeTransition(generation: 7, startTime: CACurrentMediaTime(), from: 0, to: 1)
        XCTAssertTrue(first.installAnimation(firstTransition, completion: OverviewAnimationCompletion(
            animator: fixture.animator, displayId: 101, generation: 7
        )))
        XCTAssertEqual(first.presentationProgress, 1)
        XCTAssertEqual(second.presentationProgress, 0)
        XCTAssertEqual(first.layerRenderer.activeTransition?.generation, 7)
        XCTAssertNil(second.layerRenderer.activeTransition)
        let originalAnimation = first.layerRenderer.windowLayers[item.handle]?.root
            .animation(forKey: "overview.position")

        let secondTransition = OverviewNativeTransition(generation: 8, startTime: CACurrentMediaTime(), from: 0, to: 1)
        XCTAssertTrue(second.installAnimation(secondTransition, completion: OverviewAnimationCompletion(
            animator: fixture.animator, displayId: 202, generation: 8
        )))
        first.updateLayout(layout, state: .opening, searchQuery: "updated", selectedWindowHandle: nil)
        first.updateLayer()

        XCTAssertEqual(first.layerRenderer.activeTransition?.generation, 7)
        XCTAssertEqual(second.layerRenderer.activeTransition?.generation, 8)
        XCTAssertEqual(
            first.layerRenderer.windowLayers[item.handle]?.root.animation(forKey: "overview.position")?.beginTime,
            originalAnimation?.beginTime
        )

        first.updateLayout(layout, state: .open, searchQuery: "updated", selectedWindowHandle: nil)
        XCTAssertEqual(first.presentationProgress, 1)
        XCTAssertNil(first.layerRenderer.activeTransition)
        XCTAssertEqual(second.layerRenderer.activeTransition?.generation, 8)
    }

    @MainActor
    func testOverviewFrameTraceRecordsOneSubmissionAcrossDiscreteLayerUpdates() {
        let view = OverviewView(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            displayId: 303
        )
        let panel = attach(view)
        defer { panel.close() }
        view.updateLayout(.init(), state: .opening, searchQuery: "", selectedWindowHandle: nil)
        let fixture = makeAnimationFixture { _, transition, completion in
            view.installAnimation(transition, completion: completion)
        }
        OverviewFrameTrace.shared.beginCapture()
        fixture.animator.startOpenAnimation(displayIds: [303])
        for _ in 0 ..< 3 { view.updateLayer() }
        fixture.animator.animationCompleted(displayId: 303, generation: fixture.animator.generation)
        OverviewFrameTrace.shared.endCapture()

        let trace = OverviewFrameTrace.shared.dump()
        XCTAssertEqual(trace.components(separatedBy: "event=animationSubmit").count - 1, 1)
        XCTAssertEqual(trace.components(separatedBy: "event=animationComplete").count - 1, 1)
        XCTAssertTrue(trace.contains("event=layerApply"))
        XCTAssertTrue(trace.contains("disp=303 gen=1 seq=0"))
        XCTAssertFalse(trace.contains("event=invalidation"))
    }

    @MainActor
    func testPresentProgressRendersInterpolatedModelWithoutNativeAnimation() throws {
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), displayId: 404)
        let (layout, item) = makeLayerLayout()
        let panel = attach(view)
        defer { panel.close() }
        let fixture = makeAnimationFixture()
        view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)

        view.presentProgress(0.4)
        view.updateLayer()

        let root = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle]?.root)
        let interpolated = item.interpolatedFrame(progress: 0.4)
        XCTAssertEqual(view.presentationProgress, 0.4)
        XCTAssertEqual(root.frame.origin.x, interpolated.origin.x)
        XCTAssertEqual(root.frame.origin.y, interpolated.origin.y)
        XCTAssertEqual(root.frame.width, interpolated.width)
        XCTAssertEqual(root.frame.height, interpolated.height)
        XCTAssertEqual(root.opacity, 0.4)
        XCTAssertNil(root.animation(forKey: "overview.position"))
        XCTAssertNil(view.layerRenderer.activeTransition)

        let transition = OverviewNativeTransition(
            generation: 3,
            startTime: CACurrentMediaTime(),
            from: 0.4,
            to: 1,
            initialVelocity: 2
        )
        XCTAssertTrue(view.installAnimation(transition, completion: OverviewAnimationCompletion(
            animator: fixture.animator, displayId: 404, generation: 3
        )))

        let position = try XCTUnwrap(root.animation(forKey: "overview.position") as? CASpringAnimation)
        let from = try XCTUnwrap((position.fromValue as? NSValue)?.pointValue)
        let to = try XCTUnwrap((position.toValue as? NSValue)?.pointValue)
        XCTAssertEqual(from.x, interpolated.midX)
        XCTAssertEqual(from.y, interpolated.midY)
        XCTAssertEqual(to.x, item.overviewFrame.midX)
        XCTAssertEqual(to.y, item.overviewFrame.midY)
        XCTAssertEqual(position.initialVelocity, 2 / 0.6)
        XCTAssertEqual(view.presentationProgress, 1)
    }

    @MainActor
    func testUnattachedViewSettlesAtEndpointWithoutInstallingNativeAnimation() {
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let (layout, item) = makeLayerLayout()
        let fixture = makeAnimationFixture()
        view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        let transition = OverviewNativeTransition(generation: 1, startTime: CACurrentMediaTime(), from: 0, to: 1)

        XCTAssertFalse(view.installAnimation(transition, completion: OverviewAnimationCompletion(
            animator: fixture.animator, displayId: 304, generation: 1
        )))

        XCTAssertEqual(view.presentationProgress, 1)
        XCTAssertNil(view.layerRenderer.activeTransition)
        XCTAssertEqual(view.layerRenderer.windowLayers[item.handle]?.root.frame, item.overviewFrame)
        XCTAssertNil(view.layerRenderer.windowLayers[item.handle]?.root.animation(forKey: "overview.position"))
    }

    @MainActor
    func testCardsKeepLayerIdentityAcrossAnimationAndSelection() throws {
        let (layout, item) = makeLayerLayout()
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panel = attach(view)
        defer { panel.close() }
        let fixture = makeAnimationFixture()
        view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        let card = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle])

        let transition = OverviewNativeTransition(generation: 1, startTime: CACurrentMediaTime(), from: 0, to: 1)
        XCTAssertTrue(view.installAnimation(transition, completion: OverviewAnimationCompletion(
            animator: fixture.animator, displayId: 1, generation: 1
        )))
        let animation = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual(
            (animation.fromValue as? NSValue)?.pointValue,
            CGPoint(x: item.originalFrame.midX, y: item.originalFrame.midY)
        )
        XCTAssertEqual(
            (animation.toValue as? NSValue)?.pointValue,
            CGPoint(x: item.overviewFrame.midX, y: item.overviewFrame.midY)
        )
        XCTAssertEqual(card.root.frame, item.overviewFrame)
        XCTAssertTrue(view.layerRenderer.windowLayers[item.handle] === card)

        view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: item.handle)
        view.updateLayer()
        XCTAssertTrue(view.layerRenderer.windowLayers[item.handle] === card)
        XCTAssertEqual(card.root.frame, item.overviewFrame)
        XCTAssertNil(card.root.animation(forKey: "overview.position"))
        XCTAssertTrue(view.wantsUpdateLayer)
    }

    @MainActor
    func testHoverTouchesOnlyPreviousAndCurrentCardEmphasis() throws {
        var (layout, first) = makeLayerLayout()
        let second = OverviewWindowItem(
            handle: WindowHandle(id: WindowToken(pid: 1, windowId: 2)),
            windowId: 2,
            workspaceId: first.workspaceId,
            title: "Second",
            appName: "App",
            appIcon: nil,
            originalFrame: first.originalFrame,
            overviewFrame: first.overviewFrame.offsetBy(dx: 220, dy: 0),
            matchesSearch: true
        )
        let third = OverviewWindowItem(
            handle: WindowHandle(id: WindowToken(pid: 1, windowId: 3)),
            windowId: 3,
            workspaceId: first.workspaceId,
            title: "Third",
            appName: "App",
            appIcon: nil,
            originalFrame: first.originalFrame,
            overviewFrame: first.overviewFrame.offsetBy(dx: 440, dy: 0),
            matchesSearch: true
        )
        var section = layout.workspaceSections[0]
        section.windows = [first, second, third]
        layout.replaceWorkspaceSections([section])
        let renderer = OverviewLayerRenderer()
        func state(_ hovered: WindowHandle, closeButtonHovered: Bool = false) -> OverviewRenderState {
            OverviewRenderState(
                searchQuery: "",
                selectedWindowHandle: nil,
                hoveredWindowHandle: hovered,
                closeButtonHovered: closeButtonHovered,
                progress: 1,
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                palette: .default
            )
        }
        renderer.updateLayout(layout, state: state(first.handle), caretAnimated: false)
        renderer.updatePresentation(layout, state: state(first.handle))
        let untouched = try XCTUnwrap(renderer.windowLayers[third.handle])
        let sentinelPosition = CGPoint(x: 501, y: 502)
        let sentinelColor = CGColor(red: 0.7, green: 0.1, blue: 0.2, alpha: 1)
        untouched.root.position = sentinelPosition
        untouched.border.borderColor = sentinelColor
        let previous = try XCTUnwrap(renderer.windowLayers[first.handle])
        let current = try XCTUnwrap(renderer.windowLayers[second.handle])

        renderer.updateHover(from: first.handle, layout: layout, state: state(second.handle))
        XCTAssertEqual(untouched.root.position, sentinelPosition)
        XCTAssertEqual(untouched.border.borderColor, sentinelColor)
        XCTAssertEqual(previous.border.borderColor, OverviewRenderPalette.default.normalBorder)
        XCTAssertEqual(current.border.borderColor, OverviewRenderPalette.default.hoveredBorder)

        renderer.updateHover(from: second.handle, layout: layout, state: state(second.handle, closeButtonHovered: true))
        XCTAssertEqual(untouched.root.position, sentinelPosition)
        XCTAssertEqual(untouched.border.borderColor, sentinelColor)
    }

    @MainActor
    func testPreviewContentsRemainRetainedAcrossGeometryAndMetadataChanges() throws {
        let (layout, item) = makeLayerLayout()
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panel = attach(view)
        defer { panel.close() }
        let fixture = makeAnimationFixture()
        view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            160,
            120,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        let frame = try XCTUnwrap(OverviewPreviewFrame(pixelBuffer: buffer))
        view.updatePreview(frame, for: item.handle)
        let card = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle])

        let transition = OverviewNativeTransition(generation: 1, startTime: CACurrentMediaTime(), from: 0, to: 1)
        XCTAssertTrue(view.installAnimation(transition, completion: OverviewAnimationCompletion(
            animator: fixture.animator, displayId: 1, generation: 1
        )))
        for width in [900.0, 1000.0, 1100.0, 1200.0] {
            view.setFrameSize(CGSize(width: width, height: 600))
            view.updateLayer()
        }
        view.updateLayout(layout, state: .open, searchQuery: "Window", selectedWindowHandle: item.handle)
        view.updateLayer()
        XCTAssertTrue(card.preview === frame)
        XCTAssertNotNil(card.thumbnail.contents)
        XCTAssertEqual(card.thumbnail.contentsRect, frame.contentsRect)

        view.clearPreviews()
        XCTAssertNil(card.preview)
        XCTAssertNil(card.thumbnail.contents)
    }

    @MainActor
    func testNewCardSeedsFromCachedPreview() throws {
        let (layout, item) = makeLayerLayout()
        let renderer = OverviewLayerRenderer()
        let cached = try makeOverviewPreviewFrame()
        renderer.previewForHandle = { handle in handle === item.handle ? cached : nil }
        let state = OverviewRenderState(
            searchQuery: "",
            selectedWindowHandle: nil,
            hoveredWindowHandle: nil,
            closeButtonHovered: false,
            progress: 1,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            palette: .default
        )

        renderer.updateLayout(layout, state: state, caretAnimated: false)

        let card = try XCTUnwrap(renderer.windowLayers[item.handle])
        XCTAssertTrue(card.preview === cached)
        XCTAssertNotNil(card.thumbnail.contents)

        let live = try makeOverviewPreviewFrame()
        renderer.updatePreview(live, for: item.handle)
        renderer.updateLayout(layout, state: state, caretAnimated: false)
        XCTAssertTrue(card.preview === live)
    }

    @MainActor
    func testCardsCullOffscreenWindowsAndRemoveRetiredLayers() throws {
        let (layout, item) = makeLayerLayout(overviewFrame: CGRect(x: 100, y: -1000, width: 200, height: 140))
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
        view.updateLayer()
        let card = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle])
        XCTAssertTrue(card.root.isHidden)

        view.updateLayout(.init(), state: .open, searchQuery: "", selectedWindowHandle: nil)
        XCTAssertTrue(view.layerRenderer.windowLayers.isEmpty)
        XCTAssertNil(card.root.superlayer)
    }

    @MainActor
    func testCaretUsesIndependentAnimationAndStopsForEmptySearchOrDisabledMotion() {
        let renderer = OverviewLayerRenderer()
        var layout = OverviewLayout()
        layout.searchBarFrame = CGRect(x: 20, y: 400, width: 400, height: 44)
        func state(_ query: String) -> OverviewRenderState {
            OverviewRenderState(
                searchQuery: query,
                selectedWindowHandle: nil,
                hoveredWindowHandle: nil,
                closeButtonHovered: false,
                progress: 1,
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                palette: .default
            )
        }
        renderer.updateLayout(layout, state: state("term"), caretAnimated: true)
        XCTAssertNotNil(renderer.caret.animation(forKey: "blink"))
        XCTAssertFalse(renderer.caret.isHidden)

        renderer.updateLayout(layout, state: state("term"), caretAnimated: false)
        XCTAssertNil(renderer.caret.animation(forKey: "blink"))
        XCTAssertEqual(renderer.caret.opacity, 1)

        renderer.updateLayout(layout, state: state(""), caretAnimated: true)
        XCTAssertNil(renderer.caret.animation(forKey: "blink"))
        XCTAssertTrue(renderer.caret.isHidden)
    }

    @MainActor
    func testStripAnchorPreviewStaysOpaqueAndPlaceholdersFade() throws {
        var (layout, item) = makeLayerLayout()
        layout.settleRestFrames(anchorWorkspaceId: item.workspaceId)
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        view.presentProgress(0.4)
        view.updateLayer()
        let card = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle])
        XCTAssertEqual(card.root.opacity, 0.4)

        view.updatePreview(try makeOverviewPreviewFrame(), for: item.handle)
        view.updateLayer()
        XCTAssertEqual(card.root.opacity, 1)

        layout.settleRestFrames(anchorWorkspaceId: nil)
        view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        view.updateLayer()
        XCTAssertEqual(card.root.opacity, 0.4)
    }

    @MainActor
    func testStripAnchorPreviewStillDimsForSearch() throws {
        var (layout, item) = makeLayerLayout(matchesSearch: false)
        layout.settleRestFrames(anchorWorkspaceId: item.workspaceId)
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.updateLayout(layout, state: .opening, searchQuery: "missing", selectedWindowHandle: nil)
        view.updatePreview(try makeOverviewPreviewFrame(), for: item.handle)
        view.presentProgress(0.4)
        view.updateLayer()
        let card = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle])
        XCTAssertEqual(card.root.opacity, 0.3)
    }

    @MainActor
    func testScrolledStripUsesProgressForContentOffsetAndCulling() throws {
        var (layout, item) = makeLayerLayout()
        layout.scrollOffset = -1000
        layout.settleRestFrames(anchorWorkspaceId: item.workspaceId)
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        let card = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle])
        let content = try XCTUnwrap(card.root.superlayer?.superlayer)

        for progress in [1.0, 0.4, 0.0] {
            view.presentProgress(progress)
            view.updateLayer()
            XCTAssertEqual(content.frame.minY, -layout.scrollOffset * progress)
        }
        XCTAssertFalse(card.root.isHidden)
        XCTAssertEqual(card.root.frame, item.originalFrame)
    }

    @MainActor
    func testStripTransitionKeepsMovingCardsAndContentSpringUntilCancelled() throws {
        var (layout, item) = makeLayerLayout(overviewFrame: CGRect(x: 100, y: -1000, width: 200, height: 140))
        var section = try XCTUnwrap(layout.workspaceSections.first)
        section.windows[0].restFrame = CGRect(x: 50, y: -2000, width: 600, height: 400)
        layout.replaceWorkspaceSections([section])
        layout.scrollOffset = -1000
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panel = attach(view)
        defer { panel.close() }
        let fixture = makeAnimationFixture()
        view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
        view.updateLayer()
        let card = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle])
        let content = try XCTUnwrap(card.root.superlayer?.superlayer)
        let transition = OverviewNativeTransition(generation: 1, startTime: CACurrentMediaTime(), from: 1, to: 0)

        XCTAssertTrue(view.installAnimation(transition, completion: OverviewAnimationCompletion(
            animator: fixture.animator, displayId: 1, generation: 1
        )))

        XCTAssertFalse(card.root.isHidden)
        XCTAssertEqual(card.root.frame, section.windows[0].restFrame)
        XCTAssertEqual(content.frame.minY, 0)
        let animation = try XCTUnwrap(content.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual(animation.stiffness, transition.makeAnimation(keyPath: "position").stiffness)
        XCTAssertEqual(animation.damping, transition.makeAnimation(keyPath: "position").damping)
        view.cancelAnimation()
        XCTAssertNil(content.animation(forKey: "overview.position"))
    }

    @MainActor
    func testGestureReleaseReanchorsFromDisplayedCardGeometry() throws {
        var (layout, item) = makeLayerLayout()
        var section = try XCTUnwrap(layout.workspaceSections.first)
        section.windows[0].restFrame = CGRect(x: 50, y: -1400, width: 600, height: 400)
        layout.replaceWorkspaceSections([section])
        layout.scrollOffset = -200
        let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let panel = attach(view)
        defer { panel.close() }
        let fixture = makeAnimationFixture()
        view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil)
        view.presentProgress(0.4)
        view.updateLayer()
        let card = try XCTUnwrap(view.layerRenderer.windowLayers[item.handle])
        let content = try XCTUnwrap(card.root.superlayer?.superlayer)
        let displayedPosition = card.root.position
        let displayedBounds = card.root.bounds
        let displayedContentPosition = content.position

        layout.settleRestFrames(anchorWorkspaceId: item.workspaceId)
        layout.scrollOffset = -100
        view.updateLayout(
            layout,
            state: .closing(targetWindow: item.handle),
            searchQuery: "",
            selectedWindowHandle: item.handle
        )
        let transition = OverviewNativeTransition(generation: 1, startTime: CACurrentMediaTime(), from: 0.4, to: 0)
        XCTAssertTrue(view.installAnimation(transition, completion: OverviewAnimationCompletion(
            animator: fixture.animator, displayId: 1, generation: 1
        )))

        let position = try XCTUnwrap(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
        let bounds = try XCTUnwrap(card.root.animation(forKey: "overview.bounds") as? CASpringAnimation)
        let contentMotion = try XCTUnwrap(content.animation(forKey: "overview.position") as? CASpringAnimation)
        XCTAssertEqual((position.fromValue as? NSValue)?.pointValue, displayedPosition)
        XCTAssertEqual((bounds.fromValue as? NSValue)?.rectValue, displayedBounds)
        XCTAssertEqual((contentMotion.fromValue as? NSValue)?.pointValue, displayedContentPosition)
        XCTAssertEqual(card.root.frame, item.originalFrame)
    }

    @MainActor
    private func attach(_ view: OverviewView) -> NSPanel {
        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        return panel
    }

    @MainActor
    private func makeAnimationFixture(
        installer: OverviewAnimator.AnimationInstaller? = nil
    ) -> (controller: WMController, overview: OverviewController, animator: OverviewAnimator) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewRendererTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let overview = OverviewController(wmController: controller, motionPolicy: controller.motionPolicy)
        let animator = OverviewAnimator(controller: overview, animationInstaller: installer)
        return (controller, overview, animator)
    }

    private func makeLayerLayout(
        overviewFrame: CGRect = CGRect(x: 100, y: 100, width: 200, height: 140),
        matchesSearch: Bool = true
    ) -> (OverviewLayout, OverviewWindowItem) {
        let workspaceId = UUID()
        let token = WindowToken(pid: 1, windowId: 1)
        let item = OverviewWindowItem(
            handle: WindowHandle(id: token),
            windowId: 1,
            workspaceId: workspaceId,
            title: "Window",
            appName: "App",
            appIcon: nil,
            originalFrame: CGRect(x: 50, y: 50, width: 600, height: 400),
            overviewFrame: overviewFrame,
            matchesSearch: matchesSearch
        )
        let section = OverviewWorkspaceSection(
            workspaceId: workspaceId,
            name: "Workspace",
            windows: [item],
            sectionFrame: overviewFrame,
            labelFrame: .zero,
            gridFrame: overviewFrame,
            isActive: true
        )
        var layout = OverviewLayout()
        layout.replaceWorkspaceSections([section])
        return (layout, item)
    }

    private func assertColor(
        _ color: CGColor,
        equals expected: [CGFloat],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let components = color.components else {
            XCTFail("Expected RGB color components", file: file, line: line)
            return
        }

        XCTAssertEqual(components.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(components, expected) {
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }
}
