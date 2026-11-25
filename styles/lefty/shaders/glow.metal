// values: intensity 0-1, motion speed 0-4, spark radius in points 0-3, glow height 0.1-1

uint glowHash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

float glowDrift(float2 point) {
    return omni_noise(point) * 0.65 + omni_noise(point * 2.1 + 17.0) * 0.35;
}

float4 shade(float2 uv, constant OmniShader& shader) {
    float strength = clamp(shader.values.x, 0.0, 1.0);
    float time = shader.time * clamp(shader.values.y, 0.0, 4.0);
    float radius = clamp(shader.values.z, 0.0, 3.0);
    float reach = clamp(shader.values.w, 0.1, 1.0);
    float2 size = max(shader.size, float2(1.0));
    float2 point = uv * size;
    float3 base = shader.colors[omni_surface].rgb;
    float3 tint = shader.colors[omni_accent].rgb;
    float3 color = base;
    if (strength > 0.0) {
        // Distance from the bottom edge relative to the bar, so tall panels keep a thin bed below their text.
        float extent = min(size.y, 60.0);
        float rise = (1.0 - uv.y) * size.y / extent;
        float heat = glowDrift(float2(point.x / 150.0 + time * 0.05, point.y / 90.0 + time * 0.09));
        float breath = 0.85 + 0.15 * sin(time * 0.6 + point.x / 260.0);
        float bed = exp(-rise * rise / (reach * reach * 0.30)) * smoothstep(0.2, 0.85, heat) * breath;
        color = mix(color, tint, bed * 0.30 * strength);
        if (radius > 0.0) {
            float2 cellSize = float2(64.0, 46.0);
            float2 position = float2(point.x, point.y + time * 7.0);
            int2 cell = int2(floor(position / cellSize));
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    int2 index = cell + int2(x, y);
                    uint hash = glowHash(uint(index.x) * 73u + uint(index.y) * 4099u + 19u);
                    if ((hash & 3u) == 0u) {
                        continue;
                    }
                    float seed = float((hash >> 2) & 1023u) / 1023.0;
                    float other = float((hash >> 12) & 1023u) / 1023.0;
                    float2 center = (float2(index) + float2(seed, other) * 0.8 + 0.1) * cellSize;
                    center.x += sin(time * (0.5 + other * 0.5) + seed * 6.2831853) * 6.0;
                    float spark = radius * (0.55 + 0.45 * other);
                    float aa = 0.75 / max(shader.scale, 0.5);
                    float mask = 1.0 - smoothstep(spark - aa, spark + aa, distance(position, center));
                    float flicker = 0.55 + 0.45 * sin(time * (1.2 + seed * 1.6) + other * 6.2831853);
                    float fade = 1.0 - smoothstep(0.08, 0.30, rise);
                    color = mix(color, tint, mask * flicker * fade * 0.75 * strength);
                }
            }
        }
        uint grain = glowHash(uint(point.x * shader.scale) + uint(point.y * shader.scale) * 8191u);
        color += (float(grain & 255u) / 255.0 - 0.5) * 0.006;
    }
    return float4(clamp(color, 0.0, 1.0), 1.0);
}
