// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

uint vitreusSparksPcg(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float vitreusSparksChance(uint seed, uint index, uint salt) {
    return float(vitreusSparksPcg(seed ^ vitreusSparksPcg(index ^ vitreusSparksPcg(salt)))) / 4294967295.0;
}

float4 shade(float2 uv, constant OmniShader& shader) {
    float time = shader.time;
    if (time <= 0.0) return float4(0.0);
    float unit = max(shader.values.x, 0.01);
    uint seed = uint(max(shader.values.y, 0.0));
    float2 point = (uv - 0.5) * shader.size / unit;
    float edge = 0.75 / max(shader.scale * unit, 0.01);
    float3 mint = shader.colors[omni_accent].rgb;
    float3 ink = shader.colors[omni_foreground].rgb;
    float2 gravity = float2(0.0, 40.0);
    float4 light = float4(0.0);
    for (uint index = 0; index < 36; ++index) {
        float age = time - vitreusSparksChance(seed, index, 7u) * 0.06;
        float life = mix(0.5, 1.0, vitreusSparksChance(seed, index, 1u));
        if (age < 0.0 || age > life) continue;
        float phase = age / life;
        float angle = (vitreusSparksChance(seed, index, 4u) - 0.5) * 6.2831853;
        float speed = mix(70.0, 170.0, vitreusSparksChance(seed, index, 5u));
        float2 launch = float2(cos(angle), sin(angle)) * speed;
        float slow = exp(-1.2 * age);
        float carried = (1.0 - slow) / 1.2;
        float2 position = launch * carried + gravity * (age - carried) / 1.2;
        float2 velocity = launch * slow + gravity * (1.0 - slow) / 1.2;
        float size = mix(3.5, 1.0, phase);
        float fast = length(velocity);
        float2 along = fast > 0.001 ? velocity / fast : float2(1.0, 0.0);
        float2 local = point - position;
        local = float2(dot(local, along), dot(local, float2(-along.y, along.x)));
        float reach = size * 0.5 + fast * 0.03;
        float thick = max(size * 0.22, 0.6);
        float distance = length(float2(max(abs(local.x) - max(reach - thick, 0.0), 0.0), local.y)) - thick;
        float alpha = (1.0 - phase) * (1.0 - smoothstep(-edge, edge, distance));
        if (alpha <= 0.001) continue;
        light = float4(mix(mint, ink, phase) * alpha, alpha) + light * (1.0 - alpha);
    }
    return light.a > 0.0 ? float4(clamp(light.rgb / light.a, 0.0, 1.0), light.a) : float4(0.0);
}
