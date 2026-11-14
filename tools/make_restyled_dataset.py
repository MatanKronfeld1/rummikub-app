#!/usr/bin/env python3
"""Build a classifier dataset that also covers a second physical tile set.

The training photos show one tile set: pale ink and a colorless embossed logo.
This script turns those real tiles into the look of another set (vivid ink, a
colored heart in a round dimple, a whiter face) and adds them to a *copy* of the
existing dataset:

    datasets/tiles_cls     (untouched, the current model's data)
    datasets/tiles_cls_v2  (copy of it + syn_* restyled crops per class)

Digit shapes stay real because they come from the source tile's own ink mask.
The restyled crops are also seen from oblique camera angles, which the rotation
in make_classifier_dataset.py does not cover: every sample is warped first and
then cropped by the bounding box of the warped tile, the same way a detector box
on a tilted rack catches the corners of the neighboring tiles.

Validation stays the real held-out crops, so it answers one question only: did
the old set get worse? It says nothing about the new set.
"""

from __future__ import annotations

import argparse
import math
import random
import shutil
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from make_classifier_dataset import (
    MARGIN_PER_SIDE,
    Tile,
    class_parts,
    extract_tiles,
    load_names,
    photometric,
    render,
    validation_stems,
)
from tile_crops import CLS_SIZE
from tile_ink import InkAnalysis, recolor_tile

# Vivid ink of the target set, RGB, on a neutral face.
INK = {
    "Red": (205, 28, 38),
    "Blue": (24, 108, 214),
    "Orange": (240, 160, 30),
    "Black": (22, 22, 28),
}
FACE = (236, 230, 212)
# Rack and table colors seen behind a tile (tile corners sit on these).
BACKDROPS = ((122, 132, 186), (92, 104, 158), (60, 62, 80), (150, 40, 40), (200, 190, 170))

LOGO_OFFSET = 1.2  # logo center = tile center - 1.2 * (digit center - tile center)
DIMPLE_RADIUS = 0.17  # of the tile's short side
LOGO_ERASE = 1.7  # the old logo is wider than the dimple that replaces it
HEART_SIZE = 0.5  # of the dimple radius
MIN_BACKDROP_AREA = 0.06  # of the context; smaller blobs are digits, not rack
MAX_SHEAR = 0.32
MAX_KEYSTONE = 0.0006  # perspective, per pixel of a 300 px tile


def tile_axes(analysis: InkAnalysis) -> tuple[np.ndarray, np.ndarray, float]:
    """(tile center, unit vector digit -> logo, distance digit center -> logo center)."""
    x1, y1, x2, y2 = analysis.box
    center = np.array([(x1 + x2) / 2, (y1 + y2) / 2], dtype=np.float32)
    ys, xs = np.nonzero(analysis.core)
    digit = np.array([x1 + xs.mean(), y1 + ys.mean()], dtype=np.float32)
    offset = center - digit
    length = float(np.linalg.norm(offset))
    if length < 1.0:  # digit centered: fall back to an upright tile
        return center, np.array([0.0, 1.0], dtype=np.float32), 0.0
    return center, offset / length, length


def heart_polygon(center: np.ndarray, down: np.ndarray, size: float) -> np.ndarray:
    """Heart outline around ``center`` whose point goes along ``down``."""
    points = []
    for t in np.linspace(0, 2 * math.pi, 48, endpoint=False):
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        points.append((x / 17, -y / 17))
    right = np.array([-down[1], down[0]], dtype=np.float32)
    return np.array([center + size * (x * right + y * down) for x, y in points])


def soft_mask(shape: tuple[int, int], draw, scale: int = 4) -> np.ndarray:
    """Anti-aliased float mask, drawn at ``scale`` times the size."""
    height, width = shape
    big = np.zeros((height * scale, width * scale), dtype=np.uint8)
    draw(big, scale)
    return cv2.resize(big, (width, height), interpolation=cv2.INTER_AREA).astype(np.float32) / 255


