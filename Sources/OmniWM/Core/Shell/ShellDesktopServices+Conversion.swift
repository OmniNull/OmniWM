// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellDesktopServices {
    func convert(_ operation: Operation, ids: [ShellResourceID], format: ShellImageConversionFormat) {
        let key = ShellResourceLeaseKey(id: operation.request.id, incarnation: 0)
        operation.cancelPresentation = { [self] in
            operation.cancelPresentation = nil
            retire(operation)
            Task { await resources.finishAction(key) }
        }
        Task { [self] in
            await resources.beginAction(key, inputs: ids, operation: operation.fence) { [self] result in
                Task { @MainActor in await convertPrepared(operation, key: key, format: format, result: result) }
            }
        }
    }

    private func convertPrepared(
        _ operation: Operation,
        key: ShellResourceLeaseKey,
        format: ShellImageConversionFormat,
        result: Result<ShellResourceStore.ActionFiles, ShellResourceFailure>
    ) async {
        var ids: [ShellResourceID] = []
        do {
            _ = try result.get()
            guard current(operation) else { throw ShellResourceFailure("cancelled") }
            let converted = try await resources
                .convertImages(key, format: format) { [ledger = operation.ledger] completed, total in
                    var writer = ShellValueWriter()
                    writer.map(1)
                    writer.key("progress")
                    writer.map(2)
                    writer.key("completed")
                    writer.number(Double(completed))
                    writer.key("total")
                    writer.number(Double(total))
                    ledger.complete(ShellServiceCompletion(id: key.id, payload: writer.bytes, isProgress: true))
                }
            guard current(operation) else { throw ShellResourceFailure("cancelled") }
            ids = try await operation.bridge.admit(key.id, converted.descriptors)
            guard current(operation) else { throw ShellResourceFailure("cancelled") }
            try await resources.importOutputs(converted.files, ids: ids, action: key)
            if !finish(operation, result: ShellDesktopResult(resources: ids)) {
                await operation.bridge.release(ids, owner: key.id.owner, store: resources)
            }
        } catch {
            if !ids.isEmpty { await operation.bridge.release(ids, owner: key.id.owner, store: resources) }
            finish(operation, result: ShellDesktopResult(error: String(describing: error)))
        }
        await resources.finishAction(key)
    }
}
