// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

float vitreusSeekHeight(float x, float span, float falloff, float amplitude, float phase) {
    float envelope = clamp(x / falloff, 0.0, 1.0) * clamp((span - x) / falloff, 0.0, 1.0);
    return amplitude * envelope * sin(x * 0.24166097 - phase);
}

float4 shade(float2 uv, constant OmniShader& shader) {
    float unit = max(shader.values.x, 0.01);
    float span = clamp(shader.values.y, 0.0, 192.0);
    if (span <= 0.0) return float4(0.0);
    float hot = clamp(shader.values.z, 0.0, 1.0);
    float phase = shader.time * 2.0943951;
    float amplitude = 3.4 + 1.1 * hot;
    float falloff = max(0.001, min(span * 0.2, 9.0));
    float2 point = uv * shader.size / unit - float2(4.0, 10.0);
    float x = clamp(point.x - 3.75, 0.0, span);
    float2 previous = float2(x, vitreusSeekHeight(x, span, falloff, amplitude, phase));
    float distance = length(point - previous);
    for (int step = -4; step <= 5; ++step) {
        x = clamp(point.x + float(step) * 0.75, 0.0, span);
        float2 current = float2(x, vitreusSeekHeight(x, span, falloff, amplitude, phase));
        float2 segment = current - previous;
        float along = clamp(dot(point - previous, segment) / max(dot(segment, segment), 1e-6), 0.0, 1.0);
        distance = min(distance, length(point - previous - segment * along));
        previous = current;
    }
    float edge = 0.75 / max(shader.scale * unit, 0.01);
    float coverage = 1.0 - smoothstep(-edge, edge, distance - (2.0 + hot));
    float breathing = shader.values.w > 0.5 ? 0.8 + 0.2 * sin(phase) : 1.0;
    float4 mint = shader.colors[omni_accent];
    return float4(mint.rgb, mint.a * coverage * min(1.0, span / 6.0) * breathing);
}
