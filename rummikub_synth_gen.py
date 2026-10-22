#!/usr/bin/env python3
"""
rummikub_synth_gen.py
======================
Generates realistic synthetic Rummikub RACK datasets: tiles are pasted into
the two shelf grooves of real photos of an empty rack, at random slot
positions, with random classes/tilt/lighting - and matching YOLO labels are
written out automatically.

------------------------------------------------------------------------
EXPECTED INPUT FORMAT (Roboflow "YOLOv8" export) for the `extract` step
------------------------------------------------------------------------
your_dataset/
  data.yaml            <- contains a `names:` list, e.g. ['1_black','1_blue',...]
  train/
    images/*.jpg
    labels/*.txt       <- one line per box: "class_id x_center y_center w h" (normalized 0-1)

------------------------------------------------------------------------
INSTALL
------------------------------------------------------------------------
pip install pillow numpy pyyaml opencv-python-headless matplotlib ultralytics
# `--bg-removal sam` (the default) uses Segment Anything. Each existing YOLO
# box is a prompt, so the cutout follows the tile instead of the table color.
# The first run downloads mobile_sam.pt.
# `--bg-removal grabcut` is the fast classical fallback.
# `--bg-removal rembg` needs a separate `pip install rembg`.
# matplotlib is only needed for calibrate_rack.py (needs a display).

------------------------------------------------------------------------
LAYOUT IN THIS REPO
------------------------------------------------------------------------
your_dataset/train/images + labels   real labeled photos
your_dataset/data.yaml                class names
backgrounds/                          empty-rack photos (not rack_photos/)
rack_coords.yaml                      shelf calibration, keyed by filename stem
tiles_extracted/                      output of `extract`
synthetic_dataset/                    output of `generate`

------------------------------------------------------------------------
USAGE
------------------------------------------------------------------------
# Step 0 (once per new background photo): calibrate the two shelf rows.
# Needs a desktop window. The four photos already in backgrounds/ are
# pre-filled in rack_coords.yaml.
python calibrate_rack.py --image backgrounds/IMG_4484.jpeg --coords-file rack_coords.yaml

# Step 1: extract every tile instance from the real labeled photos
python rummikub_synth_gen.py extract --dataset ./your_dataset/train --classes ./your_dataset/data.yaml --out ./tiles_extracted --bg-removal sam

# Step 2: generate synthetic rack images + YOLO labels
python rummikub_synth_gen.py generate --tiles ./tiles_extracted --backgrounds ./backgrounds --rack-coords rack_coords.yaml --classes ./your_dataset/data.yaml --out ./synthetic_dataset --num-images 800

# Or generate freely oriented melds on arbitrary table/background photos
python rummikub_synth_gen.py generate-board --tiles ./tiles_extracted --backgrounds ./tables --classes ./your_dataset/data.yaml --out ./board_dataset --num-images 800 --seed 123
"""

import argparse
import contextlib
import io
import random
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

try:
    import yaml
except ImportError:
    yaml = None

try:
    # Optional. A partial rembg install prints an error and calls sys.exit
    # when its onnxruntime backend is missing. That must not block GrabCut.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from rembg import remove as rembg_remove
    HAVE_REMBG = True
except (ImportError, SystemExit, OSError, RuntimeError):
    rembg_remove = None
    HAVE_REMBG = False

try:
    import cv2
    HAVE_CV2 = True
except ImportError:
    HAVE_CV2 = False

# Fallback used only if no rack_coords.yaml is supplied and no filename match
# is found. Calibrate your own photos with calibrate_rack.py instead of
# relying on this - it's an average of 4 sample photos and will be off for
# any new photo's exact framing.
DEFAULT_RACK_COORDS = (0.070, 0.930, 0.270, 0.420, 0.420, 0.570)


# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------

def load_class_names(classes_yaml_path):
    if yaml is None:
        sys.exit("Please run: pip install pyyaml")
    with open(classes_yaml_path, "r") as f:
        data = yaml.safe_load(f)
    names = data.get("names")
    if isinstance(names, dict):
        names = [names[i] for i in sorted(names.keys())]
    if not names:
        sys.exit(f"Could not find a `names` list in {classes_yaml_path}")
    return names


def load_rack_coords(rack_coords_path):
    """Returns dict: key (filename stem or 'default') -> 6-tuple of normalized coords."""
    if rack_coords_path is None:
        return {"default": DEFAULT_RACK_COORDS}
    if yaml is None:
        sys.exit("Please run: pip install pyyaml")
    path = Path(rack_coords_path)
    if not path.exists():
        sys.exit(f"--rack-coords file not found: {path}. Run calibrate_rack.py first.")
    with open(path) as f:
        raw = yaml.safe_load(f) or {}
    coords = {k: tuple(v) for k, v in raw.items()}
    coords.setdefault("default", DEFAULT_RACK_COORDS)
    return coords


