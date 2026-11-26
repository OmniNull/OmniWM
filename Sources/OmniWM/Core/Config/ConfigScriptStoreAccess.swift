// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

struct ConfigScriptStoreAccess {
    let store: ConfigScriptStore
    var staged: ConfigScriptStoreStage?

    init(store: ConfigScriptStore) {
        self.store = store
    }

    mutating func get(_ span: omni_config_span, into read: inout omni_config_store_read) throws(ConfigScriptError) {
        let key = try ConfigScriptStore.key(span)
        try load()
        guard let value = staged?.snapshot.values[key] else { return }
        guard value.write(to: &read) else {
            throw ConfigScriptError(line: nil, message: "A stored value doesn't fit the read buffer.")
        }
    }

    mutating func set(
        _ span: omni_config_span, to value: omni_config_store_value, at site: omni_config_location
    ) throws(ConfigScriptError) {
        let key = try ConfigScriptStore.key(span)
        try load()
        try staged?.set(key, to: value, at: site)
    }

    mutating func clear(_ span: omni_config_span?, at site: omni_config_location) throws(ConfigScriptError) {
        guard let span else {
            try load(replacingCorruptAt: site)
            staged?.clearAll(at: site)
            return
        }
        let key = try ConfigScriptStore.key(span)
        try load()
        staged?.clear(key, at: site)
    }

    private mutating func load(replacingCorruptAt site: omni_config_location? = nil) throws(ConfigScriptError) {
        guard staged == nil else { return }
        switch store.committed() {
        case let .success(snapshot):
            staged = ConfigScriptStoreStage(snapshot: snapshot)
        case .failure(.corrupt) where site != nil:
            staged = ConfigScriptStoreStage(snapshot: ConfigScriptStore.Snapshot(), replacingAt: site)
        case let .failure(error):
            throw ConfigScriptError(line: nil, message: error.message)
        }
    }
}

extension ConfigScriptStage {
    static var storeCallbacks: omni_config_store_callbacks {
        omni_config_store_callbacks(
            get: { context, key, read, error, capacity in
                guard let read else { return false }
                return Self.withStore(context, error: error, capacity: capacity) { access throws(ConfigScriptError) in
                    try access.get(key, into: &read.pointee)
                }
            },
            set: { context, key, value, location, error, capacity in
                guard let value else { return false }
                return Self.withStore(context, error: error, capacity: capacity) { access throws(ConfigScriptError) in
                    try access.set(key, to: value.pointee, at: location)
                }
            },
            clear: { context, key, location, error, capacity in
                Self.withStore(context, error: error, capacity: capacity) { access throws(ConfigScriptError) in
                    try access.clear(key?.pointee, at: location)
                }
            }
        )
    }

    private static func withStore(
        _ context: UnsafeMutableRawPointer?,
        error: UnsafeMutablePointer<CChar>?,
        capacity: Int,
        _ body: (inout ConfigScriptStoreAccess) throws(ConfigScriptError) -> Void
    ) -> Bool {
        guard let context else { return false }
        let stage = context.assumingMemoryBound(to: ConfigScriptStage.self)
        do throws(ConfigScriptError) {
            guard stage.pointee.store != nil else {
                throw ConfigScriptError(line: nil, message: "omniwm.store is only available in a callback.")
            }
            try body(&stage.pointee.store!)
            return true
        } catch let failure {
            return failure.write(to: error, capacity: capacity)
        }
    }
}
