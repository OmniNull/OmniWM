// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import Synchronization

struct ShellThumbnailRequest: Hashable, Sendable {
    let owner: ShellServiceOwner
    let resource: ShellResourceID
    let revision: UInt64
    let pixels: Int
    let scale: Double

    init(resource: ShellResourceID, owner: ShellServiceOwner, revision: UInt64, points: Double, scale: Double) throws {
        let pixels = (points * scale).rounded(.up)
        guard points.isFinite, points > 0, scale.isFinite, scale > 0,
              pixels.isFinite, pixels >= 1, pixels <= 2048
        else { throw ShellResourceFailure("thumbnail size exceeds 2048 physical pixels") }
        self.resource = resource
        self.owner = owner
        self.revision = revision
        self.pixels = Int(pixels)
        self.scale = scale
    }
}

struct ShellThumbnailBinding: Hashable, Sendable {
    let id = UUID()
    let request: ShellThumbnailRequest
    let operation = ShellResourceOperation()

    var isActive: Bool {
        operation.whileActive { true } ?? false
    }

    func cancel() {
        operation.cancel()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ShellThumbnailKey: Hashable, Sendable {
    let backing: UUID
    let revision: UInt64
    let pixels: Int
    let scale: Double
}

final class ShellThumbnailCache: Sendable {
    struct Capture: Equatable, Sendable {
        var id: UInt64 = 0
        var bytesBegin = 0
        var bytesEnd = 0
        var bytesPeak = 0
        var entriesBegin = 0
        var entriesEnd = 0
        var entriesPeak = 0

        var detail: String {
            "cache_bytes_begin=\(bytesBegin) cache_bytes_end=\(bytesEnd) cache_bytes_peak=\(bytesPeak)"
                + " cache_entries_begin=\(entriesBegin) cache_entries_end=\(entriesEnd) cache_entries_peak=\(entriesPeak)"
        }
    }

    enum Status: Equatable, Sendable { case pending, ready, evicted, failed(String) }

    private enum BindingState { case pending, ready(ShellThumbnailKey), failed(String) }
    private struct Image {
        let image: CGImage
        let cost: Int
        var touched: UInt64
        var owners: Set<ShellServiceOwner>
    }

    private struct State {
        var clock: UInt64 = 0
        var bytes = 0
        var images: [ShellThumbnailKey: Image] = [:]
        var bindings: [ShellThumbnailBinding: BindingState] = [:]
        var capture = Capture()
    }

    let byteLimit: Int
    let entryLimit: Int
    let catalog: ShellResourceCatalog
    private let state = Mutex(State())

    init(catalog: ShellResourceCatalog, byteLimit: Int = 64 << 20, entryLimit: Int = 512) {
        self.catalog = catalog
        self.byteLimit = byteLimit
        self.entryLimit = entryLimit
    }

    var retainedBytes: Int {
        state.withLock { $0.bytes }
    }

    var entryCount: Int {
        state.withLock { $0.images.count }
    }

    func captureBegin(_ id: UInt64) {
        state.withLock {
            guard id != 0, $0.capture.id != id else { return }
            $0.capture = Capture(
                id: id, bytesBegin: $0.bytes, bytesPeak: $0.bytes,
                entriesBegin: $0.images.count, entriesPeak: $0.images.count
            )
        }
    }

    func captureEnd(_ id: UInt64) -> Capture? {
        state.withLock {
            guard id != 0, $0.capture.id == id else { return nil }
            $0.capture.bytesEnd = $0.bytes
            $0.capture.entriesEnd = $0.images.count
            defer { $0.capture = Capture() }
            return $0.capture
        }
    }

    func isCurrent(_ binding: ShellThumbnailBinding) -> Bool {
        guard binding.isActive, let metadata = catalog.metadata(binding.request.resource, owner: binding.request.owner),
              metadata.revision == binding.request.revision
        else { return false }
        return state.withLock { $0.bindings[binding] != nil }
    }

    func status(_ binding: ShellThumbnailBinding) -> Status? {
        guard isCurrent(binding) else { return nil }
        return state.withLock { state in
            switch state.bindings[binding] {
            case .pending: return .pending
            case let .failed(error): return .failed(error)
            case let .ready(key): return state.images[key] == nil ? .evicted : .ready
            case nil: return nil
            }
        }
    }

    func bitmap(_ binding: ShellThumbnailBinding) -> CGImage? {
        guard isCurrent(binding) else { return nil }
        return state.withLock { state in
            guard case let .ready(key) = state.bindings[binding], var entry = state.images[key] else { return nil }
            state.clock &+= 1
            entry.touched = state.clock
            state.images[key] = entry
            return entry.image
        }
    }

    @discardableResult
    func admit(_ binding: ShellThumbnailBinding) -> Bool {
        binding.operation.whileActive { state.withLock { $0.bindings[binding] = .pending }
            return true
        } ?? false
    }

    func remove(_ binding: ShellThumbnailBinding) {
        _ = state.withLock { $0.bindings.removeValue(forKey: binding) }
    }

    func cached(_ key: ShellThumbnailKey) -> CGImage? {
        state.withLock { state in
            guard var entry = state.images[key] else { return nil }
            state.clock &+= 1
            entry.touched = state.clock
            state.images[key] = entry
            return entry.image
        }
    }

    func publish(
        _ image: CGImage,
        key: ShellThumbnailKey,
        bindings: [ShellThumbnailBinding]
    ) throws -> [ShellThumbnailBinding] {
        let cost = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard image.width > 0, image.height > 0, image.width <= key.pixels, image.height <= key.pixels,
              !cost.overflow, cost.partialValue > 0, cost.partialValue <= byteLimit, entryLimit > 0
        else { throw ShellResourceFailure("thumbnail image exceeds cache limits") }
        let bindings = bindings.filter(isCurrent)
        guard !bindings.isEmpty else { return [] }
        return state.withLock { state in
            let bindings = bindings.filter { state.bindings[$0] != nil }
            guard !bindings.isEmpty else { return [] }
            let previous = state.images.removeValue(forKey: key)
            if let previous { state.bytes -= previous.cost }
            while state.bytes + cost.partialValue > byteLimit || state.images.count >= entryLimit {
                guard let oldest = state.images.min(by: { $0.value.touched < $1.value.touched })?.key,
                      let removed = state.images.removeValue(forKey: oldest)
                else { break }
                state.bytes -= removed.cost
            }
            state.clock &+= 1
            state.images[key] = Image(
                image: image,
                cost: cost.partialValue,
                touched: state.clock,
                owners: (previous?.owners ?? []).union(bindings.map(\.request.owner))
            )
            state.bytes += cost.partialValue
            if state.capture.id != 0 {
                state.capture.bytesPeak = max(state.capture.bytesPeak, state.bytes)
                state.capture.entriesPeak = max(state.capture.entriesPeak, state.images.count)
            }
            for binding in bindings { state.bindings[binding] = .ready(key) }
            return bindings
        }
    }

    func fail(_ bindings: [ShellThumbnailBinding], error: String) -> [ShellThumbnailBinding] {
        let current = bindings.filter(isCurrent)
        return state.withLock { state in
            let current = current.filter { state.bindings[$0] != nil }
            for binding in current { state.bindings[binding] = .failed(String(error.prefix(1024))) }
            return current
        }
    }

    func removeAll() {
        state.withLock {
            let capture = $0.capture
            $0 = State()
            $0.capture = capture
        }
    }

    func retire(_ owner: ShellServiceOwner) {
        state.withLock { state in
            state.bindings = state.bindings.filter { $0.key.request.owner != owner }
            for key in state.images.keys {
                state.images[key]?.owners.remove(owner)
                if state.images[key]?.owners.isEmpty == true,
                   let removed = state.images.removeValue(forKey: key) { state.bytes -= removed.cost }
            }
        }
    }
}
