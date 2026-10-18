// What vapord draws in every scene: the controllers, the ball and its table as lit meshes, and
// bare hands as glowing lines. Their colours and light are the scene's (Look, from scene.json).

#include <metal_stdlib>
using namespace metal;

struct Camera {
    float4x4 view, proj;
};

struct Look {
    float4 light;     // xyz: the direction light comes from; w: how lit the side away from it is
    float4 tint;      // what the light does to a surface's own colour
    float4 rim;       // the rim light round an edge, as seen
    float4 ambient;   // added everywhere
};

struct MeshVertex {
    packed_float3 pos;
    packed_float3 normal;
    float2 uv;
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float3 to_eye;
    float2 uv;
};

vertex MeshOut mesh_vs(uint id [[vertex_id]], const device MeshVertex *v [[buffer(0)]], constant Camera &cam [[buffer(1)]],
                       constant float4x4 &model [[buffer(2)]]) {
    MeshVertex m = v[id];
    float4 world = model * float4(float3(m.pos), 1);
    MeshOut o;
    o.position = cam.proj * cam.view * world;
    o.normal = normalize((model * float4(float3(m.normal), 0)).xyz);
    float4 eye = cam.view * world;   // the eye looks down -z in view space
    o.to_eye = normalize(-(transpose(float3x3(cam.view[0].xyz, cam.view[1].xyz, cam.view[2].xyz)) * eye.xyz));
    o.uv = m.uv;
    return o;
}

// Lit by the scene's light with a rim round its edges, and glow added: a control lit as it's
// touched and pressed.
fragment float4 mesh_fs(MeshOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4 &glow [[buffer(0)]],
                        constant Look &look [[buffer(1)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::repeat);
    float3 n = normalize(in.normal);
    float3 base = tex.sample(smp, in.uv).rgb;
    float lit = look.light.w + (1 - look.light.w) * max(dot(n, normalize(look.light.xyz)), 0.0);
    float rim = pow(1.0 - max(dot(n, normalize(in.to_eye)), 0.0), 3.0);
    return float4(base * lit * look.tint.rgb + look.rim.rgb * rim + look.ambient.rgb + glow.rgb, 1);
}

// A hand: a glowing line along each bone, and a dot on each fingertip (a line from the tip to
// itself). Each is a quad around the line, facing the eye, with room for the glow.
struct Segment {
    float4 a_radius;
    float4 b;
    float4 colour;
};

struct SegmentOut {
    float4 position [[position]];
    float2 q;        // along and across the line, in radii from its start
    float length_;   // its length, in radii
    float4 colour;
};

constant float kGlow = 2.6;   // how far the glow reaches, in radii

vertex SegmentOut line_vs(uint vid [[vertex_id]], uint iid [[instance_id]], const device Segment *segs [[buffer(0)]],
                          constant Camera &cam [[buffer(1)]]) {
    Segment s = segs[iid];
    float r = s.a_radius.w;
    float4 a = cam.view * float4(s.a_radius.xyz, 1), b = cam.view * float4(s.b.xyz, 1);
    // Aimed along the line as it appears, which perspective turns from its run across the view:
    // a finger pointing away runs mostly in depth.
    float2 d = b.xy / max(-b.z, 1e-3) - a.xy / max(-a.z, 1e-3);
    float len = length(b.xyz - a.xyz);
    float2 along = length(d) > 1e-6 ? normalize(d) : float2(1, 0), across = float2(-along.y, along.x);
    bool end = vid >= 2;
    float side = (vid & 1) ? 1 : -1;
    float4 v = end ? b : a;
    v.xy += along * (end ? 1 : -1) * r * kGlow + across * side * r * kGlow;
    SegmentOut o;
    o.position = cam.proj * v;
    o.q = float2(end ? len / r + kGlow : -kGlow, side * kGlow);
    o.length_ = len / r;
    o.colour = s.colour;
    return o;
}

fragment float4 line_fs(SegmentOut in [[stage_in]]) {
    float dx = max(max(-in.q.x, in.q.x - in.length_), 0.0);
    float r = length(float2(dx, in.q.y));
    float core = smoothstep(1.0, 0.6, r);
    float glow = exp(-max(r - 0.6, 0.0) * 1.6) * 0.6 * smoothstep(kGlow, kGlow * 0.6, r);
    float a = clamp(core + glow * (1 - core), 0.0, 1.0);
    if (a < 0.01) discard_fragment();
    float3 c = mix(in.colour.rgb, float3(1.0), core * 0.45);
    return float4(c * a, a);
}
