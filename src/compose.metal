#include <metal_stdlib>
using namespace metal;

struct Ffr { float2 eyeSizeRatio; float2 centerSize; float2 centerShift; float2 edgeRatio; uint enabled; };
// A source of the compositor's blend: how its head was turned relative to the frame being
// encoded, per eye (three float4 columns of a 3x3: target eye frame -> source eye frame).
struct Source { float4 rot[6]; uint identity; uint present; uint2 pad; };
struct Compose {
    float4 rect[2]; uint slice[2]; Ffr ffr;   // as axr_submit fills them (LEGACY)
    uint blend;                               // 0: LEGACY, one source as it is; 1: cross-fade; 2: overlay (the dashboard)
    float alpha;                              // 1: weight of the foreground source (textures 0, 1); 2: how bright the other stays
    uint2 pad;
    float4 tanfov[2];                         // per eye: tan of fov left, right, up, down
    Source src[2];                            // foreground, other (textures 2, 3)
};
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

// Unsqueezing reaches a little past the eye's edges. Clamped to its rect, as clamp_to_edge
// would to a texture of its own, so an eye sharing a texture (an output slot) keeps to its half.
float4 sample_eye(texture2d_array<float> t, float2 uv, float4 rect, uint slice) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 size = float2(t.get_width(), t.get_height());
    float2 p = clamp(rect.xy + uv * rect.zw, rect.xy + 0.5 / size, rect.xy + rect.zw - 0.5 / size);
    return t.sample(s, p, slice);
}

// A source's eye at output pixel uv, or black where the source didn't look. The output ray (in
// the eye's frame: tan space, -Z forward, uv.y = 0 at the top) is turned into the source's eye
// frame by the rotation between the two frames' head poses and projected back with the same fov.
float4 sample_source(constant Compose &c, uint which, uint e, float2 uv, texture2d_array<float> t) {
    constant Source &src = c.src[which];
    if (src.identity != 0) return sample_eye(t, uv, c.rect[e], c.slice[e]);
    float4 tf = c.tanfov[e];
    float3 d = float3(mix(tf.x, tf.y, uv.x), mix(tf.z, tf.w, uv.y), -1.0);
    float3x3 m = float3x3(src.rot[e * 3].xyz, src.rot[e * 3 + 1].xyz, src.rot[e * 3 + 2].xyz);
    float3 ds = m * d;
    if (ds.z >= -1e-6) return float4(0, 0, 0, 1);
    float2 p = ds.xy / -ds.z;
    float2 su = float2((p.x - tf.x) / (tf.y - tf.x), (p.y - tf.z) / (tf.w - tf.z));
    if (any(su < 0.0) || any(su > 1.0)) return float4(0, 0, 0, 1);
    return sample_eye(t, su, c.rect[e], c.slice[e]);
}

fragment float4 fs(VOut in [[stage_in]], texture2d_array<float> left [[texture(0)]],
                   texture2d_array<float> right [[texture(1)]], texture2d_array<float> oleft [[texture(2)]],
                   texture2d_array<float> oright [[texture(3)]], constant Compose &c [[buffer(0)]]) {
    bool isRight = in.uv.x > 0.5;
    // ALVR mirrors the right eye so both squeeze towards the nose the same way.
    float2 eyeUV = float2(isRight ? (1.0 - in.uv.x) * 2.0 : in.uv.x * 2.0, in.uv.y);
    if (c.ffr.enabled != 0) { eyeUV = unsqueeze(eyeUV, c.ffr); }
    float2 uv = float2(isRight ? 1.0 - eyeUV.x : eyeUV.x, eyeUV.y);
    uint e = isRight ? 1 : 0;
    if (c.blend == 0) return sample_eye(isRight ? right : left, uv, c.rect[e], c.slice[e]);
    // The compositor: the foreground over the other source, blended in linear light (the
    // textures are sRGB views and so is the target), the other reprojected to the foreground
    // frame's head pose.
    float4 fg = sample_source(c, 0, e, uv, isRight ? right : left);
    if (c.blend == 2) {
        // The dashboard: the lounge's panel, premultiplied, over the game dimmed to alpha; the
        // lounge drives, so the game's held frame is the one reprojected.
        float3 under = c.src[1].present != 0 ? sample_source(c, 1, e, uv, isRight ? oright : oleft).rgb * c.alpha : float3(0.0);
        return float4(under * (1.0 - fg.a) + fg.rgb, 1.0);
    }
    if (c.src[1].present == 0 || c.alpha >= 1.0) return float4(fg.rgb, 1.0);
    float4 ot = sample_source(c, 1, e, uv, isRight ? oright : oleft);
    return float4(mix(ot.rgb, fg.rgb, c.alpha), 1.0);
}
