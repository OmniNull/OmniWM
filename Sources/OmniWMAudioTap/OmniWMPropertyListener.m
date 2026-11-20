// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#include "OmniWMPropertyListener.h"
#include <Block.h>

omni_audio_listener_block *omni_audio_listener_block_create(AudioObjectPropertyListenerBlock block) {
    return _Block_copy((__bridge const void *)block);
}

void omni_audio_listener_block_destroy(omni_audio_listener_block *block) {
    _Block_release(block);
}

OSStatus omni_audio_listener_add(omni_audio_listener_block *block, AudioObjectID object,
                                const AudioObjectPropertyAddress *address, dispatch_queue_t queue) {
    return AudioObjectAddPropertyListenerBlock(object, address, queue, (__bridge AudioObjectPropertyListenerBlock)block);
}

OSStatus omni_audio_listener_remove(omni_audio_listener_block *block, AudioObjectID object,
                                   const AudioObjectPropertyAddress *address, dispatch_queue_t queue) {
    return AudioObjectRemovePropertyListenerBlock(object, address, queue, (__bridge AudioObjectPropertyListenerBlock)block);
}

omni_video_listener_block *omni_video_listener_block_create(CMIOObjectPropertyListenerBlock block) {
    return _Block_copy((__bridge const void *)block);
}

void omni_video_listener_block_destroy(omni_video_listener_block *block) {
    _Block_release(block);
}

OSStatus omni_video_listener_add(omni_video_listener_block *block, CMIOObjectID object,
                                const CMIOObjectPropertyAddress *address, dispatch_queue_t queue) {
    return CMIOObjectAddPropertyListenerBlock(object, address, queue, (__bridge CMIOObjectPropertyListenerBlock)block);
}

OSStatus omni_video_listener_remove(omni_video_listener_block *block, CMIOObjectID object,
                                   const CMIOObjectPropertyAddress *address, dispatch_queue_t queue) {
    return CMIOObjectRemovePropertyListenerBlock(object, address, queue, (__bridge CMIOObjectPropertyListenerBlock)block);
}
