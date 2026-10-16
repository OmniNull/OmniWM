// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

struct ShellResourceImage: Equatable, Sendable {
    let owner: ShellServiceOwner
    let resource: ShellResourceID
    let revision: UInt64

    init(_ source: String) throws {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "v1",
              let generation = UInt64(parts[1]), String(generation) == parts[1],
              let owner = UInt32(parts[2]), String(owner) == parts[2],
              let epoch = UInt32(parts[3]), String(epoch) == parts[3],
              let id = UUID(uuidString: String(parts[4])), id.uuidString.lowercased() == parts[4],
              let revision = UInt64(parts[5]), String(revision) == parts[5]
        else { throw ShellResourceFailure("invalid resource image identity") }
        self.owner = ShellServiceOwner(generation: generation, owner: owner, epoch: epoch)
        resource = ShellResourceID(id)
        self.revision = revision
    }
}

@MainActor
final class ShellResourceImages {
    private struct Target {
        weak var surface: ShellWidgetSurface?
        let handle: ElementHandle
        let binding: ShellThumbnailBinding
    }

    private let store: ShellResourceStore
    private let producer: ShellResourceThumbnails.Produce?
    private var targets: [UUID: Target] = [:]
    private var closing = false
    private lazy var thumbnails = ShellResourceThumbnails(store: store, producer: producer) { [weak self] completion in
        Task { @MainActor [weak self] in self?.receive(completion) }
    }

    init(store: ShellResourceStore, producer: ShellResourceThumbnails.Produce? = nil) {
        self.store = store
        self.producer = producer
    }

    func captureBegin(_ id: UInt64) async {
        await thumbnails.captureBegin(id)
    }

    func captureEnd(_ id: UInt64) async -> ShellResourceThumbnails.Capture? {
        await thumbnails.captureEnd(id)
    }

    func bind(
        _ image: ShellResourceImage,
        points: Double,
        scale: Double,
        surface: ShellWidgetSurface,
        handle: ElementHandle
    ) throws -> ShellThumbnailBinding {
        guard !closing, let metadata = store.catalog.metadata(image.resource, owner: image.owner),
              metadata.revision == image.revision
        else { throw ShellResourceFailure("resource image owner or revision is stale") }
        let request = try ShellThumbnailRequest(
            resource: image.resource,
            owner: image.owner,
            revision: image.revision,
            points: points,
            scale: scale
        )
        let binding = ShellThumbnailBinding(request: request)
        targets[binding.id] = Target(surface: surface, handle: handle, binding: binding)
        let thumbnails = thumbnails
        Task { [weak self] in
            do { try await thumbnails.acquire(binding) }
            catch { self?.receiveAdmissionFailure(binding, error: String(describing: error)) }
        }
        return binding
    }

    func bitmap(_ binding: ShellThumbnailBinding) -> CGImage? {
        thumbnails.cache.bitmap(binding)
    }

    func release(_ binding: ShellThumbnailBinding) {
        binding.cancel()
        targets.removeValue(forKey: binding.id)
        let thumbnails = thumbnails
        Task { await thumbnails.release(binding) }
    }

    func retire(_ owner: ShellServiceOwner) async {
        for (id, target) in targets where target.binding.request.owner == owner {
            target.binding.cancel()
            targets.removeValue(forKey: id)
        }
        await thumbnails.retire(owner)
    }

    func close() async {
        closing = true
        for target in targets.values { target.binding.cancel() }
        targets.removeAll()
        await thumbnails.close()
    }

    private func receive(_ completion: ShellResourceThumbnails.Completion) {
        for binding in completion.bindings {
            guard let target = targets[binding.id] else { continue }
            guard let surface = target.surface else { release(binding)
                continue
            }
            guard thumbnails.cache.isCurrent(binding) else { continue }
            surface.resourceImageCompleted(
                binding,
                handle: target.handle,
                image: completion.image,
                error: completion.error
            )
        }
    }

    private func receiveAdmissionFailure(_ binding: ShellThumbnailBinding, error: String) {
        guard binding.isActive, let target = targets[binding.id], let surface = target.surface else { return }
        surface.resourceImageCompleted(binding, handle: target.handle, image: nil, error: error)
    }
}
