"""Shared tile-crop geometry so training, evaluation and auto-labeling all feed
the classifier exactly what the Roboflow Workflow feeds it.

Workflow chain (see roboflow/workflow_two_stage.json):

    detector box -> Detection Offset (10 % of width/height, split over both
    sides, i.e. 5 % per side) -> Dynamic Crop (no padding option exists) ->
    classifier

Roboflow resizes the rectangular crop to the model's square input.  Stretching
is what its classification path normally does, while the Ultralytics predictor
resizes the short side and center-crops.  To be robust to either, training
renders most samples stretched and some center-cropped.
"""

from __future__ import annotations

from PIL import Image, ImageOps

# Detection Offset adds 10 % in total; half goes to each side.
OFFSET_PERCENT_TOTAL = 10
MARGIN_PER_SIDE = OFFSET_PERCENT_TOTAL / 200.0
CLS_SIZE = 224


def crop_with_margin(
    image: Image.Image,
    box_xyxy: tuple[float, float, float, float],
    margin: float = MARGIN_PER_SIDE,
) -> Image.Image:
    """Crop a box expanded by ``margin`` per side, clipped to the image."""
    x1, y1, x2, y2 = box_xyxy
    dx, dy = (x2 - x1) * margin, (y2 - y1) * margin
    left, top = max(0, round(x1 - dx)), max(0, round(y1 - dy))
    right, bottom = min(image.width, round(x2 + dx)), min(image.height, round(y2 + dy))
    right, bottom = max(right, left + 1), max(bottom, top + 1)
    return image.crop((left, top, right, bottom))


def stretch_square(image: Image.Image, size: int = CLS_SIZE) -> Image.Image:
    """Non-aspect-preserving resize (what Roboflow's classifier path does)."""
    return image.convert("RGB").resize((size, size), Image.Resampling.BILINEAR)


def center_square(image: Image.Image, size: int = CLS_SIZE) -> Image.Image:
    """Ultralytics-style eval transform: short side to ``size``, center crop."""
    image = image.convert("RGB")
    scale = size / min(image.size)
    resized = image.resize(
        (max(size, round(image.width * scale)), max(size, round(image.height * scale))),
        Image.Resampling.BILINEAR,
    )
    left = (resized.width - size) // 2
    top = (resized.height - size) // 2
    return resized.crop((left, top, left + size, top + size))


def workflow_view(
    image: Image.Image,
    box_xyxy: tuple[float, float, float, float],
    size: int = CLS_SIZE,
) -> Image.Image:
    """The exact image the classifier sees inside the Workflow."""
    return stretch_square(crop_with_margin(image, box_xyxy), size)


def load_photo(path) -> Image.Image:
    return ImageOps.exif_transpose(Image.open(path)).convert("RGB")
