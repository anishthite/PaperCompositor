# Reading Mode error isolation — 2026-10-27

Version 0.5.0 presents the two Reading variants as independent **Soft Reading** and
**Surface Dots** looks with matching, separately saved breakdowns. The measurements
below come from their shared implementation in the development workspace.

**Main finding:** the large mismatch was the affine tone approximation, not the
BT.601 coefficients. Version 0.4.1 replaces that approximation with a native,
cached 1024-sample lookup when grayscale is 100%. No capture/render loop is added.
Version 0.4.2 also exposes the previous curve as **Soft / Original Tone**; the
historical error below measures fidelity to Surface Dots, not aesthetic quality.
Soft's rendered tone matches the old baseline captures pixel-for-pixel on both
scenes. Its own affine-contract error is at most 0.7494/255 (0.6558 at half strength).

Reference: the scalar grayscale, tone and palette expressions in
[surface-dots/reading_mode.glsl](https://github.com/snes19xx/surface-dots/blob/main/.config/hypr/shaders/reading_mode.glsl),
applied to **the same captured native desktop RGB bytes**, preserving their ICC
profile. This is an independent mathematical reference, not literal execution of
the entire original GLSL shader or a claim about Hyprland's framebuffer profile.

## Where the errors are

| Stage | Maximum absolute channel error, native RGB8 levels | Location / cause |
|---|---:|---|
| Bypass | 0 | No transformation |
| Grayscale | 0.666 | Native input/grayscale precision; coefficients are correct and output is neutral |
| Grayscale + palette, no tone | 0.6813 | Native matrix/quantization precision, not original-hue leakage |
| **Old affine tone** | **45.4161** | `RGColorFilters`: `clamp(1.18 × gray − 0.09)` did not implement gamma, S-curve or midtone boost |
| **New source-tone lookup** | **2.2820** | Grayscale/input precision amplified by the steep source curve, plus lookup/output precision |
| New tone using separately captured grayscale as its input oracle | 0.7977 | Lookup sampling/output residual once the preceding grayscale-stage difference is removed |
| Half-strength new tone | 1.8740 | Native blend between grayscale and source-tone lookup |
| New grayscale + tone + palette | 2.3080 | Combined scalar color stages, **without** texture or vignette |

These maxima combine two 512² scenes: four channel/gray ramps and a deterministic
RGB grid. Each stage measures 571,392 ramp channels and 738,048 grid channels after
excluding borders/band boundaries. Grayscale's maximum channel spread is at most
one encoded unit; there is no surviving input chroma at full grayscale.

### Concrete worst pixels

- **Old tone:** native input `(144,32,204)` gives gray `85.096/255`; source tone
  expects `32.583925/255`, but the affine path renders `78/255`—error **45.416075/255**.
- **New tone:** native input `(231,63,206)` expects `114.718010/255`, renders
  `117/255`—error **2.281990/255**.
- **New color chain:** native input `(68,143,169)` expects red `106.307980/255`,
  renders `104/255`—error **2.307980/255**.

On the RGB grid, tone mean error falls from **21.4230** to **0.4551/255**;
p99 falls from **45.1093** to **1.6633/255**. This is not a full-shader metric.

## The earlier color-space diagnosis was misleading

Nominal sRGB red `(255,0,0)` becomes native display RGB `(234,51,35)` on this Mac.
Applying BT.601 to that actual input gives:

```text
0.299 × 234 + 0.587 × 51 + 0.114 × 35 = 103.933
```

The observed gray `104` is correct for those bytes. Comparing it to nominal sRGB
red's gray `76.245` mixes different input spaces. Likewise, the native palette's
white `(240,235,219)` converts to approximately `(241,235,217)` in the sRGB
screenshot view; those are not evidence of swapped palette coefficients.

The audit now decodes raw and processed captures into their **own identical native
profile**, checks matching profiles/dimensions and validates each frame's unique
identity strip and corner markers. It does not infer a macOS color-conversion bug
from nominal image RGB values. Profile-preserving RGB8 captures cannot establish
the exact bit depth of WindowServer's internal intermediate surfaces.

## Implementation and remaining limits

`src/ReadingGraph.h` runs:

```text
BT.601 grayscale matrix → luminanceMap(source tone, amount) → palette matrix
```

The lookup stores the source expression:

```text
g = smoothstep(0.08, 0.92, gray^1.2)
tone = g + 0.1 × smoothstep(0.3, 0.5, g) × (1 − smoothstep(0.5, 0.7, g))
```

A rendered inverse-ramp positive control confirmed the native lookup executes on
the live backdrop. Advertised `lut` and guessed filter names were not accepted
as evidence; a tested `lut` configuration bypassed the chain and was discarded.
Float 256/1024/4096-sample maps did not remove the preceding grayscale precision
limit; the shipped 1024-sample RGB8 image is cached once and costs 4 KB of pixels.
The map's blend amount is tested at 0, 0.5 and 1.

The source shader is always grayscale. For deliberately partial/bypassed grayscale
in the stage explorer, retain the old affine colored-exploration path; applying a
luminance map there would silently discard colors again. This distinction is
explicit in the UI/help. No existing parameter values are reset.

**Not fixed or certified by this audit:**

| Stage | Remaining deliberate difference |
|---|---|
| Highlight mask | Linear clamped ramp instead of source smoothstep; scalar maximum mask-weight difference is about 0.0962 |
| Grain/fibers | Repeating static anisotropic tiles and multiply blending, not the source's full-coordinate additive hash noise |
| Bayer | Ordered pattern exists, but is part of the native multiply-texture path rather than source additive grayscale processing |
| Vignette | Native radial gradient after the palette, versus source distance/smoothstep darkening of gray before palette mapping |
| Spatial paper tint | Source adds position-dependent paper-color variation; omitted here |

Therefore **2.308/255 is not the maximum error of the complete Reading Mode**.
Texture, vignette, spatial tint, coordinate conventions and other displays/profiles
are not included in that scalar-color figure. Energy savings remain unmeasured.

## Reproduce

Disable global ScreenSlanger/PaperCompositor effects first. Screenshot access must
already be authorized; probes use bounded click-through windows and exit after
one screenshot. Keep the desktop unlocked/still during the sequence.

```sh
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -mmacosx-version-min=15.0 -Isrc -framework AppKit -framework QuartzCore -framework ImageIO \
  tests/TextureProbe.m -o /tmp/ReadingTextureProbe

swift tests/ReadingAudit.swift generate /tmp/reading-audit
for scene in ramps rgb; do
  for stage in raw bypass grey palette tone tone-half soft soft-half color; do
    /tmp/ReadingTextureProbe /tmp/reading-audit/$scene-$stage.json \
      /tmp/reading-audit/$scene-$stage.png || break 2
  done
done
swift tests/ReadingAudit.swift measure /tmp/reading-audit
```

The final command writes `reading-results.json` with sample counts, mean/p99/max,
worst pixel coordinates, expected/actual values and calibrated input RGB.
It rejects stale frame identities and excessive error. Optional historical
`ramps-before.png` / `rgb-before.png` captures from the old binary are reported
without applying the new curve's pass threshold.

This run's artifacts: `/tmp/reading-error-audit/native/reading-results.json`.
Native self-checks additionally cover source-tone anchors, monotonicity, cached
lookup construction, stage ordering and all 256 checkbox combinations at 1x/2x.
