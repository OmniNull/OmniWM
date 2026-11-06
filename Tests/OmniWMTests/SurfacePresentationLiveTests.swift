// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreMedia
import CoreVideo
import Foundation
@testable import OmniWM
import QuartzCore
import ScreenCaptureKit
import XCTest

#if OMNIWM_LIVE_CHECKS

    private enum SurfaceMeasurement {
        static let onePixel: Double = 1
        static let calibrationShift: CGFloat = 24
        static let clientGray: CGFloat = 0.25
        static let medianRadiusPixels = 2
        static let colorConversionsInCapture = 2
        static let channelStepsPerConversion = 1
    }

    @MainActor
    final class SurfacePresentationLiveTests: XCTestCase {
        private struct RailPresentationReport: Codable {
            let schema: Int
            let generatedAt: String
            let requestedFrames: Int
            let displayRefreshRate: Int
            let captureScale: Double
            let captureCallbacks: Int
            let frameStatusCounts: [String: Int]
            let completeFrames: Int
            let locatedFrames: Int
            let calibrationDetectedOffsetPixels: Double
            let calibrationRealigned: Bool
            let movementBearingFrames: Int
            let baselineOffsetPixels: Double
            let alignedWithinOnePixel: Int
            let alignedRate: Double
            let signedErrorHistogram: [String: Int]
            let lagVerdict: String
            let railBehindSamples: Int
            let clientBehindSamples: Int
            let absoluteErrorP50Pixels: Double
            let absoluteErrorP95Pixels: Double
            let absoluteErrorP99Pixels: Double
            let absoluteErrorMaxPixels: Double
            let slsDeferredSubmissions: Int
            let slsSubmissionFailures: Int
            let displayLinkDroppedCallbacks: Int
        }

        private struct BorderPresentationRGB: Equatable {
            static let red = Self(red: 255, green: 0, blue: 0)
            static let green = Self(red: 0, green: 255, blue: 0)
            static let blue = Self(red: 0, green: 0, blue: 255)

            let red: Int
            let green: Int
            let blue: Int
        }

        private struct BorderPresentationSample {
            let label: String
            let point: CGPoint
        }

        private struct BorderPresentationBitmap {
            let width: Int
            let height: Int
            let bytesPerRow: Int
            let bytes: [UInt8]

            init?(image: CGImage) {
                let bitmapWidth = image.width
                let bitmapHeight = image.height
                let bitmapBytesPerRow = bitmapWidth * 4
                var storage = [UInt8](repeating: 0, count: bitmapBytesPerRow * bitmapHeight)
                let rendered = storage.withUnsafeMutableBytes { buffer in
                    guard let context = CGContext(
                        data: buffer.baseAddress,
                        width: bitmapWidth,
                        height: bitmapHeight,
                        bitsPerComponent: 8,
                        bytesPerRow: bitmapBytesPerRow,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                            | CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else { return false }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight))
                    return true
                }
                guard rendered else { return nil }
                width = bitmapWidth
                height = bitmapHeight
                bytesPerRow = bitmapBytesPerRow
                bytes = storage
            }

            func medianColor(
                at point: CGPoint, radius: Int = SurfaceMeasurement.medianRadiusPixels
            ) -> BorderPresentationRGB? {
                let centerX = Int(point.x.rounded())
                let centerY = Int(point.y.rounded())
                guard centerX >= 0, centerX < width, centerY >= 0, centerY < height else { return nil }
                var reds: [Int] = []
                var greens: [Int] = []
                var blues: [Int] = []
                for y in max(0, centerY - radius) ... min(height - 1, centerY + radius) {
                    for x in max(0, centerX - radius) ... min(width - 1, centerX + radius) {
                        let offset = y * bytesPerRow + x * 4
                        reds.append(Int(bytes[offset]))
                        greens.append(Int(bytes[offset + 1]))
                        blues.append(Int(bytes[offset + 2]))
                    }
                }
                reds.sort()
                greens.sort()
                blues.sort()
                let index = reds.count / 2
                return BorderPresentationRGB(red: reds[index], green: greens[index], blue: blues[index])
            }
        }

        func testLiveBorderPresentsConfiguredColorsAcrossResize() async throws {
            guard CGPreflightScreenCaptureAccess() else {
                throw MissingTestPrerequisite("Screen Recording permission is required")
            }
            guard let screen = NSScreen.screens.max(by: {
                      $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
                  }) ?? NSScreen.main,
                  let displayId = screen.displayId
            else {
                throw MissingTestPrerequisite("No measurable display is available")
            }

            let largeFrame = borderPresentationFrame(on: screen)
            let smallFrame = CGRect(origin: largeFrame.origin, size: CGSize(width: 360, height: 240))
            let clientGray = SurfaceMeasurement.clientGray
            let clientColor = NSColor(srgbRed: clientGray, green: clientGray, blue: clientGray, alpha: 1)
            let clientWindow = makeClientWindow(frame: smallFrame, backgroundColor: clientColor)
            let captureSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let clientComponents = try XCTUnwrap(
                clientColor.cgColor.converted(to: captureSpace, intent: .defaultIntent, options: nil)?.components
            )
            let expectedClient = BorderPresentationRGB(
                red: Int((clientComponents[0] * 255).rounded()),
                green: Int((clientComponents[1] * 255).rounded()),
                blue: Int((clientComponents[2] * 255).rounded())
            )
            let borderWidth: CGFloat = 12
            let cornerRadii = WindowCornerRadii(uniform: 12)
            let redConfig = BorderConfig(
                enabled: true,
                width: borderWidth,
                color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
            )
            let blueConfig = BorderConfig(
                enabled: true,
                width: borderWidth,
                color: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1)
            )
            let greenConfig = BorderConfig(
                enabled: true,
                width: borderWidth,
                color: SettingsColor(red: 0, green: 1, blue: 0, alpha: 1)
            )
            let borderWindow = BorderWindow(config: redConfig)
            defer {
                borderWindow.destroy()
                clientWindow.close()
            }

            clientWindow.orderFrontRegardless()

            let shareable = try await SCShareableContent.currentProcess
            let display = try XCTUnwrap(shareable.displays.first { $0.displayID == displayId })
            let application = try XCTUnwrap(shareable.applications.first { $0.processID == getpid() })
            let captureRegion = ScreenCoordinateSpace.toWindowServer(
                rect: largeFrame.insetBy(dx: -borderWidth, dy: -borderWidth)
            ).intersection(display.frame)
            let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = captureRegion.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.width = max(1, Int((captureRegion.width * CGFloat(filter.pointPixelScale)).rounded()))
            configuration.height = max(1, Int((captureRegion.height * CGFloat(filter.pointPixelScale)).rounded()))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsDisplay = true
            configuration.shouldBeOpaque = true
            let targetToken = WindowToken(pid: getpid(), windowId: clientWindow.windowNumber)
            let watch = try await ScreenWatch.started(filter: filter, configuration: configuration)
            addTeardownBlock { await watch.stop() }

            XCTAssertTrue(
                borderWindow.update(
                    frame: smallFrame,
                    targetToken: targetToken,
                    cornerRadii: cornerRadii,
                    forceOrdering: true
                )
            )
            let initialWindowId = try XCTUnwrap(borderWindow.windowId)
            try await assertBorderPresentation(
                borderWindow,
                expected: .red,
                expectedClient: expectedClient,
                targetFrame: smallFrame,
                borderWidth: borderWidth,
                scale: screen.backingScaleFactor,
                cornerRadii: cornerRadii,
                captureRegion: captureRegion,
                filter: filter,
                configuration: configuration,
                watch: watch,
                label: "border-red-small"
            )

            borderWindow.updateConfig(blueConfig)
            XCTAssertTrue(
                borderWindow.update(
                    frame: smallFrame,
                    targetToken: targetToken,
                    cornerRadii: cornerRadii
                )
            )
            XCTAssertEqual(borderWindow.windowId, initialWindowId)
            try await assertBorderPresentation(
                borderWindow,
                expected: .blue,
                expectedClient: expectedClient,
                targetFrame: smallFrame,
                borderWidth: borderWidth,
                scale: screen.backingScaleFactor,
                cornerRadii: cornerRadii,
                captureRegion: captureRegion,
                filter: filter,
                configuration: configuration,
                watch: watch,
                label: "border-blue-small"
            )

            XCTAssertTrue(
                borderWindow.update(
                    frame: smallFrame,
                    targetToken: targetToken,
                    cornerRadii: cornerRadii
                )
            )

            clientWindow.setFrame(largeFrame, display: true)
            XCTAssertTrue(
                borderWindow.update(
                    frame: largeFrame,
                    targetToken: targetToken,
                    cornerRadii: cornerRadii
                )
            )
            XCTAssertEqual(borderWindow.windowId, initialWindowId)
            try await assertBorderPresentation(
                borderWindow,
                expected: .blue,
                expectedClient: expectedClient,
                targetFrame: largeFrame,
                borderWidth: borderWidth,
                scale: screen.backingScaleFactor,
                cornerRadii: cornerRadii,
                captureRegion: captureRegion,
                filter: filter,
                configuration: configuration,
                watch: watch,
                label: "border-blue-large"
            )

            borderWindow.updateConfig(greenConfig)
            XCTAssertTrue(
                borderWindow.update(
                    frame: largeFrame,
                    targetToken: targetToken,
                    cornerRadii: cornerRadii
                )
            )
            try await assertBorderPresentation(
                borderWindow,
                expected: .green,
                expectedClient: expectedClient,
                targetFrame: largeFrame,
                borderWidth: borderWidth,
                scale: screen.backingScaleFactor,
                cornerRadii: cornerRadii,
                captureRegion: captureRegion,
                filter: filter,
                configuration: configuration,
                watch: watch,
                label: "border-green-large"
            )

            clientWindow.setFrame(smallFrame, display: true)
            XCTAssertTrue(
                borderWindow.update(
                    frame: smallFrame,
                    targetToken: targetToken,
                    cornerRadii: cornerRadii
                )
            )
            clientWindow.setFrame(largeFrame, display: true)
            XCTAssertTrue(
                borderWindow.update(
                    frame: largeFrame,
                    targetToken: targetToken,
                    cornerRadii: cornerRadii
                )
            )
            XCTAssertEqual(borderWindow.windowId, initialWindowId)
            try await assertBorderPresentation(
                borderWindow,
                expected: .green,
                expectedClient: expectedClient,
                targetFrame: largeFrame,
                borderWidth: borderWidth,
                scale: screen.backingScaleFactor,
                cornerRadii: cornerRadii,
                captureRegion: captureRegion,
                filter: filter,
                configuration: configuration,
                watch: watch,
                label: "border-green-regrown"
            )

            XCTAssertTrue(
                borderWindow.update(
                    frame: largeFrame,
                    targetToken: targetToken,
                    cornerRadii: cornerRadii,
                    ordersAboveTarget: true
                )
            )
            try await assertBorderPresentation(
                borderWindow,
                expected: .green,
                expectedClient: expectedClient,
                targetFrame: largeFrame,
                borderWidth: borderWidth,
                scale: screen.backingScaleFactor,
                cornerRadii: cornerRadii,
                captureRegion: captureRegion,
                filter: filter,
                configuration: configuration,
                watch: watch,
                label: "border-green-above-target"
            )
        }

        func testLiveTabRailPresentationAlignsWithSLSClientFrames() async throws {
            guard CGPreflightScreenCaptureAccess() else {
                throw MissingTestPrerequisite("Screen Recording permission is required")
            }
            guard let screen = NSScreen.screens.max(by: {
                      $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
                  }) ?? NSScreen.main,
                  let displayId = screen.displayId
            else {
                throw MissingTestPrerequisite("No measurable display is available")
            }

            let requestedFrames = max(240, environmentInteger("OMNIWM_RAIL_MEASUREMENT_FRAMES", default: 900))
            let baseFrame = clientFrame(on: screen)
            let clientWindow = makeClientWindow(frame: baseFrame)
            let manager = TabRailManager()
            defer {
                manager.removeAll()
                clientWindow.close()
            }
            clientWindow.orderFrontRegardless()

            let workspaceId = WorkspaceDescriptor.ID()
            let owner = TabRailOwner.niriColumn(NodeId())
            let key = TabRailKey(workspaceId: workspaceId, owner: owner)
            let info = TabRailInfo(
                workspaceId: workspaceId,
                owner: owner,
                plannedSeq: 1,
                tileFrame: baseFrame,
                tabCount: 3,
                activeVisualIndex: 1,
                activeWindowId: clientWindow.windowNumber
            )
            manager.updateRails([info], forceOrdering: true)
            let railWindow = try XCTUnwrap(manager.existingWindow(for: key))
            railWindow.displayIfNeeded()
            railWindow.contentView?.display()

            let clientWid = CGWindowID(clientWindow.windowNumber)
            let railWid = CGWindowID(railWindow.windowNumber)
            let shareable = try await SCShareableContent.currentProcess
            let display = try XCTUnwrap(shareable.displays.first { $0.displayID == displayId })
            let presented = try await presentedWindows([clientWid, railWid], on: display)
            let clientCaptureWindow = presented[0]
            let railCaptureWindow = presented[1]

            let captureRegion = captureRegionForRailMotion(baseFrame: baseFrame, displayFrame: display.frame)
            let filter = SCContentFilter(
                display: display,
                including: [clientCaptureWindow, railCaptureWindow]
            )
            let captureScale = CGFloat(filter.pointPixelScale)
            let railFrame = railWindow.frame
            let (located, locatedChanged) = boundedChanges()
            let output = RailCompositeCaptureOutput(
                changed: locatedChanged,
                clientWidthPixels: Int((baseFrame.width * captureScale).rounded()),
                railLeadingPixels: Int(((railFrame.minX - baseFrame.minX) * captureScale).rounded()),
                railSpanPixels: Int(((railFrame.width + SurfaceMeasurement.calibrationShift) * captureScale).rounded()),
                railHeightPixels: Int((railFrame.height * captureScale).rounded()),
                pointPixelScale: captureScale,
                backgroundColor: CGColor(
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    components: [1, 1, 1, 1]
                )!
            )
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = captureRegion.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.width = Int((captureRegion.width * captureScale).rounded())
            configuration.height = Int((captureRegion.height * captureScale).rounded())
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = .zero
            configuration.queueDepth = 8
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.backgroundColor = output.backgroundColor
            configuration.ignoreShadowsDisplay = true
            configuration.shouldBeOpaque = true
            if let directory = ProcessInfo.processInfo.environment["OMNIWM_SURFACE_MEASUREMENT_OUTPUT_DIR"],
               let image = try? await SCScreenshotManager.captureImage(
                   contentFilter: filter,
                   configuration: configuration
               )
            {
                let representation = NSBitmapImageRep(cgImage: image)
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("rail-calibration.png")
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? representation.representation(using: .png, properties: [:])?.write(to: url)
                let railFilter = SCContentFilter(desktopIndependentWindow: railCaptureWindow)
                let railConfiguration = SCStreamConfiguration()
                railConfiguration.width = max(1, Int((railCaptureWindow.frame.width * captureScale).rounded()))
                railConfiguration.height = max(1, Int((railCaptureWindow.frame.height * captureScale).rounded()))
                railConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
                railConfiguration.showsCursor = false
                if let railImage = try? await SCScreenshotManager.captureImage(
                    contentFilter: railFilter,
                    configuration: railConfiguration
                ) {
                    let railRepresentation = NSBitmapImageRep(cgImage: railImage)
                    let railURL = URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent("rail-window-calibration.png")
                    try? railRepresentation.representation(using: .png, properties: [:])?.write(to: railURL)
                }
            }

            let outputQueue = DispatchQueue(label: "com.omniwm.surface-presentation-capture", qos: .userInteractive)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()

            let baselineReady = { !output.snapshot().locatedSamples.isEmpty }
            await located.wait("no locatable composite frame", until: baselineReady)
            guard baselineReady() else {
                try? await stream.stopCapture()
                outputQueue.sync {}
                return
            }
            let baselineSnapshot = output.snapshot()
            let baselineOffset = median(baselineSnapshot.locatedSamples.map(\.relativeOffsetPixels))
            let initialDisplayTime = baselineSnapshot.locatedSamples.last?.displayTime ?? 0
            let calibrationShiftPixels = Double(SurfaceMeasurement.calibrationShift * captureScale)
            let calibrationFrame = baseFrame.offsetBy(dx: SurfaceMeasurement.calibrationShift, dy: 0)
            let shiftRail = { (frame: CGRect) in
                manager.applyAnimationGeometry(
                    [TabRailGeometryCommand(key: key, tileFrame: frame, visibleTileFrame: frame)], in: workspaceId
                )
            }
            let railIsShifted = { (after: UInt64) in
                output.snapshot().locatedSamples.last.map {
                    $0.displayTime > after
                        && abs($0.relativeOffsetPixels - baselineOffset - calibrationShiftPixels)
                        <= SurfaceMeasurement.onePixel
                } == true
            }
            let railIsAligned = {
                output.snapshot().locatedSamples.last.map {
                    abs($0.relativeOffsetPixels - baselineOffset) <= SurfaceMeasurement.onePixel
                } == true
            }
            shiftRail(calibrationFrame)
            await located.wait("the rail did not reach its calibration offset") { railIsShifted(initialDisplayTime) }
            let calibrationDetected = railIsShifted(initialDisplayTime)
            let calibrationOffset = output.snapshot().locatedSamples.last.map {
                $0.relativeOffsetPixels - baselineOffset
            } ?? 0
            shiftRail(baseFrame)
            await located.wait("the rail did not return to its client", until: railIsAligned)
            let calibrationRealigned = railIsAligned()
            guard calibrationDetected, calibrationRealigned else {
                try? await stream.stopCapture()
                outputQueue.sync {}
                XCTFail(
                    "Rail pixel calibration failed"
                        + " detected=\(calibrationDetected) realigned=\(calibrationRealigned)"
                        + " offset=\(calibrationOffset)"
                )
                return
            }
            let baselineDisplayTime = output.snapshot().locatedSamples.last?.displayTime ?? 0

            let driver = RailPresentationDisplayLinkDriver(frames: requestedFrames) { index in
                let frame = self.railMotionFrame(index: index, baseFrame: baseFrame)
                let command = TabRailGeometryCommand(key: key, tileFrame: frame, visibleTileFrame: frame)
                SkyLight.shared.withTransactionScope {
                    let result = SkyLight.shared.batchMoveWindows([
                        (
                            windowId: UInt32(clientWindow.windowNumber),
                            origin: ScreenCoordinateSpace.toWindowServer(rect: frame).origin
                        )
                    ])
                    manager.applyAnimationGeometry([command], in: workspaceId)
                    switch result {
                    case .deferred:
                        output.noteDeferredSubmission()
                    case .submitted:
                        break
                    case .unavailable:
                        output.noteSubmissionFailure()
                    }
                }
            }
            await driver.run(on: screen)
            let lastMotionTime = output.snapshot().locatedSamples.last?.displayTime ?? baselineDisplayTime
            let finalFrame = railMotionFrame(index: requestedFrames - 1, baseFrame: baseFrame)
            shiftRail(finalFrame.offsetBy(dx: SurfaceMeasurement.calibrationShift, dy: 0))
            await located.wait("the end-of-motion marker never appeared") { railIsShifted(lastMotionTime) }
            let endOfMotion = output.snapshot().locatedSamples.last?.displayTime ?? lastMotionTime
            try await stream.stopCapture()
            outputQueue.sync {}

            let snapshot = output.snapshot()
            let motionSamples = snapshot.locatedSamples
                .filter { $0.displayTime > baselineDisplayTime && $0.displayTime < endOfMotion }
                .sorted { $0.displayTime < $1.displayTime }
            let movementSamples = movementBearingSamples(motionSamples)
            let absoluteErrors = movementSamples.map {
                abs($0.relativeOffsetPixels - baselineOffset)
            }
            let signedErrors = movementSamples.map {
                $0.relativeOffsetPixels - baselineOffset
            }
            let signedErrorHistogram = Dictionary(grouping: signedErrors) {
                String(Int($0.rounded()))
            }.mapValues(\.count)
            let aligned = absoluteErrors.filter { $0 <= SurfaceMeasurement.onePixel }.count
            let alignedRate = Double(aligned) / Double(max(1, absoluteErrors.count))
            let report = RailPresentationReport(
                schema: 1,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                requestedFrames: requestedFrames,
                displayRefreshRate: screen.maximumFramesPerSecond,
                captureScale: captureScale,
                captureCallbacks: snapshot.callbacks,
                frameStatusCounts: Dictionary(uniqueKeysWithValues: snapshot.frameStatusCounts.map {
                    (frameStatusLabel($0.key), $0.value)
                }),
                completeFrames: snapshot.completeFrames,
                locatedFrames: snapshot.locatedSamples.count,
                calibrationDetectedOffsetPixels: calibrationOffset,
                calibrationRealigned: calibrationRealigned,
                movementBearingFrames: movementSamples.count,
                baselineOffsetPixels: baselineOffset,
                alignedWithinOnePixel: aligned,
                alignedRate: alignedRate,
                signedErrorHistogram: signedErrorHistogram,
                lagVerdict: lagVerdict(signedErrors: signedErrors),
                railBehindSamples: signedErrors.filter { $0 < 0 }.count,
                clientBehindSamples: signedErrors.filter { $0 > 0 }.count,
                absoluteErrorP50Pixels: percentile(absoluteErrors, 0.50),
                absoluteErrorP95Pixels: percentile(absoluteErrors, 0.95),
                absoluteErrorP99Pixels: percentile(absoluteErrors, 0.99),
                absoluteErrorMaxPixels: absoluteErrors.max() ?? 0,
                slsDeferredSubmissions: snapshot.deferredSubmissions,
                slsSubmissionFailures: snapshot.submissionFailures,
                displayLinkDroppedCallbacks: driver.droppedCallbacks
            )
            try emit(report, label: "rail-presentation")

            XCTAssertGreaterThanOrEqual(movementSamples.count, Self.railSweepFrames - Self.railSweepSettleSamples)
            XCTAssertEqual(snapshot.submissionFailures, 0)
            XCTAssertEqual(snapshot.frameStatusCounts[SCFrameStatus.blank.rawValue, default: 0], 0)
            XCTAssertEqual(snapshot.frameStatusCounts[SCFrameStatus.suspended.rawValue, default: 0], 0)
            XCTAssertEqual(aligned, absoluteErrors.count)
            XCTAssertLessThanOrEqual(absoluteErrors.max() ?? 0, SurfaceMeasurement.onePixel)
        }

        private func clientFrame(on screen: NSScreen) -> CGRect {
            let visible = screen.visibleFrame
            return CGRect(
                x: visible.midX - 150,
                y: visible.midY - 120,
                width: 300,
                height: 240
            )
        }

        private func borderPresentationFrame(on screen: NSScreen) -> CGRect {
            let visible = screen.visibleFrame
            return CGRect(
                x: visible.midX - 260,
                y: visible.midY - 180,
                width: 520,
                height: 360
            )
        }

        private func makeClientWindow(
            frame: CGRect,
            backgroundColor: NSColor = NSColor(
                calibratedRed: 1,
                green: 0,
                blue: 1,
                alpha: 1
            )
        ) -> NSPanel {
            let window = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = backgroundColor
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.sharingType = .readOnly
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return window
        }

        private func exteriorBorderPresentationSamples(
            targetFrame: CGRect,
            borderWidth: CGFloat,
            cornerRadii: WindowCornerRadii
        ) -> [BorderPresentationSample] {
            let edgeOffset = borderWidth / 2

            func cornerPoint(center: CGPoint, radius: CGFloat, xSign: CGFloat, ySign: CGFloat) -> CGPoint {
                let offset = (radius + edgeOffset) / sqrt(2)
                return CGPoint(x: center.x + xSign * offset, y: center.y + ySign * offset)
            }

            return [
                BorderPresentationSample(
                    label: "top-exterior",
                    point: CGPoint(x: targetFrame.midX, y: targetFrame.maxY + edgeOffset)
                ),
                BorderPresentationSample(
                    label: "bottom-exterior",
                    point: CGPoint(x: targetFrame.midX, y: targetFrame.minY - edgeOffset)
                ),
                BorderPresentationSample(
                    label: "left-exterior",
                    point: CGPoint(x: targetFrame.minX - edgeOffset, y: targetFrame.midY)
                ),
                BorderPresentationSample(
                    label: "right-exterior",
                    point: CGPoint(x: targetFrame.maxX + edgeOffset, y: targetFrame.midY)
                ),
                BorderPresentationSample(
                    label: "top-left-exterior",
                    point: cornerPoint(
                        center: CGPoint(
                            x: targetFrame.minX + cornerRadii.topLeft,
                            y: targetFrame.maxY - cornerRadii.topLeft
                        ),
                        radius: cornerRadii.topLeft,
                        xSign: -1,
                        ySign: 1
                    )
                ),
                BorderPresentationSample(
                    label: "top-right-exterior",
                    point: cornerPoint(
                        center: CGPoint(
                            x: targetFrame.maxX - cornerRadii.topRight,
                            y: targetFrame.maxY - cornerRadii.topRight
                        ),
                        radius: cornerRadii.topRight,
                        xSign: 1,
                        ySign: 1
                    )
                ),
                BorderPresentationSample(
                    label: "bottom-left-exterior",
                    point: cornerPoint(
                        center: CGPoint(
                            x: targetFrame.minX + cornerRadii.bottomLeft,
                            y: targetFrame.minY + cornerRadii.bottomLeft
                        ),
                        radius: cornerRadii.bottomLeft,
                        xSign: -1,
                        ySign: -1
                    )
                ),
                BorderPresentationSample(
                    label: "bottom-right-exterior",
                    point: cornerPoint(
                        center: CGPoint(
                            x: targetFrame.maxX - cornerRadii.bottomRight,
                            y: targetFrame.minY + cornerRadii.bottomRight
                        ),
                        radius: cornerRadii.bottomRight,
                        xSign: 1,
                        ySign: -1
                    )
                )
            ]
        }

        private func interiorClientPresentationSamples(
            targetFrame: CGRect,
            borderWidth: CGFloat
        ) -> [BorderPresentationSample] {
            let edgeInset = borderWidth / 2
            return [
                BorderPresentationSample(
                    label: "top-client",
                    point: CGPoint(x: targetFrame.midX, y: targetFrame.maxY - edgeInset)
                ),
                BorderPresentationSample(
                    label: "bottom-client",
                    point: CGPoint(x: targetFrame.midX, y: targetFrame.minY + edgeInset)
                ),
                BorderPresentationSample(
                    label: "left-client",
                    point: CGPoint(x: targetFrame.minX + edgeInset, y: targetFrame.midY)
                ),
                BorderPresentationSample(
                    label: "right-client",
                    point: CGPoint(x: targetFrame.maxX - edgeInset, y: targetFrame.midY)
                )
            ]
        }

        private func assertBorderPresentation(
            _ borderWindow: BorderWindow,
            expected: BorderPresentationRGB,
            expectedClient: BorderPresentationRGB,
            targetFrame: CGRect,
            borderWidth: CGFloat,
            scale: CGFloat,
            cornerRadii: WindowCornerRadii,
            captureRegion: CGRect,
            filter: SCContentFilter,
            configuration: SCStreamConfiguration,
            watch: ScreenWatch,
            label: String
        ) async throws {
            let geometry = BorderConfig(enabled: true, width: borderWidth)
                .resolvedGeometry(for: targetFrame, scale: scale)
            XCTAssertEqual(borderWindow.targetFrameOnScreen, geometry.targetFrame)
            XCTAssertEqual(borderWindow.frameOnScreen, geometry.surfaceFrame)
            let borderSamples = exteriorBorderPresentationSamples(
                targetFrame: targetFrame,
                borderWidth: borderWidth,
                cornerRadii: cornerRadii
            )
            let clientSamples = interiorClientPresentationSamples(
                targetFrame: targetFrame,
                borderWidth: borderWidth
            )
            var lastImage: CGImage?
            var lastMismatches: [String] = []
            var frames = watch.changes.makeAsyncIterator()
            repeat {
                if let image = try? await SCScreenshotManager.captureImage(
                       contentFilter: filter,
                       configuration: configuration
                   ),
                   let bitmap = BorderPresentationBitmap(image: image)
                {
                    lastImage = image
                    let borderMismatches = borderSamples.compactMap { sample in
                        let point = borderPresentationPixelPoint(
                            for: sample.point,
                            captureRegion: captureRegion,
                            bitmap: bitmap
                        )
                        guard let actual = bitmap.medianColor(at: point) else {
                            return "\(sample.label)=out-of-bounds"
                        }
                        guard borderPresentationColor(actual, matches: expected) else {
                            return "\(sample.label)=\(actual.red),\(actual.green),\(actual.blue)"
                        }
                        return nil
                    }
                    let clientMismatches = clientSamples.compactMap { sample in
                        let point = borderPresentationPixelPoint(
                            for: sample.point,
                            captureRegion: captureRegion,
                            bitmap: bitmap
                        )
                        guard let actual = bitmap.medianColor(at: point) else {
                            return "\(sample.label)=out-of-bounds"
                        }
                        guard borderPresentationColor(actual, matches: expectedClient) else {
                            return "\(sample.label)=\(actual.red),\(actual.green),\(actual.blue)"
                        }
                        return nil
                    }
                    lastMismatches = borderMismatches + clientMismatches
                    if lastMismatches.isEmpty {
                        try writeBorderPresentationImage(image, label: label)
                        return
                    }
                }
            } while await frames.next() != nil

            if let lastImage {
                try writeBorderPresentationImage(lastImage, label: "\(label)-failed")
            }
            XCTFail(
                "Border presentation did not reach \(expected.red),\(expected.green),\(expected.blue): "
                    + lastMismatches.joined(separator: "; ")
            )
        }

        private func borderPresentationPixelPoint(
            for appKitPoint: CGPoint,
            captureRegion: CGRect,
            bitmap: BorderPresentationBitmap
        ) -> CGPoint {
            let windowServerPoint = ScreenCoordinateSpace.toWindowServer(point: appKitPoint)
            return CGPoint(
                x: (windowServerPoint.x - captureRegion.minX) / captureRegion.width * CGFloat(bitmap.width),
                y: (windowServerPoint.y - captureRegion.minY) / captureRegion.height * CGFloat(bitmap.height)
            )
        }

        private func borderPresentationColor(
            _ actual: BorderPresentationRGB,
            matches expected: BorderPresentationRGB
        ) -> Bool {
            let rounding = SurfaceMeasurement.colorConversionsInCapture * SurfaceMeasurement.channelStepsPerConversion
            return abs(actual.red - expected.red) <= rounding
                && abs(actual.green - expected.green) <= rounding
                && abs(actual.blue - expected.blue) <= rounding
        }

        private func writeBorderPresentationImage(_ image: CGImage, label: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["OMNIWM_SURFACE_MEASUREMENT_OUTPUT_DIR"] else {
                return
            }
            let representation = NSBitmapImageRep(cgImage: image)
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("\(label).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try representation.representation(using: .png, properties: [:])?.write(to: url)
        }

        private func captureRegionForRailMotion(baseFrame: CGRect, displayFrame: CGRect) -> CGRect {
            let left = railMotionFrame(index: 0, baseFrame: baseFrame)
            let right = railMotionFrame(index: Self.railSweepFrames - 1, baseFrame: baseFrame)
            let margin = SurfaceMeasurement.calibrationShift + TabRailMetrics.hitWidth
            let appKitBounds = left.union(right).insetBy(dx: -margin, dy: -margin)
            return ScreenCoordinateSpace.toWindowServer(rect: appKitBounds).intersection(displayFrame)
        }

        private static let railSweepFrames = 250
        private static let railSweepSettleSamples = 25
        private static let railSweepStepPixels: CGFloat = 2

        private func railMotionFrame(index: Int, baseFrame: CGRect) -> CGRect {
            let phase = index % Self.railSweepFrames
            let offset = CGFloat(phase) * Self.railSweepStepPixels
            return baseFrame.offsetBy(dx: offset, dy: 0)
        }

        private func movementBearingSamples(
            _ samples: [RailCompositeCaptureOutput.LocatedSample]
        ) -> [RailCompositeCaptureOutput.LocatedSample] {
            guard var previous = samples.first else { return [] }
            var result: [RailCompositeCaptureOutput.LocatedSample] = []
            var samplesSinceReset = Int.max
            for sample in samples.dropFirst() {
                let movedForward = sample.clientOriginPixels > previous.clientOriginPixels
                    || sample.railAnchorPixels > previous.railAnchorPixels
                let sweepReset = sample.clientOriginPixels < previous.clientOriginPixels
                    || sample.railAnchorPixels < previous.railAnchorPixels
                if sweepReset {
                    samplesSinceReset = 0
                } else if movedForward {
                    if samplesSinceReset >= Self.railSweepSettleSamples {
                        result.append(sample)
                    }
                    samplesSinceReset = samplesSinceReset == Int.max ? Int.max : samplesSinceReset + 1
                }
                previous = sample
            }
            return result
        }

        private func lagVerdict(signedErrors: [Double]) -> String {
            let behind = signedErrors.contains { $0 < 0 }
            let ahead = signedErrors.contains { $0 > 0 }
            switch (behind, ahead) {
            case (false, false): return "aligned"
            case (true, false): return "rail-lags-client"
            case (false, true): return "client-lags-rail"
            case (true, true): return "mixed"
            }
        }

        private func percentile(_ values: [Double], _ quantile: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int((Double(sorted.count - 1) * quantile).rounded(.toNearestOrAwayFromZero))
            return sorted[min(max(0, index), sorted.count - 1)]
        }

        private func median(_ values: [Double]) -> Double {
            percentile(values, 0.50)
        }

        private func frameStatusLabel(_ rawValue: Int) -> String {
            guard let status = SCFrameStatus(rawValue: rawValue) else {
                return "unknown-\(rawValue)"
            }
            switch status {
            case .complete:
                return "complete"
            case .idle:
                return "idle"
            case .blank:
                return "blank"
            case .suspended:
                return "suspended"
            case .started:
                return "started"
            case .stopped:
                return "stopped"
            @unknown default:
                return "unknown-\(rawValue)"
            }
        }

        private func environmentInteger(_ key: String, default defaultValue: Int) -> Int {
            ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? defaultValue
        }

        private func emit<T: Encodable>(_ report: T, label: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            print("OMNIWM_SURFACE_MEASUREMENT_BEGIN \(label)")
            print(text)
            print("OMNIWM_SURFACE_MEASUREMENT_END \(label)")
            if let directory = ProcessInfo.processInfo.environment["OMNIWM_SURFACE_MEASUREMENT_OUTPUT_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("\(label).json")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            }
        }

        private func presentedWindows(_ ids: [CGWindowID], on display: SCDisplay) async throws -> [SCWindow] {
            let watch = try await ScreenWatch.started(
                filter: SCContentFilter(display: display, excludingWindows: []),
                configuration: SCStreamConfiguration()
            )
            var frames = watch.changes.makeAsyncIterator()
            var presented: [SCWindow] = []
            while true {
                let content = try await SCShareableContent.currentProcess
                presented = ids.compactMap { id in content.windows.first { $0.windowID == id && $0.isOnScreen } }
                guard presented.count < ids.count, await frames.next() != nil else { break }
            }
            await watch.stop()
            guard presented.count == ids.count else { throw MissingMeasurementWindows() }
            return presented
        }
    }

    private struct MissingMeasurementWindows: Error {}

    private final class ScreenChangeOutput: NSObject, SCStreamOutput, Sendable {
        private let changed: AsyncStream<Void>.Continuation

        init(changed: AsyncStream<Void>.Continuation) {
            self.changed = changed
        }

        func stream(
            _: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of outputType: SCStreamOutputType
        ) {
            guard outputType == .screen, sampleBuffer.surfaceFrameStatus == .complete else { return }
            changed.yield()
        }
    }

    @MainActor
    private final class ScreenWatch {
        let changes: AsyncStream<Void>
        private let stream: SCStream
        private let output: ScreenChangeOutput

        private init(filter: SCContentFilter, configuration: SCStreamConfiguration) throws {
            let (changes, changed) = boundedChanges()
            self.changes = changes
            output = ScreenChangeOutput(changed: changed)
            stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(
                output, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.omniwm.surface-presentation-watch", qos: .userInteractive)
            )
        }

        static func started(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> ScreenWatch {
            let watch = try ScreenWatch(filter: filter, configuration: configuration)
            try await watch.stream.startCapture()
            return watch
        }

        func stop() async {
            try? await stream.stopCapture()
        }
    }

    private extension CMSampleBuffer {
        var surfaceFrameStatus: SCFrameStatus? {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                let status = attachments.first?[.status] as? NSNumber
            else { return nil }
            return SCFrameStatus(rawValue: status.intValue)
        }
    }

    private final class RailCompositeCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
        private static let channelMidpoint: UInt8 = 128

        struct LocatedSample: Sendable {
            let displayTime: UInt64
            let clientOriginPixels: Int
            let railAnchorPixels: Int

            var relativeOffsetPixels: Double {
                Double(railAnchorPixels - clientOriginPixels)
            }
        }

        struct Snapshot: Sendable {
            let callbacks: Int
            let frameStatusCounts: [Int: Int]
            let completeFrames: Int
            let locatedSamples: [LocatedSample]
            let deferredSubmissions: Int
            let submissionFailures: Int
        }

        private struct State {
            var callbacks = 0
            var frameStatusCounts: [Int: Int] = [:]
            var completeFrames = 0
            var locatedSamples: [LocatedSample] = []
            var deferredSubmissions = 0
            var submissionFailures = 0
        }

        private let changed: AsyncStream<Void>.Continuation
        private let clientWidthPixels: Int
        private let railLeadingPixels: Int
        private let railSpanPixels: Int
        private let railHeightPixels: Int
        private let pointPixelScale: CGFloat
        let backgroundColor: CGColor
        private let lock = NSLock()
        private var state = State()

        init(
            changed: AsyncStream<Void>.Continuation,
            clientWidthPixels: Int,
            railLeadingPixels: Int,
            railSpanPixels: Int,
            railHeightPixels: Int,
            pointPixelScale: CGFloat,
            backgroundColor: CGColor
        ) {
            self.changed = changed
            self.clientWidthPixels = clientWidthPixels
            self.railLeadingPixels = railLeadingPixels
            self.railSpanPixels = railSpanPixels
            self.railHeightPixels = railHeightPixels
            self.pointPixelScale = pointPixelScale
            self.backgroundColor = backgroundColor
        }

        func stream(
            _: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of outputType: SCStreamOutputType
        ) {
            guard outputType == .screen else { return }
            lock.withLock { state.callbacks += 1 }
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                      sampleBuffer,
                      createIfNecessary: false
                  ) as? [[SCStreamFrameInfo: Any]],
                  let attachment = attachments.first,
                  let statusNumber = attachment[.status] as? NSNumber,
                  let status = SCFrameStatus(rawValue: statusNumber.intValue)
            else { return }
            lock.withLock {
                state.frameStatusCounts[status.rawValue, default: 0] += 1
                if status == .complete {
                    state.completeFrames += 1
                }
            }
            guard status == .complete,
                  let displayTime = (attachment[.displayTime] as? NSNumber)?.uint64Value,
                  let pixelBuffer = sampleBuffer.imageBuffer
            else { return }

            guard let located = locateWindows(in: pixelBuffer, displayTime: displayTime) else { return }
            lock.withLock { state.locatedSamples.append(located) }
            changed.yield()
        }

        func noteDeferredSubmission() {
            lock.withLock { state.deferredSubmissions += 1 }
        }

        func noteSubmissionFailure() {
            lock.withLock { state.submissionFailures += 1 }
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(
                    callbacks: state.callbacks,
                    frameStatusCounts: state.frameStatusCounts,
                    completeFrames: state.completeFrames,
                    locatedSamples: state.locatedSamples,
                    deferredSubmissions: state.deferredSubmissions,
                    submissionFailures: state.submissionFailures
                )
            }
        }

        private func locateWindows(
            in pixelBuffer: CVPixelBuffer,
            displayTime: UInt64
        ) -> LocatedSample? {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let middleY = height / 2
            let rowRange = max(0, middleY - 3) ... min(height - 1, middleY + 3)
            var clientRight = -1

            for y in rowRange {
                let row = bytes.advanced(by: y * bytesPerRow)
                for x in 0 ..< width where isClientPixel(row.advanced(by: x * 4)) {
                    clientRight = max(clientRight, x)
                }
            }
            guard clientRight >= clientWidthPixels - 1 else { return nil }
            let clientOrigin = clientRight - clientWidthPixels + 1
            let scanMinX = max(0, clientOrigin + railLeadingPixels)
            let scanMaxX = min(width - 1, scanMinX + railSpanPixels)
            let minimumRailPixels = Int((TabRailMetrics.minimumSegmentHeight * pointPixelScale).rounded())
            var railAnchor: Int?

            for x in scanMinX ... scanMaxX {
                var railPixelCount = 0
                for y in 0 ..< height {
                    let pixel = bytes.advanced(by: y * bytesPerRow + x * 4)
                    if isRailPixel(pixel) {
                        railPixelCount += 1
                    }
                }
                if railPixelCount >= minimumRailPixels, railPixelCount <= railHeightPixels {
                    railAnchor = x
                    break
                }
            }
            guard let railAnchor else { return nil }
            return LocatedSample(
                displayTime: displayTime,
                clientOriginPixels: clientOrigin,
                railAnchorPixels: railAnchor
            )
        }

        private func isClientPixel(_ pixel: UnsafePointer<UInt8>) -> Bool {
            let blue = pixel[0]
            let green = pixel[1]
            let red = pixel[2]
            let alpha = pixel[3]
            return blue >= Self.channelMidpoint && red >= Self.channelMidpoint
                && green < Self.channelMidpoint && alpha >= Self.channelMidpoint
        }

        private func isRailPixel(_ pixel: UnsafePointer<UInt8>) -> Bool {
            let blue = pixel[0]
            let green = pixel[1]
            let red = pixel[2]
            let alpha = pixel[3]
            let isBackground = green >= Self.channelMidpoint && red >= Self.channelMidpoint
                && blue >= Self.channelMidpoint
            return alpha >= Self.channelMidpoint && !isBackground && !isClientPixel(pixel)
        }
    }

    @MainActor
    private final class RailPresentationDisplayLinkDriver: NSObject {
        private let frames: Int
        private let apply: @MainActor (Int) -> Void
        private var displayLink: CADisplayLink?
        private var continuation: CheckedContinuation<Void, Never>?
        private var lastTimestamp: CFTimeInterval?
        private var index = 0

        private(set) var droppedCallbacks = 0

        init(frames: Int, apply: @escaping @MainActor (Int) -> Void) {
            self.frames = frames
            self.apply = apply
        }

        func run(on screen: NSScreen) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let displayLink = screen.displayLink(target: self, selector: #selector(tick(_:)))
                self.displayLink = displayLink
                displayLink.add(to: .main, forMode: .common)
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            if let lastTimestamp, link.duration > 0, link.timestamp - lastTimestamp > link.duration * 1.5 {
                droppedCallbacks += 1
            }
            lastTimestamp = link.timestamp
            apply(index)
            index += 1
            guard index >= frames else { return }
            link.remove(from: .main, forMode: .common)
            displayLink = nil
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }
    }
#endif
