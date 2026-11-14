#!/usr/bin/env python3
"""Sort the tiles of box-corrected photos into class folders for review, then
write the reviewed classes back onto the photos.

sort: crop every box the way the app does (tools/tile_crops.py) and file the
crop under the class the current classifier guesses. A Roboflow export's test
split goes to holdout/, the rest to train/.

    python tools/review_crops.py sort --export datasets/new_photos/batch2_corrected --out autolabeled/batch2_review

Then fix the folders by hand: move a crop into its right class folder, or into
_reject when it is not a readable face-up tile. A crop name starts with the
classifier's confidence (000-100), so sorting a folder by name lists the
doubtful ones first.

collect: write the reviewed classes as 53-class YOLO labels next to a copy of
each photo. That is the --source layout of tools/make_classifier_dataset.py and
tools/make_restyled_dataset.py.

    python tools/review_crops.py collect --review autolabeled/batch2_review --out datasets/new_photos/batch2_labeled

A deleted crop counts as rejected. sort never writes into an existing folder,
so a finished review cannot be overwritten.
"""

from __future__ import annotations

import argparse
import json
import shutil
from collections import Counter
from pathlib import Path

from ultralytics import YOLO

from make_classifier_dataset import IMAGE_SUFFIXES, load_names
from make_detector_v2_dataset import clean_stem
from tile_crops import load_photo, workflow_view

REJECT = "_reject"
MANIFEST = "manifest.json"
COLLECTED = "collected.json"  # marks a collect output, so a rerun may replace it
SMALL_SIDE = 24  # px; a tile this small in the photo is hard to read even for a person


def photo_folders(export: Path) -> list[tuple[str, Path]]:
    """(split, folder) of a Roboflow export, or one flat images/ + labels/ folder."""
    splits = [(s, export / s) for s in ("train", "valid", "test") if (export / s / "images").is_dir()]
    if splits:
        return splits
    if (export / "images").is_dir():
        return [("train", export)]
    raise SystemExit(f"No images/ folder in {export} or in its train/valid/test folders.")


