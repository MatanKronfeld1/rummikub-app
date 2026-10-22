#!/usr/bin/env python3
"""Build a balanced tile-crop classification dataset from YOLO annotations.

What makes this dataset trustworthy
-----------------------------------
* Every training tile is analyzed (tools/tile_ink.py).  A tile is used only if
  the ink color found on it equals the color in its label.  Tiles whose label
  disagrees with what is printed on them (your own tagging slips) are excluded
  and listed in ``suspect_labels.csv`` so they can be fixed at the source.
* Recoloring never falls back to the original image.  If a digit cannot be
  recolored, that sample is simply not produced.
* Validation crops are untouched real crops from held-out photos (the same
  image-level split as the detector), minus tiles whose label is provably wrong.

What the classifier sees
------------------------
The crop geometry matches the Roboflow Workflow exactly (tools/tile_crops.py):
detector box + 5 % per side, then resized to a square.  Training samples add
box jitter, any rotation (board tiles lie at every angle) and lighting changes.
"""

from __future__ import annotations

import argparse
import csv
import random
import shutil
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import yaml
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

from tile_crops import (
    CLS_SIZE,
    MARGIN_PER_SIDE,
    center_square,
    load_photo,
    stretch_square,
)
from tile_ink import COLORS, InkAnalysis, analyze_tile, recolor_tile, strong_ink_ratio

IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG")
CONTEXT_MARGIN = 0.30  # extra photo kept around each box so boxes can be jittered
STRETCH_PROBABILITY = 0.70  # rest are rendered the Ultralytics center-crop way


@dataclass
class Tile:
    name: str
    stem: str
    index: int
    split: str  # "train" or "val"
    status: str  # ok | joker | rejected | mismatch:<Color>
    ctx: np.ndarray | None = None  # RGB context crop (train only)
    box: tuple[float, float, float, float] | None = None  # box inside ctx
    analysis: InkAnalysis | None = None
    view: Image.Image | None = None  # canonical un-jittered crop (val only)


def load_names(path: Path) -> list[str]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    names = data.get("names")
    if isinstance(names, dict):
        names = [names[key] for key in sorted(names, key=lambda value: int(value))]
    if not isinstance(names, list) or not names:
        raise SystemExit(f"No names list in {path}")
    return [str(name) for name in names]


def class_parts(name: str) -> tuple[str | None, int | None]:
    if name.lower() == "joker":
        return None, None
    for color in COLORS:
        if name.startswith(color):
            try:
                return color, int(name[len(color) :])
            except ValueError:
                pass
    raise ValueError(f"Unsupported class name: {name}")


def validation_stems(split_file: Path) -> set[str]:
    if not split_file.exists():
        raise SystemExit(
            f"{split_file} is missing; run tools/make_detector_dataset.py first "
            "so detector and classifier use the same image-level split."
        )
    result = set()
    for line in split_file.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0] == "val":
            result.add(parts[2])
    if not result:
        raise SystemExit(f"No validation stems found in {split_file}")
    return result


# --------------------------------------------------------------------------
# Extraction
# --------------------------------------------------------------------------

