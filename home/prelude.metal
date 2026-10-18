// What vapord gives every scene's backdrop.metal, ahead of it. A scene defines one function,
//
//     float3 backdrop(float3 o, float3 d, constant Eye &eye, thread float &depth);
//
// the colour (linear, not sRGB) seen from o looking along d (a unit vector), setting depth to how
// far along d that surface is (left at INFINITY for the sky), which hides the scene's pictures
// behind it. Metres, y up, the floor at y = 0, ahead is -z. See home/SCENES.md.

#include <metal_stdlib>
using namespace metal;

struct Eye {
    float4 rot0, rot1, rot2;   // the eye's orientation, as the columns of a rotation
    float4 pos;                // the eye's position, metres, floor at y = 0
    float4 tan;                // tangents of the left, right, up and down field of view angles
    float4 time;               // x: seconds since the scene started
    float4 ball;               // the ball's centre (xyz) and radius (w), for a shadow
};

struct Picture {               // an upright picture facing +z: centre and half size, metres
    float3 centre;
    float2 half_size;
    int texture;               // which of the scene's images
    bool flip;                 // mirrored left to right
};

static float3 lin(float3 srgb) { return pow(srgb, 2.2); }
static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float3 backdrop(float3 o, float3 d, constant Eye &eye, thread float &depth);

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut vs(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut o;
    o.position = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

fragment float4 fs(VOut in [[stage_in]], constant Eye &eye [[buffer(0)]], constant Picture *pictures [[buffer(1)]],
                   constant int &picture_count [[buffer(2)]], array<texture2d<float>, 8> images [[texture(0)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 v = normalize(float3(mix(eye.tan.x, eye.tan.y, in.uv.x), mix(eye.tan.z, eye.tan.w, in.uv.y), -1.0));
    float3 d = normalize(float3x3(eye.rot0.xyz, eye.rot1.xyz, eye.rot2.xyz) * v);
    float3 o = eye.pos.xyz;
    float depth = INFINITY;
    float3 c = backdrop(o, d, eye, depth);

    // The pictures, furthest first, each over what's behind it.
    for (int i = 0; i < picture_count; i++) {
        Picture b = pictures[i];
        if (abs(d.z) < 1e-4) continue;
        float k = (b.centre.z - o.z) / d.z;
        if (k <= 0 || k > depth) continue;
        float3 p = o + d * k;
        float2 q = (p.xy - b.centre.xy) / b.half_size;
        if (any(abs(q) > 1.0)) continue;
        float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
        if (b.flip) uv.x = 1.0 - uv.x;
        float4 s = images[b.texture].sample(smp, uv);
        s *= smoothstep(1.0, 0.96, max(abs(q.x), abs(q.y)));   // no seam where the picture ends
        c = c * (1.0 - s.a) + s.rgb;
    }
    return float4(c, 1.0);
}

#line 1 "backdrop.metal"
