// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreVideo
import ImageIO
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    final class OverviewLayerCompositorLiveTests: XCTestCase {
        func testCompositorKeepsExpandedWallpaperBehindRibbonCards() async throws {
            guard CGPreflightScreenCaptureAccess()
            else { throw MissingTestPrerequisite("Screen Recording permission is required") }
            _ = NSApplication.shared
            let screen = try XCTUnwrap(NSScreen.main)
            let panel = NSPanel(
                contentRect: CGRect(x: screen.frame.midX - 400, y: screen.frame.midY - 180, width: 800, height: 360),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 800, height: 360))
            panel.contentView = view
            defer { panel.close() }
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            let wallpaper = try XCTUnwrap(context.makeImage())
            view.layerRenderer.wallpaperForDisplay = { _, _ in wallpaper }
            let workspaceId = UUID()
            let cards = [50.0, 630.0].enumerated().map { index, x in
                var item = OverviewWindowItem(
                    handle: WindowHandle(id: WindowToken(pid: getpid(), windowId: index + 1)),
                    windowId: index + 1, workspaceId: workspaceId, title: "Window \(index + 1)",
                    appName: "App", appIcon: nil, originalFrame: .zero,
                    overviewFrame: CGRect(x: x, y: 100, width: 100, height: 130), matchesSearch: true
                )
                item.isTiled = true
                return item
            }
            var layout = OverviewLayout()
            layout.replaceWorkspaceSections([OverviewWorkspaceSection(
                workspaceId: workspaceId, name: "Workspace", windows: cards,
                sectionFrame: CGRect(x: 0, y: 60, width: 800, height: 240), labelFrame: .zero, gridFrame: .zero,
                isActive: true, displayId: screen.displayId,
                visibleFrame: CGRect(x: 180, y: 60, width: 300, height: 220),
                ribbonFrame: CGRect(x: 20, y: 60, width: 760, height: 220)
            )])
            view.updateLayout(layout, state: .open, searchQuery: "", selectedWindowHandle: nil)
            view.updateLayer()
            panel.orderBack(nil)
            panel.displayIfNeeded()
            CATransaction.flush()
            let content = try await SCShareableContent.currentProcess
            let window = try XCTUnwrap(content.windows.first { Int($0.windowID) == panel.windowNumber })
            let config = SCStreamConfiguration()
            config.width = 800
            config.height = 360
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
            )
            let bitmap = try Bitmap(image: image)
            XCTAssertEqual(bitmap.color(at: CGPoint(x: 70, y: 80)), .blue)
            XCTAssertEqual(bitmap.color(at: CGPoint(x: 710, y: 80)), .blue)
            XCTAssertFalse(panel.isKeyWindow)
            if let path = ProcessInfo.processInfo.environment["OMNIWM_OVERVIEW_TEST_CAPTURE_PATH"] {
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
                ))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }

        func testCompositorPreservesPreviewCropOrientationAndTransparentBackdrop() async throws {
            guard CGPreflightScreenCaptureAccess()
            else { throw MissingTestPrerequisite("Screen Recording permission is required") }
            _ = NSApplication.shared
            let screen = try XCTUnwrap(NSScreen.main)
            let panel = NSPanel(
                contentRect: CGRect(x: screen.frame.midX - 240, y: screen.frame.midY - 180, width: 480, height: 360),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
            panel.contentView = view
            defer {
                view.clearPreviews()
                panel.close()
            }

            let handle = WindowHandle(id: WindowToken(pid: getpid(), windowId: 1))
            let cardFrame = CGRect(x: 80, y: 60, width: 320, height: 240)
            let layout = makeLayout(handle: handle, cardFrame: cardFrame)
            let palette = OverviewRenderPalette(
                backdropColor: SettingsColor(red: 0, green: 0, blue: 0, alpha: 0),
                normalBorderColor: SettingsColor(red: 1, green: 1, blue: 1, alpha: 1),
                hoveredBorderColor: SettingsColor(red: 1, green: 1, blue: 1, alpha: 1),
                selectedBorderColor: SettingsColor(red: 1, green: 1, blue: 1, alpha: 1)
            )
            view.updateLayout(
                layout, state: .open, searchQuery: "", selectedWindowHandle: nil,
                palette: palette, animationsEnabled: false
            )
            view.updatePreview(try makeQuadrantPreview(), for: handle)
            let card = try XCTUnwrap(view.layerRenderer.windowLayers[handle])
            XCTAssertNil(card.thumbnail.animation(forKey: "overview.previewReveal"))
            view.updateLayer()
            panel.orderBack(nil)
            panel.displayIfNeeded()
            CATransaction.flush()

            let content = try await SCShareableContent.currentProcess
            let window = try XCTUnwrap(content.windows.first { Int($0.windowID) == panel.windowNumber })
            let config = SCStreamConfiguration()
            config.width = 480
            config.height = 360
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config
            )
            let bitmap = try Bitmap(image: image)
            let preview = OverviewRenderGeometry.aspectFitRect(
                contentSize: CGSize(width: 320, height: 200), in: cardFrame.insetBy(dx: 1, dy: 1)
            )
            XCTAssertEqual(
                bitmap.color(at: CGPoint(
                    x: preview.minX + preview.width * 0.25,
                    y: preview.maxY - preview.height * 0.25
                )),
                .red
            )
            XCTAssertEqual(
                bitmap.color(at: CGPoint(
                    x: preview.minX + preview.width * 0.75,
                    y: preview.maxY - preview.height * 0.25
                )),
                .green
            )
            XCTAssertEqual(
                bitmap.color(at: CGPoint(
                    x: preview.minX + preview.width * 0.25,
                    y: preview.maxY - preview.height * 0.75
                )),
                .blue
            )
            XCTAssertEqual(
                bitmap.color(at: CGPoint(
                    x: preview.minX + preview.width * 0.75,
                    y: preview.maxY - preview.height * 0.75
                )),
                .yellow
            )
            XCTAssertEqual(bitmap.pixel(at: CGPoint(x: 20, y: 20)).3, 0)
            XCTAssertTrue(bitmap.hasWhitePixel(in: CGRect(
                x: cardFrame.minX + 38,
                y: cardFrame.minY + 18,
                width: 120,
                height: 16
            )))
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertFalse(panel.isMainWindow)
        }

        func testCompositorAnimatesCardGeometryAndHitTestingWithoutViewTicks() async throws {
            guard CGPreflightScreenCaptureAccess()
            else { throw MissingTestPrerequisite("Screen Recording permission is required") }
            _ = NSApplication.shared
            let screen = try XCTUnwrap(NSScreen.main)
            let panel = NSPanel(
                contentRect: CGRect(x: screen.frame.midX - 240, y: screen.frame.midY - 180, width: 480, height: 360),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            let view = OverviewView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
            panel.contentView = view
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let settings = SettingsStore(
                persistence: SettingsFilePersistence(
                    directory: directory.appendingPathComponent("config"),
                    startWatching: false,
                    deferSaves: false
                ),
                runtimeState: RuntimeStateStore(
                    directory: directory.appendingPathComponent("state"),
                    deferSaves: false
                ),
                autosaveEnabled: false
            )
            let controller = WMController(settings: settings)
            let overview = OverviewController(wmController: controller, motionPolicy: controller.motionPolicy)
            let animator = OverviewAnimator(controller: overview)
            defer {
                view.cancelAnimation()
                view.clearPreviews()
                panel.close()
                try? FileManager.default.removeItem(at: directory)
            }
            let handle = WindowHandle(id: WindowToken(pid: getpid(), windowId: 1))
            let original = CGRect(x: 10, y: 10, width: 460, height: 340)
            let destination = CGRect(x: 130, y: 100, width: 160, height: 120)
            let layout = makeLayout(handle: handle, cardFrame: destination, originalFrame: original)
            let clear = SettingsColor(red: 0, green: 0, blue: 0, alpha: 0)
            let white = SettingsColor(red: 1, green: 1, blue: 1, alpha: 1)
            let palette = OverviewRenderPalette(
                backdropColor: clear,
                normalBorderColor: white,
                hoveredBorderColor: white,
                selectedBorderColor: white
            )
            view.updateLayout(layout, state: .opening, searchQuery: "", selectedWindowHandle: nil, palette: palette)
            view.updatePreview(try makeQuadrantPreview(), for: handle)
            view.updateLayer()
            panel.orderBack(nil)
            panel.displayIfNeeded()
            CATransaction.flush()
            let start = CACurrentMediaTime()
            let transition = OverviewNativeTransition(generation: 1, startTime: start, from: 0, to: 1)
            let completion = OverviewAnimationCompletion(
                animator: animator,
                displayId: try XCTUnwrap(screen.displayId),
                generation: 1
            )
            XCTAssertTrue(view.installAnimation(transition, completion: completion))
            let elapsed = 0.05
            let host = try XCTUnwrap(view.layer)
            host.speed = 0
            host.timeOffset = start + elapsed
            CATransaction.flush()

            let content = try await SCShareableContent.currentProcess
            let window = try XCTUnwrap(content.windows.first { Int($0.windowID) == panel.windowNumber })
            let config = SCStreamConfiguration()
            config.width = 480
            config.height = 360
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.shouldBeOpaque = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: config
            )
            let bitmap = try Bitmap(image: image)
            let card = try XCTUnwrap(view.layerRenderer.windowLayers[handle])
            let displayed = try XCTUnwrap(card.root.presentation()).frame
            let expected = try XCTUnwrap(layout.window(for: handle))
                .interpolatedFrame(progress: transition.value(at: start + elapsed))
            XCTAssertEqual(displayed.minX, expected.minX, accuracy: 0.01)
            XCTAssertEqual(displayed.minY, expected.minY, accuracy: 0.01)
            XCTAssertEqual(displayed.width, expected.width, accuracy: 0.01)
            XCTAssertEqual(displayed.height, expected.height, accuracy: 0.01)
            let visiblePoint = CGPoint(x: displayed.minX + 5, y: displayed.midY)
            XCTAssertFalse(destination.contains(visiblePoint))
            XCTAssertTrue(view.layerRenderer.windowHit(at: visiblePoint, layout: layout)?.window.handle === handle)
            XCTAssertGreaterThan(bitmap.pixel(at: visiblePoint).3, 20)
            XCTAssertEqual(bitmap.pixel(at: CGPoint(x: 5, y: 5)).3, 0)
            XCTAssertNotNil(card.root.animation(forKey: "overview.position") as? CASpringAnimation)
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertFalse(panel.isMainWindow)
            withExtendedLifetime((controller, overview, animator)) {}
        }

        private func makeLayout(
            handle: WindowHandle,
            cardFrame: CGRect,
            originalFrame: CGRect? = nil
        ) -> OverviewLayout {
            let workspaceId = UUID()
            let item = OverviewWindowItem(
                handle: handle, windowId: 1, workspaceId: workspaceId,
                title: "Preview", appName: "Native", appIcon: nil,
                originalFrame: originalFrame ?? cardFrame, overviewFrame: cardFrame, matchesSearch: true
            )
            let section = OverviewWorkspaceSection(
                workspaceId: workspaceId, name: "Workspace", windows: [item],
                sectionFrame: cardFrame, labelFrame: .zero, gridFrame: cardFrame, isActive: true
            )
            var layout = OverviewLayout()
            layout.replaceWorkspaceSections([section])
            return layout
        }

        private func makeQuadrantPreview() throws -> OverviewPreviewFrame {
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            XCTAssertEqual(
                CVPixelBufferCreate(kCFAllocatorDefault, 400, 240, kCVPixelFormatType_32BGRA, attributes, &buffer),
                kCVReturnSuccess
            )
            let pixelBuffer = try XCTUnwrap(buffer)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(pixelBuffer, []), kCVReturnSuccess)
            do {
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
                let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                for row in 0 ..< 240 {
                    for column in 0 ..< 400 {
                        let inside = (40 ..< 360).contains(column) && (20 ..< 220).contains(row)
                        let right = column >= 200
                        let bottom = row >= 120
                        let red: UInt8 = !inside || (!bottom && !right) || (bottom && right) ? 255 : 0
                        let green: UInt8 = inside && right ? 255 : 0
                        let blue: UInt8 = !inside || (bottom && !right) ? 255 : 0
                        let offset = row * stride + column * 4
                        bytes[offset] = blue
                        bytes[offset + 1] = green
                        bytes[offset + 2] = red
                        bytes[offset + 3] = 255
                    }
                }
            }
            return try XCTUnwrap(OverviewPreviewFrame(
                pixelBuffer: pixelBuffer,
                contentRect: CGRect(x: 40, y: 20, width: 320, height: 200)
            ))
        }

        private enum Color {
            case red, green, blue, yellow, unknown
        }

        private struct Bitmap {
            let width: Int
            let height: Int
            let bytes: [UInt8]

            init(image: CGImage) throws {
                width = image.width
                height = image.height
                var storage = [UInt8](repeating: 0, count: width * height * 4)
                try storage.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(
                        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                bytes = storage
            }

            func pixel(at point: CGPoint) -> (UInt8, UInt8, UInt8, UInt8) {
                let x = min(width - 1, max(0, Int(point.x)))
                let y = min(height - 1, max(0, height - 1 - Int(point.y)))
                let offset = (y * width + x) * 4
                return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
            }

            func color(at point: CGPoint) -> Color {
                let (red, green, blue, _) = pixel(at: point)
                if red > 180, green < 80, blue < 80 { return .red }
                if green > 180, red < 80, blue < 80 { return .green }
                if blue > 180, red < 80, green < 80 { return .blue }
                if red > 180, green > 180, blue < 80 { return .yellow }
                return .unknown
            }

            func hasWhitePixel(in rect: CGRect) -> Bool {
                for y in Int(rect.minY) ..< Int(rect.maxY) {
                    for x in Int(rect.minX) ..< Int(rect.maxX) {
                        let (red, green, blue, alpha) = pixel(at: CGPoint(x: x, y: y))
                        if red > 180, green > 180, blue > 180, alpha > 180 { return true }
                    }
                }
                return false
            }
        }
    }
#endif
