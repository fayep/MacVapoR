#include <metal_stdlib>
using namespace metal;

struct Ffr { float2 eyeSizeRatio; float2 centerSize; float2 centerShift; float2 edgeRatio; uint enabled; };
struct Compose { float4 rect[2]; uint slice[2]; Ffr ffr; };
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// ALVR's ffr.comp: for a pixel of the squeezed frame, where it sits in the full eye image.
float2 unsqueeze(float2 eyeUV, constant Ffr &f) {
    eyeUV /= f.eyeSizeRatio;
    float2 c0 = (1. - f.centerSize) * .5;
    float2 c1 = (f.edgeRatio - 1.) * c0 * (f.centerShift + 1.) / f.edgeRatio;
    float2 c2 = (f.edgeRatio - 1.) * f.centerSize + 1.;
    float2 loBound = c0 * (f.centerShift + 1.) / c2;
    float2 hiBound = c0 * (f.centerShift - 1.) / c2 + 1.;
    float2 underBound = float2(eyeUV.x < loBound.x, eyeUV.y < loBound.y);
    float2 inBound = float2(loBound.x < eyeUV.x && eyeUV.x < hiBound.x, loBound.y < eyeUV.y && eyeUV.y < hiBound.y);
    float2 overBound = float2(eyeUV.x > hiBound.x, eyeUV.y > hiBound.y);
    float2 center = eyeUV * c2 / f.edgeRatio + c1;
    float2 d2 = eyeUV * c2;
    float2 d3 = (eyeUV - 1.) * c2 + 1.;
    float2 g1 = eyeUV / loBound;
    float2 g2 = (1. - eyeUV) / (1. - hiBound);
    return underBound * (g1 * center + (1. - g1) * d2) + inBound * center + overBound * (g2 * center + (1. - g2) * d3);
}

fragment float4 fs(VOut in [[stage_in]], texture2d_array<float> left [[texture(0)]],
                   texture2d_array<float> right [[texture(1)]], constant Compose &c [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    bool isRight = in.uv.x > 0.5;
    // ALVR mirrors the right eye so both squeeze towards the nose the same way.
    float2 eyeUV = float2(isRight ? (1.0 - in.uv.x) * 2.0 : in.uv.x * 2.0, in.uv.y);
    if (c.ffr.enabled != 0) { eyeUV = unsqueeze(eyeUV, c.ffr); }
    float2 uv = float2(isRight ? 1.0 - eyeUV.x : eyeUV.x, eyeUV.y);
    uint e = isRight ? 1 : 0;
    float2 t = c.rect[e].xy + uv * c.rect[e].zw;
    return isRight ? right.sample(s, t, c.slice[1]) : left.sample(s, t, c.slice[0]);
}
