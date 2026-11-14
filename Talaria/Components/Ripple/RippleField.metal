#include <metal_stdlib>
using namespace metal;

// The app's background: a sky of scattered particles drifting like water, with broad soft
// waves rolling through and patches that shimmer, like stars moving through the Milky Way.
// Waves and drift follow `heading`, which leans with the phone's tilt and the person's swipes
// (RippleMotion.swift). Each particle's resting place comes from its index (a jittered grid)
// and its motion from the clock, so nothing is uploaded but a few numbers per frame. The waves
// are laid out in window space, so separate views (iPad columns, a pushed screen) line up.

// Must match RippleUniforms in RippleField.swift.
struct Uniforms {
  float4 color;
  float4 crestColor;
  float4 sparkleColor;  // what a shimmering particle turns toward
  float2 viewSize;  // points
  float2 offset;    // the view's top left in the window, points
  float2 canvas;    // the window's size, points
  float2 heading;   // the way the waves travel, unit vector, y down
  float2 flow;      // how far the water has carried the particles, points
  float2 extent;    // the grid's size, points (particles wrap around inside it)
  float travel;     // how far the waves have travelled, points
  float energy;     // 0 at rest, toward 1 on a wash or a swipe
  float time;
  float scale;      // pixels per point
  float spacing;    // points between neighbouring particles
  float columns;
  float dotSize;    // points
  float intro;      // 0 to 1 while the field fades in at launch
};

struct VertexOut {
  float4 position [[position]];
  float pointSize [[point_size]];
  float4 color;
};

static float hash(float n) { return fract(sin(n) * 43758.5453); }

static float hash2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

// Smooth value noise, 0 to 1.
static float noise(float2 p) {
  float2 i = floor(p);
  float2 f = fract(p);
  float2 s = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash2(i), hash2(i + float2(1, 0)), s.x),
             mix(hash2(i + float2(0, 1)), hash2(i + float2(1, 1)), s.x), s.y);
}

vertex VertexOut ripple_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
  float index = float(vid);
  float column = fmod(index, u.columns);
  float row = floor(index / u.columns);
  float2 grid = (float2(column, row) + 0.5
                 + (float2(hash(index * 12.9898 + 1.0), hash(index * 78.233 + 2.0)) - 0.5) * 0.9)
              * u.spacing;
  float t = u.time;

  // Depth: near particles are bigger and brighter and the water carries them faster, far ones
  // lag behind, which gives the sky its depth.
  float depth = hash(index * 3.17 + 7.0);
  float2 home = grid + u.flow * (0.35 + 0.9 * depth);
  home = fmod(fmod(home, u.extent) + u.extent, u.extent);

  float2 canvas = u.canvas;
  float2 world = home + u.offset;

  // Fronts are arcs of a wide circle behind the window, so they curve gently and turn about the
  // window's centre as the heading changes.
  float2 heading = u.heading;
  float2 side = float2(-heading.y, heading.x);
  float2 centre = canvas * 0.5;
  float span = length(canvas);
  float radius = 1.4 * span;
  float2 fromSource = world - (centre - heading * radius);
  float dist = length(fromSource) - radius;
  float2 radial = fromSource / max(length(fromSource), 1e-3);
  float across = dot(world - centre, side);
  // The fronts wobble so they never look machine drawn.
  float warp = 22.0 * sin(across / 130.0 + 0.15 * t) + 10.0 * sin(across / 70.0 - 0.1 * t + 1.7);
  float wave = sin(6.2832 * (dist + warp - u.travel) / 430.0);
  // Swells come in sets: stronger and weaker stretches drift along with the waves.
  float sets = 0.55 + 0.45 * (0.5 + 0.5 * sin(6.2832 * (dist - 0.59 * u.travel) / 1500.0
                                               + 1.1 * sin(across / 300.0 + 0.05 * t)));
  sets *= 1.0 + 0.5 * u.energy;
  // Broad, soft crests: a wide band of brighter particles fading out on both sides.
  float crest = saturate(pow(0.5 + 0.5 * wave, 2.5) * sets);

  // Shimmer: patches of sky that drift along and come and go; inside one, particles twinkle,
  // each at its own pace.
  float2 patchAt = world / 110.0 + float2(0.07 * t, -0.05 * t);
  float patches = noise(patchAt) * 0.65 + noise(patchAt * 2.3 + 17.0) * 0.35;
  float group = smoothstep(0.58, 0.78, patches);
  float twinkle = pow(0.5 + 0.5 * sin(t * (0.8 + 1.4 * hash(index + 11.0)) + 6.2832 * hash(index + 13.0)), 4.0);
  float shimmer = group * twinkle;

  // Particles ride the waves a little, bunching up on each crest, and sway on their own.
  float2 drift = float2(sin(t * (0.25 + hash(index) * 0.4) + index),
                        cos(t * (0.2 + hash(index + 2.0) * 0.4) + index * 1.3)) * 1.5;
  float2 pos = home - radial * (wave * sets * 7.0 * (1.0 + 0.5 * u.energy)) + drift;

  // Everywhere, a little stronger on the side the waves come from.
  float upstream = -dot(pos + u.offset - centre, heading) / span;
  float reach = 0.55 + 0.45 * smoothstep(-0.45, 0.45, upstream);
  float alpha = (0.17 + 0.9 * crest) * (0.55 + 0.6 * depth) + 1.1 * shimmer;
  alpha = saturate(alpha) * reach * u.intro;

  // Most particles in the palette's color, a few paler; shimmering ones flare toward the
  // sparkle color (near white on dark screens, deep indigo on light ones).
  float tint = hash(index + 21.0);
  float4 color = mix(u.color, u.crestColor, crest * 0.35 + (tint > 0.85 ? 0.4 : 0.0));
  color = mix(color, u.sparkleColor, shimmer * 0.6);
  float size = u.dotSize * (0.6 + 0.8 * depth) * (1.0 + 0.4 * crest + 0.7 * shimmer);

  float2 ndc = pos / u.viewSize * 2.0 - 1.0;
  VertexOut out;
  out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
  out.pointSize = max(size * u.scale, 1.0);
  out.color = float4(color.rgb * alpha, alpha);  // premultiplied
  return out;
}

fragment float4 ripple_fragment(VertexOut in [[stage_in]], float2 pc [[point_coord]]) {
  float d = length(pc - 0.5) * 2.0;
  if (d > 1.0) discard_fragment();
  // A bright core with a soft halo, like a star.
  float glow = 1.0 - smoothstep(0.0, 1.0, d);
  return in.color * (glow * glow * 0.7 + (1.0 - smoothstep(0.25, 0.55, d)) * 0.5);
}