def extract_tiles(source: Path, names: list[str], val_stems: set[str]) -> list[Tile]:
    tiles: list[Tile] = []
    for label_path in sorted((source / "labels").glob("*.txt")):
        image_path = next(
            (
                source / "images" / f"{label_path.stem}{suffix}"
                for suffix in IMAGE_SUFFIXES
                if (source / "images" / f"{label_path.stem}{suffix}").exists()
            ),
            None,
        )
        if image_path is None:
            continue
        image = load_photo(image_path)
        width, height = image.size
        split = "val" if label_path.stem in val_stems else "train"
        for index, line in enumerate(label_path.read_text(encoding="utf-8").splitlines()):
            parts = line.split()
            if len(parts) < 5:
                continue
            class_id = int(parts[0])
            if not 0 <= class_id < len(names):
                continue
            xc, yc, bw, bh = (float(v) for v in parts[1:5])
            box = (
                (xc - bw / 2) * width,
                (yc - bh / 2) * height,
                (xc + bw / 2) * width,
                (yc + bh / 2) * height,
            )
            name = names[class_id]
            color, _ = class_parts(name)

            cx1 = max(0, int(box[0] - CONTEXT_MARGIN * (box[2] - box[0])))
            cy1 = max(0, int(box[1] - CONTEXT_MARGIN * (box[3] - box[1])))
            cx2 = min(width, int(box[2] + CONTEXT_MARGIN * (box[2] - box[0])))
            cy2 = min(height, int(box[3] + CONTEXT_MARGIN * (box[3] - box[1])))
            ctx = np.asarray(image.crop((cx1, cy1, cx2, cy2)))
            local = (box[0] - cx1, box[1] - cy1, box[2] - cx1, box[3] - cy1)

            analysis = None
            if color is None:
                status = "joker"
            else:
                analysis = analyze_tile(ctx, local)
                if analysis is None:
                    status = "rejected"
                elif analysis.color != color:
                    status = f"mismatch:{analysis.color}"
                else:
                    status = "ok"

            tile = Tile(name, label_path.stem, index, split, status)
            if split == "train":
                tile.ctx, tile.box, tile.analysis = ctx, local, analysis
            else:
                tile.view = stretch_square(
                    Image.fromarray(ctx).crop(_margin_window(local, ctx.shape, None, None)),
                    CLS_SIZE,
                )
            tiles.append(tile)
    return tiles


# --------------------------------------------------------------------------
# Views and augmentation
# --------------------------------------------------------------------------

def _margin_window(box, shape, rng, jitter):
    """(left, top, right, bottom) of the box plus per-side margin."""
    x1, y1, x2, y2 = box
    w, h = x2 - x1, y2 - y1
    margins = [MARGIN_PER_SIDE] * 4
    if rng is not None:
        margins = [MARGIN_PER_SIDE + rng.uniform(-jitter, jitter) for _ in range(4)]
    height, width = shape[:2]
    left = max(0, int(round(x1 - w * margins[0])))
    top = max(0, int(round(y1 - h * margins[1])))
    right = min(width, int(round(x2 + w * margins[2])))
    bottom = min(height, int(round(y2 + h * margins[3])))
    return left, top, max(right, left + 1), max(bottom, top + 1)


def rotate_view(view: Image.Image, rng: random.Random) -> Image.Image:
    # Rack tiles are nearly upright, board tiles lie at any angle.
    angle = rng.uniform(-8, 8) if rng.random() < 0.40 else rng.uniform(0, 360)
    arr = np.asarray(view)
    ring = np.concatenate([arr[0], arr[-1], arr[:, 0], arr[:, -1]])
    fill = tuple(int(v) for v in np.median(ring, axis=0))
    return view.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True, fillcolor=fill)


def photometric(view: Image.Image, rng: random.Random) -> Image.Image:
    view = ImageEnhance.Brightness(view).enhance(rng.uniform(0.70, 1.25))
    view = ImageEnhance.Contrast(view).enhance(rng.uniform(0.85, 1.15))
    gains = np.array([rng.uniform(0.94, 1.06) for _ in range(3)], dtype=np.float32)
    arr = np.clip(np.asarray(view, dtype=np.float32) * gains, 0, 255)
    if rng.random() < 0.30:
        arr = np.clip(arr + np.random.default_rng(rng.randrange(2**32)).normal(
            0, rng.uniform(2, 6), arr.shape), 0, 255)
    view = Image.fromarray(arr.astype(np.uint8))
    if rng.random() < 0.30:
        view = view.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.0)))
    return view


def render(view: Image.Image, size: int, rng: random.Random) -> Image.Image:
    if rng.random() < STRETCH_PROBABILITY:
        return stretch_square(view, size)
    return center_square(view, size)


