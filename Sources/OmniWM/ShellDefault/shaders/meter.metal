// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

float4 shade(float2 uv, constant OmniShader& shader) {
    int role = omni_cyan;
    switch (int(shader.values.x)) {
    case 1: role = omni_purple; break;
    case 2: role = omni_green; break;
    case 3: role = omni_orange; break;
    default: break;
    }
    float4 tint = shader.colors[role];
    float2 p = uv * shader.size;
    float radius = shader.size.y * 0.5;
    float2 q = abs(p - shader.size * 0.5) - shader.size * 0.5 + radius;
    float edge = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float coverage = clamp(0.5 - edge * shader.scale, 0.0, 1.0);
    float3 top = min(tint.rgb * 1.15 + 0.1, 1.0);
    return float4(mix(top, tint.rgb, uv.y), tint.a * coverage);
}
