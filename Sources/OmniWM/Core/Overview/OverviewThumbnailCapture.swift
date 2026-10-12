// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import IOSurface
import QuartzCore

@MainActor
final class OverviewThumbnailCapture {
    typealias StreamFactory = @MainActor (OverviewPreviewRequest, OverviewPreviewStream) async throws
        -> any OverviewPreviewStreamControl

    private static var nextCacheId: UInt64 = 0

    private enum Status {
        case queued, starting, running, completed, failed
    }

    private final class Source {
        let id: UInt64
        let generation: UInt64
        let request: OverviewPreviewRequest
        let requestedAt = CACurrentMediaTime()
        var status = Status.queued
        var published = false
        var lastRequestedUse: UInt64 = 0
        var output: OverviewPreviewStream?
        var control: (any OverviewPreviewStreamControl)?

        init(id: UInt64, generation: UInt64, request: OverviewPreviewRequest) {
            self.id = id
            self.generation = generation
            self.request = request
        }
    }

    private struct CachedPreview {
        let frame: OverviewPreviewFrame
        let token: WindowToken
        var lastRequestedUse: UInt64
        let capturedAt: UInt64
    }

    private let consumer: OverviewFrameTrace.PreviewConsumer
    private let cacheId: UInt64
    private let traceRecorder: OverviewFrameTrace.Recorder
    private let coordinator: PreviewCaptureCoordinator
    private let adoptsProvisionalPreviews: Bool
    private let hasCaptureAccess: @MainActor () -> Bool
    private let streamFactory: StreamFactory?
    private var generation: UInt64 = 1
    private var nextSourceId: UInt64 = 0
    private var sources: [ObjectIdentifier: Source] = [:]
    private var sourceOrder: [ObjectIdentifier] = []
    private var starts: [UInt64: Task<Void, Never>] = [:]
    private var previewCache: [WindowHandle: CachedPreview] = [:]
    let maximumRetainedBytes: Int
    private var stopsAfterFirstFrame = false
    private(set) var isPresenting = false
    var onPreview: @MainActor (WindowHandle, OverviewPreviewFrame?) -> Void = { _, _ in }
    var onReadinessChange: @MainActor () -> Void = {}
    var onCaptureStarted: @MainActor () -> Void = {}

    init(
        coordinator: PreviewCaptureCoordinator = .shared,
        consumer: OverviewFrameTrace.PreviewConsumer = .overview,
        traceRecorder: OverviewFrameTrace.Recorder = OverviewFrameTrace.shared,
        hasCaptureAccess: @escaping @MainActor () -> Bool = { ScreenCapturePermissionMonitor.shared.isGranted },
        adoptsProvisionalPreviews: Bool = true,
        maximumRetainedBytes: Int = 128 * 1_024 * 1_024,
        streamFactory: StreamFactory? = nil
    ) {
        Self.nextCacheId &+= 1
        cacheId = Self.nextCacheId
        self.consumer = consumer
        self.traceRecorder = traceRecorder
        self.coordinator = coordinator
        self.adoptsProvisionalPreviews = adoptsProvisionalPreviews
        self.hasCaptureAccess = hasCaptureAccess
        self.maximumRetainedBytes = max(0, maximumRetainedBytes)
        self.streamFactory = streamFactory
        coordinator.register(self)
    }

    var hasPendingFirstFrames: Bool {
        sources.values.contains { !$0.published && $0.status != .failed && $0.status != .completed }
    }

    var cachedByteCount: Int {
        previewCache.values.reduce(0) { $0 + $1.frame.surface.allocationSize }
    }