def augmented_sample(
    ctx: np.ndarray,
    box: tuple[float, float, float, float],
    size: int,
    rng: random.Random,
) -> Image.Image:
    window = _margin_window(box, ctx.shape, rng, jitter=0.035)
    view = Image.fromarray(ctx).crop(window)
    view = rotate_view(view, rng)
    view = photometric(view, rng)
    return render(view, size, rng)


# --------------------------------------------------------------------------
# Review material
# --------------------------------------------------------------------------

def write_review_sheets(output: Path, names: list[str]) -> None:
    review = output / "review"
    review.mkdir(parents=True, exist_ok=True)
    cell, columns = 80, 12
    groups = {color: [n for n in names if n.startswith(color)] for color in COLORS}
    groups["Joker"] = [n for n in names if n.lower() == "joker"]
    for group, members in groups.items():
        members = sorted(members, key=lambda n: (class_parts(n)[1] or 0))
        sheet = Image.new("RGB", (columns * cell + 70, len(members) * cell), "white")
        draw = ImageDraw.Draw(sheet)
        for row, name in enumerate(members):
            draw.text((4, row * cell + cell // 2 - 5), name, fill="black")
            files = sorted((output / "train" / name).glob("*.jpg"))
            real = [f for f in files if f.name.startswith("real_")]
            aug = [f for f in files if f.name.startswith("aug_")]
            chosen = (real[:4] + aug)[:columns]
            for col, path in enumerate(chosen):
                thumb = Image.open(path).resize((cell - 2, cell - 2))
                sheet.paste(thumb, (70 + col * cell, row * cell))
        sheet.save(review / f"{group}.jpg", quality=88)


# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

def build(
    source: Path,
    classes: Path,
    split_file: Path,
    output: Path,
    target_per_class: int,
    size: int,
    seed: int,
) -> None:
    names = load_names(classes)
    tiles = extract_tiles(source, names, validation_stems(split_file))
    if output.exists():
        shutil.rmtree(output)
    rng = random.Random(seed)

    # --- sources and palette (training tiles whose ink matches their label) --
    usable = [t for t in tiles if t.split == "train" and t.status in ("ok", "joker")]
    by_number: dict[int, list[Tile]] = {}
    jokers: list[Tile] = []
    palette_samples: dict[str, list[np.ndarray]] = {c: [] for c in COLORS}
    for tile in usable:
        color, number = class_parts(tile.name)
        if color is None:
            jokers.append(tile)
            continue
        by_number.setdefault(number, []).append(tile)
        palette_samples[color].append(strong_ink_ratio(tile.ctx, tile.analysis))
    missing = [c for c, v in palette_samples.items() if not v]
    if missing:
        raise SystemExit(f"No clean example for color(s): {missing}")
    # Ink color relative to the tile face: ratio * face = target for any photo.
    palette = {c: np.median(np.array(v), axis=0) for c, v in palette_samples.items()}
    print("Ink palette (ratio to face):",
          {c: [round(float(x), 2) for x in v] for c, v in palette.items()})

    stats = {name: Counter() for name in names}
    for tile in tiles:
        stats[tile.name][f"{tile.split}_{tile.status.split(':')[0]}"] += 1

    # --- validation: real, held-out, label-consistent -----------------------
    for tile in tiles:
        if tile.split != "val" or tile.status.startswith("mismatch"):
            continue
        val_dir = output / "val" / tile.name
        val_dir.mkdir(parents=True, exist_ok=True)
        tile.view.save(val_dir / f"{tile.stem}_{tile.index}.jpg", quality=95)
        stats[tile.name]["val_written"] += 1

    # --- training -----------------------------------------------------------
    for name in names:
        train_dir = output / "train" / name
        train_dir.mkdir(parents=True, exist_ok=True)
        (output / "val" / name).mkdir(parents=True, exist_ok=True)
        color, number = class_parts(name)
        own = [t for t in usable if t.name == name]
        pool = jokers if color is None else by_number.get(number or 0, [])
        if not pool:
            print(f"[warn] no usable source tile for {name}")
            continue

        written = 0
        for tile in own[:target_per_class]:
            window = _margin_window(tile.box, tile.ctx.shape, None, None)
            view = Image.fromarray(tile.ctx).crop(window)
            stretch_square(view, size).save(train_dir / f"real_{written:04d}.jpg", quality=95)
            written += 1
            stats[name]["real_written"] += 1

        failures = 0
        while written < target_per_class and failures < 400:
            source_tile = rng.choice(pool)
            ctx = source_tile.ctx
            if color is not None and source_tile.analysis.color != color:
                target = np.clip(palette[color] * source_tile.analysis.face_rgb, 0, 255)
                recolored = recolor_tile(ctx, source_tile.analysis, target)
                if recolored is ctx:  # recoloring failed: never keep the original
                    failures += 1
                    continue
                ctx = recolored
            augmented_sample(ctx, source_tile.box, size, rng).save(
                train_dir / f"aug_{written:04d}.jpg", quality=92
            )
            written += 1
            stats[name]["aug_written"] += 1
        if written < target_per_class:
            print(f"[warn] {name}: only {written}/{target_per_class} samples produced")

    # --- reports ------------------------------------------------------------
    output.mkdir(parents=True, exist_ok=True)
    with open(output / "suspect_labels.csv", "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["image_stem", "box_index", "split", "label", "problem", "suggested_label"])
        for tile in tiles:
            if tile.status in ("ok", "joker"):
                continue
            color, number = class_parts(tile.name)
            if tile.status.startswith("mismatch"):
                found = tile.status.split(":")[1]
                writer.writerow([tile.stem, tile.index, tile.split, tile.name,
                                 f"label says {color} but tile shows {found}", f"{found}{number}"])
            else:
                writer.writerow([tile.stem, tile.index, tile.split, tile.name,
                                 "no clean digit found (blank slot, not a tile, or unreadable)", ""])
    with open(output / "report.txt", "w", encoding="utf-8") as handle:
        handle.write("class real_train real_val aug excluded_train excluded_val\n")
        for name in names:
            s = stats[name]
            excluded_train = sum(v for k, v in s.items()
                                 if k.startswith("train_") and not k.endswith(("ok", "joker")))
            excluded_val = s["val_mismatch"]
            handle.write(f"{name} {s['real_written']} {s['val_written']} {s['aug_written']} "
                         f"{excluded_train} {excluded_val}\n")

    write_review_sheets(output, names)
    manifest = {
        "seed": seed,
        "image_size": size,
        "target_per_class": target_per_class,
        "classes": len(names),
        "train_images": sum(1 for _ in (output / "train").rglob("*.jpg")),
        "val_images": sum(1 for _ in (output / "val").rglob("*.jpg")),
        "excluded_tiles": sum(1 for t in tiles if t.status not in ("ok", "joker")),
    }
    (output / "manifest.yaml").write_text(yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8")
    print(
        f"Wrote {manifest['train_images']} train and {manifest['val_images']} real validation "
        f"crops to {output}. {manifest['excluded_tiles']} source tiles were excluded; see "
        f"{output / 'suspect_labels.csv'}."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("your_dataset/train"))
    parser.add_argument("--classes", type=Path, default=Path("your_dataset/data.yaml"))
    parser.add_argument("--split-file", type=Path, default=Path("datasets/tiles_det/split.txt"))
    parser.add_argument("--out", type=Path, default=Path("datasets/tiles_cls"))
    parser.add_argument("--target-per-class", type=int, default=180)
    parser.add_argument("--size", type=int, default=CLS_SIZE)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    build(args.source, args.classes, args.split_file, args.out,
          args.target_per_class, args.size, args.seed)


if __name__ == "__main__":
    main()
