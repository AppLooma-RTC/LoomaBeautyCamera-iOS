/// Metal Shading Language sources, compiled at run time with
/// `MTLDevice.makeLibrary(source:options:)` so the package needs no .metal
/// build step. A port of the GLSL ES pipeline used on the other platforms.
///
/// Texture coordinates have a top-left origin: (0, 0) is the first row of the
/// pixel buffer. Every uniform block is made of float4s only, so the Swift
/// structs that feed them have the same layout.
enum Shaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

constant float3 W = float3(0.299, 0.587, 0.114);

struct VOut {
    float4 position [[position]];
    float2 uv;
};

// Full-frame quad as a 4-vertex triangle strip.
vertex VOut vQuad(uint vid [[vertex_id]]) {
    float2 p = float2(float(vid & 1u), float((vid >> 1) & 1u));
    VOut o;
    o.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// Filled polygons and stickers: positions in buffer texture coordinates.
struct PolyIn { float2 pos; };
vertex VOut vPoly(const device float2 *pts [[buffer(0)]], uint vid [[vertex_id]]) {
    float2 p = pts[vid];
    VOut o;
    o.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
    o.uv = float2(0.0);
    return o;
}

struct StickerVertex { float4 posUv; };
vertex VOut vSticker(constant float4 *verts [[buffer(0)]], uint vid [[vertex_id]]) {
    float4 v = verts[vid];
    VOut o;
    o.position = float4(v.x * 2.0 - 1.0, 1.0 - v.y * 2.0, 0.0, 1.0);
    o.uv = v.zw;
    return o;
}

fragment float4 fPoly(VOut in [[stage_in]], constant float4 &value [[buffer(0)]]) {
    return float4(value.x);
}

fragment float4 fSticker(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

// Camera frame to RGBA. BGRA input reads as rgba through the texture format.
fragment float4 fCopy(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}

// Bi-planar YCbCr (420f / 420v) to RGB. p.x = video range, p.y = BT.709.
fragment float4 fCopyYuv(VOut in [[stage_in]], texture2d<float> yTex [[texture(0)]],
                         texture2d<float> cTex [[texture(1)]], constant float4 &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = yTex.sample(s, in.uv).r;
    float2 c = cTex.sample(s, in.uv).rg - 0.5;
    if (p.x > 0.5) { y = (y - 16.0 / 255.0) * (255.0 / 219.0); c *= 255.0 / 224.0; }
    float3 rgb;
    if (p.y > 0.5) rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
    else           rgb = float3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x);
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}

// Downsample for the guided filter: colour in rgb, squared luma in a.
fragment float4 fDown(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4 &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 t = p.xy;
    float3 c = tex.sample(s, in.uv + float2(-t.x, -t.y)).rgb
             + tex.sample(s, in.uv + float2( t.x, -t.y)).rgb
             + tex.sample(s, in.uv + float2(-t.x,  t.y)).rgb
             + tex.sample(s, in.uv + float2( t.x,  t.y)).rgb;
    c *= 0.25;
    float l = dot(c, W);
    return float4(c, l * l);
}

// Separable 9-tap Gaussian; p.xy is one texel along x or y, times the radius scale.
fragment float4 fBlur(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4 &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 d = p.xy;
    float4 r = tex.sample(s, in.uv) * 0.2270270270;
    r += (tex.sample(s, in.uv + d * 1.3846153846) + tex.sample(s, in.uv - d * 1.3846153846)) * 0.3162162162;
    r += (tex.sample(s, in.uv + d * 3.2307692308) + tex.sample(s, in.uv - d * 3.2307692308)) * 0.0702702703;
    return r;
}

struct FinalU {
    float4 skin01;    // skin reference uv 0 (xy), 1 (zw)
    float4 skin2;     // skin reference uv 2 (xy), hasFace, bgMode
    float4 a;         // smooth, whiten, rosy, sharpen
    float4 b;         // lutAmount, makeup, lipAmt, blushAmt
    float4 lip;       // rgb, complexion
    float4 blush;     // rgb, contour
    float4 shadowCol; // rgb, light3d
    float4 tone;      // rgb, darkCircles
    float4 c;         // smileLines, brightEyes, whiteTeeth, blemish
    float4 d;         // lipstick, eyebrow, eyeshadow, eyelash
    float4 e;         // lenses, contrast, lowLight, unused
    float4 f;         // texel (xy), frame rotation, seg rotation
};

float skinMask(float3 c) {
    float y  = dot(c, W);
    float cb = 0.5 + (-0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b);
    float cr = 0.5 + ( 0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b);
    float mCr = smoothstep(0.505, 0.53, cr) * (1.0 - smoothstep(0.66, 0.70, cr));
    float mCb = smoothstep(0.28, 0.31, cb) * (1.0 - smoothstep(0.50, 0.53, cb));
    float mY  = smoothstep(0.06, 0.14, y);
    return mCr * mCb * mY;
}

// Buffer uv to upright uv for a frame that `rot` clockwise degrees make upright.
float2 toUp(float2 uv, float rot) {
    if (rot > 260.0) return float2(uv.y, 1.0 - uv.x);
    if (rot > 170.0) return float2(1.0 - uv.x, 1.0 - uv.y);
    if (rot > 80.0) return float2(1.0 - uv.y, uv.x);
    return uv;
}

float3 lookup(texture2d<float> lut, sampler s, float3 c) {
    float b = c.b * 63.0;
    float2 q1; q1.y = floor(floor(b) / 8.0); q1.x = floor(b) - q1.y * 8.0;
    float2 q2; q2.y = floor(ceil(b) / 8.0);  q2.x = ceil(b) - q2.y * 8.0;
    float2 t = float2(0.125 * c.r + 0.5 / 512.0 - c.r / 512.0, 0.125 * c.g + 0.5 / 512.0 - c.g / 512.0);
    float3 a1 = lut.sample(s, q1 * 0.125 + t).rgb;
    float3 a2 = lut.sample(s, q2 * 0.125 + t).rgb;
    return mix(a1, a2, fract(b));
}

fragment float4 fFinal(VOut in [[stage_in]],
                       texture2d<float> uSrc [[texture(0)]],
                       texture2d<float> uMean [[texture(1)]],
                       texture2d<float> uLut [[texture(2)]],
                       texture2d<float> uFace [[texture(3)]],
                       texture2d<float> uSeg [[texture(4)]],
                       texture2d<float> uBg [[texture(5)]],
                       texture2d<float> uMask2 [[texture(6)]],
                       texture2d<float> uMask3 [[texture(7)]],
                       texture2d<float> uGlass [[texture(8)]],
                       constant FinalU &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    constexpr sampler sr(filter::linear, address::repeat);
    float2 vUv = in.uv;
    float2 uSkinUv0 = u.skin01.xy, uSkinUv1 = u.skin01.zw, uSkinUv2 = u.skin2.xy;
    float uHasFace = u.skin2.z, uBgMode = u.skin2.w;
    float uSmooth = u.a.x, uWhiten = u.a.y, uRosy = u.a.z, uSharpen = u.a.w;
    float uLutAmount = u.b.x, uMakeup = u.b.y, uLipAmt = u.b.z, uBlushAmt = u.b.w;
    float3 uLip = u.lip.rgb; float uComplexion = u.lip.w;
    float3 uBlush = u.blush.rgb; float uContour = u.blush.w;
    float3 uShadowCol = u.shadowCol.rgb; float uLight3d = u.shadowCol.w;
    float3 uTone = u.tone.rgb; float uDarkCircles = u.tone.w;
    float uSmileLines = u.c.x, uBrightEyes = u.c.y, uWhiteTeeth = u.c.z, uBlemish = u.c.w;
    float uLipstick = u.d.x, uEyebrow = u.d.y, uEyeshadow = u.d.z, uEyelash = u.d.w;
    float uLenses = u.e.x, uContrast = u.e.y, uLowLight = u.e.z;
    float2 uTexel = u.f.xy; float uFrameRot = u.f.z, uSegRot = u.f.w;

    float3 c = uSrc.sample(s, vUv).rgb;
    float4 m = uMean.sample(s, vUv);
    float sk = skinMask(c);
    float face = uFace.sample(s, vUv).r;

    // 1. Skin probability from this face's own skin colour (cheeks and forehead).
    float3 ref = (uMean.sample(s, uSkinUv0).rgb + uMean.sample(s, uSkinUv1).rgb + uMean.sample(s, uSkinUv2).rgb) / 3.0;
    float3 dRef = (m.rgb - ref) * float3(1.0, 1.3, 1.3);
    float skinProb = exp(-dot(dRef, dRef) * 28.0) * smoothstep(0.0, 0.35, sk + 0.2);

    // 2. High-pass: strong local detail is an edge, and edges are never smoothed.
    float3 hp = c - m.rgb;
    float hpMag = (abs(hp.r) + abs(hp.g) + abs(hp.b)) / 3.0;
    float edge = smoothstep(0.08, 0.2, hpMag);

    // 3. Where to smooth: face skin, away from edges; outside the face nothing.
    float skin = uHasFace > 0.5 ? face * skinProb * (1.0 - edge) : 0.0;

    // 4. Dark detail (beard, brows, lashes, pupils, nostrils) is never smoothed.
    float darkKeep = clamp((m.r - 0.24) * 4.0, 0.0, 1.0);

    // 5. Textured areas are smoothed less.
    float lm = dot(m.rgb, W);
    float v = max(m.a - lm * lm, 0.0);
    float tol = 0.002 + 0.03 * uSmooth * uSmooth + 0.006 * uSmooth;
    float varKeep = tol / (v + tol);

    // 6. Target colour: darker spots lifted fully, brighter detail a little.
    float3 lift = m.rgb - c;
    float darker = step(0.0, lift.r + lift.g + lift.b);
    float3 smoothC = c + lift * mix(0.5 + 0.5 * uSmooth, 1.0, darker);

    float3 r = mix(c, smoothC, clamp(skin * darkKeep * varKeep * uSmooth * 2.4, 0.0, 1.0));

    float4 fm = uFace.sample(s, vUv);
    float4 f2 = uHasFace > 0.5 ? uMask2.sample(s, vUv) : float4(0.0);
    if (uHasFace < 0.5) fm = float4(0.0);

    // Blemishes.
    float spot = smoothstep(0.012, 0.06, dot(m.rgb - c, W));
    r = mix(r, m.rgb, spot * uBlemish * skin);
    // Smile lines and dark circles.
    r = mix(r, m.rgb * 1.02, f2.g * uSmileLines * 0.85);
    r = mix(r, mix(r, m.rgb, 0.6) * 1.1 + float3(0.02, 0.012, 0.0), f2.r * uDarkCircles * 0.8);

    // Sharpen detail outside the smoothed skin.
    float3 detail = c - m.rgb;
    r += detail * uSharpen * 1.2 * (1.0 - 0.85 * skin);
    // Low-light boost.
    float lmL = dot(m.rgb, W);
    float dark = 1.0 - smoothstep(0.12, 0.6, lmL);
    r += (1.0 - r) * uLowLight * 0.35 * dark * (1.0 - smoothstep(0.0, 0.8, dot(r, W)));

    // Whitening: a log curve that lifts mid-tones.
    float k = 1.0 + uWhiten * 5.0;
    float3 lifted = log(clamp(r, 0.0, 1.0) * (k - 1.0) + 1.0) / log(k);
    float lumIn = dot(c, W);
    float pale = smoothstep(0.62, 0.85, lumIn);
    float skinOnly = max(face * smoothstep(0.1, 0.24, dot(m.rgb, W)), sk * skinProb * (1.0 - pale));
    lifted = mix(lifted, lifted * float3(1.0, 0.98, 1.025), skinOnly * 0.6);
    r = mix(r, lifted, uWhiten > 0.0 ? (0.85 + 0.1 * face + 0.05 * skin) * mix(1.0 - 0.75 * pale, 1.0, face) : 0.0);

    // Rosy.
    r = mix(r, r * float3(1.03, 0.96, 1.03) + float3(0.03, 0.0, 0.035), uRosy * clamp(0.6 * skinOnly + 0.4 * face, 0.0, 1.0));

    // Complexion.
    float lumC = dot(r, W);
    float3 found = uTone * (lumC / max(dot(uTone, W), 0.05));
    r = mix(r, mix(r, found, 0.65), uComplexion * skin * 0.75);
    // Contour and 3D light.
    r *= 1.0 - f2.a * uContour * 0.2;
    r = mix(r, r + (1.0 - r) * 0.28, f2.b * uLight3d);
    // Eye make-up: mask 3 = (brows, upper lids, lash line, irises).
    float4 f3 = uHasFace > 0.5 ? uMask3.sample(s, vUv) : float4(0.0);
    r = mix(r, r * float3(0.55, 0.5, 0.48), f3.r * uEyebrow * 0.7);
    r = mix(r, mix(r, uShadowCol * (0.45 + 0.9 * dot(r, W)), 0.75), f3.g * (1.0 - fm.a) * uEyeshadow * 0.65);
    r = mix(r, r * 0.35, f3.b * (1.0 - fm.a * 0.6) * uEyelash * 0.8);
    float irisL = dot(r, W);
    r = mix(r, float3(0.50, 0.33, 0.18) * (0.4 + 1.2 * irisL), f3.a * fm.a * uLenses * 0.7);
    // Lipstick.
    float lipW = smoothstep(0.4, 0.85, fm.g) * smoothstep(0.1, 0.28, dot(c, W));
    r = mix(r, float3(0.86, 0.27, 0.32) * (0.6 + 0.85 * dot(r, W)), lipW * uLipstick * 0.95);

    // Clarity in the eyes.
    float3 ec = (r - 0.5) * 1.18 + 0.5 + 0.035;
    r = mix(r, ec, fm.a * uBrightEyes);
    // White teeth.
    float mouth = smoothstep(0.2, 0.42, fm.g) * (1.0 - smoothstep(0.58, 0.8, fm.g));
    float lt = dot(r, W);
    float sat = max(r.r, max(r.g, r.b)) - min(r.r, min(r.g, r.b));
    float teeth = mouth * smoothstep(0.22, 0.4, lt) * (1.0 - smoothstep(0.25, 0.45, sat));
    r = mix(r, float3(min(lt * 1.15 + 0.04, 1.0)) * float3(0.99, 1.0, 1.02), teeth * uWhiteTeeth * 0.8);

    // Make-up: lip colour and blush.
    if (uMakeup > 0.0) {
        float lum = dot(r, W);
        float3 lipTint = uLip * (0.55 + 0.9 * lum);
        r = mix(r, lipTint, smoothstep(0.62, 0.95, fm.g) * uLipAmt * 0.75);
        r = mix(r, r * (0.6 + 0.4 * uBlush) + uBlush * 0.18, fm.b * uBlushAmt * 0.45);
    }

    // Contrast, whole picture.
    r = (r - 0.5) * (1.0 + 0.3 * uContrast) + 0.5;
    r = clamp(r, 0.0, 1.0);
    if (uLutAmount > 0.0) r = mix(r, lookup(uLut, s, r), uLutAmount);

    // Background.
    if (uBgMode > 0.5) {
        float2 up = toUp(vUv, uFrameRot);
        float3 c0 = uSrc.sample(s, vUv).rgb;
        float acc = 0.0; float wsum = 0.0;
        for (int i = -1; i <= 1; i++) for (int j = -1; j <= 1; j++) {
            float2 o = float2(float(i), float(j)) * uTexel * 5.0;
            float3 cn = uSrc.sample(s, vUv + o).rgb;
            float3 dc = cn - c0;
            float w = exp(-dot(dc, dc) * 40.0);
            acc += uSeg.sample(s, toUp(vUv + o, uSegRot)).r * w;
            wsum += w;
        }
        float person = smoothstep(0.4, 0.7, acc / max(wsum, 1e-4));
        float3 bg;
        if (uBgMode < 1.5) bg = uBg.sample(s, vUv).rgb;
        else if (uBgMode < 2.5) bg = uBg.sample(s, up).rgb;
        else {
            // Frosted glass: the blurred room seen through the glass, bent by its relief.
            float3 gl = uGlass.sample(sr, up).rgb;
            float gLum = dot(gl, W);
            float2 e = float2(0.012, 0.007);
            float gx = dot(uGlass.sample(sr, up + float2(e.x, 0.0)).rgb, W) - dot(uGlass.sample(sr, up - float2(e.x, 0.0)).rgb, W);
            float gy = dot(uGlass.sample(sr, up + float2(0.0, e.y)).rgb, W) - dot(uGlass.sample(sr, up - float2(0.0, e.y)).rgb, W);
            float2 grad = float2(gx, gy);
            bg = uBg.sample(s, vUv + grad * 0.08).rgb;
            bg = mix(bg, float3(gLum), 0.12) + (gx + gy) * 0.22 + (gLum - 0.55) * 0.12;
        }
        r = mix(bg, r, person);
    }
    return float4(r, 1.0);
}
"""#
}
