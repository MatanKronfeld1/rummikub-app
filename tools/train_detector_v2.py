#!/usr/bin/env python3
"""Fine-tune a copy of the current detector on datasets/tiles_det_v2.

Starts from detect/best.pt and writes only under --output, so the current weights
stay as they are. Run it under ultralytics==8.3.40 (the version the project trains
with). Early stopping is off and the final epoch (last.pt) is the one to use: the
validation photos are the old set, so "best" is picked blind to the new photos.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import yaml
from ultralytics import YOLO

# ultralytics 8.3.40 integrates the precision-recall curve with np.trapz, which
# numpy 2.x removed. Colab ships numpy 2.x on Python 3.13, where numpy 1.x has no
# build, so the old name is restored instead of downgrading.
if not hasattr(np, "trapz"):
    np.trapz = np.trapezoid


def portable_yaml(path: Path) -> Path:
    """Point the dataset yaml at this machine's folder (the zip comes from Windows)."""
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    data["path"] = str(path.resolve().parent)
    runtime = path.with_name("data.runtime.yaml")
    runtime.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
    return runtime


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", default="detect/best.pt")
    parser.add_argument("--data", default="datasets/tiles_det_v2/data.yaml")
    parser.add_argument("--output", default="runs/rummikub_det_v2")
    parser.add_argument("--device", default="0")
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()

    YOLO(args.weights).train(
        data=str(portable_yaml(Path(args.data))),
        epochs=args.epochs,
        imgsz=1024,
        batch=8,
        device=args.device,
        workers=args.workers,
        # Absolute, or ultralytics nests a relative project under its own runs/.
        project=str(Path(args.output).resolve()),
        name="detect",
        exist_ok=True,
        # Low rate: this adjusts a working model, it does not train a new one.
        optimizer="AdamW",
        lr0=0.0005,
        patience=0,
        close_mosaic=10,
    )
    print(f"Detector v2: {Path(args.output) / 'detect/weights/last.pt'}")


if __name__ == "__main__":
    main()