def paint_heart_dimple(
    rgb: np.ndarray,
    analysis: InkAnalysis,
    ink: np.ndarray,
    rng: random.Random,
) -> np.ndarray:
    """Replace the embossed logo with a round dimple holding a colored heart."""
    x1, y1, x2, y2 = analysis.box
    short = min(x2 - x1, y2 - y1)
    center, down, length = tile_axes(analysis)
    logo = center + down * length * LOGO_OFFSET * rng.uniform(0.92, 1.08)
    radius = short * DIMPLE_RADIUS * rng.uniform(0.92, 1.08)
    shape = rgb.shape[:2]

    # The emboss is low contrast: flat face color hides it, and unlike inpainting
    # it cannot smear the digit's ink into the dimple. The digit itself is kept.
    erase = soft_mask(shape, lambda big, s: cv2.circle(
        big, tuple(int(v * s) for v in logo), int(radius * LOGO_ERASE * s), 255, -1))
    erase = cv2.GaussianBlur(erase, (0, 0), max(1.0, radius * 0.12))
    digit = np.zeros(shape, dtype=np.uint8)
    digit[y1:y2, x1:x2] = analysis.core
    digit = cv2.dilate(digit, np.ones((7, 7), np.uint8)) > 0
    erase[digit] = 0
    out = rgb.astype(np.float32)
    out = out * (1 - erase[..., None]) + analysis.face_rgb * erase[..., None]

    # A concave dimple: lit on the side away from the light, shaded on the other.
    disc = soft_mask(shape, lambda big, s: cv2.circle(
        big, tuple(int(v * s) for v in logo), int(radius * s), 255, -1))
    disc = cv2.GaussianBlur(disc, (0, 0), max(0.6, radius * 0.05))
    light = rng.uniform(0, 2 * math.pi)
    yy, xx = np.indices(shape, dtype=np.float32)
    across = ((xx - logo[0]) * math.cos(light) + (yy - logo[1]) * math.sin(light)) / max(radius, 1)
    shade = 1.0 - 0.09 * np.clip(across, -1, 1)
    out *= (1 - disc[..., None]) + disc[..., None] * shade[..., None] * rng.uniform(0.93, 0.99)

    outline = heart_polygon(logo, down, radius * HEART_SIZE * rng.uniform(0.9, 1.1))
    heart = soft_mask(shape, lambda big, s: cv2.fillPoly(
        big, [np.round(outline * s).astype(np.int32)], 255))
    return np.clip(out * (1 - heart[..., None]) + ink * heart[..., None], 0, 255).astype(np.uint8)


def backdrop_swap(
    rgb: np.ndarray,
    box: tuple[int, int, int, int],
    face: np.ndarray,
    rng: random.Random,
) -> np.ndarray:
    """Recolor the rack or table. Neighboring tiles stay, so crops keep their clutter."""
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
    face_lab = cv2.cvtColor(face.reshape(1, 1, 3).astype(np.uint8), cv2.COLOR_RGB2LAB).astype(np.float32)
    not_tile = (np.linalg.norm(lab - face_lab, axis=2) > 30).astype(np.uint8)

    # This tile's own ink and heart are never backdrop.
    x1, y1, x2, y2 = box
    inset_x, inset_y = int((x2 - x1) * 0.12), int((y2 - y1) * 0.12)
    not_tile[y1 + inset_y : y2 - inset_y, x1 + inset_x : x2 - inset_x] = 0
    not_tile = cv2.morphologyEx(not_tile, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))

    # The rack is one big region; a neighbor's digit is a small island.
    count, labels, stats, _ = cv2.connectedComponentsWithStats(not_tile, connectivity=8)
    min_area = MIN_BACKDROP_AREA * not_tile.size
    keep = np.zeros_like(not_tile, dtype=np.float32)
    for index in range(1, count):
        if stats[index, cv2.CC_STAT_AREA] >= min_area:
            keep[labels == index] = 1.0
    alpha = cv2.GaussianBlur(keep, (0, 0), 1.5)[..., None]
    color = np.array(rng.choice(BACKDROPS), dtype=np.float32) * rng.uniform(0.7, 1.1)
    return np.clip(rgb * (1 - alpha) + color * alpha, 0, 255).astype(np.uint8)


def restyle(
    ctx: np.ndarray,
    analysis: InkAnalysis,
    color: str,
    rng: random.Random,
) -> np.ndarray | None:
    """The source tile in the target set's look, or None if it cannot be recolored."""
    ink = np.array(INK[color], dtype=np.float32) * rng.uniform(0.9, 1.05)
    # Move the whole context first, so the ink is computed against a whiter face.
    gain = np.array(FACE, dtype=np.float32) * rng.uniform(0.94, 1.04) / np.maximum(analysis.face_rgb, 1.0)
    white = np.clip(ctx.astype(np.float32) * gain, 0, 255).astype(np.uint8)
    moved = InkAnalysis(
        analysis.color, analysis.box, analysis.core,
        np.clip(analysis.face_rgb * gain, 0, 255).astype(np.float32),
        np.clip(analysis.ink_rgb * gain, 0, 255).astype(np.float32),
        analysis.area_frac,
    )
    recolored = recolor_tile(white, moved, np.clip(ink, 0, 255))
    if recolored is white:
        return None
    out = paint_heart_dimple(recolored, moved, ink, rng)
    if rng.random() < 0.8:
        out = backdrop_swap(out, moved.box, moved.face_rgb, rng)
    return out