def yolo_line_to_box(line, img_w, img_h):
    parts = line.strip().split()
    cls_id = int(parts[0])
    xc, yc, w, h = (float(p) for p in parts[1:5])
    xc, yc, w, h = xc * img_w, yc * img_h, w * img_w, h * img_h
    x1, y1 = xc - w / 2, yc - h / 2
    x2, y2 = xc + w / 2, yc + h / 2
    return cls_id, int(round(x1)), int(round(y1)), int(round(x2)), int(round(y2))


def box_to_yolo_line(cls_id, x1, y1, x2, y2, img_w, img_h):
    xc = (x1 + x2) / 2 / img_w
    yc = (y1 + y2) / 2 / img_h
    w = (x2 - x1) / img_w
    h = (y2 - y1) / img_h
    return f"{cls_id} {xc:.6f} {yc:.6f} {w:.6f} {h:.6f}"


def remove_bg_grabcut(pil_img, inner_margin_frac=0.15, iterations=3, max_side=192):
    """Classical background removal (OpenCV GrabCut).

    A plain rectangle init treats the whole tile as only *probably* foreground.
    These tiles are cream on a cream table, so that init keeps the number and
    deletes the tile face. The mask below locks the center as foreground and
    the outer border (the padding added around the YOLO box) as background,
    and lets GrabCut decide only the edge band — which is where a loose box
    still contains a strip of table.

    Crops from 12MP photos are roughly 500x650. GrabCut at that size takes
    several seconds per tile, so the mask is solved on a copy whose long side
    is at most max_side, then scaled back. RGB stays full resolution."""
    rgb = np.array(pil_img.convert("RGB"))
    h, w = rgb.shape[:2]
    if h < 6 or w < 6:
        alpha = np.full((h, w), 255, dtype=np.uint8)
        return Image.fromarray(np.dstack([rgb, alpha]), mode="RGBA")

    scale = min(1.0, max_side / float(max(h, w)))
    if scale < 1.0:
        sw = max(1, int(round(w * scale)))
        sh = max(1, int(round(h * scale)))
        small = cv2.resize(rgb, (sw, sh), interpolation=cv2.INTER_AREA)
    else:
        small = rgb
        sh, sw = h, w

    bgr = np.ascontiguousarray(small[:, :, ::-1])
    mask = np.full((sh, sw), cv2.GC_PR_FGD, np.uint8)
    bx = max(1, int(round(sw * inner_margin_frac * 0.55)))
    by = max(1, int(round(sh * inner_margin_frac * 0.55)))
    mask[:by, :] = cv2.GC_BGD
    mask[-by:, :] = cv2.GC_BGD
    mask[:, :bx] = cv2.GC_BGD
    mask[:, -bx:] = cv2.GC_BGD
    ix = max(bx + 1, int(round(sw * 0.22)))
    iy = max(by + 1, int(round(sh * 0.22)))
    if ix < sw - ix and iy < sh - iy:
        mask[iy:sh - iy, ix:sw - ix] = cv2.GC_FGD

    bgd_model = np.zeros((1, 65), np.float64)
    fgd_model = np.zeros((1, 65), np.float64)
    try:
        cv2.grabCut(
            bgr, mask, (0, 0, sw, sh), bgd_model, fgd_model,
            iterations, cv2.GC_INIT_WITH_MASK,
        )
        alpha = np.where((mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD), 255, 0).astype("uint8")
    except cv2.error:
        alpha = np.full((sh, sw), 255, dtype=np.uint8)
    if (sh, sw) != (h, w):
        alpha = cv2.resize(alpha, (w, h), interpolation=cv2.INTER_LINEAR)
    return Image.fromarray(np.dstack([rgb, alpha]), mode="RGBA")


def load_sam_predictor(model_name, imgsz=640):
    """Load Segment Anything once. Each tile is segmented from its own crop,
    so a small tile still fills the model input instead of disappearing
    inside a downscaled 12MP photo."""
    try:
        from ultralytics.models.sam import Predictor as SAMPredictor
    except ImportError:
        sys.exit("--bg-removal sam requires `pip install ultralytics`")
    return SAMPredictor(overrides={
        "model": model_name,
        "conf": 0.25,
        "imgsz": imgsz,
        "save": False,
        "verbose": False,
        "mode": "predict",
        "task": "segment",
    })


