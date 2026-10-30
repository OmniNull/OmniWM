// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#define OMNI_TEXTURE

float4 shade(float2 uv, constant OmniShader& shader, texture2d<float> image) {
    float4 source = omni_sample(image, uv);
    float radius = max(shader.values.y, 0.0);
    float amount = max(shader.values.z, 0.0);
    float4 halo = float4(0.0);
    if (radius > 0.0 && amount > 0.0) {
        float2 reach = radius / max(shader.size, float2(1.0));
        float total = 0.0;
        for (uint index = 0; index < 32; ++index) {
            float spread = (float(index) + 0.5) / 32.0;
            float angle = float(index) * 2.39996323;
            float weight = exp(-2.0 * spread);
            float4 tap = omni_sample(image, uv + float2(cos(angle), sin(angle)) * sqrt(spread) * reach);
            halo += float4(tap.rgb * tap.a, tap.a) * weight;
            total += weight;
        }
        halo /= total;
    }
    float glow = clamp(halo.a * amount, 0.0, 1.0) * (1.0 - source.a);
    float alpha = source.a + glow;
    if (alpha <= 0.0) return float4(0.0);
    float3 bloom = halo.a > 0.0 ? halo.rgb / halo.a : float3(0.0);
    float3 color = (source.rgb * source.a + bloom * glow) / alpha;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    return float4(clamp(mix(float3(luma), color, clamp(shader.values.x, 0.0, 3.0)), 0.0, 1.0), alpha);
}