def oblique_view(
    ctx: np.ndarray,
    box: tuple[float, float, float, float],
    rng: random.Random,
) -> Image.Image:
    """Warp the context, then crop the warped tile's bounding box plus margin."""
    x1, y1, x2, y2 = box
    corners = np.array([(x1, y1), (x2, y1), (x2, y2), (x1, y2)], dtype=np.float32)
    center = corners.mean(axis=0)
    side = max(x2 - x1, y2 - y1)

    # Rack tiles stay near upright, board tiles lie at any angle.
    angle = rng.uniform(-20, 20) if rng.random() < 0.40 else rng.uniform(0, 360)
    cos, sin = math.cos(math.radians(angle)), math.sin(math.radians(angle))
    rotate = np.array([[cos, -sin, 0], [sin, cos, 0], [0, 0, 1]], dtype=np.float64)
    shear = np.array([
        [1, rng.uniform(-MAX_SHEAR, MAX_SHEAR), 0],
        [rng.uniform(-MAX_SHEAR, MAX_SHEAR), 1, 0],
        [rng.uniform(-MAX_KEYSTONE, MAX_KEYSTONE) * 300 / side,
         rng.uniform(-MAX_KEYSTONE, MAX_KEYSTONE) * 300 / side, 1],
    ], dtype=np.float64)
    to_origin = np.array([[1, 0, -center[0]], [0, 1, -center[1]], [0, 0, 1]], dtype=np.float64)

    height, width = ctx.shape[:2]
    # Keep everything: the canvas is 3 tiles wide, the border is replicated.
    canvas = int(side * 3)
    back = np.array([[1, 0, canvas / 2], [0, 1, canvas / 2], [0, 0, 1]], dtype=np.float64)
    matrix = back @ rotate @ shear @ to_origin
    warped = cv2.warpPerspective(ctx, matrix, (canvas, canvas), flags=cv2.INTER_LINEAR,
                                 borderMode=cv2.BORDER_REPLICATE)
    moved = cv2.perspectiveTransform(corners[None], matrix)[0]
    left, top = moved.min(axis=0)
    right, bottom = moved.max(axis=0)
    margins = [MARGIN_PER_SIDE + rng.uniform(-0.035, 0.035) for _ in range(4)]
    w, h = right - left, bottom - top
    window = (
        max(0, int(left - w * margins[0])),
        max(0, int(top - h * margins[1])),
        min(canvas, int(right + w * margins[2])),
        min(canvas, int(bottom + h * margins[3])),
    )
    return Image.fromarray(warped).crop(window)


def restyled_sample(tile: Tile, color: str, size: int, rng: random.Random) -> Image.Image | None:
    styled = restyle(tile.ctx, tile.analysis, color, rng)
    if styled is None:
        return None
    return render(photometric(oblique_view(styled, tile.box, rng), rng), size, rng)


def build(
    source: Path,
    classes: Path,
    split_file: Path,
    base: Path,
    output: Path,
    per_class: int,
    size: int,
    seed: int,
    preview_only: bool,
) -> None:
    if output.resolve() == base.resolve():
        raise SystemExit("--out must differ from --base: the base dataset stays untouched.")
    names = load_names(classes)
    tiles = extract_tiles(source, names, validation_stems(split_file))
    usable = [t for t in tiles if t.split == "train" and t.status == "ok"]
    by_number: dict[int, list[Tile]] = {}
    for tile in usable:
        by_number.setdefault(class_parts(tile.name)[1], []).append(tile)
    rng = random.Random(seed)

    if preview_only:
        columns = 10
        rows = sorted(n for n in names if class_parts(n)[0])[::5]
        sheet = Image.new("RGB", (columns * 150, len(rows) * 150), "white")
        for row, name in enumerate(rows):
            color, number = class_parts(name)
            for col in range(columns):
                sample = restyled_sample(rng.choice(by_number[number]), color, size, rng)
                if sample is not None:
                    sheet.paste(sample.resize((148, 148)), (col * 150, row * 150))
        output.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(output.with_suffix(".preview.jpg"), quality=90)
        print(f"Preview: {output.with_suffix('.preview.jpg')}")
        return

    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(base / "train", output / "train")
    shutil.copytree(base / "val", output / "val")

    for name in names:
        color, number = class_parts(name)
        if color is None:  # the target set's joker is unknown: keep only real ones
            continue
        written = failures = 0
        while written < per_class and failures < 400:
            sample = restyled_sample(rng.choice(by_number[number]), color, size, rng)
            if sample is None:
                failures += 1
                continue
            sample.save(output / "train" / name / f"syn_{written:04d}.jpg", quality=92)
            written += 1
        if written < per_class:
            print(f"[warn] {name}: only {written}/{per_class} samples produced")
    print(f"Wrote {sum(1 for _ in (output / 'train').rglob('syn_*.jpg'))} restyled crops to {output}.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("your_dataset/train"))
    parser.add_argument("--classes", type=Path, default=Path("your_dataset/data.yaml"))
    parser.add_argument("--split-file", type=Path, default=Path("datasets/tiles_det/split.txt"))
    parser.add_argument("--base", type=Path, default=Path("datasets/tiles_cls"))
    parser.add_argument("--out", type=Path, default=Path("datasets/tiles_cls_v2"))
    parser.add_argument("--per-class", type=int, default=120)
    parser.add_argument("--size", type=int, default=CLS_SIZE)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--preview", action="store_true", help="only write a contact sheet")
    args = parser.parse_args()
    build(args.source, args.classes, args.split_file, args.base, args.out,
          args.per_class, args.size, args.seed, args.preview)


if __name__ == "__main__":
    main()
