// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class ShellSettingsPreviewCacheTests: XCTestCase {
    private enum Failure: Error {
        case render
    }

    @MainActor
    private final class Renderer {
        private var calls: [CheckedContinuation<CGImage, any Error>] = []
        private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private(set) var cancellations = 0

        var count: Int {
            calls.count
        }

        func render(_: ShellSettingsPreview.Request) async throws -> CGImage {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    calls.append(continuation)
                    let ready = callWaiters.filter { calls.count >= $0.0 }
                    callWaiters.removeAll { calls.count >= $0.0 }
                    for (_, waiter) in ready { waiter.resume() }
                }
            } onCancel: {
                Task { @MainActor in
                    self.cancellations += 1
                    let ready = self.cancellationWaiters.filter { self.cancellations >= $0.0 }
                    self.cancellationWaiters.removeAll { self.cancellations >= $0.0 }
                    for (_, waiter) in ready { waiter.resume() }
                }
            }
        }

        func waitForCalls(_ count: Int) async {
            if calls.count >= count { return }
            await withCheckedContinuation { callWaiters.append((count, $0)) }
        }

        func waitForCancellations(_ count: Int) async {
            if cancellations >= count { return }
            await withCheckedContinuation { cancellationWaiters.append((count, $0)) }
        }

        func finish(_ index: Int, result: Result<CGImage, any Error>) {
            calls[index].resume(with: result)
        }
    }

    private func request(_ revision: UInt64 = 0) -> ShellSettingsPreview.Request {
        .init(
            config: ShellConfig(), surface: .bar, style: .init(), scale: 1,
            dark: false, fullWidth: false, revision: revision
        )
    }

    private func image(_ side: Int = 8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    func testEqualConcurrentRequestsShareRenderingAndCompletedImage() async throws {
        let renderer = Renderer()
        let cache = ShellSettingsPreviewCache(render: renderer.render)
        let request = request()
        let image = try image()
        let first = Task { try await cache.image(for: request) }
        await renderer.waitForCalls(1)
        let second = Task {
            Task { @MainActor in renderer.finish(0, result: .success(image)) }
            return try await cache.image(for: request)
        }
        let firstImage = try await first.value
        let secondImage = try await second.value
        XCTAssertTrue(firstImage === image)
        XCTAssertTrue(secondImage === image)
        let cachedImage = try await cache.image(for: request)
        XCTAssertTrue(cachedImage === image)
        XCTAssertEqual(renderer.count, 1)
        XCTAssertEqual(cache.count, 1)
    }

    func testCancelledWaiterReturnsBeforeRenderingFinishesAndPreservesOtherConsumer() async throws {
        let renderer = Renderer()
        let cache = ShellSettingsPreviewCache(render: renderer.render)
        let request = request()
        let first = Task { try await cache.image(for: request) }
        await renderer.waitForCalls(1)
        let second = Task {
            first.cancel()
            return try await cache.image(for: request)
        }
        let result = await first.result
        guard case .failure(is CancellationError) = result else {
            XCTFail("Cancelled consumer received a preview")
            return
        }
        XCTAssertEqual(renderer.count, 1)
        XCTAssertEqual(renderer.cancellations, 0)
        let image = try image()
        renderer.finish(0, result: .success(image))
        let secondImage = try await second.value
        XCTAssertTrue(secondImage === image)
        XCTAssertEqual(cache.count, 1)
    }

    func testLastConsumerCancelsRenderAndLateCompletionCannotReplaceNewRequest() async throws {
        let renderer = Renderer()
        let cache = ShellSettingsPreviewCache(render: renderer.render)
        let request = request()
        let first = Task { try await cache.image(for: request) }
        await renderer.waitForCalls(1)
        first.cancel()
        let result = await first.result
        guard case .failure(is CancellationError) = result else {
            XCTFail("Last cancelled consumer received a preview")
            return
        }
        await renderer.waitForCancellations(1)
        XCTAssertEqual(cache.count, 0)
        let second = Task { try await cache.image(for: request) }
        await renderer.waitForCalls(2)
        let old = try image(4)
        let replacement = try image(8)
        renderer.finish(0, result: .success(old))
        renderer.finish(1, result: .success(replacement))
        let secondImage = try await second.value
        let cachedImage = try await cache.image(for: request)
        XCTAssertTrue(secondImage === replacement)
        XCTAssertTrue(cachedImage === replacement)
        XCTAssertEqual(renderer.count, 2)
        XCTAssertEqual(cache.count, 1)
    }

    func testSharedFailureClearsPendingRenderAndAllowsRetry() async throws {
        let renderer = Renderer()
        let cache = ShellSettingsPreviewCache(render: renderer.render)
        let request = request()
        let first = Task { try await cache.image(for: request) }
        await renderer.waitForCalls(1)
        let second = Task {
            Task { @MainActor in renderer.finish(0, result: .failure(Failure.render)) }
            return try await cache.image(for: request)
        }
        for result in [await first.result, await second.result] {
            guard case let .failure(error) = result, error is Failure else {
                XCTFail("Consumers did not share the render failure")
                continue
            }
        }
        XCTAssertEqual(renderer.count, 1)
        XCTAssertEqual(cache.count, 0)
        let retry = Task { try await cache.image(for: request) }
        await renderer.waitForCalls(2)
        let image = try image()
        renderer.finish(1, result: .success(image))
        let retryImage = try await retry.value
        XCTAssertTrue(retryImage === image)
        XCTAssertEqual(cache.count, 1)
    }

    func testDifferentRevisionsRenderIndependently() async throws {
        let renderer = Renderer()
        let cache = ShellSettingsPreviewCache(render: renderer.render)
        let firstRequest = request()
        let secondRequest = request(1)
        let first = Task { try await cache.image(for: firstRequest) }
        await renderer.waitForCalls(1)
        let second = Task { try await cache.image(for: secondRequest) }
        await renderer.waitForCalls(2)
        let firstImage = try image(4)
        let secondImage = try image(8)
        renderer.finish(1, result: .success(secondImage))
        renderer.finish(0, result: .success(firstImage))
        let renderedFirst = try await first.value
        let renderedSecond = try await second.value
        XCTAssertTrue(renderedFirst === firstImage)
        XCTAssertTrue(renderedSecond === secondImage)
        XCTAssertEqual(cache.count, 2)
    }

    func testCancellationBeforeRegistrationDoesNotStartRendering() async {
        let renderer = Renderer()
        let cache = ShellSettingsPreviewCache(render: renderer.render)
        let request = request()
        let task = Task { try await cache.image(for: request) }
        task.cancel()
        guard case .failure(is CancellationError) = await task.result else {
            XCTFail("Cancelled request succeeded")
            return
        }
        XCTAssertEqual(renderer.count, 0)
        XCTAssertEqual(cache.count, 0)
    }

    func testCompletedCacheRetainsTwelveImagesAndTouchesHitsBeforeEviction() async throws {
        var renders = 0
        let image = try image()
        let cache = ShellSettingsPreviewCache { _ in
            renders += 1
            return image
        }
        for revision: UInt64 in 0 ..< 12 { cache.insert(image, for: request(revision)) }
        _ = try await cache.image(for: request(0))
        cache.insert(image, for: request(12))
        XCTAssertEqual(cache.count, 12)
        XCTAssertEqual(cache.retainedBytes, image.bytesPerRow * image.height * 12)
        _ = try await cache.image(for: request(0))
        XCTAssertEqual(renders, 0)
        _ = try await cache.image(for: request(1))
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cache.count, 12)
    }

    func testCompletedCachePreservesByteLimitAndAccountsForReplacements() throws {
        let image = try image(2048)
        let cache = ShellSettingsPreviewCache()
        for revision: UInt64 in 0 ..< 3 { cache.insert(image, for: request(revision)) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.retainedBytes, ShellSettingsPreviewCache.maximumBytes)
        let replacement = try self.image()
        cache.insert(replacement, for: request(2))
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(
            cache.retainedBytes,
            image.bytesPerRow * image.height + replacement.bytesPerRow * replacement.height
        )
    }
}
