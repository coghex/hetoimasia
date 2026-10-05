#!/usr/bin/env python3
"""The independent reference for the mip examples in Test.Asset.Image.Mips.

Prints every generated level of each fixture the suite writes expected texels
for. It uses only the standard library and shares nothing with the generator
under test: footprints and alpha are exact fractions, linear colour is
double precision, and the coverage scale follows the rule documented in
Hetoimasia.Asset.Image.Internal.MipChain, written here from that text.

Run it with `python3 mip_reference.py` in this directory.
"""

from fractions import Fraction
import math


def to_linear(byte):
    v = byte / 255
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def from_linear(linear):
    linear = max(0.0, min(1.0, linear))
    return linear * 12.92 if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055


def nearest(x):
    """Round to nearest, halves up."""
    return math.floor(x + Fraction(1, 2)) if isinstance(x, Fraction) else math.floor(x + 0.5)


def premultiplied(texel):
    r, g, b, a = texel
    return tuple(min(255, nearest(255 * from_linear(to_linear(c) * a / 255))) for c in (r, g, b)) + (a,)


def overlap(lo, hi, s):
    return max(Fraction(0), min(hi, Fraction(s + 1)) - max(lo, Fraction(s)))


def averages(texels, width, height, w, h):
    """Per output texel: linear colour averages, stored colour averages, and
    the alpha average in code values. Output texel (x, y) averages level 0's
    rectangle [x·W/w, (x+1)·W/w) × [y·H/h, (y+1)·H/h)."""
    out = []
    for y in range(h):
        y0, y1 = Fraction(y * height, h), Fraction((y + 1) * height, h)
        for x in range(w):
            x0, x1 = Fraction(x * width, w), Fraction((x + 1) * width, w)
            area = (x1 - x0) * (y1 - y0)
            linear, stored, alpha = [0.0] * 3, [Fraction(0)] * 3, Fraction(0)
            for sy in range(height):
                for sx in range(width):
                    weight = overlap(x0, x1, sx) * overlap(y0, y1, sy) / area
                    if weight == 0:
                        continue
                    texel = texels[sy * width + sx]
                    for c in range(3):
                        linear[c] += float(weight) * to_linear(texel[c])
                        stored[c] += weight * texel[c]
                    alpha += weight * texel[3]
            out.append((linear, stored, alpha))
    return out


def scale_for(alphas, covered0, total):
    """The coverage scale for one level's alpha averages."""
    n = len(alphas)
    target = Fraction(covered0 * n, total)
    covered = lambda s: sum(1 for a in alphas if min(255, nearest(s * a)) >= 128)
    achievable = {0: None}
    for v in sorted({a for a in alphas if a > 0}, reverse=True):
        achievable.setdefault(sum(1 for a in alphas if a >= v), v)
    unscaled = covered(Fraction(1))
    best = min(abs(k - target) for k in achievable)
    if abs(unscaled - target) == best:
        return Fraction(1)
    k = min((k for k in achievable if abs(k - target) == best), key=lambda k: abs(k - unscaled))
    return Fraction(127) / max(alphas) if k == 0 else Fraction(255, 2) / achievable[k]


def chain(texels, width, height, colour, preserve):
    covered0 = sum(1 for t in texels if t[3] >= 128)
    levels = []
    level = 1
    while max(width, height) >> level:
        w, h = max(1, width >> level), max(1, height >> level)
        averaged = averages(texels, width, height, w, h)
        alphas = [a for _, _, a in averaged]
        s = scale_for(alphas, covered0, width * height) if preserve else Fraction(1)
        texels_out = []
        for linear, stored, a in averaged:
            alpha = min(255, nearest(s * a))
            if colour:
                factor = float(min(Fraction(255), s * a) / a) if a > 0 else 1.0
                rgb = tuple(min(255, nearest(255 * from_linear(c * factor))) for c in linear)
            else:
                rgb = tuple(min(255, nearest(c)) for c in stored)
            texels_out.append(rgb + (alpha,))
        levels.append(((w, h), texels_out))
        level += 1
    return levels


def binary(texels):
    return all(t[3] in (0, 255) for t in texels)


def saturation():
    texels = []
    for colour, opaque in zip([(200, 40, 40), (40, 200, 40), (40, 40, 200), (200, 200, 40)], [7, 3, 2, 2]):
        texels += [colour + (255,)] * opaque + [(0, 0, 0, 0)] * (8 - opaque)
    return texels


STRAIGHT_FIVE_BY_THREE = [
    (250, 10, 10, 255), (10, 250, 10, 128), (10, 10, 250, 64), (128, 128, 128, 200), (255, 255, 255, 1),
    (200, 100, 50, 0), (50, 100, 200, 255), (90, 180, 30, 90), (30, 30, 30, 30), (220, 220, 0, 180),
    (0, 0, 0, 255), (255, 0, 255, 140), (0, 255, 255, 20), (170, 85, 0, 240), (60, 60, 200, 110),
]

# name: (level 0 texels, width, height, colour, preserve coverage)
FIXTURES = {
    "odd-extent data 3 × 1": ([(0, 10, 200, 0), (0, 20, 100, 128), (255, 30, 0, 255)], 3, 1, False, False),
    "dataFiveByThree": (
        [(10, 0, 0, 255), (20, 40, 0, 255), (30, 80, 0, 0), (40, 120, 0, 255), (250, 160, 0, 255),
         (0, 0, 10, 200), (0, 0, 20, 100), (0, 0, 30, 50), (0, 0, 40, 25), (0, 0, 250, 0),
         (5, 5, 5, 1), (15, 15, 15, 2), (25, 25, 25, 3), (35, 35, 35, 4), (245, 245, 245, 5)],
        5, 3, False, False),
    "linear-light colour 2 × 2": ([(255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255), (0, 0, 0, 0)], 2, 2, True, True),
    "colourFiveByThree": ([premultiplied(t) for t in STRAIGHT_FIVE_BY_THREE], 5, 3, True, False),
    "saturation, colour, preserved": (saturation(), 32, 1, True, True),
    "saturation, colour, plain": (saturation(), 32, 1, True, False),
    "saturation, data, preserved": (saturation(), 32, 1, False, True),
    "equalGroups": ([(100, 100, 100, a) for a in [255, 255, 255, 0, 255, 0, 0, 0]], 8, 1, False, True),
    "ties": ([(10, 20, 30, a) for a in [250, 0, 200, 0, 150, 0, 100, 0]], 8, 1, False, True),
    "closest count 0": ([(10, 20, 30, a) for a in [127, 127, 127, 255]], 4, 1, False, True),
    "notCutout, plain": ([(60, 60, 60, a) for a in [130, 130, 130, 0]], 4, 1, False, False),
    "notCutout, preserved": ([(60, 60, 60, a) for a in [130, 130, 130, 0]], 4, 1, False, True),
}

if __name__ == "__main__":
    for name, (texels, width, height, colour, preserve) in FIXTURES.items():
        print(f"{name} (level 0 binary: {binary(texels)})")
        if name == "colourFiveByThree":
            print(f"  level 0, premultiplied: {texels}")
        for extent, level in chain(texels, width, height, colour, preserve):
            print(f"  {extent}: {level}")
