// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#define OMNI_TEXTURE

float4 shade(float2 uv, constant OmniShader& shader, texture2d<float> image) {
    float4 source = omni_sample(image, uv);
    float progress = clamp(uv.y / max(shader.values.x, 0.001), 0.0, 1.0);
    float middle = clamp(shader.values.y, 0.001, 0.999);
    float3 high = shader.colors[omni_secondaryContainerForeground].rgb;
    float3 mint = shader.colors[omni_accent].rgb;
    float3 low = shader.colors[omni_accent].rgb;
    float3 color = progress <= middle ? mix(high, mint, progress / middle)
        : mix(mint, low, (progress - middle) / (1.0 - middle));
    return float4(clamp(color, 0.0, 1.0), source.a);
}
