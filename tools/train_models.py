#!/usr/bin/env python3
"""Train the detector and crop classifier (intended for a Colab/Kaggle GPU)."""

from __future__ import annotations

import argparse
from pathlib import Path

import yaml
from ultralytics import YOLO


def portable_detection_yaml(path: Path) -> Path:
    """Repair a dataset YAML after moving it from Windows to Colab/Linux."""
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    configured = Path(str(data.get("path", "")))
    if configured.is_dir():
        return path
    data["path"] = str(path.resolve().parent)
    runtime = path.with_name("data.runtime.yaml")
    runtime.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
    return runtime


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--det-data", default="datasets/tiles_det/data.yaml")
    parser.add_argument("--cls-data", default="datasets/tiles_cls")
    parser.add_argument("--output", default="runs/rummikub")
    parser.add_argument("--device", default="0")
    parser.add_argument("--det-model", default="yolo11s.pt")
    parser.add_argument("--cls-model", default="yolo11s-cls.pt")
    parser.add_argument("--det-epochs", type=int, default=60)
    parser.add_argument("--cls-epochs", type=int, default=40)
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()

    output = Path(args.output)
    det_data = portable_detection_yaml(Path(args.det_data))
    YOLO(args.det_model).train(
        data=str(det_data),
        epochs=args.det_epochs,
        imgsz=1024,
        batch=-1,
        device=args.device,
        workers=args.workers,
        project=str(output),
        name="detect",
        patience=15,
        close_mosaic=10,
    )
    YOLO(args.cls_model).train(
        data=args.cls_data,
        epochs=args.cls_epochs,
        imgsz=224,
        batch=-1,
        device=args.device,
        workers=args.workers,
        project=str(output),
        name="classify",
        patience=10,
        # Rotation/photometric variety is already baked into the dataset by
        # make_classifier_dataset.py (ultralytics' classification pipeline ignores
        # `degrees`). Anything that could change ink color or hide the digit would
        # corrupt the 4 color classes, so it is disabled. Flips are off because
        # mirrored digits are different glyphs.
        auto_augment=None,
        erasing=0.0,
        hsv_h=0.0,
        hsv_s=0.2,
        hsv_v=0.3,
        fliplr=0.0,
        flipud=0.0,
        scale=0.15,
    )
    print(f"Detector: {output / 'detect/weights/best.pt'}")
    print(f"Classifier: {output / 'classify/weights/best.pt'}")


if __name__ == "__main__":
    main()