def _box_is_tile_like(rgb_crop):
    """Blank sheet, floor and empty boxes are almost flat. A real tile has a
    number, so its grayscale standard deviation stays well above that."""
    gray = cv2.cvtColor(rgb_crop, cv2.COLOR_RGB2GRAY)
    return float(gray.std()) >= 18.0


def _sam_mask_on_crop(predictor, crop_rgb, local_box):
    bgr = np.ascontiguousarray(crop_rgb[:, :, ::-1])
    predictor.set_image(bgr)
    try:
        results = predictor(bboxes=[[float(v) for v in local_box]])
    finally:
        predictor.reset_image()
    if not results or results[0].masks is None:
        return None
    raw = results[0].masks.data.detach().cpu().numpy()
    if raw.shape[0] < 1:
        return None
    mask = raw[0]
    crop_h, crop_w = crop_rgb.shape[:2]
    if mask.shape != (crop_h, crop_w):
        mask = cv2.resize(mask.astype(np.float32), (crop_w, crop_h), interpolation=cv2.INTER_LINEAR)
    x1, y1, x2, y2 = [int(round(v)) for v in local_box]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(crop_w, x2), min(crop_h, y2)
    if x2 <= x1 or y2 <= y1:
        return None
    clipped = np.zeros((crop_h, crop_w), np.uint8)
    clipped[y1:y2, x1:x2] = (mask[y1:y2, x1:x2] > 0.5).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(clipped, connectivity=8)
    if count <= 1:
        return None
    largest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    area = int(stats[largest, cv2.CC_STAT_AREA])
    if area / max(1, (x2 - x1) * (y2 - y1)) < 0.60:
        return None
    return (labels == largest).astype(np.uint8) * 255


def cut_tile_with_sam(predictor, rgb, box):
    """Cut one labeled tile out of an RGB photo. Returns an RGBA image, or
    None when the box is a blank surface or a sliver rather than a tile."""
    height, width = rgb.shape[:2]
    x1, y1, x2, y2 = box
    x1, y1 = max(0, int(x1)), max(0, int(y1))
    x2, y2 = min(width, int(x2)), min(height, int(y2))
    box_w, box_h = x2 - x1, y2 - y1
    if box_w < 16 or box_h < 16:
        return None
    aspect = box_h / float(box_w)
    if aspect < 0.55 or aspect > 1.85:
        return None
    raw = rgb[y1:y2, x1:x2]
    if not _box_is_tile_like(raw):
        return None

    pad = int(round(0.22 * max(box_w, box_h)))
    cx1, cy1 = max(0, x1 - pad), max(0, y1 - pad)
    cx2, cy2 = min(width, x2 + pad), min(height, y2 + pad)
    crop = rgb[cy1:cy2, cx1:cx2]
    local = (x1 - cx1, y1 - cy1, x2 - cx1, y2 - cy1)
    mask = _sam_mask_on_crop(predictor, crop, local)
    if mask is not None:
        tile = rgba_from_mask(crop, mask)
        if tile is not None:
            return tile

    # The label is already a tile-shaped box. A small inset drops the border
    # strip of table without depending on a mask.
    dx, dy = max(1, int(box_w * 0.04)), max(1, int(box_h * 0.04))
    inner = raw[dy:box_h - dy, dx:box_w - dx]
    if inner.shape[0] < 16 or inner.shape[1] < 16:
        inner = raw
    alpha = np.full(inner.shape[:2], 255, np.uint8)
    return Image.fromarray(np.dstack([inner, alpha]), mode="RGBA")


def rgba_from_mask(rgb, mask):
    """Crop an RGB image to the opaque bounds of a mask."""
    ys, xs = np.where(mask > 0)
    if xs.size < 80:
        return None
    x1, x2 = int(xs.min()), int(xs.max()) + 1
    y1, y2 = int(ys.min()), int(ys.max()) + 1
    alpha = mask[y1:y2, x1:x2]
    color = rgb[y1:y2, x1:x2]
    return Image.fromarray(np.dstack([color, alpha]), mode="RGBA")


# --------------------------------------------------------------------------
# Step 1: EXTRACT - crop every labeled instance out of the real photos
# --------------------------------------------------------------------------

