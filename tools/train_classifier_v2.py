#!/usr/bin/env python3
"""Fine-tune a copy of the current classifier on datasets/tiles_cls_v2.

Starts from classify/best.pt and writes only under --output, so the current
weights stay as they are. Augmentation matches tools/train_models.py.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from ultralytics import YOLO


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", default="classify/best.pt")
    parser.add_argument("--data", default="datasets/tiles_cls_v2")
    parser.add_argument("--output", default="runs/rummikub_v2")
    parser.add_argument("--device", default="0")
    parser.add_argument("--epochs", type=int, default=15)
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()

    YOLO(args.weights).train(
        data=args.data,
        epochs=args.epochs,
        imgsz=224,
        batch=args.batch,
        device=args.device,
        workers=args.workers,
        # Absolute, or ultralytics nests a relative project under its own runs/.
        project=str(Path(args.output).resolve()),
        name="classify",
        exist_ok=True,
        # Low rate: this adjusts a working model, it does not train a new one.
        optimizer="AdamW",
        lr0=0.0005,
        patience=6,
        auto_augment=None,
        erasing=0.0,
        hsv_h=0.0,
        hsv_s=0.2,
        hsv_v=0.3,
        fliplr=0.0,
        flipud=0.0,
        scale=0.15,
    )
    print(f"Classifier v2: {Path(args.output) / 'classify/weights/best.pt'}")


if __name__ == "__main__":
    main()
