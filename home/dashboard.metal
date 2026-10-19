// The dashboard's panel: one textured quad in the world, its picture premultiplied, drawn over
// what's behind it (or over nothing, alpha 0, while a game is under the lounge).

#include <metal_stdlib>
using namespace metal;

struct Camera {
    float4x4 view, proj;
};

struct Panel {
    float4 centre;
    float4 right, up;   // half the panel's width and height, as vectors in the world
    float4 opacity;     // x
};

struct PanelOut {
    float4 position [[position]];
    float2 uv;
};

vertex PanelOut panel_vs(uint id [[vertex_id]], constant Panel &p [[buffer(0)]], constant Camera &cam [[buffer(1)]]) {
    float2 c = float2(id & 1, id >> 1);   // a strip: top left, top right, bottom left, bottom right
    float3 w = p.centre.xyz + p.right.xyz * (c.x * 2 - 1) + p.up.xyz * (1 - c.y * 2);
    PanelOut o;
    o.position = cam.proj * cam.view * float4(w, 1);
    o.uv = c;
    return o;
}

fragment float4 panel_fs(PanelOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant Panel &p [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return tex.sample(smp, in.uv) * p.opacity.x;
}
