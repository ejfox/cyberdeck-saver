#include <metal_stdlib>
using namespace metal;

// ============================================================
// Shared types
// ============================================================

struct Uniforms {
    float2 resolution;
    float time;
    uint frame;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle — 3 vertices, no vertex buffer needed
vertex VertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    VertexOut out;
    out.texCoord = float2((vid << 1) & 2, vid & 2);
    out.position = float4(out.texCoord * 2.0 - 1.0, 0.0, 1.0);
    out.texCoord.y = 1.0 - out.texCoord.y;
    return out;
}

// ============================================================
// BLOOM — Red-selective neon glow (ported from bloom-vulpes.glsl)
// Only glows red/pink pixels + very bright pixels
// ============================================================

constant float3 bloomSamples[24] = {
    float3( 0.1693761725038636,  0.9855514761735895, 1.0),
    float3(-1.333070830962943,   0.4721463328627773, 0.7071067811865475),
    float3(-0.8464394909806497, -1.51113870578065,   0.5773502691896258),
    float3( 1.554155680728463,  -1.2588090085709776, 0.5),
    float3( 1.681364377589461,   1.4741145918052656, 0.4472135954999579),
    float3(-1.2795157692199817,  2.088741103228784,  0.4082482904638631),
    float3(-2.4575847530631187, -0.9799373355024756, 0.3779644730092272),
    float3( 0.5874641440200847, -2.7667464429345077, 0.35355339059327373),
    float3( 2.997715703369726,   0.11704939884745152,0.3333333333333333),
    float3( 0.41360842451688395,  3.1351121305574803,0.31622776601683794),
    float3(-3.167149933769243,   0.9844599011770256, 0.30151134457776363),
    float3(-1.5736713846521535, -3.0860263079123245, 0.2886751345948129),
    float3( 2.888202648340422,  -2.1583061557896213, 0.2773500981126146),
    float3( 2.7150778983300325,  2.5745586041105715, 0.2672612419124244),
    float3(-2.1504069972377464,  3.2211410627650165, 0.2581988897471611),
    float3(-3.6548858794907493, -1.6253643308191343, 0.25),
    float3( 1.0130775986052671, -3.9967078676335834, 0.24253562503633297),
    float3( 4.229723673607257,   0.33081361055181563,0.23570226039551587),
    float3( 0.40107790291173834, 4.340407413572593,  0.22941573387056174),
    float3(-4.319124570236028,   1.159811599693438,  0.22360679774997896),
    float3(-1.9209044802827355, -4.160543952132907,  0.2182178902359924),
    float3( 3.8639122286635708, -2.6589814382925123, 0.21320071635561041),
    float3( 3.3486228404946234,  3.4331800232609,    0.20851441405707477),
    float3(-2.8769733643574344,  3.9652268864187157, 0.20412414523193154)
};

float luminance(float4 c) {
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
}

fragment float4 bloom_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.texCoord;
    float4 original = tex.sample(s, uv);
    float4 color = original;
    float2 stepSize = float2(1.8) / u.resolution;

    for (int i = 0; i < 24; i++) {
        float3 sp = bloomSamples[i];
        float4 c = tex.sample(s, uv + sp.xy * stepSize);
        float l = luminance(c);

        float brightness = max(max(c.r, c.g), c.b);
        bool veryBright = brightness > 0.55;
        bool isRed = c.r > 0.75 && c.r > c.g * 1.2;

        if (l > 0.2 && (veryBright || isRed)) {
            color += l * sp.z * c * 0.08;
        }
    }

    // Subtle red emphasis on the bloom contribution only.
    float4 bloomOnly = color - original;
    bloomOnly.r *= 1.1;
    return original + bloomOnly;
}

// ============================================================
// TFT — LCD subpixel effect (ported from tft-subtle.glsl)
// ============================================================

fragment float4 tft_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 color = tex.sample(s, in.texCoord).rgb;

    float res = 3.0;
    float strength = 0.26;

    float scanline = step(1.2, fmod(in.texCoord.y * u.resolution.y, res));
    float grille   = step(1.2, fmod(in.texCoord.x * u.resolution.x, res));
    float mask = scanline * grille;

    color *= max(1.0 - strength, mask);

    return float4(color, 1.0);
}

// ============================================================
// VIGNETTE — Edge darkening (ported from vignette-vulpes.glsl)
// ============================================================

fragment float4 vignette_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 color = tex.sample(s, in.texCoord);

    float2 diff = in.texCoord - float2(0.5);
    float dist = length(diff) * 1.2;
    float vignette = 1.0 - smoothstep(0.0, 1.0, dist);
    vignette = mix(1.0, vignette, 0.15);

    color.rgb *= vignette;
    return color;
}