def cmd_extract(args):
    class_names = load_class_names(args.classes)
    images_dir = Path(args.dataset) / "images"
    labels_dir = Path(args.dataset) / "labels"
    out_dir = Path(args.out)

    if not images_dir.exists() or not labels_dir.exists():
        sys.exit(f"Expected {images_dir} and {labels_dir} to exist. "
                  f"Point --dataset at the folder that directly contains images/ and labels/.")

    for name in class_names:
        (out_dir / name).mkdir(parents=True, exist_ok=True)

    counts = {name: 0 for name in class_names}
    rejected = 0
    label_files = sorted(labels_dir.glob("*.txt"))
    if not label_files:
        sys.exit(f"No .txt label files found in {labels_dir}")

    sam_predictor = None
    if args.bg_removal == "sam":
        if not HAVE_CV2:
            sys.exit("--bg-removal sam requires `pip install opencv-python-headless`")
        print(f"Loading Segment Anything ({args.sam_model}). The first run downloads the weights.", flush=True)
        sam_predictor = load_sam_predictor(args.sam_model)

    for label_file in label_files:
        stem = label_file.stem
        img_path = None
        for ext in (".jpg", ".jpeg", ".png", ".JPG", ".JPEG", ".PNG"):
            candidate = images_dir / f"{stem}{ext}"
            if candidate.exists():
                img_path = candidate
                break
        if img_path is None:
            print(f"  [skip] no image found for {label_file.name}")
            continue

        img = Image.open(img_path).convert("RGB")
        img_w, img_h = img.size

        with open(label_file) as f:
            lines = [l for l in f.readlines() if l.strip()]
        print(f"  {img_path.name} ({len(lines)} tiles)", flush=True)

        parsed = []
        for i, line in enumerate(lines):
            cls_id, x1, y1, x2, y2 = yolo_line_to_box(line, img_w, img_h)
            if cls_id < 0 or cls_id >= len(class_names):
                print(f"  [warn] class id {cls_id} out of range in {label_file.name}, skipping")
                continue
            parsed.append((i, cls_id, x1, y1, x2, y2))

        rgb = np.array(img) if args.bg_removal == "sam" else None

        for i, cls_id, x1, y1, x2, y2 in parsed:
            if args.bg_removal == "sam":
                crop = cut_tile_with_sam(sam_predictor, rgb, (x1, y1, x2, y2))
                if crop is None:
                    rejected += 1
                    continue
            else:
                box_w, box_h = x2 - x1, y2 - y1
                # grabcut needs a bit of surrounding context to separate tile from
                # background; a plain crop for no-removal / rembg only needs a
                # couple px of padding.
                pad = max(2, int(0.15 * max(box_w, box_h))) if args.bg_removal == "grabcut" else 2
                x1p, y1p = max(0, x1 - pad), max(0, y1 - pad)
                x2p, y2p = min(img_w, x2 + pad), min(img_h, y2 + pad)
                crop = img.crop((x1p, y1p, x2p, y2p))
                if args.bg_removal == "grabcut":
                    if not HAVE_CV2:
                        sys.exit("--bg-removal grabcut requires `pip install opencv-python-headless`")
                    crop = remove_bg_grabcut(crop)
                elif args.bg_removal == "rembg":
                    if not HAVE_REMBG:
                        sys.exit("--bg-removal rembg requires `pip install rembg`")
                    crop = rembg_remove(crop)

            name = class_names[cls_id]
            counts[name] += 1
            out_path = out_dir / name / f"{stem}_{i}.png"
            crop.save(out_path)

    print("\nExtraction complete. Instances per class:")
    zero_classes = [n for n, c in counts.items() if c == 0]
    for name in class_names:
        print(f"  {name}: {counts[name]}")
    if rejected:
        print(f"\nSkipped {rejected} boxes that were blank, too thin, or not a tile.")
    if zero_classes:
        print(f"\nWARNING: {len(zero_classes)} classes have ZERO real examples: {zero_classes}")
        print("  These need at least one real photographed tile before they can")
        print("  appear in synthetic generation.")


# --------------------------------------------------------------------------
# Step 2: GENERATE (rack mode) - paste tiles into the two shelf grooves
# --------------------------------------------------------------------------

def open_tile_for_paste(path, min_luminance=40):
    """Trim a crop to its opaque silhouette. Drops masks that collapsed to a
    near-black blob (GrabCut kept nothing tile-like)."""
    tile = Image.open(path).convert("RGBA")
    arr = np.array(tile)
    opaque = arr[:, :, 3] > 32
    if int(opaque.sum()) < 80:
        return None
    pixels = arr[:, :, :3][opaque]
    if float(pixels.mean()) < min_luminance:
        return None
    # A real tile carries a number, so some pixels differ from the cream face.
    # Flat sheet, floor and paper scraps do not.
    median = np.median(pixels, axis=0)
    distance = np.abs(pixels.astype(np.int16) - median).max(axis=1)
    if float((distance > 45).mean()) < 0.02:
        return None
    ys, xs = np.where(opaque)
    x1, x2 = int(xs.min()), int(xs.max()) + 1
    y1, y2 = int(ys.min()), int(ys.max()) + 1
    return tile.crop((x1, y1, x2, y2))


