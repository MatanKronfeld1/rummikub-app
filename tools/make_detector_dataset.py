#!/usr/bin/env python3
"""Build a one-class YOLO tile-detection dataset from the labeled source set.

The split is performed by source image (never by tile), and the validation set
is deliberately seeded with board-like images so it measures both rack and
table performance.
"""

from __future__ import annotations

import argparse
import random
import shutil
from dataclasses import dataclass
from pathlib import Path

import yaml

IMAGE_SUFFIXES = (".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG")


@dataclass(frozen=True)
class Sample:
    stem: str
    image: Path
    label: Path
    board_like: bool


def _read_boxes(path: Path) -> list[tuple[float, float, float, float]]:
    boxes: list[tuple[float, float, float, float]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        boxes.append(tuple(float(value) for value in parts[1:5]))
    return boxes


def _is_board_like(boxes: list[tuple[float, float, float, float]]) -> bool:
    """Infer scene type from geometry; racks normally contain only two rows."""
    if len(boxes) < 3:
        return True
    median_h = sorted(box[3] for box in boxes)[len(boxes) // 2]
    threshold = max(0.025, median_h * 0.65)
    rows: list[float] = []
    for y in sorted(box[1] for box in boxes):
        for index, center in enumerate(rows):
            if abs(y - center) <= threshold:
                rows[index] = (center + y) / 2
                break
        else:
            rows.append(y)
    return len(rows) > 3


def discover(source: Path) -> list[Sample]:
    image_dir, label_dir = source / "images", source / "labels"
    if not image_dir.is_dir() or not label_dir.is_dir():
        raise SystemExit(f"Expected {image_dir} and {label_dir}")
    samples: list[Sample] = []
    for label in sorted(label_dir.glob("*.txt")):
        image = next(
            (image_dir / f"{label.stem}{suffix}" for suffix in IMAGE_SUFFIXES
             if (image_dir / f"{label.stem}{suffix}").exists()),
            None,
        )
        if image is None:
            print(f"[skip] no image for {label.name}")
            continue
        boxes = _read_boxes(label)
        if boxes:
            samples.append(Sample(label.stem, image, label, _is_board_like(boxes)))
    if len(samples) < 2:
        raise SystemExit("Need at least two labeled images")
    return samples


def split_samples(
    samples: list[Sample], val_fraction: float, seed: int
) -> tuple[list[Sample], list[Sample]]:
    rng = random.Random(seed)
    desired = min(len(samples) - 1, max(1, round(len(samples) * val_fraction)))
    board = [sample for sample in samples if sample.board_like]
    rack = [sample for sample in samples if not sample.board_like]
    rng.shuffle(board)
    rng.shuffle(rack)

    # Aim for roughly one third board scenes, while never exhausting a scene
    # category from training when there is more than one example.
    board_count = min(len(board), max(1, round(desired / 3))) if board else 0
    if len(board) > 1:
        board_count = min(board_count, len(board) - 1)
    val = board[:board_count]
    remaining = [sample for sample in rack + board[board_count:] if sample not in val]
    rng.shuffle(remaining)
    val.extend(remaining[: desired - len(val)])
    val_stems = {sample.stem for sample in val}
    train = [sample for sample in samples if sample.stem not in val_stems]
    return train, val


def _write_sample(sample: Sample, output: Path, split: str) -> None:
    image_out = output / split / "images" / sample.image.name
    label_out = output / split / "labels" / f"{sample.stem}.txt"
    image_out.parent.mkdir(parents=True, exist_ok=True)
    label_out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(sample.image, image_out)

    lines = []
    for raw in sample.label.read_text(encoding="utf-8").splitlines():
        parts = raw.split()
        if len(parts) >= 5:
            lines.append("0 " + " ".join(parts[1:5]))
    label_out.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def build(source: Path, output: Path, val_fraction: float, seed: int) -> None:
    samples = discover(source)
    train, val = split_samples(samples, val_fraction, seed)
    if output.exists():
        shutil.rmtree(output)
    for split, selected in (("train", train), ("val", val)):
        for sample in selected:
            _write_sample(sample, output, split)
    config = {
        "path": str(output.resolve()),
        "train": "train/images",
        "val": "val/images",
        "nc": 1,
        "names": ["tile"],
    }
    (output / "data.yaml").write_text(
        yaml.safe_dump(config, sort_keys=False), encoding="utf-8"
    )
    (output / "split.txt").write_text(
        "\n".join(
            [f"seed={seed}", f"train={len(train)}", f"val={len(val)}"]
            + [f"val\t{'board' if s.board_like else 'rack'}\t{s.stem}" for s in val]
        )
        + "\n",
        encoding="utf-8",
    )
    print(
        f"Wrote {len(train)} train and {len(val)} val images to {output} "
        f"({sum(s.board_like for s in val)} board-like validation images)."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("your_dataset/train"))
    parser.add_argument("--out", type=Path, default=Path("datasets/tiles_det"))
    parser.add_argument("--val-fraction", type=float, default=0.20)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    if not 0 < args.val_fraction < 1:
        parser.error("--val-fraction must be between 0 and 1")
    build(args.source, args.out, args.val_fraction, args.seed)


if __name__ == "__main__":
    main()