    func reconcile(
        represented: Set<WindowHandle>,
        visible: [OverviewPreviewRequest],
        prioritizing selectedHandle: WindowHandle? = nil,
        retainingUnrepresentedPreviews: Bool = false,
        firstFrameOnly: Bool = false
    ) {
        isPresenting = true
        stopsAfterFirstFrame = firstFrameOnly
        for handle in Array(previewCache.keys)
            where (!retainingUnrepresentedPreviews && !represented.contains(handle))
            || previewCache[handle]?.token != handle.token
        {
            let reason: OverviewFrameTrace.PreviewReason = previewCache[handle]?.token != handle.token
                ? .tokenChanged : .unrepresented
            removeCachedPreview(for: handle, reason: reason)
            onPreview(handle, nil)
        }
        var requests = collectRequests(represented: represented, visible: visible, selectedHandle: selectedHandle)
        adoptSharedPreviews(for: &requests, droppingSatisfied: firstFrameOnly)
        for (key, source) in sources where requests[key]?.token != source.request.token
            || (!firstFrameOnly && source.status == .completed)
        {
            retire(source)
            sources.removeValue(forKey: key)
        }
        guard !requests.isEmpty, hasCaptureAccess() else {
            for source in sources.values { retire(source) }
            sources.removeAll()
            onReadinessChange()
            return
        }
        var added = false
        for key in sourceOrder {
            guard sources[key] == nil, let request = requests[key] else { continue }
            nextSourceId &+= 1
            let source = Source(id: nextSourceId, generation: generation, request: request)
            sources[key] = source
            trace(.previewRequested, source: source)
            added = true
        }
        for key in sourceOrder.reversed() {
            guard let source = sources[key] else { continue }
            let use = coordinator.nextUse()
            source.lastRequestedUse = use
            previewCache[source.request.handle]?.lastRequestedUse = use
            completeFirstFrame(source)
        }
        if added { onCaptureStarted() }
        startQueuedSources()
        onReadinessChange()
    }

    func remove(handle: WindowHandle) {
        let key = ObjectIdentifier(handle)
        if let source = sources.removeValue(forKey: key) { retire(source) }
        sourceOrder.removeAll { $0 == key }
        removeCachedPreview(for: handle, reason: .removed)
        onPreview(handle, nil)
        onReadinessChange()
    }

    func clear() {
        generation &+= 1
        isPresenting = false
        for source in sources.values { retire(source) }
        sources.removeAll()
        sourceOrder.removeAll()
        coordinator.trimRetainedPreviews()
        if traceRecorder.isActive {
            traceRecorder.record(record(.previewCacheCleared, reason: .retained, bytes: cachedByteCount))
        }
    }

    private func retire(_ source: Source) {
        source.output?.invalidate()
        if starts[source.id] != nil {
            starts[source.id]?.cancel()
        } else {
            source.control?.stop()
            source.control = nil
        }
    }

    private func startQueuedSources() {
        for key in sourceOrder {
            guard starts.count < 4 else { return }
            guard let source = sources[key], source.status == .queued else { continue }
            source.status = .starting
            let sourceId = source.id
            let output = OverviewPreviewStream(
                onReady: { [weak self] in
                    Task { @MainActor [weak self] in self?.publish(key: key, sourceId: sourceId) }
                },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in self?.streamFailed(key: key, sourceId: sourceId) }
                }
            )
            source.output = output
            starts[source.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let control = try await makeControl(request: source.request, output: output)
                    try Task.checkCancellation()
                    source.control = control
                    try await control.start()
                    finishStarting(source, failed: false)
                } catch {
                    if !(error is CancellationError) {
                        ScreenCapturePermissionMonitor.shared.noteCaptureFailure(error)
                        FallbackFiringRecorder.shared.note(.capture, "overviewStreamStartException")
                    }
                    finishStarting(source, failed: true)
                }
            }
        }
    }

    private func finishStarting(_ source: Source, failed: Bool) {
        starts.removeValue(forKey: source.id)
        if isCurrent(source), !failed, source.status != .failed, source.status != .completed {
            source.status = .running
            trace(.previewStarted, source: source)
        } else {
            source.output?.invalidate()
            source.control?.stop()
            source.control = nil
            if source.status != .completed { source.status = .failed }
        }
        startQueuedSources()
        if isCurrent(source) { onReadinessChange() }
    }

    private func isCurrent(_ source: Source) -> Bool {
        source.generation == generation && sources[ObjectIdentifier(source.request.handle)] === source &&
            source.request.handle.token == source.request.token
    }

    private func publish(key: ObjectIdentifier, sourceId: UInt64) {
        guard let source = sources[key], source.id == sourceId,
              isCurrent(source), source.status != .failed,
              let frame = source.output?.take()
        else { return }
        previewCache[source.request.handle] = CachedPreview(
            frame: frame,
            token: source.request.token,
            lastRequestedUse: source.lastRequestedUse,
            capturedAt: coordinator.nextUse()
        )
        if !source.published {
            source.published = true
            trace(.previewArrived, source: source)
        }
        onPreview(source.request.handle, frame)
        completeFirstFrame(source)
        onReadinessChange()
    }

    private func completeFirstFrame(_ source: Source) {
        guard stopsAfterFirstFrame, source.published, source.status != .completed else { return }
        retire(source)
        source.status = .completed
    }

    private func streamFailed(key: ObjectIdentifier, sourceId: UInt64) {
        guard let source = sources[key], source.id == sourceId, isCurrent(source) else { return }
        source.output?.invalidate()
        source.status = .failed
        if stopsAfterFirstFrame { source.control?.stop() }
        source.control = nil
        FallbackFiringRecorder.shared.note(.capture, "overviewStreamException")
        onReadinessChange()
    }

    private func makeControl(
        request: OverviewPreviewRequest,
        output: OverviewPreviewStream
    ) async throws -> any OverviewPreviewStreamControl {
        if let streamFactory { return try await streamFactory(request, output) }
        let startedAt = CACurrentMediaTime()
        let discovery = await coordinator.window(for: request.token)
        if let discoveredCount = discovery.discoveredCount {
            traceRecorder.record(record(
                .previewDiscovery,
                sourceId: generation,
                requestedAt: startedAt,
                sequence: UInt64(discoveredCount)
            ))
        }
        try Task.checkCancellation()
        guard let window = discovery.window, request.token == request.handle.token else {
            throw CancellationError()
        }
        return try OverviewNativePreviewStream(window: window, request: request, output: output)
    }
}

