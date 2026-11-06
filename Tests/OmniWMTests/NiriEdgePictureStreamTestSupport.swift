// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class NiriPictureStreamTestDriver {
    enum Failure: Error { case requested }

    final class Surface: NiriEdgePictureSurface {
        let windowId: UInt32? = 500
        var isVisibleForCapture = true
        var changed: (@MainActor () -> Void)?
        var content: NiriPictureContent?
        var publications: [OverviewPreviewFrame] = []
        var onPublication: (() -> Void)?
        var geometry: NiriEdgePictureGeometry?
        var activate: (@MainActor () -> Void)?

        func setOrderingTarget(_: Int?) {}
        func observeVisibility(_ changed: (@MainActor () -> Void)?) {
            self.changed = changed
        }

        func update(
            geometry: NiriEdgePictureGeometry, content: NiriPictureContent,
            activate: @escaping @MainActor () -> Void
        ) {
            self.geometry = geometry
            self.content = content
            self.activate = activate
        }

        func setContent(_ content: NiriPictureContent) {
            self.content = content
            if let frame = content.preview { publications.append(frame)
                onPublication?()
            }
        }

        func hide() {
            changed = nil
        }

        func destroy() {
            changed = nil
        }

        func visible(_ visible: Bool) {
            isVisibleForCapture = visible
            changed?()
        }
    }

    final class Control: OverviewPreviewStreamControl {
        let started = XCTestExpectation(description: "Stream start invoked")
        var continuation: CheckedContinuation<Void, any Error>?
        var stops = 0

        func start() async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func finish(_ error: (any Error)? = nil) {
            let next = continuation
            continuation = nil
            if let error { next?.resume(throwing: error) } else { next?.resume() }
        }

        func stop() {
            stops += 1
        }
    }

    struct Preparation {
        let request: NiriPictureStreamSession.Request
        let output: OverviewPreviewStream
        let complete: @MainActor (NiriPictureStreamSession.Build?) -> Void
    }

    let token = WindowToken(pid: 100, windowId: 200)
    let workspace = WorkspaceDescriptor.ID()
    let display = CGRect(x: 0, y: 0, width: 800, height: 600)
    var scale: CGFloat = 2
    let failureDeadline: TimeInterval = 5
    var eligible = true
    var overviewOpen = false
    var preparations: [Preparation] = []
    var captures: [@MainActor (CGImage?) -> Void] = []
    var controls: [Control] = []
    var surfaces: [Surface] = []
    var activations: [WindowToken] = []

    func presenter() -> NiriEdgePictures {
        NiriEdgePictures(
            capture: { [self] _, completion in captures.append(completion)
                return nil
            },
            prepareStream: { [self] request, output, complete in
                preparations.append(Preparation(request: request, output: output, complete: complete))
                return nil
            },
            makeSurface: { [self] in let surface = Surface()
                surfaces.append(surface)
                return surface
            },
            isCaptureEligible: { [self] _ in eligible }, isOverviewOpen: { [self] in overviewOpen },
            activate: { [self] token, _ in activations.append(token) }
        )
    }

    func plan(
        settled: Bool = true,
        pictured: Bool = true,
        size: CGSize? = nil,
        visibleHeight: CGFloat? = nil
    ) -> WorkspaceLayoutPlan {
        var diff = WorkspaceLayoutDiff()
        diff.picturePreparation = NiriPicturePreparation(isSettled: settled)
        let pictureFrame = CGRect(
            x: display.minX, y: visibleHeight.map { display.maxY - $0 } ?? display.midY,
            width: size?.width ?? display.width,
            height: size?.height ?? display.height
        )
        if pictured { diff.edgeHiddenFrames[token] = pictureFrame }
        return WorkspaceLayoutPlan(
            workspaceId: workspace,
            monitor: LayoutMonitorSnapshot(
                monitorId: .init(displayId: 1), displayId: 1, frame: display, visibleFrame: display,
                workingFrame: display, fullscreenLayoutFrame: display, scale: scale, orientation: .vertical
            ), sessionPatch: .init(workspaceId: workspace), diff: diff, isAnimationTick: !settled
        )
    }

    func mount(_ presenter: NiriEdgePictures, visibleHeight: CGFloat? = nil) throws -> CGImage {
        presenter.reconcile(plan(visibleHeight: visibleHeight))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        try XCTUnwrap(captures.last)(image)
        return image
    }

    func prepared(_ index: Int? = nil) throws -> Control {
        let control = Control()
        let preparation = try XCTUnwrap(index.map { preparations[$0] } ?? preparations.last)
        preparation.complete { [self] in controls.append(control)
            return control
        }
        return control
    }

    func running(_ presenter: NiriEdgePictures) async throws -> Control {
        let control = try prepared()
        await started(control)
        let task = presenter.pictures[token]?.stream?.startTask
        control.finish()
        await task?.value
        return control
    }

    func started(_ control: Control) async {
        let result = await XCTWaiter.fulfillment(of: [control.started], timeout: failureDeadline)
        XCTAssertEqual(result, .completed)
    }

    func finish(_ presenter: NiriEdgePictures) {
        presenter.reset()
        for control in controls { control.finish(CancellationError()) }
    }
}
