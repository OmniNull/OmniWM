// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

float4 shade(float2 uv, constant OmniShader& shader) {
    float2 point = (uv - 0.5) * shader.size;
    float base = shader.values.x;
    float reach = shader.values.y;
    float width = shader.values.z;
    float slot = round(atan2(point.y, point.x) / (2.0 * M_PI_F) * 60.0);
    float angle = slot / 60.0 * 2.0 * M_PI_F;
    float2 direction = float2(cos(angle), sin(angle));
    int index = int(fmod(slot + 60.0, 60.0));
    float value = clamp(shader.audio[index], 0.01, 1.0);
    float along = clamp(dot(point, direction), base, base + value * reach);
    float distance = length(point - direction * along) - width * 0.5;
    float alpha = clamp(0.5 - distance * shader.scale, 0.0, 1.0);
    float4 color = shader.colors[omni_accent];
    return float4(color.rgb, color.a * alpha);
}
