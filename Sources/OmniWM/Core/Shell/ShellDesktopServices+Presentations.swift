// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellDesktopServices {
    func present(
        _ operation: Operation,
        ids: [ShellResourceID],
        source: ShellDesktopSource?,
        anchor: ShellDesktopAnchor?,
        resolveAnchor: (@MainActor () async throws -> ShellDesktopAnchor)?
    ) {
        guard let source, source.isCurrent() else {
            finish(operation, result: ShellDesktopResult(error: "source_surface_unavailable"))
            return
        }
        Task { [self] in
            do {
                operation.pin = try await resources.retain(ids, owner: operation.request.id.owner)
                guard current(operation), source.isCurrent(), let pin = operation.pin else {
                    finish(operation, result: ShellDesktopResult(error: "cancelled"))
                    return
                }
                let completion: ShellDesktopPlatform.PresentationCompletion = { [self] error in
                    finish(operation, result: ShellDesktopResult(error: error))
                }
                let presentation: ShellDesktopPlatform.Presentation
                switch operation.request.action {
                case let .quicklook(_, index):
                    let urls = try pin.values.map { value -> URL in
                        guard case let .file(url) = value else { throw ShellResourceFailure("unsupported_resource") }
                        return url
                    }
                    presentation = try platform.quicklook(urls, index, source, completion)
                case let .share(_, service):
                    let resolved = try await resolveAnchor?() ?? anchor
                    guard current(operation), source.isCurrent(), let resolved, resolved.isCurrent() else {
                        throw ShellResourceFailure("anchor_unavailable")
                    }
                    presentation = try platform.share(pin.values, service, source, resolved, completion)
                default:
                    throw ShellResourceFailure("invalid_desktop_operation")
                }
                if operations[operation.request.id] === operation, !operation.finishing {
                    operation.cancelPresentation = presentation.cancel
                    guard current(operation), source.isCurrent() else {
                        finish(operation, result: ShellDesktopResult(error: "cancelled"))
                        return
                    }
                    try presentation.start()
                    if !operation.fence.isActive { presentation.cancel() }
                }
            } catch {
                finish(operation, result: ShellDesktopResult(error: String(describing: error)))
            }
        }
    }

    func picked(_ operation: Operation, result: Result<[URL], ShellResourceFailure>) {
        let id = operation.request.id
        guard operations[id] === operation, picker == id else { return }
        picker = nil
        operation.cancelPresentation = nil
        guard current(operation) else {
            finish(operation, result: ShellDesktopResult(error: "cancelled"))
            return
        }
        switch result {
        case let .failure(error):
            finish(operation, result: ShellDesktopResult(error: error.description))
        case let .success(urls):
            Task { [self] in
                var selection: ShellResourceStore.Selection?
                var ids: [ShellResourceID] = []
                do {
                    let prepared = try await resources.prepareSelection(
                        urls,
                        owner: id.owner,
                        operation: operation.fence
                    )
                    selection = prepared
                    guard current(operation) else { throw ShellResourceFailure("cancelled") }
                    ids = try await operation.bridge.admit(id, prepared.items)
                    guard current(operation) else { throw ShellResourceFailure("cancelled") }
                    try await resources.installSelection(
                        prepared,
                        ids: ids,
                        owner: id.owner,
                        operation: operation.fence
                    )
                    selection = nil
                    if !finish(operation, result: ShellDesktopResult(resources: ids)) {
                        await operation.bridge.release(ids, owner: id.owner, store: resources)
                    }
                } catch {
                    if let selection { await resources.discardSelection(selection) }
                    if !ids.isEmpty { await operation.bridge.release(ids, owner: id.owner, store: resources) }
                    finish(operation, result: ShellDesktopResult(error: String(describing: error)))
                }
            }
        }
    }

    func readClipboard(_ items: [ShellDropItem], operation: Operation) {
        guard !items.isEmpty else {
            finish(operation, result: ShellDesktopResult(resources: []))
            return
        }
        Task { [self] in
            let id = operation.request.id
            var ids: [ShellResourceID] = []
            do {
                guard items.count <= ShellResourceStore.attachmentLimit,
                      current(operation) else { throw ShellResourceFailure("clipboard_unavailable") }
                ids = try await operation.bridge.admit(
                    id,
                    items.map { ShellPickedResource(name: $0.name, kind: $0.kind, uti: $0.uti) }
                )
                guard current(operation) else { throw ShellResourceFailure("cancelled") }
                try await resources.materialize(items.map(\.source), ids: ids, owner: id.owner)
                if !finish(operation, result: ShellDesktopResult(resources: ids)) {
                    await operation.bridge.release(ids, owner: id.owner, store: resources)
                }
            } catch {
                if !ids.isEmpty { await operation.bridge.release(ids, owner: id.owner, store: resources) }
                finish(operation, result: ShellDesktopResult(error: String(describing: error)))
            }
        }
    }
}