extension OverviewThumbnailCapture {
    func preview(for handle: WindowHandle) -> OverviewPreviewFrame? {
        guard let cached = previewCache[handle], cached.token == handle.token else {
            return adoptsProvisionalPreviews ? adoptSharedPreview(for: handle, satisfying: nil) : nil
        }
        let use = coordinator.nextUse()
        previewCache[handle]?.lastRequestedUse = use
        sources[ObjectIdentifier(handle)]?.lastRequestedUse = use
        return cached.frame
    }

    func forEachRetainedPreview(_ body: (WindowHandle, OverviewPreviewFrame, UInt64) -> Void) {
        for (handle, cached) in previewCache {
            body(handle, cached.frame, cached.lastRequestedUse)
        }
    }

    func retainedPreview(matching token: WindowToken) -> PreviewCaptureCoordinator.SharedPreview? {
        previewCache.first { $0.key.token == token && $0.value.token == token }.map {
            PreviewCaptureCoordinator.SharedPreview(frame: $0.value.frame, capturedAt: $0.value.capturedAt)
        }
    }

    func evictRetainedPreview(for handle: WindowHandle) {
        removeCachedPreview(for: handle, reason: .budget)
        onPreview(handle, nil)
    }

    private func adoptSharedPreviews(
        for requests: inout [ObjectIdentifier: OverviewPreviewRequest],
        droppingSatisfied: Bool
    ) {
        for (key, request) in requests where previewCache[request.handle]?.token != request.token {
            guard let frame = adoptSharedPreview(
                for: request.handle,
                satisfying: adoptsProvisionalPreviews ? nil : request
            ) else { continue }
            onPreview(request.handle, frame)
            if droppingSatisfied, frame.covers(request) { requests.removeValue(forKey: key) }
        }
    }

    private func adoptSharedPreview(
        for handle: WindowHandle,
        satisfying request: OverviewPreviewRequest?
    ) -> OverviewPreviewFrame? {
        guard let shared = coordinator.sharedPreview(for: handle.token, excluding: self, satisfying: request) else {
            return nil
        }
        previewCache[handle] = CachedPreview(
            frame: shared.frame,
            token: handle.token,
            lastRequestedUse: coordinator.nextUse(),
            capturedAt: shared.capturedAt
        )
        if traceRecorder.isActive {
            traceRecorder.record(record(
                .previewAdopted,
                token: handle.token,
                pixelWidth: shared.frame.surface.width,
                pixelHeight: shared.frame.surface.height,
                bytes: shared.frame.surface.allocationSize
            ))
        }
        return shared.frame
    }

    func remove(token: WindowToken) {
        let handles = Set(previewCache.compactMap { handle, cached in
            cached.token == token || handle.token == token ? handle : nil
        }).union(sources.values.compactMap { source in
            source.request.token == token || source.request.handle.token == token ? source.request.handle : nil
        })
        for handle in handles { remove(handle: handle) }
    }

