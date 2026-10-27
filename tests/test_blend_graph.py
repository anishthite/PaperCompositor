# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Anish Thite
"""Check the compositor graph's algebra against the original shader blend.

This verifies math only, NOT Core Animation color spaces, masks, or precision.
Run: python3 tests/test_blend_graph.py
"""
import itertools
import random


def overlay(c, b):
    return 2 * c * b if c < 0.5 else 1 - 2 * (1 - c) * (1 - b)


def original(c, b, luminance, strength):
    luma_blend = c + (b * c - c) * luminance * strength
    texture_effect = 0.5 + (b - 0.5) * strength
    overlay_blend = overlay(c, texture_effect)
    return overlay_blend + (luma_blend - overlay_blend) * luminance


def source_over(top, bottom, mask):
    return top * mask + bottom * (1 - mask)


def graph(c, b, luminance, strength):
    multiply = c * b
    luma_blend = source_over(multiply, c, luminance * strength)
    texture_effect = source_over(b, 0.5, strength)
    overlay_blend = overlay(c, texture_effect)
    return source_over(luma_blend, overlay_blend, luminance)


if __name__ == "__main__":
    boundary = (0, 0.01, 0.499999, 0.5, 0.500001, 0.99, 1)
    cases = list(itertools.product(boundary, repeat=4))
    rng = random.Random(0)
    cases.extend(tuple(rng.random() for _ in range(4)) for _ in range(10000))
    worst = max(abs(original(*case) - graph(*case)) for case in cases)
    assert worst < 1e-12, worst
    print(f"PASS: {len(cases)} blend cases; maximum algebraic error {worst:.3g}")
    print("Core Animation output remains unverified by this check.")
