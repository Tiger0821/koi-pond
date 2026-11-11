// Compiled at launch with MTLDevice.makeLibrary(source:), so SwiftPM needs no Metal build step.
enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 world;   // width, height, time, pixel mode
        float4 water;   // rgb, clarity
        float4 tint;    // rgb multiply, ambient add
        float4 glow;    // rgb, strength
        float4 fx;      // caustics, current strength, flow time, rain
        float4 fx2;     // lightning, saturation, points per texel, fish colour kept at night
    };

    struct Instance {
        float2 position;
        float2 size;
        float rotation;
        float kind;
        float seed;
        float phase;
        float4 color0;
        float4 color1;
        float4 color2;
        float4 params;
        float4 params2;
        float4 params3;
        float4 params4;
    };

    constant float TAU = 6.2831853;
    constant float2 kCorners[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
    };

    // MARK: Noise

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float2 hash22(float2 p) {
        float n = hash21(p);
        return float2(n, hash21(p + n * 19.19 + 7.7));
    }

    float vnoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
    }

    float fbm(float2 p) {
        float s = 0.0;
        float a = 0.5;
        for (int i = 0; i < 4; i++) {
            s += a * vnoise(p);
            p = p * 2.03 + float2(11.7, 5.3);
            a *= 0.5;
        }
        return s / 0.9375;
    }

    // Distance between the nearest two animated cell centres: thin bright lines where cells meet.
    float cellEdges(float2 p, float t) {
        float2 i = floor(p);
        float2 f = fract(p);
        float f1 = 8.0;
        float f2 = 8.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 g = float2(float(x), float(y));
                float2 o = 0.5 + 0.42 * sin(t + TAU * hash22(i + g));
                float d = length(g + o - f);
                if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
            }
        }
        return f2 - f1;
    }

    float caustics(float2 p, float t) {
        // Warp the cells so the light lines curve like refracted sunlight instead of tiles.
        p += float2(sin(p.y / 53.0 + t * 0.4), cos(p.x / 61.0 - t * 0.3)) * 11.0;
        float a = 1.0 - smoothstep(0.0, 0.08, cellEdges(p / 70.0, t * 0.8));
        float b = 1.0 - smoothstep(0.0, 0.07, cellEdges(p / 44.0 + 3.1, t * 1.1 + 1.7));
        return a * 0.35 + b * 0.2 + a * b * 1.2;
    }

    // Keep in sync with Flow.streamFunction in KoiPondCore.
    float streamFn(float2 p, float t) {
        return 190.0 * sin(0.0031 * p.x + 0.21 * t)
             + 170.0 * cos(0.0037 * p.y - 0.17 * t)
             + 230.0 * sin(0.0021 * (p.x - p.y) + 0.13 * t)
             + 0.18 * p.y;
    }

    // MARK: Shared shading

    float edgeMask(float d, float aa, bool pixel) {
        return pixel ? step(d, 0.0) : 1.0 - smoothstep(-aa, aa, d);
    }

    float3 posterize(float3 c, bool pixel) {
        return pixel ? floor(c * 18.0 + 0.5) / 18.0 : c;
    }

    float3 underwater(float3 c, float depth, constant Uniforms& u) {
        float murk = clamp(depth * (1.0 - u.water.w * 0.8) * 0.9, 0.0, 0.85);
        return mix(c, u.water.rgb * 0.92, murk);
    }

    float4 shadowColor(float m, float alpha) {
        return float4(0.02, 0.07, 0.08, m * alpha);
    }

    // MARK: Full-screen passes

    struct FullOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex FullOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        FullOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = p;
        return o;
    }

    fragment float4 water_fragment(FullOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        bool pixel = u.world.w > 0.5;
        float2 world = u.world.xy;
        float2 p = in.uv * world;
        float t = u.world.z;
        float clarity = u.water.w;

        float deep = fbm(p / 300.0 + 3.7);
        float3 col = u.water.rgb * (0.8 + 0.3 * deep);

        // Pebbles and silt on the floor show through clear water.
        float silt = fbm(p / 38.0 + 9.1);
        float pebbles = smoothstep(0.66, 0.82, vnoise(p / 6.5)) * smoothstep(0.4, 0.7, silt);
        col = mix(col, col * 0.72, pebbles * (0.15 + 0.45 * clarity));
        col *= 0.97 + 0.06 * silt * clarity;

        // Banks are darker than the open middle.
        float2 q = (in.uv - 0.5) * 2.0;
        float bank = length(q * float2(0.85, 1.0));
        col *= 0.68 + 0.32 * (1.0 - smoothstep(0.5, 1.5, bank));

        // Core glow: light pooling toward the upper left.
        float gd = length(p - float2(0.4, 0.6) * world) / min(world.x, world.y);
        float g = exp(-gd * gd * 3.0) * u.glow.w;
        col = col * (1.0 + g * 0.35) + u.glow.rgb * g * 0.12;

        col += float3(1.0, 0.98, 0.9) * caustics(p, t) * u.fx.x * (0.2 + 0.8 * clarity) * 0.1;

        // Currents: faint streaks along the stream function's level lines.
        if (u.fx.y > 0.001) {
            float ft = u.fx.z;
            float lane = vnoise(float2(streamFn(p, ft) / 5.0, 0.37));
            float seg = vnoise(p / 90.0 + float2(ft * 0.31, -ft * 0.23));
            float streak = smoothstep(0.74, 0.9, lane) * smoothstep(0.42, 0.8, seg);
            col += float3(0.85, 0.97, 1.0) * streak * u.fx.y * 0.09;
        }

        return float4(posterize(col, pixel), 1.0);
    }

    fragment float4 composite_fragment(FullOut in [[stage_in]],
                                       texture2d<float> scene [[texture(0)]],
                                       sampler smp [[sampler(0)]],
                                       constant Uniforms& u [[buffer(0)]]) {
        float3 c = scene.sample(smp, float2(in.uv.x, 1.0 - in.uv.y)).rgb;
        float luma = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(luma), c, u.fx2.y);
        c = c * u.tint.rgb + u.tint.w;

        float rain = u.fx.w;
        if (rain > 0.01) {
            float2 p = in.uv * u.world.xy;
            if (u.world.w > 0.5) { p = floor(p / u.fx2.z) * u.fx2.z; }
            float2 rp = float2(p.x + p.y * 0.22, p.y);
            float h = hash21(float2(floor(rp.x / 4.0), 3.7));
            float y = fract(rp.y / 220.0 + u.world.z * (2.2 + h * 1.5) + h * 17.0);
            float drop = step(1.0 - 0.18 * rain, h) * smoothstep(0.0, 0.03, y) * (1.0 - smoothstep(0.03, 0.12, y));
            c += drop * 0.07 * rain;
        }

        c += u.fx2.x * float3(0.7, 0.78, 0.95) * 0.5;
        return float4(saturate(c), 1.0);
    }

    // MARK: Instances

    struct InstOut {
        float4 position [[position]];
        float2 local;
        uint iid [[flat]];
    };

    vertex InstOut instance_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device Instance* inst [[buffer(0)]],
                                   constant Uniforms& u [[buffer(1)]]) {
        Instance I = inst[iid];
        float2 local = kCorners[vid] * I.size;
        float s = sin(I.rotation);
        float c = cos(I.rotation);
        float2 w = I.position + float2(local.x * c - local.y * s, local.x * s + local.y * c);
        InstOut o;
        o.position = float4(w / u.world.xy * 2.0 - 1.0, 0.0, 1.0);
        o.local = local;
        o.iid = iid;
        return o;
    }

    struct FishShape {
        float body;   // signed distance to the body edge, negative inside
        float tail;
        float fin;
        float s;      // 0 at the head, 1 at the tail tip
        float y;      // lateral position after bending
        float hw;     // body half width at s
        float tailU;  // 0 at the tail's root, 1 at its tip
        float tailV;  // 0 on the centre line, 1 at the edge of the tail
        float finU;   // 0 at a pectoral fin's root, 1 at its tip
        float finV;   // -1…1 across a pectoral fin
    };

    float fishHalfWidth(float s, float W) {
        if (s < 0.26) {
            float k = (0.26 - s) / 0.26;
            return W * sqrt(max(0.0, 1.0 - k * k));
        }
        return W * mix(1.0, 0.2, smoothstep(0.26, 0.8, s));
    }

    float fishBend(float s, float L, float amp, float curv, float phase) {
        return amp * L * sin(phase - s * 5.2) * pow(s, 1.6) + curv * L * s * s;
    }

    // Top-down koi with +x as the head; the spine bends with the swim wave and the turn.
    // Dancing moves the body only, from the head back to the tail's root: `squash` above 0 shortens and
    // fattens it (below 0 stretches it), and `jolt` swings the head about that root. The tail fin and its
    // swimming beat are left as they are.
    FishShape fishShape(float2 p, float L, float W, float amp, float curv, float phase, float squash, float jolt) {
        FishShape f;
        const float root = 0.72;
        float xRoot = (0.5 - root) * L;
        float k = 1.0 - 0.2 * squash;
        float x = p.x > xRoot ? xRoot + (p.x - xRoot) / k : p.x;
        float s = (0.5 * L - x) / L;
        float sc = clamp(s, 0.0, 1.0);
        float swing = jolt * max(0.0, p.x - xRoot);
        float y = p.y - fishBend(sc, L, amp, curv, phase) - swing;
        float fat = mix(1.0 + 0.24 * squash, 1.0, smoothstep(root - 0.15, root, sc));
        float hw = fishHalfWidth(sc, W) * fat;
        f.body = max(abs(y) - hw, max(-s, s - 0.82) * L);

        float tu = (s - 0.7) / 0.3;
        float spread = W * (0.16 + 1.1 * pow(clamp(tu, 0.0, 1.0), 1.15));
        float yr = clamp(abs(y) / max(spread, 0.001), 0.0, 1.0);
        float tailEnd = 0.74 + 0.26 * yr;   // forked tip
        f.tail = max(abs(y) - spread, max(-tu, tu - tailEnd) * L * 0.3);
        f.tailU = clamp(tu / tailEnd, 0.0, 1.0);
        f.tailV = yr;

        // Pectoral fins sweep back and out, paddling slowly, carried along with the dancing body.
        float s3 = 0.3;
        float fx = xRoot + ((0.5 - s3) * L - xRoot) * k;
        float off3 = fishBend(s3, L, amp, curv, phase) + jolt * max(0.0, fx - xRoot);
        float side = (p.y - off3) >= 0.0 ? 1.0 : -1.0;
        float2 q = float2(p.x - fx, abs(p.y - off3) - fishHalfWidth(s3, W) * (1.0 + 0.24 * squash) * 0.75);
        float ang = 0.55 + 0.3 * sin(phase * 0.5 + side * 0.8);
        float2 dir = float2(-cos(ang), sin(ang));
        float along = dot(q, dir);
        float across = dot(q, float2(-dir.y, dir.x));
        float fl = L * 0.2;
        float fw = L * 0.06;
        f.fin = (length(float2((along - fl * 0.5) / (fl * 0.5), across / fw)) - 1.0) * fw;
        f.finU = clamp(along / fl, 0.0, 1.0);
        f.finV = clamp(across / fw, -1.0, 1.0);

        f.s = s;
        f.y = y;
        f.hw = hw;
        return f;
    }

    // A pixel artist's ramp rather than plain darkening: shadows on whites and blues lean cool, shadows on
    // reds, oranges and yellows lean towards red-orange (so gold goes amber, never olive), and light above
    // 1 lifts towards a warm white.
    float3 lightRamp(float3 c, float light) {
        if (light >= 1.0) { return mix(c, float3(1.0, 0.98, 0.92), saturate((light - 1.0) * 1.6)); }
        float warm = saturate((c.r - c.b) * 1.6);
        float3 tint = mix(float3(0.84, 0.92, 1.0), float3(1.0, 0.8, 0.6), warm);
        return c * light * pow(tint, float3((1.0 - light) * 2.0));
    }

    // Undo part of the scene's grey-out and tint on a fish (the composite applies both after), so under
    // moonlight or at dusk it stays its own colour, only dimmer.
    float3 keepColour(float3 c, float keep, constant Uniforms& u) {
        const float3 W3 = float3(0.299, 0.587, 0.114);
        float3 T = max(u.tint.rgb, float3(0.05));
        float A = u.tint.w;
        float3 today = mix(float3(dot(c, W3)), c, u.fx2.y) * T + A;
        float3 own = c * dot(T, W3) + A;
        float3 x = (mix(today, own, keep) - A) / T;
        float lx = dot(x, W3);
        return saturate(lx + (x - lx) / max(u.fx2.y, 0.2));
    }

    // Koi and small fish: patterns placed the way judges like them, lit from the upper left like the
    // shadows, a shine and glinting scales on metallic fish, see-through fins with rays fanning out, and in
    // Pixel a one-texel outline in a darker shade of the colour inside.
    float4 shadeFish(Instance I, float2 p, constant Uniforms& u, bool pixel, float aa) {
        float L = I.params.x;
        float W = L * I.params.y;
        FishShape f = fishShape(p, L, W, I.params.z, I.params.w, I.phase, I.color1.w, I.color2.w);
        float mBody = edgeMask(f.body, aa, pixel);
        float mTail = edgeMask(f.tail, aa, pixel);
        float mFin = edgeMask(f.fin, aa, pixel);
        if (mBody + mTail + mFin <= 0.0) { return float4(0.0); }

        float t = u.world.z;
        float3 baseC = I.color0.rgb;
        float3 patchC = I.color1.rgb;
        float3 accentC = I.color2.rgb;
        float special = I.params2.z;
        float metallic = I.params3.x;
        float fins = I.params3.y;
        bool redEyes = I.params3.z > 0.5;
        float lateral = f.y / max(W, 0.001);
        float uu = clamp(f.y / max(f.hw, 0.001), -1.0, 1.0);
        float rim = abs(uu);

        float pattern = I.params4.x;
        float scales = I.params4.y;
        bool lips = I.params4.z > 0.5;
        bool inkWash = I.params4.w > 0.5;
        bool clouds = pattern > 3.5 && pattern < 4.5;

        // Scales on a staggered lattice that bends with the body. Each scale is a disc whose front is tucked
        // under the scales ahead of it, so a point belongs to the frontmost disc over it and the lines left
        // showing are the scales' rounded back edges. `sEdge` is 0 on that edge. The head has none.
        float sCell = pixel ? max(L * 0.085, 4.5 * u.fx2.z) : L * 0.062;   // in Pixel, at least 4.5 texels
        const float sR = 0.8;
        float2 sc0 = float2(0.0);
        float d1 = 9.0;
        if (scales > 0.5 || pattern > 4.5) {
            float2 gp = float2(f.s * L, f.y) / sCell;
            float ry = floor(gp.y + 0.5);
            float front = 1e9;
            for (int j = -1; j <= 1; j++) {
                float row = ry + float(j);
                float off = 0.5 * fmod(abs(row), 2.0);
                float cx = floor(gp.x - off) + off;
                for (int i = 0; i <= 1; i++) {
                    float2 c = float2(cx + float(i), row);
                    float d = length((gp - c) * float2(1.0, 1.12));
                    if (d < sR && c.x < front) { front = c.x; d1 = d; sc0 = c; }
                }
            }
        }
        float sEdge = sR - d1;
        float2 sLocal = float2(f.s * L, f.y) / sCell - sc0;   // +x points to the tail
        float sId = hash21(sc0 + I.seed * 1.37);
        float outline = pixel ? step(sEdge, 0.2) : 1.0 - smoothstep(0.03, 0.13, sEdge);
        float trailing = outline * smoothstep(-0.15, 0.2, sLocal.x);   // the back edge of each scale
        float scaleZone = smoothstep(0.17, 0.23, f.s) * step(f.s, 0.8) * (1.0 - smoothstep(0.72, 0.98, rim));

        // Plate edges that follow the scales (kiwa): read the pattern at the scale's centre.
        float kiwa = (scales > 0.5 && scales < 1.5) ? 0.75 * scaleZone : 0.0;
        float sP = mix(f.s, sc0.x * sCell / L, kiwa);
        float yP = mix(f.y, sc0.y * sCell, kiwa);
        float lP = yP / max(W, 0.001);
        float uP = clamp(yP / max(f.hw, 0.001), -1.0, 1.0);

        float2 pq = float2(sP * 5.0, lP * 1.3);
        if (clouds) {
            float2 w = float2(vnoise(pq * 0.8 + I.seed), vnoise(pq * 0.8 + I.seed + 9.0));
            pq += (w - 0.5) * 2.4;
        }
        float n1 = fbm(pq + I.seed * 7.31);
        float n2 = clouds ? fbm(pq * 0.9 + I.seed * 3.17 + 40.0) + 0.2 * (1.0 - rim) - 0.08
                          : fbm(float2(sP * 11.0, lP * 2.6) + I.seed * 3.17 + 40.0);
        float hi = n1 - I.params2.x;   // above 0: red
        if (pattern < 0.5 || pattern > 4.5) {
            hi += 0.12 * exp(-pow((sP - 0.14) / 0.07, 2.0));          // a plate on the head
        } else if (pattern < 1.5) {
            // Inazuma: one band zigzagging down the back like lightning, from a red head.
            float zig = (abs(fract(sP / 0.21 + I.seed * 0.13) - 0.5) * 4.0 - 1.0) * 0.42;
            float band = 0.5 - abs(uP - zig) + (n1 - 0.5) * 0.35;
            float head = 0.62 - length(float2((sP - 0.13) / 0.11, uP / 1.15));
            hi = max(band, head);
        } else if (pattern < 2.5) {
            // Sandan: three plates with white between them, alternating a little from side to side.
            float d = 9.0;
            for (int k = 0; k < 3; k++) {
                float c = 0.13 + 0.205 * float(k);
                float side = k == 1 ? 0.14 : -0.1;
                d = min(d, length(float2((sP - c) / 0.078, (uP - side) / 0.92)));
            }
            hi = (1.0 - d) * 0.6 + (n1 - 0.5) * 0.45;
        } else if (pattern < 3.5) {
            // Maruten: a round crown on the head, then two plates.
            float crown = 1.0 - length(float2((f.s - 0.11) * L, f.y)) / (W * 0.6);
            float d = min(length(float2((sP - 0.35) / 0.085, (uP - 0.1) / 0.9)),
                          length(float2((sP - 0.55) / 0.075, (uP + 0.12) / 0.85)));
            hi = max(crown * 0.8, (1.0 - d) * 0.6 + (n1 - 0.5) * 0.45);
        }
        if (pattern > 4.5 && scaleZone > 0.5 && !(sId < 0.62 && d1 < 0.42)) { hi = min(hi, -0.01); }   // kanoko dapples
        if (!clouds && (f.s < 0.035 || sP > 0.66)) { hi = -1.0; }   // white nose, clean white before the tail
        if (lips && f.s < 0.045 && rim < 0.6) { hi = 1.0; }          // kuchibeni
        float su = n2 - I.params2.y;
        if (!clouds && baseC.b > 0.8 && f.s < 0.24) { su = -1.0; }   // no black on a Sanke's head
        if (pattern > 5.5) {
            // Bekko: round black spots scattered over the back, the head left clean.
            float bc = L * 0.12;
            float2 q = float2(f.s * L, f.y) / bc;
            float2 qi = floor(q);
            float2 h2 = hash22(qi + I.seed);
            float2 c = qi + 0.5 + (h2 - 0.5) * 0.3;
            float r = 0.2 + 0.14 * fract(h2.x * 7.3);
            su = (h2.y > 0.4 && f.s > 0.2 && f.s < 0.7 && rim < 0.8) ? r - length(q - c) : -1.0;
        }

        float hiA = step(0.0, hi);
        float suA = step(0.0, su);
        if (inkWash) {
            // Sumi-e: graded edges with a dry-brush grain across the back.
            float grain = (vnoise(float2(f.s * 38.0, lateral * 5.0) + I.seed) - 0.5) * 0.06;
            hiA = smoothstep(-0.07, 0.06, hi + grain);
            suA = smoothstep(-0.09, 0.06, su + grain);
            if (pixel) { hiA = floor(hiA * 3.0 + 0.5) / 3.0; suA = floor(suA * 3.0 + 0.5) / 3.0; }
        }
        float3 col = mix(mix(baseC, patchC, hiA), accentC, suA);

        bool asagi = special > 2.5 && special < 3.5;
        if (special > 0.5 && special < 1.5) {
            if (length(float2((f.s - 0.11) * L, f.y)) < W * 0.62) { col = patchC; }   // tancho crown
        } else if (asagi) {
            if (rim > 0.62) { col = patchC; }                                       // red flanks
            if (f.s > 0.05 && f.s < 0.2 && rim > 0.45) { col = patchC; }          // red cheeks
            if (f.s < 0.2 && rim < 0.55) { col = mix(col, float3(0.84, 0.9, 0.94), 0.55); }   // pale head
        } else if (special > 3.5) {
            if (rim < 0.38 && f.s > 0.08) { col = accentC; }                       // minnow back stripe
        }

        // Scales, in staggered rows along the body: Asagi's net and the metallic glints both use them.
        float cell = L * 0.09;
        float2 g = float2(f.s * L, f.y) / cell;
        g.x += 0.5 * fmod(abs(floor(g.y)), 2.0);
        float2 id = floor(g);
        float2 inCell = fract(g) - 0.5;
        if (asagi) {
            // Reticulation: each scale darker in the middle, its edge paler, so the edges draw a light net.
            float diamond = abs(inCell.x) + abs(inCell.y);
            float net = smoothstep(0.17, 0.24, f.s) * (1.0 - smoothstep(0.6, 0.95, rim)) * step(f.s, 0.8);
            float middle = pixel ? step(diamond, 0.34) : 1.0 - smoothstep(0.28, 0.4, diamond);
            float3 dark = col * float3(0.44, 0.49, 0.6);
            float3 pale = mix(col, float3(0.92, 0.95, 0.97), 0.22);
            col = mix(col, mix(pale, dark, middle), net * 0.9);
        }

        // Scale finishes. `inside` is 0 on the line between two scales and 1 well inside one; `back` grows
        // toward each scale's back edge (the front is tucked under the scale ahead).
        float inside = pixel ? step(0.2, sEdge) : smoothstep(0.03, 0.2, sEdge);
        float back = smoothstep(-0.3, 0.35, sLocal.x);
        float warmth = saturate((col.r - col.b) * 1.6);   // warm scales shade warm, cool ones blue
        float mirror = 0.0;
        float mirrorRim = 0.0;
        if (scales > 0.5 && scales < 1.5) {
            // Fukurin: every scale lit along its back edge.
            col = mix(col, lightRamp(col, 1.25), trailing * scaleZone * 0.75);
            col = mix(col, lightRamp(col, 0.86), (1.0 - back) * inside * scaleZone * 0.45);
        } else if (scales > 1.5 && scales < 2.5) {
            // Gin-rin, before its glitter: pearly back halves and fine lines between the scales.
            col = mix(col, lightRamp(col, 1.2), back * inside * scaleZone * 0.4);
            col = mix(col, lightRamp(col, 0.84), (1.0 - inside) * scaleZone * 0.5);
        } else if (scales > 2.5 && scales < 3.5) {
            // Doitsu: smooth skin and one row of big mirror scales each side of the spine, overlapping like tiles.
            float mc = L * 0.085;
            float2 m = float2(fract(f.s * L / mc) - 0.5, (abs(f.y) - f.hw * 0.36) / (mc * 0.8));
            float md = length(m);
            float inRow = step(0.2, f.s) * step(f.s, 0.7);
            mirror = (pixel ? step(md, 0.55) : 1.0 - smoothstep(0.5, 0.58, md)) * inRow;
            mirrorRim = mirror * (pixel ? step(0.4, md) : smoothstep(0.38, 0.5, md)) * step(-0.15, m.x);
            col = mix(col, lightRamp(col, 0.72), mirrorRim * 0.85);
            col = mix(col, lightRamp(col, 1.08), mirror * (1.0 - mirrorRim) * 0.3);
        } else if (scales > 3.5 && scales < 4.5) {
            // Koromo: indigo on the back edge of the red scales, the red head left clean.
            float onRed = hiA * scaleZone * step(0.24, f.s);
            col = mix(col, float3(0.2, 0.2, 0.42), trailing * onRed * 0.85);
            col = mix(col, col * float3(0.82, 0.8, 0.95), (1.0 - back) * inside * onRed * 0.4);
        } else if (scales > 4.5 && scales < 5.5) {
            // Matsuba: every scale dark in the middle, its edge left in the body colour, like a pine cone.
            float core = pixel ? step(0.3, sEdge) : smoothstep(0.06, 0.42, sEdge);
            float3 dark = mix(col * float3(0.2, 0.2, 0.22), lightRamp(col, 0.3), 0.3);
            col = mix(col, dark, core * (0.65 + 0.35 * (1.0 - back)) * scaleZone * 0.9);
        } else if (scales > 5.5) {
            // Net: pale lines between the scales, each scale deeper toward its tucked-in front, fainter under red.
            float3 dark = mix(col * float3(0.55, 0.6, 0.72), lightRamp(col, 0.66), warmth);
            float3 pale = mix(mix(col, float3(0.94, 0.96, 0.98), 0.3), lightRamp(col, 1.25), warmth);
            float3 netC = mix(pale, mix(col, dark, 0.35 + 0.65 * (1.0 - back)), inside);
            col = mix(col, netC, scaleZone * (1.0 - 0.6 * hiA) * 0.9);
        }

        // Light from the upper left (the shadows fall down and right), on a rounded back.
        float sr = sin(I.rotation);
        float cr = cos(I.rotation);
        float2 lw = float2(-0.6, 0.8);
        float2 ll = float2(dot(lw, float2(cr, sr)), dot(lw, float2(-sr, cr)));
        float3 Ld = float3(ll * 0.6, 0.8);
        float nose = smoothstep(0.12, 0.0, f.s) * 0.7;
        float3 n = normalize(float3(nose, uu, sqrt(max(0.0, 1.0 - uu * uu))));
        float diffuse = max(dot(n, Ld), 0.0);
        float light = (0.6 + 0.5 * diffuse) * (1.0 - 0.1 * pow(rim, 4.0));
        if (metallic > 0.0) {
            // More contrast, and a broad sheen drifting down the body.
            float sheen = max(0.0, sin(f.s * 9.0 - t * 1.2 + I.seed)) * (1.0 - rim);
            light = mix(light, (light - 0.8) * 1.3 + 0.8 + 0.14 * sheen, metallic);
        }
        if (pixel) { light = floor(light * 5.0 + 0.5) / 5.0; }
        col = lightRamp(col, light);

        if (metallic > 0.0) {
            // The highlight along the lit side of the back, then a few scales glinting in turn.
            float3 H = normalize(Ld + float3(0.0, 0.0, 1.0));
            float spec = pow(max(dot(n, H), 0.0), 18.0) * smoothstep(0.03, 0.12, f.s) * (1.0 - smoothstep(0.55, 0.75, f.s));
            if (pixel) { spec = step(0.62, spec) * 0.75; } else { spec *= 0.8 + 0.2 * sin(f.s * 12.0 - t * 1.4 + I.seed); }
            col = mix(col, float3(1.0, 0.99, 0.93), spec * 0.8 * metallic);

            float h = hash21(id + I.seed * 1.37);
            float twinkle = pow(saturate(sin(t * (1.1 + h * 1.3) + h * 50.0)), 12.0);
            float glint = step(0.74, h) * step(length(inCell), 0.2) * twinkle * smoothstep(0.15, 0.25, f.s) * step(f.s, 0.78);
            if (pixel) { glint = step(0.4, glint); }
            col = mix(col, float3(1.0), glint * metallic * (0.45 + 0.55 * diffuse));
        }

        if (scales > 1.5 && scales < 2.5) {
            // Gin-rin: a bright diamond on most scales, flashing in a wave down the back as the fish swims.
            float diamond = abs(sLocal.x - 0.12) + abs(sLocal.y) * 1.3;
            float spot = pixel ? step(diamond, 0.26) : 1.0 - smoothstep(0.16, 0.26, diamond);
            float wave = pow(saturate(sin(t * 1.8 - sc0.x * 0.55 + sc0.y * 1.7 + sId * 6.0 + I.phase)), 3.0);
            float lit = step(0.35, sId) * (0.35 + 0.65 * wave);
            float3 sparkle = mix(float3(1.0), float3(1.0, 0.88, 0.64), max(hiA, warmth));
            col = mix(col, sparkle, spot * lit * scaleZone * step(rim, 0.85) * (0.6 + 0.4 * diffuse));
        }
        if (mirror > 0.0) {
            // Each mirror scale catches the light on its own.
            float h = hash21(float2(floor(f.s / 0.085), f.y > 0.0 ? 1.0 : 0.0) + I.seed);
            float shine = 0.3 + 0.7 * pow(saturate(sin(t * (0.7 + h) + h * 40.0)), 4.0);
            if (pixel) { shine = floor(shine * 3.0 + 0.5) / 3.0; }
            col = mix(col, float3(1.0, 0.99, 0.95), mirror * (1.0 - mirrorRim) * shine * 0.4 * (0.5 + 0.5 * diffuse));
        }

        if (pixel && f.body > -aa * 1.3) { col = lightRamp(col, 0.64); }   // outline: the colour inside, darker

        float eyeS = 0.075;
        float2 eye = float2((f.s - eyeS) * L, abs(f.y) - fishHalfWidth(eyeS, W) * 0.62);
        if (length(eye) < max(W * 0.12, aa * 1.2)) { col = redEyes ? float3(0.72, 0.12, 0.1) : float3(0.06, 0.06, 0.08); }

        // Fins: the body's colour at the root thinning out to a pale clear edge, with rays fanning out.
        bool pectoral = mFin >= mTail;
        float along = pectoral ? f.finU : f.tailU;
        float rays = pectoral ? 0.5 + 0.5 * cos(f.finV * 9.0) : 0.5 + 0.5 * cos(f.tailV * 21.0);
        float3 rootC = dot(baseC, float3(0.333)) < 0.25 ? float3(0.95, 0.94, 0.9) : baseC;   // black koi have white fins
        float3 finC = mix(rootC, mix(rootC, float3(1.0, 0.98, 0.9), 0.38), smoothstep(0.25, 1.0, along));
        if (pectoral) {
            if (fins > 0.5 && fins < 1.5 && f.finU < 0.42) { finC = float3(0.08, 0.08, 0.1); }      // black roots
            if (fins > 1.5 && fins < 2.5 && abs(f.finV - 0.15) < 0.2 && f.finU > 0.2) {
                finC = float3(0.1, 0.1, 0.12);                                                        // black stripes
            }
            if (fins > 2.5 && f.finU < 0.4) { finC = patchC; }                                        // red roots
        }
        finC *= 0.88 + 0.12 * rays;
        float finEdge = (pectoral ? f.fin : f.tail) > -max(aa * 1.4, L * 0.01) ? 1.0 : 0.0;
        finC = mix(finC, float3(1.0, 0.99, 0.95), finEdge * 0.35);
        finC = lightRamp(finC, 0.96 + 0.08 * diffuse);
        float finA = max(mTail, mFin) * (mix(0.92, 0.6, smoothstep(0.3, 1.0, along)) + finEdge * 0.15);
        if (pixel) { finA = floor(finA * 4.0 + 0.5) / 4.0; }

        float3 outC = underwater(mix(finC, col, mBody), I.params2.w, u);
        outC = keepColour(outC, u.fx2.w, u);
        float outA = mix(finA, 1.0, mBody);
        return float4(posterize(outC, pixel), outA * I.color0.a);
    }

    float4 shadeFishShadow(Instance I, float2 p, bool pixel, float aa) {
        float L = I.params.x;
        FishShape f = fishShape(p, L, L * I.params.y, I.params.z, I.params.w, I.phase, I.color1.w, I.color2.w);
        float d = min(f.body, min(f.tail, f.fin));
        float blur = aa + 2.0 + L * 0.03;
        float m = pixel ? step(d, 0.0) : 1.0 - smoothstep(-blur, blur, d);
        return shadowColor(m, I.color0.a);
    }

    // Top-down turtle with +x as the head; flippers stroke alternately on each side.
    float4 shadeTurtle(Instance I, float2 p, constant Uniforms& u, bool pixel, float aa, bool shadow) {
        float L = I.params.x;
        float ph = I.phase;
        float side = p.y >= 0.0 ? 0.0 : 3.14159;
        float2 q = float2(p.x, abs(p.y));

        float2 sp = p / float2(L * 0.3, L * 0.25);
        float shell = (length(sp) - 1.0) * L * 0.25;
        float head = length(p - float2(L * (0.36 + 0.015 * sin(ph * 0.5)), 0.0)) - L * 0.085;

        float fa = 0.75 + 0.45 * sin(ph + side);
        float2 fd = float2(cos(fa), sin(fa));
        float2 fq = q - float2(L * 0.15, L * 0.18);
        float front = (length(float2((dot(fq, fd) - L * 0.11) / (L * 0.12), dot(fq, float2(-fd.y, fd.x)) / (L * 0.045))) - 1.0) * L * 0.045;
        float ba = 2.35 + 0.3 * sin(ph + side + 1.6);
        float2 bd = float2(cos(ba), sin(ba));
        float2 bq = q - float2(-L * 0.17, L * 0.15);
        float back = (length(float2((dot(bq, bd) - L * 0.07) / (L * 0.075), dot(bq, float2(-bd.y, bd.x)) / (L * 0.035))) - 1.0) * L * 0.035;
        float tail = (length((p - float2(-L * 0.32, 0.0)) / float2(L * 0.06, L * 0.025)) - 1.0) * L * 0.025;
        float skin = min(min(head, front), min(back, tail));

        if (shadow) {
            float d = min(shell, skin);
            float blur = aa + 3.0;
            float m = pixel ? step(d, 0.0) : 1.0 - smoothstep(-blur, blur, d);
            return shadowColor(m, I.color0.a);
        }

        float mShell = edgeMask(shell, aa, pixel);
        float mSkin = edgeMask(skin, aa, pixel);
        if (mShell + mSkin <= 0.0) { return float4(0.0); }

        float3 skinC = I.color1.rgb;
        float stripe = step(0.7, fract((p.x + p.y * 0.6) / (L * 0.05)));
        skinC = mix(skinC, I.color2.rgb, stripe * 0.5);
        if (length(float2(p.x - L * 0.39, abs(p.y) - L * 0.04)) < max(L * 0.018, aa)) { skinC = float3(0.05); }
        if (pixel && skin > -aa * 1.3) { skinC *= 0.75; }

        float rn = length(sp);
        float3 shellC = I.color0.rgb * (1.05 - 0.3 * rn * rn);
        shellC = mix(shellC * 0.6, shellC, smoothstep(0.02, 0.1, cellEdges(p / (L * 0.11) + I.seed, 0.0)));
        if (rn > 0.84) { shellC = mix(I.color0.rgb, I.color2.rgb, 0.25) * 0.85; }
        if (pixel && shell > -aa * 1.3) { shellC *= 0.7; }

        float3 c = underwater(mix(skinC, shellC, mShell), I.params2.w, u);
        return float4(posterize(c, pixel), max(mShell, mSkin) * I.color0.a);
    }

    float4 shadePad(Instance I, float2 p, bool pixel, float aa, bool shadow) {
        float R = I.params.x;
        float r = length(p);
        if (shadow) {
            float blur = aa + 3.0;
            float m = pixel ? step(r - R, 0.0) : 1.0 - smoothstep(-blur, blur, r - R);
            return shadowColor(m, I.color0.a);
        }
        float ang = atan2(p.y, p.x);
        float wedge = (abs(ang) - I.params.y) * r;
        float d = max(r - R, -wedge);
        float m = edgeMask(d, aa, pixel);
        if (m <= 0.0) { return float4(0.0); }

        float3 c = mix(I.color0.rgb, float3(0.62, 0.6, 0.25), I.params.z);
        float rn = r / R;
        float veins = abs(fract(ang * 11.0 / TAU + 0.5) - 0.5);
        c *= 1.0 - 0.14 * (1.0 - smoothstep(0.03, 0.08, veins)) * smoothstep(0.12, 0.3, rn);
        c *= 1.0 + 0.1 * dot(p / max(R, 0.001), float2(-0.7, 0.7));
        if (rn > 0.86) { c *= 0.82; }
        if (pixel && d > -aa * 1.3) { c *= 0.75; }
        c *= 0.95 + 0.1 * vnoise(p / 7.0 + I.seed);
        return float4(posterize(c, pixel), m * I.color0.a);
    }

    float4 shadeFlower(Instance I, float2 p, bool pixel, float aa) {
        float R = I.params.x;
        float n = I.params.y;
        bool lily = I.params.z > 0.5;
        float r = length(p);
        float ang = atan2(p.y, p.x);
        float k = lily ? 2.2 : 0.55;
        float lobe = pow(abs(cos(ang * n * 0.5)), k);
        float rOut = R * (0.5 + 0.5 * lobe);
        float mOut = edgeMask(r - rOut, aa, pixel);
        if (mOut <= 0.0) { return float4(0.0); }
        float lobe2 = pow(abs(cos((ang + 3.14159 / n) * n * 0.5)), k);
        float rIn = R * (0.32 + 0.33 * lobe2);

        float3 outer = I.color0.rgb * (0.82 + 0.18 * lobe);
        float3 tip = lily ? outer * 0.9 : I.color0.rgb * float3(0.92, 0.6, 0.72);
        outer = mix(outer, tip, smoothstep(0.6, 1.0, r / max(rOut, 0.001)));
        float3 inner = I.color1.rgb * (0.85 + 0.15 * lobe2);
        float3 center = I.color2.rgb * (1.0 - 0.25 * step(0.75, vnoise(p / max(R * 0.07, 0.5) + I.seed)));

        float3 c = mix(outer, inner, edgeMask(r - rIn, aa, pixel));
        c = mix(c, center, edgeMask(r - R * 0.2, aa, pixel));
        if (pixel && (r - rOut) > -aa * 1.3) { c *= 0.8; }
        return float4(posterize(c, pixel), mOut * I.color0.a);
    }

    float4 shadeFood(Instance I, float2 p, constant Uniforms& u, bool pixel, float aa) {
        float R = I.params.x;
        float m = edgeMask(length(p) - R, max(aa * 0.6, 0.3), pixel);
        if (m <= 0.0) { return float4(0.0); }
        float3 c = I.color0.rgb * (1.0 + 0.3 * dot(p / max(R, 0.001), float2(-0.6, 0.6)));
        c = underwater(c, I.params2.w, u);
        return float4(posterize(c, pixel), m * I.color0.a);
    }

    float4 shadePlant(Instance I, float2 p, constant Uniforms& u, bool pixel, float aa) {
        float S = I.params.x;
        float d = 1000.0;
        float tipT = 0.0;
        for (int i = 0; i < 5; i++) {
            float a = I.seed * 1.7 + float(i) * 1.2566 + 0.15 * sin(u.world.z * 0.6 + I.seed + float(i));
            float2 dir = float2(cos(a), sin(a));
            float2 q = float2(dot(p, dir), dot(p, float2(-dir.y, dir.x)));
            float len = S * (0.42 + 0.12 * fract(I.seed * 3.1 + float(i) * 0.37));
            float e = (length(float2((q.x - len * 0.55) / (len * 0.55), q.y / (S * 0.13))) - 1.0) * S * 0.13;
            if (e < d) { d = e; tipT = clamp(q.x / len, 0.0, 1.0); }
        }
        float m = edgeMask(d, aa, pixel);
        if (m <= 0.0) { return float4(0.0); }
        float3 c = mix(I.color0.rgb, I.color1.rgb, tipT);
        if (pixel && d > -aa * 1.3) { c *= 0.75; }
        c = underwater(c, I.params2.w, u);
        return float4(posterize(c, pixel), m * I.color0.a);
    }

    // A splash's rings by linear deep-water wave theory (the Cauchy-Poisson problem, by stationary phase).
    // At radius r and time t the waves present are those whose group speed ½√(g/k) brings them there,
    // k = g t² / (4 r²), with crests at phase g t² / (4 r). Their size follows the splash's spectrum around
    // its main wavenumber and falls as k^(9/4) / √(r t) as the energy spreads around the ring and across the
    // widening group. The surface's slope is lit from the top left, like the pads' shadows: crests catch
    // the light on one side and darken on the other.
    float4 shadeRipple(Instance I, float2 p, constant Uniforms& u, bool pixel) {
        float t = max(I.phase, 0.02);
        float k0 = I.params.x;
        float bandwidth = I.params.y;
        float amplitude = I.params.z;
        float g = I.params.w;
        float l = max(length(p), 0.001);
        float2 outward = p / l;
        float angle = atan2(p.y, p.x);
        float s = I.seed * TAU;

        // Real rings are never quite round: the surface they cross is uneven, so they wander a little,
        // more as they grow, and lean along a direction of their own.
        float wobble = I.params2.w * (0.6 * sin(angle + s) + 0.3 * sin(2.0 * angle + s * 2.3) + 0.2 * sin(3.0 * angle + s * 4.1));
        float wander = (vnoise(p / 34.0 + I.seed * 37.0) - 0.5) * 2.0 * (1.5 + 0.05 * l);
        float r = max(l * (1.0 + wobble) + wander, 1.0);

        float k = g * t * t / (4.0 * r * r);
        float x = (k - k0) / (bandwidth * k0);
        float t0 = 0.6;
        float r0 = 0.5 * t0 * sqrt(g / k0);
        float spread = min(pow(k / k0, 2.25) * sqrt(r0 * t0 / (r * t)), 1.6);
        // Crests ride along with their ring, as they do for pond ripples of a couple of centimetres, where
        // capillary and gravity forces balance and phase and group speed meet. (Pure gravity waves' crests
        // run through the group at twice its speed, which flickered light and dark several times a second.)
        float crest = g * t * t / (4.0 * r) - 0.5 * sqrt(g * k0) * t + I.params2.x;
        // Uneven along each ring: stronger here, faded or broken there.
        float evenness = mix(0.45, 1.25, vnoise(float2(angle * 1.7 + I.seed * 13.0, r / 55.0)));
        float slope = amplitude * exp(-x * x) * spread * sin(crest) * evenness;

        // The splash itself: a dip that fills back in over a fraction of a second.
        float strength = I.params2.y;
        float sigma = 3.0 + 5.0 * strength;
        float splash = strength * exp(-t / 0.25) * (2.0 * r / (sigma * sigma)) * exp(-r * r / (sigma * sigma));
        slope += splash * sigma * 0.9;

        // Lit from the top left, like the pads' shadows. Colors come from the water itself (the weather
        // tint is applied to the whole scene afterwards): slopes facing the light take a paler, sky-lit
        // tone of the water, slopes facing away a slightly deeper one, blended smoothly in between.
        float lit = -slope * dot(outward, normalize(float2(-0.55, 0.83)));
        float3 water = u.water.rgb;
        float3 skyLit = mix(water * 1.5 + 0.12, float3(0.84, 0.92, 0.94), 0.35);
        float3 deeper = water * 0.62;
        float3 c = mix(deeper, skyLit, smoothstep(-0.7, 0.7, lit));
        float a = smoothstep(0.0, 0.7, abs(lit)) * 0.75 + abs(slope) * 0.1;
        a *= lit < 0.0 ? 0.6 : 1.0;
        if (pixel) { a = a < 0.025 ? 0.0 : floor(a * 12.0 + 0.5) / 12.0; }
        return float4(c, min(a, 0.7));
    }

    fragment float4 instance_fragment(InstOut in [[stage_in]],
                                      const device Instance* inst [[buffer(0)]],
                                      constant Uniforms& u [[buffer(1)]]) {
        Instance I = inst[in.iid];
        bool pixel = u.world.w > 0.5;
        float aa = u.fx2.z * 0.75;
        float4 c = float4(0.0);
        switch (int(I.kind + 0.5)) {
            case 0: c = shadeFish(I, in.local, u, pixel, aa); break;
            case 1: c = shadeFishShadow(I, in.local, pixel, aa); break;
            case 2: c = shadeTurtle(I, in.local, u, pixel, aa, false); break;
            case 3: c = shadeTurtle(I, in.local, u, pixel, aa, true); break;
            case 4: c = shadePad(I, in.local, pixel, aa, false); break;
            case 5: c = shadePad(I, in.local, pixel, aa, true); break;
            case 6: c = shadeFlower(I, in.local, pixel, aa); break;
            case 7: c = shadeFood(I, in.local, u, pixel, aa); break;
            case 8: c = shadePlant(I, in.local, u, pixel, aa); break;
            case 9: c = shadeRipple(I, in.local, u, pixel); break;
            default: break;
        }
        if (c.a <= 0.003) { discard_fragment(); }
        return c;
    }
    """
}