def discover_tile_crops(tiles_dir, class_names):
    """Return class-id -> crop paths, in a stable order."""
    tiles_by_class = {}
    for cls_id, name in enumerate(class_names):
        class_dir = Path(tiles_dir) / name
        if class_dir.exists():
            files = sorted(
                list(class_dir.glob("*.png"))
                + list(class_dir.glob("*.jpg"))
                + list(class_dir.glob("*.jpeg"))
            )
            if files:
                tiles_by_class[cls_id] = files
    return tiles_by_class


def parse_tile_class(name):
    """Parse common class names such as Black12, 12_black, or blue-7."""
    compact = re.sub(r"[\s_-]+", "", str(name)).lower()
    if compact in {"joker", "jolly", "wild"}:
        return None
    match = re.fullmatch(r"([a-z]+)(1[0-3]|[1-9])", compact)
    if match:
        return match.group(1), int(match.group(2))
    match = re.fullmatch(r"(1[0-3]|[1-9])([a-z]+)", compact)
    if match:
        return match.group(2), int(match.group(1))
    return None


def choose_meld_class_ids(class_names, available_classes, min_size, max_size, rng):
    """Choose a legal run or group using only classes that have crops."""
    by_color = {}
    by_value = {}
    for cls_id in available_classes:
        parsed = parse_tile_class(class_names[cls_id])
        if parsed is None:
            continue
        color, value = parsed
        by_color.setdefault(color, {})[value] = cls_id
        by_value.setdefault(value, {})[color] = cls_id

    candidates = []
    for values in by_color.values():
        for size in range(min_size, max_size + 1):
            for start in range(1, 15 - size):
                if all(value in values for value in range(start, start + size)):
                    candidates.append(tuple(values[value] for value in range(start, start + size)))

    # A Rummikub group has 3 or 4 distinct colors.
    import itertools
    for colors in by_value.values():
        ids = sorted(colors.values())
        for size in range(max(3, min_size), min(4, max_size, len(ids)) + 1):
            candidates.extend(itertools.combinations(ids, size))

    if not candidates:
        return None
    return list(rng.choice(candidates))


def _styled_tile(tile, size, rng):
    tile = tile.resize(size, Image.LANCZOS)
    tile = ImageEnhance.Brightness(tile).enhance(rng.uniform(0.90, 1.10))
    tile = ImageEnhance.Contrast(tile).enhance(rng.uniform(0.95, 1.05))
    if rng.random() < 0.20:
        tile = tile.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.2, 0.6)))
    return tile


def _make_touching_row(class_ids, tiles_by_class, target_h, rng):
    """Build a touching horizontal row and one marker mask per tile."""
    target_w = max(8, int(round(target_h * 0.72)))
    overlap = max(1, int(round(target_w * rng.uniform(0.01, 0.04))))
    stride = target_w - overlap
    row_w = stride * (len(class_ids) - 1) + target_w
    row = Image.new("RGBA", (row_w, target_h), (0, 0, 0, 0))
    markers = []

    for index, cls_id in enumerate(class_ids):
        crop = None
        for _ in range(8):
            crop = open_tile_for_paste(rng.choice(tiles_by_class[cls_id]))
            if crop is not None:
                break
        if crop is None:
            return None
        tile = _styled_tile(crop, (target_w, target_h), rng)
        x = index * stride
        row.alpha_composite(tile, (x, 0))
        marker = Image.new("L", row.size, 0)
        marker.paste(tile.getchannel("A"), (x, 0))
        markers.append(marker)
    return row, markers


def _rotate_layer(layer, markers, angle):
    rotated = layer.rotate(angle, expand=True, resample=Image.BICUBIC)
    rotated_markers = [
        marker.rotate(angle, expand=True, resample=Image.BICUBIC)
        for marker in markers
    ]
    return rotated, rotated_markers


def _random_non_overlapping_position(layer_size, canvas_size, occupied, rng, attempts=80):
    lw, lh = layer_size
    cw, ch = canvas_size
    if lw > cw or lh > ch:
        return None
    for _ in range(attempts):
        x = rng.randint(0, cw - lw)
        y = rng.randint(0, ch - lh)
        box = (x, y, x + lw, y + lh)
        if all(box[2] <= old[0] or box[0] >= old[2] or
               box[3] <= old[1] or box[1] >= old[3] for old in occupied):
            return x, y, box
    return None


