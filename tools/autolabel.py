#!/usr/bin/env python3
"""Pre-label new photos with the detector + classifier for quick human review."""

from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image
from ultralytics import YOLO
import yaml

from tile_crops import load_photo, workflow_view

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}


def expanded_crop(image: Image.Image, box: list[float]) -> Image.Image:
    """Exactly what the Roboflow Workflow feeds the classifier."""
    return workflow_view(image, tuple(box))


def to_yolo(box: list[float], width: int, height: int, class_id: int) -> str:
    x1, y1, x2, y2 = box
    return (
        f"{class_id} {(x1+x2)/2/width:.6f} {(y1+y2)/2/height:.6f} "
        f"{(x2-x1)/width:.6f} {(y2-y1)/height:.6f}"
    )


def upload_predictions(
    output: Path,
    workspace_name: str,
    detector_project: str,
    classifier_project: str,
    batch: str,
) -> None:
    key = os.environ.get("ROBOFLOW_API_KEY")
    if not key:
        raise SystemExit("Set ROBOFLOW_API_KEY to upload predictions.")
    try:
        from roboflow import Roboflow
    except ImportError as error:
        raise SystemExit("Install the upload client: pip install roboflow") from error
    workspace = Roboflow(api_key=key).workspace(workspace_name)
    detector = workspace.project(detector_project)
    classifier = workspace.project(classifier_project)
    for image_path in sorted((output / "images").iterdir()):
        label = output / "detector_labels" / f"{image_path.stem}.txt"
        detector.upload(
            image_path=str(image_path),
            annotation_path=str(label),
            split="train",
            batch_name=batch,
            is_prediction=True,
            num_retry_uploads=2,
        )
    manifest = json.loads((output / "predictions.json").read_text(encoding="utf-8"))
    for item in manifest:
        for tile in item["tiles"]:
            classifier.upload(
                image_path=str(output / tile["crop"]),
                annotation_path=tile["class"],
                split="train",
                batch_name=batch,
                is_prediction=True,
                num_retry_uploads=2,
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--detector", required=True)
    parser.add_argument("--classifier", required=True)
    parser.add_argument("--classes", type=Path, default=Path("your_dataset/data.yaml"))
    parser.add_argument("--out", type=Path, default=Path("autolabeled"))
    parser.add_argument("--det-conf", type=float, default=0.20)
    parser.add_argument("--review-conf", type=float, default=0.75)
    parser.add_argument("--device", default=None)
    parser.add_argument("--workspace", default="matan-kronfeld")
    parser.add_argument("--det-project", default="rummikub-tiles-qu08l")
    parser.add_argument("--cls-project", default="rummikub-tile-cls")
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--batch", default=None)
    args = parser.parse_args()

    files = (
        [args.input]
        if args.input.is_file()
        else sorted(path for path in args.input.iterdir() if path.suffix.lower() in IMAGE_SUFFIXES)
    )
    if not files:
        raise SystemExit(f"No images found in {args.input}")
    detector, classifier = YOLO(args.detector), YOLO(args.classifier)
    class_names = yaml.safe_load(args.classes.read_text(encoding="utf-8"))["names"]
    output_class_ids = {str(name): index for index, name in enumerate(class_names)}
    for folder in ("images", "labels", "detector_labels", "crops"):
        (args.out / folder).mkdir(parents=True, exist_ok=True)
    manifest = []

    for image_path in files:
        image = load_photo(image_path)
        output_image = args.out / "images" / f"{image_path.stem}.jpg"
        image.save(output_image, quality=95)
        result = detector.predict(
            image, imgsz=1024, conf=args.det_conf, device=args.device, verbose=False
        )[0]
        boxes = result.boxes.xyxy.cpu().numpy().tolist()
        det_confidences = result.boxes.conf.cpu().numpy().tolist()
        final_lines, detector_lines, tiles = [], [], []
        for index, (box, det_confidence) in enumerate(zip(boxes, det_confidences)):
            crop = expanded_crop(image, box)
            classified = classifier.predict(
                crop, imgsz=224, device=args.device, verbose=False
            )[0]
            classifier_id = int(classified.probs.top1)
            cls_confidence = float(classified.probs.top1conf)
            class_name = str(classified.names[classifier_id])
            if class_name not in output_class_ids:
                raise SystemExit(
                    f'Classifier returned unknown class "{class_name}"; '
                    f"check {args.classes}."
                )
            class_id = output_class_ids[class_name]
            crop_rel = Path("crops") / f"{image_path.stem}_{index:03d}_{class_name}.jpg"
            crop.save(args.out / crop_rel, quality=95)
            final_lines.append(to_yolo(box, image.width, image.height, class_id))
            detector_lines.append(to_yolo(box, image.width, image.height, 0))
            tiles.append(
                {
                    "class": class_name,
                    "class_id": class_id,
                    "detection_confidence": round(det_confidence, 6),
                    "classification_confidence": round(cls_confidence, 6),
                    "needs_review": cls_confidence < args.review_conf,
                    "box_xyxy": [round(value, 2) for value in box],
                    "crop": crop_rel.as_posix(),
                }
            )
        (args.out / "labels" / f"{image_path.stem}.txt").write_text(
            "\n".join(final_lines) + ("\n" if final_lines else ""), encoding="utf-8"
        )
        (args.out / "detector_labels" / f"{image_path.stem}.txt").write_text(
            "\n".join(detector_lines) + ("\n" if detector_lines else ""), encoding="utf-8"
        )
        manifest.append({"image": output_image.name, "tiles": tiles})

    (args.out / "predictions.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )
    review_count = sum(tile["needs_review"] for item in manifest for tile in item["tiles"])
    print(f"Labeled {len(files)} images; {review_count} low-confidence crops need review.")
    if args.upload:
        batch = args.batch or datetime.now(timezone.utc).strftime("autolabel-%Y%m%d-%H%M%S")
        upload_predictions(
            args.out, args.workspace, args.det_project, args.cls_project, batch
        )
        print(f"Uploaded as prediction batch {batch}.")


if __name__ == "__main__":
    main()