def read_boxes(label: Path) -> list[tuple[float, float, float, float]]:
    """Normalized (xc, yc, w, h) per line; the class id is ignored, polygons become their box."""
    boxes = []
    if not label.exists():
        return boxes
    for line in label.read_text(encoding="utf-8").splitlines():
        values = [float(v) for v in line.split()[1:]]
        if len(values) == 4:
            boxes.append(tuple(values))
        elif len(values) >= 6 and len(values) % 2 == 0:
            xs, ys = values[0::2], values[1::2]
            boxes.append(((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2,
                          max(xs) - min(xs), max(ys) - min(ys)))
        elif values:
            raise SystemExit(f"Cannot read this line of {label}: {line}")
    return boxes


def sort(export: Path, out: Path, classifier: str, classes: Path, holdout: list[str], device) -> None:
    if out.exists():
        raise SystemExit(f"{out} already exists; pick a new --out so a review in progress is never overwritten.")
    names = load_names(classes)
    model = YOLO(classifier)
    unknown = set(model.names.values()) - set(names)
    if unknown:
        raise SystemExit(f"The classifier has classes missing from {classes}: {sorted(unknown)}")

    photos, crops = {}, {}
    for split, folder in photo_folders(export):
        for image_path in sorted(p for p in (folder / "images").iterdir() if p.suffix in IMAGE_SUFFIXES):
            key = clean_stem(image_path.stem)
            if key in photos:
                raise SystemExit(f"Two photos are both named {key}.")
            group = "holdout" if split == "test" or any(h in key for h in holdout) else "train"
            for name in (*names, REJECT):
                (out / group / name).mkdir(parents=True, exist_ok=True)

            image = load_photo(image_path)
            boxes = read_boxes(folder / "labels" / f"{image_path.stem}.txt")
            pixel_boxes = [((xc - w / 2) * image.width, (yc - h / 2) * image.height,
                            (xc + w / 2) * image.width, (yc + h / 2) * image.height)
                           for xc, yc, w, h in boxes]
            views = [workflow_view(image, box) for box in pixel_boxes]
            results = model.predict(views, imgsz=224, device=device, verbose=False) if views else []
            for index, (view, box, result) in enumerate(zip(views, pixel_boxes, results)):
                guess = result.names[int(result.probs.top1)]
                confidence = float(result.probs.top1conf)
                file_name = f"{round(confidence * 100):03d}_{key}__{index:03d}.jpg"
                view.save(out / group / guess / file_name, quality=95)
                crops[file_name] = {
                    "photo": key, "index": index, "group": group, "guess": guess,
                    "confidence": round(confidence, 4),
                    "short_side_px": round(min(box[2] - box[0], box[3] - box[1]), 1),
                }
            photos[key] = {"image": str(image_path.resolve()), "group": group, "boxes": boxes}

    (out / MANIFEST).write_text(json.dumps({"classes": names, "photos": photos, "crops": crops}, indent=1),
                                encoding="utf-8")
    for group in sorted({p["group"] for p in photos.values()}):
        mine = [c for c in crops.values() if c["group"] == group]
        print(f"{group}: {sum(p['group'] == group for p in photos.values())} photos, {len(mine)} crops, "
              f"{sum(c['confidence'] < 0.75 for c in mine)} below 75 % confidence, "
              f"{sum(c['short_side_px'] < SMALL_SIDE for c in mine)} smaller than {SMALL_SIDE} px")
    print(f"Review the class folders in {out}, then run: python tools/review_crops.py collect --review {out} --out <folder>")


def collect(review: Path, out: Path) -> None:
    manifest = json.loads((review / MANIFEST).read_text(encoding="utf-8"))
    names, crops, photos = manifest["classes"], manifest["crops"], manifest["photos"]
    class_ids = {name: index for index, name in enumerate(names)}

    reviewed: dict[str, str] = {}
    for path in sorted(review.glob("*/*/*.jpg")):
        group, folder = path.parent.parent.name, path.parent.name
        crop = crops.get(path.name)
        if crop is None:
            raise SystemExit(f"{path} is not a crop from this review (unknown file name).")
        if folder != REJECT and folder not in class_ids:
            raise SystemExit(f"{path}: {folder} is not a class name.")
        if group != crop["group"]:
            raise SystemExit(f"{path} moved from {crop['group']}/ to {group}/; keep train and holdout apart.")
        if path.name in reviewed:
            raise SystemExit(f"{path.name} is in both {reviewed[path.name]}/ and {folder}/.")
        reviewed[path.name] = folder

    if out.exists():
        if not (out / COLLECTED).exists():
            raise SystemExit(f"{out} exists and was not written by collect; pick a new --out.")
        shutil.rmtree(out)
    by_box = {(c["photo"], c["index"]): name for name, c in crops.items()}
    counts = {group: Counter() for group in {p["group"] for p in photos.values()}}
    for key, photo in photos.items():
        group, image = photo["group"], Path(photo["image"])
        lines = []
        for index, (xc, yc, w, h) in enumerate(photo["boxes"]):
            folder = reviewed.get(by_box[(key, index)])
            if folder is None:
                counts[group]["deleted"] += 1
            elif folder == REJECT:
                counts[group]["rejected"] += 1
            else:
                lines.append(f"{class_ids[folder]} {xc:.6f} {yc:.6f} {w:.6f} {h:.6f}")
                counts[group][folder] += 1
                counts[group]["changed"] += folder != crops[by_box[(key, index)]]["guess"]
        (out / group / "images").mkdir(parents=True, exist_ok=True)
        (out / group / "labels").mkdir(parents=True, exist_ok=True)
        shutil.copy2(image, out / group / "images" / f"{key}{image.suffix}")
        (out / group / "labels" / f"{key}.txt").write_text("\n".join(lines) + ("\n" if lines else ""),
                                                            encoding="utf-8")

    summary = {group: dict(c) for group, c in counts.items()}
    (out / COLLECTED).write_text(json.dumps({"review": str(review.resolve()), "counts": summary}, indent=1),
                                 encoding="utf-8")
    for group, c in sorted(counts.items()):
        tiles = sum(c[name] for name in names)
        missing = [name for name in names if not c[name]]
        print(f"{group}: {sum(p['group'] == group for p in photos.values())} photos, {tiles} labeled tiles "
              f"({c['changed']} changed from the guess), {c['rejected']} rejected, {c['deleted']} deleted")
        if missing:
            print(f"  no tiles of: {', '.join(missing)}")
    print(f"Wrote {out}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    s = commands.add_parser("sort", help="crop and pre-sort the tiles into class folders")
    s.add_argument("--export", type=Path, required=True, help="corrected Roboflow YOLO export (unzipped)")
    s.add_argument("--out", type=Path, required=True)
    s.add_argument("--classifier", default="classify_v2/last.pt")
    s.add_argument("--classes", type=Path, default=Path("your_dataset/data.yaml"))
    s.add_argument("--holdout", nargs="*", default=[],
                   help="photos whose name contains one of these go to holdout/ even outside a test split")
    s.add_argument("--device", default=None)
    c = commands.add_parser("collect", help="write the reviewed classes as YOLO labels")
    c.add_argument("--review", type=Path, required=True)
    c.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "sort":
        sort(args.export, args.out, args.classifier, args.classes, args.holdout, args.device)
    else:
        collect(args.review, args.out)


if __name__ == "__main__":
    main()