def _paste_labeled_layer(canvas, layer, markers, class_ids, position, yolo_lines):
    px, py = position
    canvas.paste(layer, (px, py), layer)
    cw, ch = canvas.size
    for cls_id, marker in zip(class_ids, markers):
        bbox = marker.getbbox()
        if bbox is None:
            continue
        x1, y1, x2, y2 = bbox
        yolo_lines.append(
            box_to_yolo_line(cls_id, px + x1, py + y1, px + x2, py + y2, cw, ch)
        )


def cmd_generate_board(args):
    """Composite touching meld-like rows onto arbitrary table photographs."""
    class_names = load_class_names(args.classes)
    tiles_by_class = discover_tile_crops(args.tiles, class_names)
    if not tiles_by_class:
        sys.exit(f"No tile crops found under {args.tiles}. Run the `extract` step first.")

    min_meld_size = max(3, args.min_meld_size)
    max_meld_size = min(6, args.max_meld_size)
    if min_meld_size > max_meld_size:
        sys.exit("--min-meld-size must be no greater than --max-meld-size (within 3..6).")
    if args.min_melds < 0 or args.min_melds > args.max_melds:
        sys.exit("--min-melds must be non-negative and no greater than --max-melds.")
    if args.min_loose < 0 or args.min_loose > args.max_loose:
        sys.exit("--min-loose must be non-negative and no greater than --max-loose.")

    rng = random.Random(args.seed)
    backgrounds_dir = Path(args.backgrounds)
    bg_files = sorted(
        p for p in backgrounds_dir.iterdir()
        if p.is_file() and p.suffix.lower() in {".jpg", ".jpeg", ".png"}
    ) if backgrounds_dir.exists() else []
    if not bg_files:
        sys.exit(f"No background images found in {backgrounds_dir}.")

    # Validate up front instead of silently emitting empty board images.
    if choose_meld_class_ids(
        class_names, list(tiles_by_class), min_meld_size, max_meld_size, rng
    ) is None:
        sys.exit("Available crop classes cannot form a 3-6 tile run or group.")
    rng = random.Random(args.seed)

    out_dir = Path(args.out)
    (out_dir / "images").mkdir(parents=True, exist_ok=True)
    (out_dir / "labels").mkdir(parents=True, exist_ok=True)
    available_classes = sorted(tiles_by_class)

    print(f"Generating {args.num_images} synthetic board images...")
    for img_idx in range(args.num_images):
        canvas = Image.open(rng.choice(bg_files)).convert("RGB")
        cw, ch = canvas.size
        occupied = []
        yolo_lines = []
        meld_count = rng.randint(args.min_melds, args.max_melds)

        for _ in range(meld_count):
            class_ids = choose_meld_class_ids(
                class_names, available_classes, min_meld_size, max_meld_size, rng
            )
            if class_ids is None:
                break
            target_h = max(12, int(min(cw, ch) * rng.uniform(0.07, 0.12)))
            made = _make_touching_row(class_ids, tiles_by_class, target_h, rng)
            if made is None:
                continue
            layer, markers = _rotate_layer(*made, rng.uniform(0.0, 360.0))
            placement = _random_non_overlapping_position(layer.size, canvas.size, occupied, rng)
            if placement is None:
                continue
            px, py, box = placement
            occupied.append(box)
            _paste_labeled_layer(canvas, layer, markers, class_ids, (px, py), yolo_lines)

        loose_count = rng.randint(args.min_loose, args.max_loose)
        for _ in range(loose_count):
            cls_id = rng.choice(available_classes)
            target_h = max(12, int(min(cw, ch) * rng.uniform(0.07, 0.12)))
            made = _make_touching_row([cls_id], tiles_by_class, target_h, rng)
            if made is None:
                continue
            layer, markers = _rotate_layer(*made, rng.uniform(0.0, 360.0))
            placement = _random_non_overlapping_position(layer.size, canvas.size, occupied, rng)
            if placement is None:
                continue
            px, py, box = placement
            occupied.append(box)
            _paste_labeled_layer(canvas, layer, markers, [cls_id], (px, py), yolo_lines)

        out_name = f"board_synth_{img_idx:05d}"
        canvas.save(out_dir / "images" / f"{out_name}.jpg", quality=93)
        with open(out_dir / "labels" / f"{out_name}.txt", "w") as f:
            if yolo_lines:
                f.write("\n".join(yolo_lines) + "\n")

    with open(out_dir / "data.yaml", "w") as f:
        f.write("names:\n")
        for name in class_names:
            f.write(f"  - {name}\n")
        f.write(f"nc: {len(class_names)}\n")
        f.write("train: images\n")
    print(f"\nDone. Synthetic board dataset written to: {out_dir}")


