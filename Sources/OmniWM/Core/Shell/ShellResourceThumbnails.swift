// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

actor ShellResourceThumbnails {
    struct Capture: Equatable, Sendable {
        let id: UInt64
        let producerAttempts: UInt64
        let producerSuccesses: UInt64
        let cache: ShellThumbnailCache.Capture

        var detail: String {
            "utility=thumbnails producer_attempts=\(producerAttempts) producer_successes=\(producerSuccesses) "
                + cache.detail
        }
    }

    private struct ProductionCapture {
        var id: UInt64 = 0
        var attempts: UInt64 = 0
        var successes: UInt64 = 0
    }

    struct Completion: Sendable {
        let bindings: [ShellThumbnailBinding]
        let image: CGImage?
        let error: String?
    }

    typealias Produce = @Sendable (ShellResourceStore.ThumbnailSource, ShellThumbnailRequest) async throws -> CGImage

    private struct Job {
        var bindings: Set<ShellThumbnailBinding>
        var task: Task<Void, Never>?
    }

    private let queue = DispatchSerialQueue(label: "com.barut.OmniWM.shell.thumbnails", qos: .utility)
    private let store: ShellResourceStore
    private let produce: Produce
    private let completed: @Sendable (Completion) -> Void
    private var jobs: [ShellThumbnailRequest: Job] = [:]
    private var waiting: [ShellThumbnailRequest] = []
    private var active = 0
    private var closing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var capture = ProductionCapture()
    nonisolated let cache: ShellThumbnailCache
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(
        store: ShellResourceStore,
        producer: Produce? = nil,
        completed: @escaping @Sendable (Completion) -> Void = { _ in }
    ) {
        self.store = store
        cache = ShellThumbnailCache(catalog: store.catalog)
        let native = ShellThumbnailProducer()
        produce = producer ?? { try await native.produce($0, request: $1) }
        self.completed = completed
    }

    func captureBegin(_ id: UInt64) {
        guard id != 0, capture.id != id else { return }
        capture = ProductionCapture(id: id)
        cache.captureBegin(id)
    }

    func captureEnd(_ id: UInt64) -> Capture? {
        guard id != 0, capture.id == id, let cache = cache.captureEnd(id) else { return nil }
        defer { capture = ProductionCapture() }
        return Capture(id: id, producerAttempts: capture.attempts, producerSuccesses: capture.successes, cache: cache)
    }

    nonisolated func binding(
        resource: ShellResourceID,
        owner: ShellServiceOwner,
        points: Double,
        scale: Double
    ) throws -> ShellThumbnailBinding {
        guard let metadata = store.catalog.metadata(resource, owner: owner)
        else { throw ShellResourceFailure("thumbnail owner is inactive") }
        let request = try ShellThumbnailRequest(
            resource: resource,
            owner: owner,
            revision: metadata.revision,
            points: points,
            scale: scale
        )
        return ShellThumbnailBinding(request: request)
    }

    func acquire(_ binding: ShellThumbnailBinding) throws {
        guard !closing else { throw ShellResourceFailure("thumbnail service is closed") }
        let request = binding.request
        guard let metadata = store.catalog.metadata(request.resource, owner: request.owner),
              metadata.revision == request.revision
        else { throw ShellResourceFailure("thumbnail resource changed before admission") }
        guard cache.admit(binding) else { throw ShellResourceFailure("thumbnail binding was cancelled") }
        if metadata.state == .failed {
            finishFailure([binding], error: metadata.error ?? "resource failed")
        } else if metadata.state == .ready {
            if jobs[request] != nil { jobs[request]?.bindings.insert(binding) }
            else if active >= 2, waiting.count >= 64 { finishFailure([binding], error: "thumbnail queue is full") }
            else {
                jobs[request] = Job(bindings: [binding])
                waiting.append(request)
                pump()
            }
        }
    }

    func release(_ binding: ShellThumbnailBinding) {
        binding.cancel()
        cache.remove(binding)
        guard var job = jobs[binding.request] else { return }
        job.bindings.remove(binding)
        if job.bindings.isEmpty {
            if let task = job.task { task.cancel()
                jobs[binding.request] = job
            } else { jobs.removeValue(forKey: binding.request)
                waiting.removeAll { $0 == binding.request }
            }
        } else { jobs[binding.request] = job }
    }

    func retire(_ owner: ShellServiceOwner) {
        cache.retire(owner)
        for request in Array(jobs.keys) where request.owner == owner {
            if let task = jobs[request]?.task { jobs[request]?.bindings.removeAll()
                task.cancel()
            } else { jobs.removeValue(forKey: request)
                waiting.removeAll { $0 == request }
            }
        }
    }

    func close() async {
        closing = true
        cache.removeAll()
        waiting.removeAll()
        for request in Array(jobs.keys) {
            if let task = jobs[request]?.task { jobs[request]?.bindings.removeAll()
                task.cancel()
            } else { jobs.removeValue(forKey: request) }
        }
        guard active > 0 else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    private func pump() {
        while active < 2, !waiting.isEmpty {
            let request = waiting.removeFirst()
            guard jobs[request] != nil else { continue }
            active += 1
            jobs[request]?.task = Task { await self.run(request) }
        }
    }

    private func run(_ request: ShellThumbnailRequest) async {
        var pin: ShellResourceStore.Pin?
        do {
            try Task.checkCancellation()
            let source = try await store.thumbnailSource(request)
            pin = source.pin
            try Task.checkCancellation()
            let key = ShellThumbnailKey(
                backing: source.backing,
                revision: request.revision,
                pixels: request.pixels,
                scale: request.scale
            )
            let image: CGImage
            if let cached = cache.cached(key) { image = cached }
            else {
                let captureID = capture.id
                if captureID != 0 { capture.attempts &+= 1 }
                image = try await produce(source, request)
                if captureID != 0, capture.id == captureID { capture.successes &+= 1 }
            }
            try Task.checkCancellation()
            let bindings = try cache.publish(image, key: key, bindings: Array(jobs[request]?.bindings ?? []))
            if !bindings.isEmpty { completed(Completion(bindings: bindings, image: image, error: nil)) }
        } catch {
            if !Task
                .isCancelled { finishFailure(Array(jobs[request]?.bindings ?? []), error: String(describing: error)) }
        }
        await finishRun(request, pin: pin)
    }

    private func finishRun(_ request: ShellThumbnailRequest, pin: ShellResourceStore.Pin?) async {
        let remaining = jobs.removeValue(forKey: request)?.bindings ?? []
        if let pin { await store.release(pin) }
        active -= 1
        if Task.isCancelled {
            let current = remaining.filter { cache.isCurrent($0) }
            if !current.isEmpty {
                if jobs[request] != nil { jobs[request]?.bindings.formUnion(current) }
                else { jobs[request] = Job(bindings: Set(current))
                    waiting.insert(request, at: 0)
                }
            }
        }
        pump()
        if closing, active == 0 {
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func finishFailure(_ bindings: [ShellThumbnailBinding], error: String) {
        let current = cache.fail(bindings, error: error)
        if !current.isEmpty { completed(Completion(bindings: current, image: nil, error: error)) }
    }
}
