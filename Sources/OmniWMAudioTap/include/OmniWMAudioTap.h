// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#ifndef OMNIWM_AUDIO_TAP_H
#define OMNIWM_AUDIO_TAP_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

CF_ASSUME_NONNULL_BEGIN

typedef struct omni_audio_gain omni_audio_gain;

omni_audio_gain *_Nullable omni_audio_gain_create(UInt32 source_channels, float gain);
void omni_audio_gain_destroy(omni_audio_gain *state);
void omni_audio_gain_set(omni_audio_gain *state, float gain);
OSStatus omni_audio_gain_render(
    AudioObjectID device,
    const AudioTimeStamp *now,
    const AudioBufferList *input,
    const AudioTimeStamp *input_time,
    AudioBufferList *output,
    const AudioTimeStamp *output_time,
    void *_Nullable client
);

typedef struct omni_audio_ring omni_audio_ring;

omni_audio_ring *_Nullable omni_audio_ring_create(UInt32 source_channels, UInt32 capacity);
void omni_audio_ring_destroy(omni_audio_ring *ring);
void omni_audio_ring_write(omni_audio_ring *ring, const float *samples, UInt32 frames);
UInt64 omni_audio_ring_position(const omni_audio_ring *ring);
bool omni_audio_ring_read(const omni_audio_ring *ring, UInt64 start, float *samples, UInt32 count);
OSStatus omni_audio_ring_capture(
    AudioObjectID device,
    const AudioTimeStamp *now,
    const AudioBufferList *input,
    const AudioTimeStamp *input_time,
    AudioBufferList *output,
    const AudioTimeStamp *output_time,
    void *_Nullable client
);

CF_ASSUME_NONNULL_END

#endif
