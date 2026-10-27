#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Anish Thite
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${PAPER_COMPOSITOR_BUILD_DIR:-/tmp/PaperCompositor}"
app="$output/PaperCompositor.app"
texture="${PAPER_TEXTURE:-$HOME/Documents/ScreenSlanger/Shaders/eink_slang/shaders/eink_slang/png/4k/textured_paper.png}"
for option in "$@"; do
    case "$option" in
        --build-only|--self-check)
            if [[ $# -ne 1 ]]; then printf '%s must be used alone.\n' "$option" >&2; exit 2; fi ;;
        --controls|--enable|--chart|--color-only|--paper-only|--advanced) ;;
        *) printf 'Unknown option: %s\n' "$option" >&2; exit 2 ;;
    esac
done
if [[ -f "$app/Contents/MacOS/PaperCompositor" ]] && /usr/sbin/lsof -t "$app/Contents/MacOS/PaperCompositor" >/dev/null 2>&1; then
    printf 'Quit this build of PaperCompositor before overwriting it.\n' >&2
    exit 1
fi
if [[ ! -f "$texture" ]]; then
    printf 'Paper PNG missing: %s\nSet PAPER_TEXTURE to your existing e-ink paper PNG.\n' "$texture" >&2
    exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
    -mmacosx-version-min=15.0 -framework AppKit -framework QuartzCore -framework Carbon \
    "$root/src/main.m" -o "$app/Contents/MacOS/PaperCompositor"
cp "$texture" "$app/Contents/Resources/paper.png"
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/LICENSES"
cp "$root"/LICENSES/*.txt "$app/Contents/Resources/LICENSES/"
/usr/libexec/PlistBuddy -c Clear "$app/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
    -c 'Add :CFBundleIdentifier string local.screenslanger.paper-compositor' \
    -c 'Add :CFBundleExecutable string PaperCompositor' \
    -c 'Add :CFBundleName string PaperCompositor' \
    -c 'Add :CFBundlePackageType string APPL' \
    -c 'Add :LSMinimumSystemVersion string 15.0' \
    -c 'Add :LSUIElement bool true' \
    -c 'Add :NSHighResolutionCapable bool true' \
    -c 'Add :CFBundleShortVersionString string 0.3.0' \
    "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
printf 'Built %s\n' "$app"
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
if [[ "${1:-}" == "--self-check" ]]; then
    exec "$app/Contents/MacOS/PaperCompositor" --self-check
fi
open "$app" --args "$@"
