#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// One fullscreen quad, letterboxed by `scale` (1,1 == fill).
vertex VSOut vs_quad(uint vid [[vertex_id]],
                     constant float2 &scale [[buffer(0)]])
{
    const float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };
    VSOut out;
    out.position = float4(positions[vid] * scale, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 fs_scanout(VSOut in [[stage_in]],
                           texture2d<float> scanout [[texture(0)]])
{
    constexpr sampler s(mag_filter::linear,
                        min_filter::linear,
                        address::clamp_to_edge);
    return scanout.sample(s, in.uv);
}
