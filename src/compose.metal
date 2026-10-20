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

// The composition at output pixel uv (0..1 over both eyes side by side), in linear light.
float3 compose_rgb(float2 outUV, texture2d_array<float> left, texture2d_array<float> right,
                   texture2d_array<float> oleft, texture2d_array<float> oright, constant Compose &c) {
    bool isRight = outUV.x > 0.5;
    // ALVR mirrors the right eye so both squeeze towards the nose the same way.
    float2 eyeUV = float2(isRight ? (1.0 - outUV.x) * 2.0 : outUV.x * 2.0, outUV.y);
    if (c.ffr.enabled != 0) { eyeUV = unsqueeze(eyeUV, c.ffr); }
    float2 uv = float2(isRight ? 1.0 - eyeUV.x : eyeUV.x, eyeUV.y);
    uint e = isRight ? 1 : 0;
    if (c.blend == 0) return sample_eye(isRight ? right : left, uv, c.rect[e], c.slice[e]).rgb;
    // The compositor: the foreground over the other source, blended in linear light (the
    // textures are sRGB views), the other reprojected to the foreground frame's head pose.
    float4 fg = sample_source(c, 0, e, uv, isRight ? right : left);
    if (c.blend == 2) {
        // The dashboard: the lounge's panel, premultiplied, over the game dimmed to alpha; the
        // lounge drives, so the game's held frame is the one reprojected.
        float3 under = c.src[1].present != 0 ? sample_source(c, 1, e, uv, isRight ? oright : oleft).rgb * c.alpha : float3(0.0);
        return under * (1.0 - fg.a) + fg.rgb;
    }
    if (c.src[1].present == 0 || c.alpha >= 1.0) return fg.rgb;
    float4 ot = sample_source(c, 1, e, uv, isRight ? oright : oleft);
    return mix(ot.rgb, fg.rgb, c.alpha);
}

// What an sRGB render target stores: the sRGB encoding, clamped to 0..1.
float3 srgb_encode(float3 l) {
    l = saturate(l);
    return select(1.055 * pow(l, 1.0 / 2.4) - 0.055, l * 12.92, l <= 0.0031308);
}

// BT.709 Y'CbCr from sRGB-encoded R'G'B', as stored in the encoder's 420 buffer: full range
// (Y' 0..255, Cb/Cr 128 +/- 127.5) or video range (Y' 16..235, Cb/Cr 16..240), over 255.
float luma_709(float3 p, bool full) {
    float y = dot(p, float3(0.2126, 0.7152, 0.0722));
    return full ? y : (16.0 + 219.0 * y) / 255.0;
}
float2 chroma_709(float3 p, bool full) {
    float y = dot(p, float3(0.2126, 0.7152, 0.0722));
    float2 c = float2((p.b - y) / 1.8556, (p.r - y) / 1.5748);
    return full ? c + 128.0 / 255.0 : (128.0 + 224.0 * c) / 255.0;
}

// Composes straight into the encoder's 4:2:0 buffer, so VideoToolbox converts nothing and the
// range is ours to choose. A thread is one chroma sample and the 2x2 luma pixels under it.
// Chroma is sited left (co-sited with the even luma column, between the two rows), as HEVC's
// default and the client's kCVImageBufferChromaLocation_Left say: [1 2 1] over columns 2x-1,
// 2x, 2x+1. Column 2x-1 is the left neighbour's 2x+1, passed through threadgroup memory.
constant uint TG_W = 16, TG_H = 8;   // keep in step with server.m's dispatch
kernel void ycc(texture2d_array<float> left [[texture(0)]], texture2d_array<float> right [[texture(1)]],
                texture2d_array<float> oleft [[texture(2)]], texture2d_array<float> oright [[texture(3)]],
                texture2d<float, access::write> lumaT [[texture(4)]], texture2d<float, access::write> chromaT [[texture(5)]],
                constant Compose &c [[buffer(0)]], constant uint &fullRange [[buffer(1)]],
                uint2 gid [[thread_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]]) {
    threadgroup float3 edge[TG_H][TG_W][2];
    bool full = fullRange != 0;
    uint2 size = uint2(lumaT.get_width(), lumaT.get_height());
    float2 fsize = float2(size);
    uint2 p0 = gid * 2;
    float3 px[2][2];   // [row][column], sRGB-encoded
    for (uint r = 0; r < 2; r++)
        for (uint k = 0; k < 2; k++) {
            uint2 q = min(p0 + uint2(k, r), size - 1);
            px[r][k] = srgb_encode(compose_rgb((float2(q) + 0.5) / fsize, left, right, oleft, oright, c));
            if (all(p0 + uint2(k, r) < size)) lumaT.write(float4(luma_709(px[r][k], full)), p0 + uint2(k, r));
        }
    edge[lid.y][lid.x][0] = px[0][1];
    edge[lid.y][lid.x][1] = px[1][1];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // An eye's first column has no left neighbour of its own: the eyes mustn't bleed together.
    float3 west[2];
    if (p0.x == 0 || p0.x == size.x / 2) { west[0] = px[0][0]; west[1] = px[1][0]; }
    else if (lid.x > 0) { west[0] = edge[lid.y][lid.x - 1][0]; west[1] = edge[lid.y][lid.x - 1][1]; }
    else
        for (uint r = 0; r < 2; r++) {
            uint2 q = min(uint2(p0.x - 1, p0.y + r), size - 1);
            west[r] = srgb_encode(compose_rgb((float2(q) + 0.5) / fsize, left, right, oleft, oright, c));
        }
    float3 avg = (west[0] + west[1] + 2.0 * (px[0][0] + px[1][0]) + px[0][1] + px[1][1]) / 8.0;
    if (all(gid < uint2(chromaT.get_width(), chromaT.get_height()))) chromaT.write(float4(chroma_709(avg, full), 0.0, 0.0), gid);
}