    func releaseCache(reason: CacheReleaseReason = .explicitRelease) {
        guard !isPresenting else { return }
        let handles = Array(previewCache.keys)
        if traceRecorder.isActive {
            for cached in previewCache.values {
                traceEviction(cached, reason: reason.traceReason, cachedCount: 0)
            }
        }
        previewCache.removeAll()
        for handle in handles { onPreview(handle, nil) }
    }

    private func removeCachedPreview(for handle: WindowHandle, reason: OverviewFrameTrace.PreviewReason) {
        guard let cached = previewCache.removeValue(forKey: handle) else { return }
        traceEviction(cached, reason: reason)
    }

    private func traceEviction(
        _ cached: CachedPreview,
        reason: OverviewFrameTrace.PreviewReason,
        cachedCount: Int? = nil
    ) {
        guard traceRecorder.isActive else { return }
        traceRecorder.record(record(
            .previewEvicted,
            token: cached.token,
            reason: reason,
            pixelWidth: cached.frame.surface.width,
            pixelHeight: cached.frame.surface.height,
            bytes: cached.frame.surface.allocationSize,
            cachedCount: cachedCount
        ))
    }

    private func trace(_ event: OverviewFrameTrace.Event, source: Source) {
        guard traceRecorder.isActive else { return }
        let cached = previewCache[source.request.handle]
        traceRecorder.record(record(
            event,
            sourceId: source.id,
            requestedAt: source.requestedAt,
            sequence: UInt64(source.request.token.windowId),
            token: source.request.token,
            reason: event == .previewRequested ? (cached == nil ? .cacheMiss : .cachedRefresh) : nil,
            pixelWidth: source.request.pixelWidth,
            pixelHeight: source.request.pixelHeight,
            bytes: cached?.frame.surface.allocationSize ?? 0
        ))
    }

    private func record(
        _ event: OverviewFrameTrace.Event,
        sourceId: UInt64 = 0,
        requestedAt: CFTimeInterval? = nil,
        sequence: UInt64 = 0,
        token: WindowToken? = nil,
        reason: OverviewFrameTrace.PreviewReason? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        bytes: Int = 0,
        cachedCount: Int? = nil
    ) -> OverviewFrameTrace.Record {
        let now = CACurrentMediaTime()
        return OverviewFrameTrace.Record(
            event: event,
            mediaTime: now,
            displayId: 0,
            generation: sourceId,
            sequence: sequence,
            progress: 0,
            durationMs: requestedAt.map { (now - $0) * 1000 } ?? 0,
            waitMs: 0,
            targetLeadMs: 0,
            pendingInvalidations: 0,
            endpointScheduled: false,
            sessionCompleted: false,
            preview: OverviewFrameTrace.Preview(
                consumer: consumer,
                cacheId: cacheId,
                pid: token?.pid ?? 0,
                windowId: token?.windowId ?? 0,
                reason: reason,
                firstFrameOnly: stopsAfterFirstFrame,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                bytes: bytes,
                cachedCount: cachedCount ?? previewCache.count
            )
        )
    }

    private func collectRequests(
        represented: Set<WindowHandle>,
        visible: [OverviewPreviewRequest],
        selectedHandle: WindowHandle?
    ) -> [ObjectIdentifier: OverviewPreviewRequest] {
        var requests: [ObjectIdentifier: OverviewPreviewRequest] = [:]
        sourceOrder.removeAll(keepingCapacity: true)
        for request in visible where represented.contains(request.handle) && request.token == request.handle.token {
            let key = ObjectIdentifier(request.handle)
            if let previous = requests[key] {
                requests[key] = OverviewPreviewRequest(
                    handle: request.handle,
                    pixelWidth: max(previous.pixelWidth, request.pixelWidth),
                    pixelHeight: max(previous.pixelHeight, request.pixelHeight)
                )
            } else {
                requests[key] = request
                sourceOrder.append(key)
            }
        }
        if let selectedHandle,
           let index = sourceOrder.firstIndex(of: ObjectIdentifier(selectedHandle)), index != 0
        {
            sourceOrder.insert(sourceOrder.remove(at: index), at: 0)
        }
        return requests
    }
}
