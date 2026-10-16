// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

float4 shade(float2 uv, constant OmniShader& shader) {
    int bar = min(int(uv.x * 6.0), 5);
    float level = 0.0;
    for (int band = 0; band < 10; band++) {
        level = max(level, shader.audio[bar * 10 + band]);
    }
    float cell = shader.size.x / 6.0;
    float height = max(2.0, clamp(level, 0.0, 1.0) * (shader.size.y - 2.0));
    float2 point = float2((uv.x * shader.size.x) - (float(bar) + 0.5) * cell,
                         (uv.y - 0.5) * shader.size.y);
    float2 edge = abs(point) - float2(max(1.0, cell * 0.28), height * 0.5) + 1.0;
    float distance = length(max(edge, 0.0)) + min(max(edge.x, edge.y), 0.0) - 1.0;
    float alpha = clamp(0.5 - distance * shader.scale, 0.0, 1.0);
    return float4(0.984, 0.443, 0.522, alpha);
}
