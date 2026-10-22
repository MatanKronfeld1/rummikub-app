#!/usr/bin/env python3
"""Evaluate detector, classifier, and exact-image accuracy on held-out photos."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import yaml
from PIL import Image
from ultralytics import YOLO

from tile_crops import load_photo, workflow_view


def iou(a: np.ndarray, b: np.ndarray) -> float:
    x1, y1 = np.maximum(a[:2], b[:2])
    x2, y2 = np.minimum(a[2:], b[2:])
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    union = (
        max(0.0, a[2] - a[0]) * max(0.0, a[3] - a[1])
        + max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])
        - intersection
    )
    return intersection / union if union else 0.0


def ground_truth(label_path: Path, width: int, height: int) -> list[tuple[int, np.ndarray]]:
    result = []
    for line in label_path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        class_id = int(parts[0])
        xc, yc, bw, bh = (float(value) for value in parts[1:5])
        result.append(
            (
                class_id,
                np.array(
                    [
                        (xc - bw / 2) * width,
                        (yc - bh / 2) * height,
                        (xc + bw / 2) * width,
                        (yc + bh / 2) * height,
                    ]
                ),
            )
        )
    return result


def classifier_crop(image: Image.Image, box: np.ndarray) -> Image.Image:
    """Exactly what the Roboflow Workflow feeds the classifier."""
    return workflow_view(image, tuple(float(v) for v in box))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--detector", required=True)
    parser.add_argument("--classifier", required=True)
    parser.add_argument("--source", default="your_dataset/train")
    parser.add_argument("--split-file", default="datasets/tiles_det/split.txt")
    parser.add_argument("--classes", default="your_dataset/data.yaml")
    parser.add_argument("--iou", type=float, default=0.5)
    parser.add_argument("--conf", type=float, default=0.25)
    parser.add_argument("--device", default=None)
    args = parser.parse_args()

    names = yaml.safe_load(Path(args.classes).read_text(encoding="utf-8"))["names"]
    val_stems = {
        parts[2]
        for line in Path(args.split_file).read_text(encoding="utf-8").splitlines()
        if len(parts := line.split("\t")) == 3 and parts[0] == "val"
    }
    detector, classifier = YOLO(args.detector), YOLO(args.classifier)
    image_dir, label_dir = Path(args.source) / "images", Path(args.source) / "labels"
    total_gt = matched = class_correct = exact_images = image_count = 0

    for label_path in sorted(label_dir.glob("*.txt")):
        if label_path.stem not in val_stems:
            continue
        image_path = next(
            (path for suffix in (".jpg", ".jpeg", ".png") if
             (path := image_dir / f"{label_path.stem}{suffix}").exists()),
            None,
        )
        if image_path is None:
            continue
        image = load_photo(image_path)
        gt = ground_truth(label_path, *image.size)
        prediction = detector.predict(
            image, imgsz=1024, conf=args.conf, device=args.device, verbose=False
        )[0]
        boxes = prediction.boxes.xyxy.cpu().numpy()
        unused = set(range(len(boxes)))
        image_ok = len(boxes) == len(gt)
        total_gt += len(gt)

        for class_id, gt_box in gt:
            candidates = [(iou(gt_box, boxes[index]), index) for index in unused]
            best_iou, best_index = max(candidates, default=(0.0, -1))
            if best_iou < args.iou:
                image_ok = False
                continue
            unused.remove(best_index)
            matched += 1
            crop = classifier_crop(image, boxes[best_index])
            classified = classifier.predict(
                crop, imgsz=224, device=args.device, verbose=False
            )[0]
            predicted_name = classified.names[int(classified.probs.top1)]
            if predicted_name == names[class_id]:
                class_correct += 1
            else:
                image_ok = False
        if unused:
            image_ok = False
        exact_images += int(image_ok)
        image_count += 1

    print(f"Detector recall@IoU{args.iou:.2f}: {matched}/{total_gt} = {matched/max(1,total_gt):.3f}")
    print(f"Classifier top-1 on matched crops: {class_correct}/{matched} = {class_correct/max(1,matched):.3f}")
    print(f"Exact all-tiles-correct images: {exact_images}/{image_count} = {exact_images/max(1,image_count):.3f}")


if __name__ == "__main__":
    main()
