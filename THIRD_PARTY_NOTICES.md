# Third-party notices and source lineage

PaperCompositor's new contributions are copyright © 2026 Anish Thite and distributed under GPL-2.0-or-later; see [LICENSE](LICENSE). Upstream authors retain their copyrights. This notice documents shader lineage and implementation references; it does not grant rights to third-party artwork or imply endorsement.

## Original shader

Reference: crutchcorn/eink_slang, revision `16e29791f9a72b14723a8596af6d9edd00a9bf6f`:

- [Repository and credits](https://github.com/crutchcorn/eink_slang/tree/16e29791f9a72b14723a8596af6d9edd00a9bf6f)
- [Shader source and license declaration](https://github.com/crutchcorn/eink_slang/blob/16e29791f9a72b14723a8596af6d9edd00a9bf6f/shaders/eink_slang/eink_slang.slang)

The shader header attributes other code to **jdgleaver**, GBA color correction to **hunterk**, modified by **Pokefan531** and released into the public domain, and upstream LCD line weighting to **Greg Hogan (SoltanGris42), copyright (C) 2017**. The LCD-grid/line-weighting effect is not implemented by PaperCompositor. The e-ink adaptation and preset are provided by **crutchcorn**.

The source header states:

> This program is free software; you can redistribute it and/or modify it
> under the terms of the GNU General Public License as published by the Free
> Software Foundation; either version 2 of the License, or (at your option)
> any later version.

The shader repository has no top-level license file at the reviewed revision; its file-level GPL-2.0-or-later declaration is the basis for this project's conservative code-license choice. The original GLSL file is not bundled; the compositor reconstructs its color/blend operations in native layers. This license choice does not establish licensing for the texture.

## Surface Dots reading-mode reference

[snes19xx/surface-dots reading_mode.glsl](https://github.com/snes19xx/surface-dots/blob/main/.config/hypr/shaders/reading_mode.glsl) is the reference for the Reading looks' BT.601 grayscale, gamma/S-curve/midtone response, cream/charcoal endpoints and ordered-texture concept. Credit **snes19xx** for that shader and look.

PaperCompositor independently reconstructs those mathematical color operations with native filters and a sampled lookup. Its static integer-hash grain/fibers and native blend/mask/vignette implementation differ from the original procedural GLSL; these are not a shader-exact port. No original GLSL source file or Surface Dots artwork is bundled. This repository's license does not assert a license grant for the upstream repository.

## MIT-licensed context and references

Full notices are preserved verbatim:

| Project | Copyright | Notice |
|---|---|---|
| [ScreenSlanger](https://github.com/crutchcorn/ScreenSlanger/tree/5dd25807a86b4aaa0f7c401a18bee370a38287c4) / its ScreenShader lineage | © 2025 Brandon Pickering | [ScreenSlanger-MIT.txt](LICENSES/ScreenSlanger-MIT.txt) |
| [Deckle](https://github.com/Kelvanic/deckle/tree/481dd8ccbf6266b83ff297edcf0c61b9ef20b6f9) | © 2026 Deckle contributors | [Deckle-MIT.txt](LICENSES/Deckle-MIT.txt) |
| [SideEye](https://github.com/ishmael07/SideEye/tree/e82605ded630ae5453cfaa0bd43f86c97efd9cdd) | © 2026 SideEye contributors | [SideEye-MIT.txt](LICENSES/SideEye-MIT.txt) |
| [core-animation-private](https://github.com/kageroumado/core-animation-private/tree/d9931066092669506e8be77bbc86d5d2fa78df03) | © 2026 kageroumado | [CoreAnimationPrivate-MIT.txt](LICENSES/CoreAnimationPrivate-MIT.txt) |

These are development/reference sources, not packaged third-party libraries. GPL licensing of the combined reconstruction does not remove their original MIT grants or notices. Apple frameworks/private APIs are supplied by macOS, not redistributed by this repository.

[PaperScreen](https://github.com/coreyloftus/paper-screen/tree/5439733ca66489c39304276c6466f34ce8ce3390) was also reviewed for overlay/texture behavior. It is credited as a research reference only; no PaperScreen texture or source file is included, and no license grant for that project is asserted here.

## Paper artwork is not included

The original texture's SHA-256 is `d1eb321bc3db5f693979628f42c5020642f2bf34abd711d89260f9468b48f0a4`.

The upstream README credits Subtle Patterns for source image patterns. The exact PNG's author and redistribution license have not been confirmed. Neither the repository license nor shader header should be treated as permission to redistribute it. Supply a local copy for builds, and verify the asset's terms before distributing the resulting app. The screenshot in this repository shows only the controls with the effect disabled, not the paper artwork.
