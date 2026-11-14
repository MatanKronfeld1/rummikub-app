#!/usr/bin/env python3
"""Zip an autolabel batch so it can be dragged into Roboflow and corrected there.

The zip is a one-class YOLO dataset (class ``tile``) holding the batch's photos and
the detector's boxes. Roboflow keeps the split of an uploaded zip, so ``--split test``
puts the photos in Roboflow's Test set and they stay out of training.

    python tools/make_roboflow_upload.py --batch autolabeled/batch1 --split train --skip rum_img3
    python tools/make_roboflow_upload.py --batch autolabeled/holdout --split test

Nothing is sent anywhere: the zip is written next to the batch and you upload it.
"""

from __future__ import annotations

import argparse
import re
import zipfile
from pathlib import Path

DATA_YAML = """\
path: .
train: train/images
val: valid/images
test: test/images
nc: 1
names: ['tile']
"""


def slug(stem: str) -> str:
    """File names with spaces are a needless risk in an upload."""
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", stem).strip("_")


def build(batch: Path, split: str, out: Path, skip: set[str]) -> Path:
    images = sorted((batch / "images").glob("*.jpg"))
    chosen = [p for p in images if p.stem not in skip]
    if not chosen:
        raise SystemExit(f"No images left in {batch / 'images'}")
    out.mkdir(parents=True, exist_ok=True)
    target = out / f"{batch.name}_{split}.zip"
    boxes = 0
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("data.yaml", DATA_YAML)
        for image in chosen:
            label = batch / "detector_labels" / f"{image.stem}.txt"
            lines = [line for line in label.read_text(encoding="utf-8").splitlines() if line.strip()]
            for line in lines:
                parts = line.split()
                values = [float(v) for v in parts[1:5]]
                if len(parts) != 5 or parts[0] != "0" or not all(0 <= v <= 1 for v in values):
                    raise SystemExit(f"Bad label in {label}: {line}")
            name = slug(image.stem)
            archive.write(image, f"{split}/images/{name}.jpg")
            archive.writestr(f"{split}/labels/{name}.txt", "\n".join(lines) + ("\n" if lines else ""))
            boxes += len(lines)
            print(f"  {name}.jpg: {len(lines)} boxes")
    print(f"{target}: {len(chosen)} photos, {boxes} boxes, split={split}")
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch", type=Path, required=True)
    parser.add_argument("--split", choices=("train", "valid", "test"), required=True)
    parser.add_argument("--out", type=Path, default=Path("autolabeled/roboflow_upload"))
    parser.add_argument("--skip", nargs="*", default=[], help="image stems to leave out")
    args = parser.parse_args()
    build(args.batch, args.split, args.out, set(args.skip))


if __name__ == "__main__":
    main()
