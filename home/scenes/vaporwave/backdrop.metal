// Vaporwave: a purple sky over a striped sun setting into the sea, a neon grid running down to a
// silver beach lined with palms (pictures), and the name in chrome lettering. Purple, cyan and
// silver. Only the sea moves: a moving floor makes people queasy.

constant float3 kDeep = float3(0.05, 0.01, 0.12);
constant float3 kPurple = float3(0.40, 0.12, 0.72);
constant float3 kViolet = float3(0.62, 0.30, 0.95);
constant float3 kCyan = float3(0.00, 0.92, 1.00);
constant float3 kSilver = float3(0.84, 0.87, 0.94);

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

float3 backdrop(float3 o, float3 d, constant Eye &eye, thread float &depth) {
    if (d.y < -1e-4) return ground(o, d, eye.time.x, eye.ball, depth);
    return sky(d, eye.time.x);
}