// ============================================================
// SCANLINE — CRT flicker (ported from scanline-flicker.glsl)
// ============================================================

fragment float4 scanline_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 color = tex.sample(s, in.texCoord);

    float line = in.texCoord.y * u.resolution.y;
    float slowDrift = sin(u.time * 0.7) * 0.5 + 0.5;
    float fastPulse = sin(u.time * 8.0 + line * 0.01) * 0.5 + 0.5;
    float flicker = mix(slowDrift, fastPulse, 0.3);

    float scanlinePhase = sin(line * 3.14159);
    float variation = scanlinePhase * flicker * 0.015;

    color.rgb += variation;
    return color;
}

// ============================================================
// GLITCH — Analog distortion + chromatic aberration
// (ported from glitchy.glsl, based on shadertoy.com/view/wld3WN)
// ============================================================

constant uint UI3_vals[3] = { 1597334673u, 3812015801u, 2798796415u };
constant float UIF_val = 1.0 / float(0xffffffffu);

float3 hash33(float3 p) {
    uint3 q = uint3(int3(p)) * uint3(UI3_vals[0], UI3_vals[1], UI3_vals[2]);
    q = (q.x ^ q.y ^ q.z) * uint3(UI3_vals[0], UI3_vals[1], UI3_vals[2]);
    return -1.0 + 2.0 * float3(q) * UIF_val;
}

float gnoise(float3 x) {
    float3 p = floor(x);
    float3 w = fract(x);
    float3 uu = w * w * w * (w * (w * 6.0 - 15.0) + 10.0);

    float3 ga = hash33(p + float3(0, 0, 0));
    float3 gb = hash33(p + float3(1, 0, 0));
    float3 gc = hash33(p + float3(0, 1, 0));
    float3 gd = hash33(p + float3(1, 1, 0));
    float3 ge = hash33(p + float3(0, 0, 1));
    float3 gf = hash33(p + float3(1, 0, 1));
    float3 gg = hash33(p + float3(0, 1, 1));
    float3 gh = hash33(p + float3(1, 1, 1));

    float va = dot(ga, w - float3(0, 0, 0));
    float vb = dot(gb, w - float3(1, 0, 0));
    float vc = dot(gc, w - float3(0, 1, 0));
    float vd = dot(gd, w - float3(1, 1, 0));
    float ve = dot(ge, w - float3(0, 0, 1));
    float vf = dot(gf, w - float3(1, 0, 1));
    float vg = dot(gg, w - float3(0, 1, 1));
    float vh = dot(gh, w - float3(1, 1, 1));

    return 2.0 * (va +
        uu.x * (vb - va) +
        uu.y * (vc - va) +
        uu.z * (ve - va) +
        uu.x * uu.y * (va - vb - vc + vd) +
        uu.y * uu.z * (va - vc - ve + vg) +
        uu.z * uu.x * (va - vb - ve + vf) +
        uu.x * uu.y * uu.z * (-va + vb + vc - vd + ve - vf - vg + vh));
}

fragment float4 glitch_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant Uniforms &u [[buffer(0)]])
{
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.texCoord;
    float t = u.time;

    float DURATION = 10.0;
    float AMT = 0.1;

    // Smoothed glitch trigger window
    float gt = fmod(t, DURATION);
    float glitchAmount = smoothstep(DURATION * 0.001, DURATION * AMT, gt)
                       * smoothstep(DURATION * AMT, DURATION * 0.001, gt);

    float3 col = float3(0.0);
    float2 eps = float2(5.0 / u.resolution.x, 0.0);

    // Analog distortion
    float y = uv.y * u.resolution.y;
    float distortion = gnoise(float3(0.0, y * 0.01, t * 500.0)) * (glitchAmount * 4.0 + 0.1);
    distortion *= gnoise(float3(0.0, y * 0.02, t * 250.0)) * (glitchAmount * 2.0 + 0.025);

    distortion += smoothstep(0.999, 1.0, sin((uv.y + t * 1.6) * 2.0)) * 0.02;
    distortion -= smoothstep(0.999, 1.0, sin((uv.y + t) * 2.0)) * 0.02;

    float2 st = uv + float2(distortion, 0.0);

    // Chromatic aberration
    col.r = tex.sample(s, st + eps + float2(distortion)).r;
    col.g = tex.sample(s, st).g;
    col.b = tex.sample(s, st - eps - float2(distortion)).b;

    // White noise + scanlines
    float displayNoise = 0.2;
    col += (0.15 + 0.65 * glitchAmount) * hash33(float3(uv * u.resolution, fmod(float(u.frame), 1000.0))).r * displayNoise;
    col -= (0.25 + 0.75 * glitchAmount) * sin(4.0 * t + uv.y * u.resolution.y * 1.75) * displayNoise;

    return float4(col, 1.0);
}
