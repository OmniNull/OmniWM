// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellDesktopRequest: Sendable {
    enum Action: Sendable {
        case pick(multiple: Bool)
        case openURL(URL)
        case open(ShellResourceID)
        case reveal(ShellResourceID)
        case quicklook([ShellResourceID], index: Int)
        case share([ShellResourceID], service: String?)
        case clipboardCopy(ShellResourceID)
        case clipboardText(String)
        case clipboardRead
    }

    let id: ShellServiceID
    let action: Action
    let anchor: ShellDesktopAnchorLocator?

    init(id: ShellServiceID, action: Action, anchor: ShellDesktopAnchorLocator? = nil) {
        self.id = id
        self.action = action
        self.anchor = anchor
    }
}

struct ShellPickedResource: Equatable, Sendable {
    let name: String
    let kind: String
    let uti: String
}

struct ShellDesktopResourceBridge: Sendable {
    let admit: @Sendable (ShellServiceID, [ShellPickedResource]) async throws -> [ShellResourceID]
    let retireIDs: @Sendable (ShellServiceOwner, [ShellResourceID]) async -> Void

    func release(_ ids: [ShellResourceID], owner: ShellServiceOwner, store: ShellResourceStore) async {
        await store.release(ids, owner: owner)
        await retireIDs(owner, ids)
    }
}

struct ShellDesktopResult: Equatable, Sendable {
    var error: String?
    var resources: [ShellResourceID]?

    var payload: [UInt8] {
        var writer = ShellValueWriter()
        writer.map(error == nil ? 1 : 2)
        writer.key("ok")
        writer.bool(error == nil)
        if let error {
            writer.key("error")
            writer.string(String(error.prefix(1024)))
        }
        return writer.bytes
    }
}
