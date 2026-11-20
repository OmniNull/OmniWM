// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#ifndef OMNIWM_PROPERTY_LISTENER_H
#define OMNIWM_PROPERTY_LISTENER_H

#include <CoreAudio/CoreAudio.h>
#include <CoreMediaIO/CMIOHardware.h>

CF_ASSUME_NONNULL_BEGIN

typedef struct omni_audio_listener_block omni_audio_listener_block;
typedef struct omni_video_listener_block omni_video_listener_block;

omni_audio_listener_block *omni_audio_listener_block_create(AudioObjectPropertyListenerBlock block);
void omni_audio_listener_block_destroy(omni_audio_listener_block *block);
OSStatus omni_audio_listener_add(omni_audio_listener_block *block, AudioObjectID object,
                                const AudioObjectPropertyAddress *address, dispatch_queue_t queue);
OSStatus omni_audio_listener_remove(omni_audio_listener_block *block, AudioObjectID object,
                                   const AudioObjectPropertyAddress *address, dispatch_queue_t queue);

omni_video_listener_block *omni_video_listener_block_create(CMIOObjectPropertyListenerBlock block);
void omni_video_listener_block_destroy(omni_video_listener_block *block);
OSStatus omni_video_listener_add(omni_video_listener_block *block, CMIOObjectID object,
                                const CMIOObjectPropertyAddress *address, dispatch_queue_t queue);
OSStatus omni_video_listener_remove(omni_video_listener_block *block, CMIOObjectID object,
                                   const CMIOObjectPropertyAddress *address, dispatch_queue_t queue);

CF_ASSUME_NONNULL_END

#endif
