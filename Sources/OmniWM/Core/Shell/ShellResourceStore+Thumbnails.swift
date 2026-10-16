// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellResourceStore {
    struct ThumbnailSource: Sendable {
        let pin: Pin
        let backing: UUID
        let file: URL
        let uti: String
    }

    func thumbnailSource(_ request: ShellThumbnailRequest) throws -> ThumbnailSource {
        guard let metadata = catalog.metadata(request.resource, owner: request.owner),
              metadata.state == .ready, metadata.revision == request.revision,
              let record = records[request.resource], record.owner == request.owner,
              let item = backing[record.backing], case let .file(file) = item.value
        else { throw ShellResourceFailure("thumbnail resource is not a ready file") }
        _ = try fileSize(file)
        let pin = try retain([request.resource], owner: request.owner)
        return ThumbnailSource(pin: pin, backing: item.id, file: file, uti: metadata.descriptor.uti)
    }
}
