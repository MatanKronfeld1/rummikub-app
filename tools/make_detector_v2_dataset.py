#!/usr/bin/env python3
"""Detector dataset v2: the current one, untouched, plus the corrected hard photos.

    datasets/tiles_det     (unchanged; the current detector's data, 44 train / 11 val)
    datasets/tiles_det_v2  (copy of it + the corrected photos in train, each repeated)

The corrected photos are few next to the 44 originals, so each is added ``--repeat``
times under different names (ultralytics still augments every copy differently).
Validation stays the old 11 photos. The hard-photo test set is not included at all:
it is what the new detector is judged on.
"""

from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path

import yaml


def clean_stem(name: str) -> str:
    """Roboflow names files hard_1_jpg.rf.<hash>.jpg; keep it readable."""
    return re.sub(r"_(jpg|jpeg|png)\.rf\..*$", "", name)


def build(base: Path, corrected: Path, output: Path, repeat: int) -> None:
    if output.resolve() in (base.resolve(), corrected.resolve()):
        raise SystemExit("--out must be a new folder.")
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(base / "train", output / "train")
    shutil.copytree(base / "val", output / "val")

    added = boxes = 0
    for image in sorted((corrected / "train" / "images").iterdir()):
        label = corrected / "train" / "labels" / f"{image.stem}.txt"
        lines = [line for line in label.read_text(encoding="utf-8").splitlines() if line.strip()]
        for copy in range(repeat):
            name = f"hard_{clean_stem(image.name)}_x{copy}"
            shutil.copy2(image, output / "train" / "images" / f"{name}{image.suffix}")
            (output / "train" / "labels" / f"{name}.txt").write_text(
                "\n".join(lines) + "\n", encoding="utf-8")
            added += 1
            boxes += len(lines)

    config = {"path": str(output.resolve()), "train": "train/images", "val": "val/images",
              "nc": 1, "names": ["tile"]}
    (output / "data.yaml").write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
    n_train = len(list((output / "train" / "images").iterdir()))
    n_val = len(list((output / "val" / "images").iterdir()))
    print(f"Wrote {output}: {n_train} train images ({added} added from the hard photos, "
          f"{boxes} boxes), {n_val} val images.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=Path("datasets/tiles_det"))
    parser.add_argument("--corrected", type=Path, default=Path("datasets/new_photos/corrected_extracted"))
    parser.add_argument("--out", type=Path, default=Path("datasets/tiles_det_v2"))
    parser.add_argument("--repeat", type=int, default=4)
    args = parser.parse_args()
    build(args.base, args.corrected, args.out, args.repeat)


if __name__ == "__main__":
    main()
