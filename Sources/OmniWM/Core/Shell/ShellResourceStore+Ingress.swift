// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellResourceStore {
    func ingressDirectory() throws -> URL {
        try makeDirectory("promises")
    }

    func receive(
        _ file: ShellResourceReceivedFile,
        id: ShellResourceID,
        owner: ShellServiceOwner,
        operation: ShellResourceOperation
    ) throws {
        let item = Backing(id: UUID(), value: .file(file.file), size: file.size, ownedDirectory: file.directory)
        do {
            try install([item], ids: [id], owner: owner, operation: operation)
            finishWaiting([id])
        } catch {
            clean(file.directory)
            fail([id], owner: owner, error: String(describing: error))
            throw error
        }
    }

    func discard(_ files: [ShellResourceReceivedFile]) {
        for file in files { clean(file.directory) }
    }

    func finishIngress(_ directory: URL) {
        clean(directory)
    }
}
