// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreAudio
import CoreMediaIO
import Foundation
import OmniWMAudioTap

struct AudioPropertyListener {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock?
    var native: OpaquePointer?

    static func listen(
        to object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> Self? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let native = omni_audio_listener_block_create(block)
        let status = omni_audio_listener_add(native, object, &address, queue)
        guard status == noErr else {
            omni_audio_listener_block_destroy(native)
            Log.shell.error("Registering an audio listener failed with status \(status)")
            return nil
        }
        return Self(object: object, address: address, block: nil, native: native)
    }

    func remove(on queue: DispatchQueue) {
        guard let native else { return }
        var address = address
        let status = omni_audio_listener_remove(native, object, &address, queue)
        omni_audio_listener_block_destroy(native)
        if status != noErr { Log.shell.error("Removing an audio listener failed with status \(status)") }
    }
}

struct VideoPropertyListener {
    let object: CMIOObjectID
    let address: CMIOObjectPropertyAddress
    let block: CMIOObjectPropertyListenerBlock?
    var native: OpaquePointer?

    static func listen(
        to object: CMIOObjectID,
        address: CMIOObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping CMIOObjectPropertyListenerBlock
    ) -> Self? {
        var address = address
        let native = omni_video_listener_block_create(block)
        let status = omni_video_listener_add(native, object, &address, queue)
        guard status == noErr else {
            omni_video_listener_block_destroy(native)
            Log.shell.error("Registering a camera listener failed with status \(status)")
            return nil
        }
        return Self(object: object, address: address, block: nil, native: native)
    }

    func remove(on queue: DispatchQueue) {
        guard let native else { return }
        var address = address
        let status = omni_video_listener_remove(native, object, &address, queue)
        omni_video_listener_block_destroy(native)
        if status != noErr { Log.shell.error("Removing a camera listener failed with status \(status)") }
    }
}