def cmd_generate(args):
    class_names = load_class_names(args.classes)
    tiles_dir = Path(args.tiles)
    backgrounds_dir = Path(args.backgrounds)
    rack_coords = load_rack_coords(args.rack_coords)
    out_dir = Path(args.out)
    (out_dir / "images").mkdir(parents=True, exist_ok=True)
    (out_dir / "labels").mkdir(parents=True, exist_ok=True)

    tiles_by_class = {}
    for cls_id, name in enumerate(class_names):
        class_dir = tiles_dir / name
        if class_dir.exists():
            files = list(class_dir.glob("*.png")) + list(class_dir.glob("*.jpg"))
            if files:
                tiles_by_class[cls_id] = files

    if not tiles_by_class:
        sys.exit(f"No tile crops found under {tiles_dir}. Run the `extract` step first.")

    missing = [class_names[i] for i in range(len(class_names)) if i not in tiles_by_class]
    if missing:
        print(f"WARNING: {len(missing)} classes have no crops and will never appear in the "
              f"synthetic set: {missing}\n")

    bg_files = list(backgrounds_dir.glob("*.jpg")) + list(backgrounds_dir.glob("*.png")) + \
        list(backgrounds_dir.glob("*.jpeg")) + list(backgrounds_dir.glob("*.JPG")) + \
        list(backgrounds_dir.glob("*.JPEG"))
    if not bg_files:
        sys.exit(f"No background images found in {backgrounds_dir}.")

    uncalibrated = [p.name for p in bg_files
                    if not any(k != "default" and k in p.stem for k in rack_coords)]
    if uncalibrated:
        print(f"WARNING: {len(uncalibrated)} background photo(s) have no calibration entry and "
              f"will use the 'default' fallback coordinates (likely misaligned): {uncalibrated}")
        print("  Run calibrate_rack.py on them for accurate slot placement.\n")

    available_classes = list(tiles_by_class.keys())

    print(f"Generating {args.num_images} synthetic rack images...")

    for img_idx in range(args.num_images):
        bg_path = random.choice(bg_files)
        canvas = Image.open(bg_path).convert("RGB")
        cw, ch = canvas.size

        profile = rack_coords["default"]
        for key, val in rack_coords.items():
            if key != "default" and key in bg_path.stem:
                profile = val
                break

        x_start_norm, x_end_norm, top_y1_norm, top_y2_norm, bot_y1_norm, bot_y2_norm = profile

        slots_per_row = args.slots_per_row
        total_width_norm = x_end_norm - x_start_norm
        slot_width_norm = total_width_norm / slots_per_row

        yolo_lines = []
        rows = [(top_y1_norm, top_y2_norm), (bot_y1_norm, bot_y2_norm)]

        for row_idx, (y1_n, y2_n) in enumerate(rows):
            target_h = int((y2_n - y1_n) * ch)
            target_w = int(slot_width_norm * cw * 0.95)
            y_base = int(y1_n * ch)
            if target_h <= 0 or target_w <= 0:
                continue

            num_tiles_in_row = random.randint(args.min_tiles, min(args.max_tiles, slots_per_row))
            if random.random() < 0.6:
                start_slot = random.randint(0, slots_per_row - num_tiles_in_row)
                chosen_slots = list(range(start_slot, start_slot + num_tiles_in_row))
            else:
                chosen_slots = sorted(random.sample(range(slots_per_row), num_tiles_in_row))

            for slot in chosen_slots:
                tile_img = None
                cls_id = None
                for _attempt in range(8):
                    cls_id = random.choice(available_classes)
                    tile_path = random.choice(tiles_by_class[cls_id])
                    tile_img = open_tile_for_paste(tile_path)
                    if tile_img is not None:
                        break
                if tile_img is None:
                    continue
                tile_img = tile_img.resize((target_w, target_h), Image.LANCZOS)

                # Simulate the tile sliding slightly behind the rail lip
                crop_bottom = int(target_h * 0.94)
                tile_img = tile_img.crop((0, 0, target_w, crop_bottom))

                tile_img = tile_img.rotate(random.uniform(-1.5, 1.5), expand=True, resample=Image.BICUBIC)
                tile_img = ImageEnhance.Brightness(tile_img).enhance(random.uniform(0.90, 1.10))
                tile_img = ImageEnhance.Contrast(tile_img).enhance(random.uniform(0.95, 1.05))
                if random.random() < 0.25:
                    tile_img = tile_img.filter(ImageFilter.GaussianBlur(radius=random.uniform(0.3, 0.7)))

                tw, th = tile_img.size
                px = int((x_start_norm + slot * slot_width_norm) * cw) + random.randint(-2, 2)
                py = y_base + (target_h - th)
                px = max(0, min(cw - tw, px))
                py = max(0, min(ch - th, py))

                canvas.paste(tile_img, (px, py), tile_img)
                yolo_lines.append(box_to_yolo_line(cls_id, px, py, px + tw, py + th, cw, ch))

        if not yolo_lines:
            continue

        out_name = f"rack_synth_{img_idx:05d}"
        canvas.save(out_dir / "images" / f"{out_name}.jpg", quality=93)
        with open(out_dir / "labels" / f"{out_name}.txt", "w") as f:
            f.write("\n".join(yolo_lines) + "\n")

        if (img_idx + 1) % 50 == 0:
            print(f"  generated {img_idx + 1}/{args.num_images}")

    with open(out_dir / "data.yaml", "w") as f:
        f.write("names:\n")
        for name in class_names:
            f.write(f"  - {name}\n")
        f.write(f"nc: {len(class_names)}\n")
        f.write("train: images\n")

    print(f"\nDone. Synthetic rack dataset written to: {out_dir}")


# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_extract = sub.add_parser("extract", help="Crop labeled instances out of your real photos")
    p_extract.add_argument("--dataset", required=True, help="Folder containing images/ and labels/ (e.g. train/)")
    p_extract.add_argument("--classes", required=True, help="Path to data.yaml with the `names` list")
    p_extract.add_argument("--out", required=True, help="Output folder for cropped tile images, one subfolder per class")
    p_extract.add_argument("--bg-removal", choices=["sam", "grabcut", "rembg", "none"], default="sam",
                            help="How to separate each tile from the photo. "
                                 "'sam' (default) uses Segment Anything with the YOLO box as the prompt. "
                                 "'grabcut' is classical and fast. 'none' keeps the raw rectangle.")
    p_extract.add_argument("--sam-model", default="mobile_sam.pt",
                            help="Ultralytics SAM weights used when --bg-removal sam. "
                                 "mobile_sam.pt is fast on CPU; sam_b.pt is heavier and sharper.")
    p_extract.set_defaults(func=cmd_extract)

    p_generate = sub.add_parser("generate", help="Composite tiles into rack shelf slots with auto-generated YOLO labels")
    p_generate.add_argument("--tiles", required=True, help="Folder produced by the `extract` step")
    p_generate.add_argument("--backgrounds", required=True, help="Folder of empty-rack background photos")
    p_generate.add_argument("--rack-coords", default=None,
                             help="YAML file from calibrate_rack.py mapping filename stems to shelf coordinates. "
                                  "If omitted, all photos use one rough default (not recommended).")
    p_generate.add_argument("--classes", required=True, help="Path to data.yaml with the `names` list")
    p_generate.add_argument("--out", required=True, help="Output folder for the synthetic dataset")
    p_generate.add_argument("--num-images", type=int, default=500)
    p_generate.add_argument("--slots-per-row", type=int, default=13, help="Tile slots per shelf row")
    p_generate.add_argument("--min-tiles", type=int, default=3, help="Min tiles pasted per shelf row")
    p_generate.add_argument("--max-tiles", type=int, default=11, help="Max tiles pasted per shelf row")
    p_generate.set_defaults(func=cmd_generate)

    p_board = sub.add_parser(
        "generate-board",
        help="Composite randomly oriented touching melds onto arbitrary backgrounds",
    )
    p_board.add_argument("--tiles", required=True, help="Folder produced by the `extract` step")
    p_board.add_argument("--backgrounds", required=True, help="Folder of table/background photos")
    p_board.add_argument("--classes", required=True, help="Path to data.yaml with the `names` list")
    p_board.add_argument("--out", required=True, help="Output folder for the synthetic dataset")
    p_board.add_argument("--num-images", type=int, default=500)
    p_board.add_argument("--seed", type=int, default=None, help="Seed for deterministic generation")
    p_board.add_argument("--min-melds", type=int, default=2, help="Minimum touching meld rows per image")
    p_board.add_argument("--max-melds", type=int, default=5, help="Maximum touching meld rows per image")
    p_board.add_argument("--min-meld-size", type=int, default=3, help="Minimum tiles per meld (at least 3)")
    p_board.add_argument("--max-meld-size", type=int, default=6, help="Maximum tiles per meld (at most 6)")
    p_board.add_argument("--min-loose", type=int, default=0, help="Minimum loose single tiles per image")
    p_board.add_argument("--max-loose", type=int, default=3, help="Maximum loose single tiles per image")
    p_board.set_defaults(func=cmd_generate_board)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
