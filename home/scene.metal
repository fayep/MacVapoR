// MacVapoR's home scene, drawn per pixel from each eye's ray: a purple sky over a striped sun
// setting into the sea, a neon grid running down to a silver beach lined with palms, and the
// name in chrome lettering. Purple, cyan and silver. Only the sea moves: a moving floor makes
// people queasy.

#include <metal_stdlib>
using namespace metal;

struct Eye {
    float4 rot0, rot1, rot2;   // the eye's orientation, as the columns of a rotation
    float4 pos;                // the eye's position, metres, floor at y = 0
    float4 tan;                // tangents of the left, right, up and down field of view angles
    float4 time;               // seconds
    float4 ball;               // the ball's centre and radius, for its shadow
};

struct Board {                 // an upright picture facing +z: centre and half size, metres
    float3 centre;
    float2 half_size;
    int texture;               // 0 the name, 1 a palm
    bool flip;
};

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

static float3 lin(float3 srgb) { return pow(srgb, 2.2); }

constant float3 kDeep = float3(0.05, 0.01, 0.12);
constant float3 kPurple = float3(0.40, 0.12, 0.72);
constant float3 kViolet = float3(0.62, 0.30, 0.95);
constant float3 kCyan = float3(0.00, 0.92, 1.00);
constant float3 kSilver = float3(0.84, 0.87, 0.94);

static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

// The sun: low over the sea, ahead.
constant float kSunElevation = 0.16;   // radians
constant float kSunRadius = 0.26;

static float3 sky(float3 d, float t) {
    float e = d.y;
    float3 c = mix(lin(kPurple), lin(kDeep), smoothstep(0.0, 0.7, e));
    c = mix(c, lin(kViolet), exp(-max(e, 0.0) * 9.0) * 0.55);
    c += lin(kCyan) * exp(-abs(e) * 40.0) * 0.35;   // the glow along the horizon

    // Silver stars, twinkling, high up.
    float2 sp = float2(atan2(d.x, -d.z), e) * 420.0;
    float2 cell = floor(sp);
    float h = hash(cell);
    if (e > 0.2 && h > 0.993) {
        float2 off = float2(hash(cell + 17.0), hash(cell + 31.0)) * 0.6 + 0.2;   // somewhere in its cell
        float dot_ = smoothstep(0.22, 0.0, length(fract(sp) - off));
        c += lin(kSilver) * dot_ * (0.7 + 0.3 * sin(t * 2.0 + h * 50.0)) * smoothstep(0.2, 0.4, e);
    }

    float3 sun = normalize(float3(0, sin(kSunElevation), -cos(kSunElevation)));
    float3 right = float3(1, 0, 0), up = normalize(cross(right, sun));
    float2 s = float2(dot(d, right), dot(d, up)) / kSunRadius;   // the sun's disc, radius 1
    float r = length(s);
    if (dot(d, sun) > 0 && r < 1.0) {
        // Silver at the top through cyan to purple, with the bands cut out of its lower half,
        // widening downwards and drifting slowly down.
        float y = s.y;
        float3 sc = y > 0.2 ? mix(lin(kCyan), lin(kSilver), smoothstep(0.2, 0.9, y)) : mix(lin(kViolet), lin(kCyan), smoothstep(-0.9, 0.2, y));
        float band = fract(y * 7.0 + t * 0.15);
        float gap = smoothstep(0.25, -1.0, y) * 0.55;
        if (y < 0.25 && band < gap) return c + lin(kViolet) * 0.25;
        return sc * 1.4;
    }
    if (dot(d, sun) > 0) c += mix(lin(kViolet), lin(kCyan), 0.4) * exp(-(r - 1.0) * 2.5) * 0.45;
    return c;
}

// Where the ray meets the ground: the neon grid near, the beach, then the sea out to the horizon.
constant float kBeachNear = -12.0, kBeachFar = -16.5;

