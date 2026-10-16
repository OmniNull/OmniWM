// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

#include "OmniWMAudioTap.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct omni_audio_gain {
    _Atomic float gain;
    UInt32 source_channels;
};

omni_audio_gain *omni_audio_gain_create(UInt32 source_channels, float gain) {
    if (source_channels == 0) {
        return NULL;
    }
    omni_audio_gain *state = malloc(sizeof *state);
    if (state == NULL) {
        return NULL;
    }
    atomic_init(&state->gain, gain);
    state->source_channels = source_channels;
    return state;
}

void omni_audio_gain_destroy(omni_audio_gain *state) {
    free(state);
}

void omni_audio_gain_set(omni_audio_gain *state, float gain) {
    atomic_store_explicit(&state->gain, gain, memory_order_relaxed);
}

static const AudioBuffer *source_buffer(const AudioBufferList *input, UInt32 channels) {
    for (UInt32 index = input->mNumberBuffers; index > 0; index--) {
        const AudioBuffer *buffer = &input->mBuffers[index - 1];
        if (buffer->mNumberChannels == channels && buffer->mData != NULL) {
            return buffer;
        }
    }
    return NULL;
}

static float source_sample(const float *samples, UInt32 channels, UInt32 frame, UInt32 output_channel,
                           UInt32 output_channels) {
    const float *row = samples + (size_t)frame * channels;
    if (output_channels == 1 && channels > 1) {
        float sum = 0;
        for (UInt32 channel = 0; channel < channels; channel++) {
            sum += row[channel];
        }
        return sum / (float)channels;
    }
    if (channels == 1) {
        return output_channel < 2 ? row[0] : 0;
    }
    return output_channel < channels ? row[output_channel] : 0;
}

OSStatus omni_audio_gain_render(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                                const AudioTimeStamp *input_time, AudioBufferList *output,
                                const AudioTimeStamp *output_time, void *client) {
    (void)device;
    (void)now;
    (void)input_time;
    (void)output_time;
    const omni_audio_gain *state = client;
    UInt32 output_channels = 0;
    for (UInt32 index = 0; index < output->mNumberBuffers; index++) {
        output_channels += output->mBuffers[index].mNumberChannels;
    }
    const AudioBuffer *source = state != NULL ? source_buffer(input, state->source_channels) : NULL;
    float gain = state != NULL ? atomic_load_explicit(&state->gain, memory_order_relaxed) : 0;
    UInt32 first_channel = 0;
    for (UInt32 index = 0; index < output->mNumberBuffers; index++) {
        AudioBuffer *buffer = &output->mBuffers[index];
        UInt32 channels = buffer->mNumberChannels;
        if (buffer->mData == NULL || channels == 0) {
            first_channel += channels;
            continue;
        }
        memset(buffer->mData, 0, buffer->mDataByteSize);
        if (source != NULL && gain != 0) {
            UInt32 frames = buffer->mDataByteSize / (UInt32)(sizeof(float) * channels);
            UInt32 source_frames = source->mDataByteSize / (UInt32)(sizeof(float) * source->mNumberChannels);
            UInt32 count = frames < source_frames ? frames : source_frames;
            float *samples = buffer->mData;
            for (UInt32 frame = 0; frame < count; frame++) {
                for (UInt32 channel = 0; channel < channels; channel++) {
                    samples[(size_t)frame * channels + channel] =
                        gain * source_sample(source->mData, source->mNumberChannels, frame, first_channel + channel,
                                             output_channels);
                }
            }
        }
        first_channel += channels;
    }
    return noErr;
}

struct omni_audio_ring {
    _Atomic UInt64 claimed;
    _Atomic UInt64 committed;
    UInt32 source_channels;
    UInt32 mask;
    _Atomic float samples[];
};

omni_audio_ring *omni_audio_ring_create(UInt32 source_channels, UInt32 capacity) {
    if (source_channels == 0 || capacity == 0 || (capacity & (capacity - 1)) != 0) {
        return NULL;
    }
    omni_audio_ring *ring = malloc(sizeof *ring + sizeof(_Atomic float) * capacity);
    if (ring == NULL) {
        return NULL;
    }
    atomic_init(&ring->claimed, 0);
    atomic_init(&ring->committed, 0);
    ring->source_channels = source_channels;
    ring->mask = capacity - 1;
    for (UInt32 index = 0; index < capacity; index++) {
        atomic_init(&ring->samples[index], 0);
    }
    return ring;
}

void omni_audio_ring_destroy(omni_audio_ring *ring) {
    free(ring);
}

void omni_audio_ring_write(omni_audio_ring *ring, const float *samples, UInt32 frames) {
    UInt64 position = atomic_load_explicit(&ring->committed, memory_order_relaxed);
    atomic_store_explicit(&ring->claimed, position + frames, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    UInt32 channels = ring->source_channels;
    for (UInt32 frame = 0; frame < frames; frame++) {
        const float *row = samples + (size_t)frame * channels;
        float sum = 0;
        for (UInt32 channel = 0; channel < channels; channel++) {
            sum += row[channel];
        }
        atomic_store_explicit(&ring->samples[(position + frame) & ring->mask], sum / (float)channels,
                              memory_order_relaxed);
    }
    atomic_store_explicit(&ring->committed, position + frames, memory_order_release);
}

UInt64 omni_audio_ring_position(const omni_audio_ring *ring) {
    return atomic_load_explicit(&ring->committed, memory_order_acquire);
}

bool omni_audio_ring_read(const omni_audio_ring *ring, UInt64 start, float *samples, UInt32 count) {
    UInt64 capacity = (UInt64)ring->mask + 1;
    UInt64 committed = atomic_load_explicit(&ring->committed, memory_order_acquire);
    if (count > capacity || start + count > committed || committed - start > capacity) {
        return false;
    }
    for (UInt32 index = 0; index < count; index++) {
        samples[index] = atomic_load_explicit(&ring->samples[(start + index) & ring->mask], memory_order_relaxed);
    }
    atomic_thread_fence(memory_order_acquire);
    return atomic_load_explicit(&ring->claimed, memory_order_relaxed) <= start + capacity;
}

OSStatus omni_audio_ring_capture(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                                 const AudioTimeStamp *input_time, AudioBufferList *output,
                                 const AudioTimeStamp *output_time, void *client) {
    (void)device;
    (void)now;
    (void)input_time;
    (void)output_time;
    omni_audio_ring *ring = client;
    const AudioBuffer *source = ring != NULL ? source_buffer(input, ring->source_channels) : NULL;
    if (source != NULL) {
        omni_audio_ring_write(ring, source->mData,
                              source->mDataByteSize / (UInt32)(sizeof(float) * source->mNumberChannels));
    }
    for (UInt32 index = 0; index < output->mNumberBuffers; index++) {
        AudioBuffer *buffer = &output->mBuffers[index];
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
    return noErr;
}
