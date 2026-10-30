// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

uint vitreusShatterHash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

float vitreusShatterRandom(uint value) {
    return float(vitreusShatterHash(value) & 65535u) / 65535.0;
}

float4 shade(float2 uv, constant OmniShader& shader) {
    float time = shader.time;
    if (time <= 0.0 || time >= 0.95) return float4(0.0);
    float unit = max(shader.values.x, 0.01);
    uint seed = uint(max(shader.values.y, 0.0));
    float2 point = (uv - 0.5) * shader.size / unit;
    float aa = 0.75 / max(shader.scale * unit, 0.01);
    float displacement = (1.0 - exp(-1.3 * time)) / 1.3;
    float gravity = 420.0 * (time - displacement) / 1.3;
    float3 light = float3(0.0);
    float alpha = 0.0;
    for (uint index = 0; index < 30; ++index) {
        uint key = index * 17u + seed * 541u + 79u;
        float life = mix(0.5, 0.95, vitreusShatterRandom(key));
        if (time >= life) continue;
        float phase = time / life;
        float angle = vitreusShatterRandom(key + 1u) * 6.2831853;
        float speed = mix(70.0, 230.0, vitreusShatterRandom(key + 2u));
        float2 origin = float2(vitreusShatterRandom(key + 3u) - 0.5,
                               vitreusShatterRandom(key + 4u) - 0.5) * float2(44.0, 52.0);
        float2 position = origin + float2(cos(angle), sin(angle)) * speed * displacement;
        position.y += gravity;
        float halfSize = mix(6.0, 2.0, phase) * 0.5;
        float distance = max(abs(point.x - position.x), abs(point.y - position.y)) - halfSize;
        float coverage = clamp(0.5 - distance / (2.0 * aa), 0.0, 1.0);
        float particleAlpha = coverage * (1.0 - phase);
        float3 color = clamp(mix(shader.colors[omni_accent].rgb,
                                 shader.colors[omni_secondaryContainerForeground].rgb,
                                 vitreusShatterRandom(key + 5u)), 0.0, 1.0);
        light = color * particleAlpha + light * (1.0 - particleAlpha);
        alpha = particleAlpha + alpha * (1.0 - particleAlpha);
    }
    return alpha > 0.0 ? float4(clamp(light / alpha, 0.0, 1.0), alpha) : float4(0.0);
}