static float3 ground(float3 o, float3 d, float t, float4 ball, thread float &dist) {
    dist = -o.y / d.y;
    float3 p = o + d * dist;
    float3 horizon = sky(float3(d.x, 0.0, d.z), t);
    float3 c;
    if (p.z > kBeachNear) {
        float2 g = p.xz / 1.6;
        float2 w = fwidth(g) * 1.2;
        float2 line = 1.0 - smoothstep(float2(0.0), w + 0.02, abs(fract(g + 0.5) - 0.5));
        float l = max(line.x, line.y);
        c = mix(lin(kDeep) * 1.4, lin(kCyan) * 1.6, l);
        c += lin(kViolet) * 0.12 * exp(-abs(p.x) * 0.15);
    } else if (p.z > kBeachFar) {
        float ripple = 0.5 + 0.5 * sin(p.x * 0.9 + sin(p.z * 3.0));
        c = mix(lin(kSilver) * 0.55, lin(kViolet) * 0.6, 0.35 + 0.2 * ripple);
    } else {
        // The sea, with the sun's reflection broken into shimmering silver and cyan bars.
        float far = -p.z;
        float col = abs(p.x) / far;
        float shimmer = step(0.55, fract(far * 0.6 - t * 0.8 + sin(p.x * 2.0) * 0.3));
        float path = smoothstep(0.30, 0.05, col) * shimmer;
        c = mix(lin(kDeep) * 1.2, lin(kPurple) * 0.6, 0.3);
        c += mix(lin(kCyan), lin(kSilver), smoothstep(0.15, 0.0, col)) * path * 0.9;
    }
    // The ball's shadow: softer and fainter the higher it is.
    float h = max(ball.y - ball.w, 0.0), spread = ball.w * (1.0 + h * 1.5);
    float2 off = p.xz - ball.xz;
    c *= 1.0 - 0.65 * exp(-dot(off, off) / (spread * spread)) / (1.0 + h * 2.0);
    return mix(horizon, c, exp(-dist * 0.018));   // haze to the horizon
}

fragment float4 fs(VOut in [[stage_in]], constant Eye &eye [[buffer(0)]], constant Board *boards [[buffer(1)]],
                   constant int &board_count [[buffer(2)]], texture2d<float> name [[texture(0)]],
                   texture2d<float> palm [[texture(1)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float t = eye.time.x;
    float3 v = normalize(float3(mix(eye.tan.x, eye.tan.y, in.uv.x), mix(eye.tan.z, eye.tan.w, in.uv.y), -1.0));
    float3 d = normalize(float3x3(eye.rot0.xyz, eye.rot1.xyz, eye.rot2.xyz) * v);
    float3 o = eye.pos.xyz;

    float depth = INFINITY;
    float3 c;
    if (d.y < -1e-4) c = ground(o, d, t, eye.ball, depth);
    else c = sky(d, t);

    // The pictures, furthest first, each over what's behind it.
    for (int i = 0; i < board_count; i++) {
        Board b = boards[i];
        if (d.z >= -1e-4) continue;
        float k = (b.centre.z - o.z) / d.z;
        if (k <= 0 || k > depth) continue;
        float3 p = o + d * k;
        float2 q = (p.xy - b.centre.xy) / b.half_size;
        if (any(abs(q) > 1.0)) continue;
        float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
        if (b.flip) uv.x = 1.0 - uv.x;
        float4 s = b.texture == 0 ? name.sample(smp, uv) : palm.sample(smp, uv);
        s *= smoothstep(1.0, 0.96, max(abs(q.x), abs(q.y)));   // no seam where the picture ends
        c = c * (1.0 - s.a) + s.rgb;
    }
    return float4(c, 1.0);
}

// ------------------------------------------------------------------------------ hands, controllers

struct Camera {
    float4x4 view, proj;
};

// A controller: Sony's model where it's been converted, lit by the sun ahead, with a cyan rim, and
// its buttons, sticks and triggers lit (glow) as they're touched and pressed.
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

fragment float4 mesh_fs(MeshOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4 &glow [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, mip_filter::linear, address::repeat);
    float3 n = normalize(in.normal);
    float3 sun = normalize(float3(0, 0.3, -1));
    float3 base = tex.sample(smp, in.uv).rgb;
    float lit = 0.35 + 0.65 * max(dot(n, sun), 0.0);
    float rim = pow(1.0 - max(dot(n, normalize(in.to_eye)), 0.0), 3.0);
    return float4(base * lit * float3(0.85, 0.85, 1.0) + lin(kCyan) * rim * 0.8 + lin(kViolet) * 0.05 + glow.rgb, 1);
}

// A hand in neon: a glowing line along each bone, and a dot on each fingertip (a line from the
// tip to itself). Each is a quad around the line, facing the eye, with room for the glow.
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
