// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import UniformTypeIdentifiers

extension ShellResourceStore {
    struct Selection: Sendable {
        let token: UUID
        let items: [ShellPickedResource]
    }

    struct PreparingSelection {
        let owner: ShellServiceOwner
        let items: [Backing]
    }

    func prepareSelection(
        _ urls: [URL],
        owner: ShellServiceOwner,
        operation: ShellResourceOperation
    ) throws -> Selection {
        guard operation.isActive, catalog.isActive(owner) else { throw ShellResourceFailure("cancelled") }
        guard !urls.isEmpty,
              urls.count <= Self.attachmentLimit else { throw ShellResourceFailure("pick exceeds 32 files") }
        var prepared: [Backing] = []
        var items: [ShellPickedResource] = []
        do {
            for url in urls {
                guard operation.isActive else { throw ShellResourceFailure("cancelled") }
                let item = try prepare(.file(url))
                prepared.append(item)
                let values = try url.resourceValues(forKeys: [.contentTypeKey])
                let uti = values.contentType?.identifier ?? UTType(filenameExtension: url.pathExtension)?
                    .identifier ?? UTType.data.identifier
                items.append(ShellPickedResource(name: url.lastPathComponent, kind: "file", uti: uti))
            }
            guard operation.isActive, catalog.isActive(owner) else { throw ShellResourceFailure("cancelled") }
            let token = UUID()
            selections[token] = PreparingSelection(owner: owner, items: prepared)
            return Selection(token: token, items: items)
        } catch {
            for item in prepared { clean(item.ownedDirectory) }
            throw error
        }
    }

    func installSelection(
        _ selection: Selection,
        ids: [ShellResourceID],
        owner: ShellServiceOwner,
        operation: ShellResourceOperation
    ) throws {
        guard let prepared = selections.removeValue(forKey: selection.token)
        else { throw ShellResourceFailure("selection is no longer available") }
        do {
            guard prepared.owner == owner, ids.count == selection.items.count, prepared.items.count == ids.count,
                  operation.isActive, catalog.isActive(owner)
            else { throw ShellResourceFailure("selection admission is no longer valid") }
            try install(prepared.items, ids: ids, owner: owner, operation: operation)
            finishWaiting(ids)
        } catch {
            for item in prepared.items { clean(item.ownedDirectory) }
            throw error
        }
    }

    func discardSelection(_ selection: Selection) {
        guard let prepared = selections.removeValue(forKey: selection.token) else { return }
        for item in prepared.items { clean(item.ownedDirectory) }
    }
}
