// Studio: a matte grey floor with a faint one-metre grid, a pool of light where you stand, and a
// pale sky that fades into the floor at the horizon. Nothing moves.

constant float3 kHorizon = float3(0.80, 0.82, 0.86);
constant float3 kZenith = float3(0.42, 0.47, 0.56);

float3 backdrop(float3 o, float3 d, constant Eye &eye, thread float &depth) {
    float3 horizon = lin(kHorizon);
    if (d.y >= -1e-4) return mix(horizon, lin(kZenith), smoothstep(0.0, 0.6, d.y));

    depth = -o.y / d.y;
    float3 p = o + d * depth;
    float r = length(p.xz);
    float3 c = mix(lin(float3(0.60, 0.61, 0.64)), lin(float3(0.47, 0.48, 0.51)), smoothstep(2.0, 12.0, r));
    c += lin(float3(0.95, 0.93, 0.88)) * 0.25 * exp(-r * r / 6.0);   // the light where you stand

    float2 g = p.xz;
    float2 w = fwidth(g) * 1.2;
    float2 line = 1.0 - smoothstep(float2(0.0), w + 0.01, abs(fract(g + 0.5) - 0.5));
    c *= 1.0 - 0.18 * max(line.x, line.y) * exp(-r * 0.12);

    // The ball's shadow: softer and fainter the higher it is.
    float4 ball = eye.ball;
    float h = max(ball.y - ball.w, 0.0), spread = ball.w * (1.0 + h * 1.5);
    float2 off = p.xz - ball.xz;
    c *= 1.0 - 0.55 * exp(-dot(off, off) / (spread * spread)) / (1.0 + h * 2.0);
    return mix(horizon, c, exp(-depth * 0.04));   // haze to the horizon
}
