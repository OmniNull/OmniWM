// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
final class ShellDesktopServices {
    @MainActor
    final class Operation {
        let request: ShellDesktopRequest
        let ledger: ShellServiceLedger
        let bridge: ShellDesktopResourceBridge
        let fence: ShellResourceOperation
        var cancelPresentation: ShellDesktopPlatform.CancelPresentation?
        var pin: ShellResourceStore.Pin?
        var finishing = false

        init(
            request: ShellDesktopRequest,
            ledger: ShellServiceLedger,
            bridge: ShellDesktopResourceBridge,
            fence: ShellResourceOperation
        ) {
            self.request = request
            self.ledger = ledger
            self.bridge = bridge
            self.fence = fence
        }
    }

    let resources: ShellResourceStore
    let platform: ShellDesktopPlatform
    var operations: [ShellServiceID: Operation] = [:]
    var picker: ShellServiceID?
    var preview: ShellServiceID?

    init(resources: ShellResourceStore, platform: ShellDesktopPlatform = .appKit) {
        self.resources = resources
        self.platform = platform
    }

    @discardableResult
    func perform(
        _ request: ShellDesktopRequest,
        ledger: ShellServiceLedger,
        bridge: ShellDesktopResourceBridge,
        source: ShellDesktopSource? = nil,
        anchor: ShellDesktopAnchor? = nil,
        resolveAnchor: (@MainActor () async throws -> ShellDesktopAnchor)? = nil,
        registered: Bool = false
    ) -> Bool {
        let fence = ShellResourceOperation()
        let cancel: @Sendable () -> Void = { [weak self] in
            fence.cancel()
            Task { @MainActor in self?.cancel(request.id) }
        }
        let discard: @Sendable (ShellServiceCompletion) -> Void = { [resources] completion in
            guard let ids = completion.desktopResources, !ids.isEmpty else { return }
            Task { await bridge.release(ids, owner: completion.id.owner, store: resources) }
        }
        let accepted = registered
            ? ledger.adopt(request.id, cancel: cancel, discard: discard)
            : ledger.register(request.id, cancel: cancel, discard: discard)
        guard accepted else { return false }
        var ownerCount = 0
        var generationCount = 0
        for id in operations.keys where id.owner.generation == request.id.owner.generation {
            generationCount += 1
            if id.owner == request.id.owner { ownerCount += 1 }
        }
        guard ownerCount < 32, generationCount < 256 else {
            ledger.complete(ShellServiceCompletion(
                id: request.id,
                payload: ShellDesktopResult(error: "desktop_busy").payload
            ))
            return true
        }
        let operation = Operation(request: request, ledger: ledger, bridge: bridge, fence: fence)
        operations[request.id] = operation
        guard current(operation) else {
            finish(operation, result: ShellDesktopResult(error: "cancelled"))
            return true
        }
        dispatch(operation, source: source, anchor: anchor, resolveAnchor: resolveAnchor)
        return true
    }

    func open(_ url: URL, operation: Operation) {
        guard current(operation) else {
            finish(operation, result: ShellDesktopResult(error: "cancelled"))
            return
        }
        platform.open(url) { [self] error in
            Task { @MainActor in finish(operation, result: ShellDesktopResult(error: error)) }
        }
    }

    func cancel(_ id: ShellServiceID) {
        operations[id]?.cancelPresentation?()
    }

    func current(_ operation: Operation) -> Bool {
        operations[operation.request.id] === operation && operation.fence.isActive && resources.catalog
            .isActive(operation.request.id.owner)
    }

    @discardableResult
    func finish(_ operation: Operation, result: ShellDesktopResult) -> Bool {
        let id = operation.request.id
        guard operations[id] === operation, !operation.finishing else { return false }
        let deliver = current(operation)
        operation.finishing = true
        operation.cancelPresentation = nil
        if let pin = operation.pin {
            operation.pin = nil
            Task { [self] in
                await resources.release(pin)
                retire(operation)
                if operation.fence.isActive {
                    let completion = deliver ? result : ShellDesktopResult(error: "cancelled")
                    operation.ledger.complete(ShellServiceCompletion(id: id, payload: completion.payload))
                }
            }
            return false
        }
        retire(operation)
        guard deliver else {
            if operation.fence.isActive {
                operation.ledger.complete(ShellServiceCompletion(
                    id: id,
                    payload: ShellDesktopResult(error: "cancelled").payload
                ))
            }
            return false
        }
        return operation.ledger.complete(ShellServiceCompletion(
            id: id,
            payload: result.payload,
            desktopResources: result.resources
        ))
    }

    func retire(_ operation: Operation) {
        let id = operation.request.id
        guard operations[id] === operation else { return }
        operations.removeValue(forKey: id)
        if preview == id { preview = nil }
    }

    static func urlError(_ url: URL) -> String? {
        if url.isFileURL { return "file_url_requires_resource" }
        guard let scheme = url.scheme, !scheme.isEmpty else { return "invalid_url" }
        return nil
    }
}
