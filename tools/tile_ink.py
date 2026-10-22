"""Find and recolor the printed digit of a Rummikub tile.

Colors were calibrated on the real photos (OpenCV HSV, H 0-179):

    Black   V very low (median 12)
    Blue    H ~85-125 but pale: S only ~20-95  (the old S>70 rule missed it)
    Orange  H ~8-26, S >= ~115 (cream face is S ~66)
    Red     H <= 6 or >= 165, S >= ~105

The analysis is deliberately strict.  A tile that cannot be explained by exactly
one ink color is rejected rather than guessed at, so no mislabeled sample can
be created from it.
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

COLORS = ("Black", "Blue", "Orange", "Red")

BORDER_RING = 0.07  # ignore tile edges / shadows
MIN_AREA_FRAC = 0.025
MAX_AREA_FRAC = 0.45
DOMINANCE = 2.0  # best color must have >= 2x the area of the runner-up


@dataclass
class InkAnalysis:
    color: str
    box: tuple[int, int, int, int]  # x1, y1, x2, y2 inside the analyzed image
    core: np.ndarray  # uint8 mask (region sized), 255 where ink
    face_rgb: np.ndarray  # float32 (3,)
    ink_rgb: np.ndarray  # float32 (3,) median of confident ink pixels
    area_frac: float


def _color_masks(
    hsv: np.ndarray, rgb: np.ndarray, face_rgb: np.ndarray, face_v: float
) -> dict[str, np.ndarray]:
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]
    # White-balance against this tile's own face (warm indoor light makes the
    # face olive and blue ink look gray).  Afterwards the face is neutral, blue
    # ink is the only ink with B clearly above R, black ink stays neutral and
    # red/orange keep R >> B.  This works down to dim, warm photos.
    balanced = np.clip(rgb.astype(np.float32) / np.maximum(face_rgb, 1.0) * 190.0, 0, 255)
    blue_minus_red = balanced[:, :, 2] - balanced[:, :, 0]
    balanced_lum = balanced.mean(axis=2)
    bluish = blue_minus_red >= 12
    masks = {
        "Black": (v < 0.30 * face_v) & ~bluish,
        "Blue": bluish & (balanced_lum >= 38) & (balanced_lum <= 165),
        "Orange": (s >= 115) & (h >= 8) & (h <= 26) & (v >= 70),
        "Red": (s >= 105) & ((h <= 6) | (h >= 165)) & (v >= 40),
    }
    return {name: m.astype(np.uint8) for name, m in masks.items()}


def _keep_ink_components(mask: np.ndarray) -> np.ndarray:
    """Keep digit-sized components that are inside the tile face."""
    height, width = mask.shape
    ring_y, ring_x = int(height * BORDER_RING), int(width * BORDER_RING)
    cleaned = mask.copy()
    cleaned[:ring_y, :] = 0
    cleaned[height - ring_y :, :] = 0
    cleaned[:, :ring_x] = 0
    cleaned[:, width - ring_x :] = 0
    cleaned = cv2.morphologyEx(cleaned, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    count, labels, stats, _ = cv2.connectedComponentsWithStats(cleaned, connectivity=8)
    kept = np.zeros_like(cleaned)
    min_area = max(10, int(0.0025 * height * width))
    for index in range(1, count):
        x, y, w, h, area = stats[index]
        if area < min_area or w > 0.75 * width or h > 0.75 * height:
            continue
        kept[labels == index] = 255
    return kept


def _face_model(region: np.ndarray) -> tuple[np.ndarray, float, np.ndarray] | None:
    """Estimate the tile face color and a mask of the tile itself.

    The face is the bright, large, uniform cluster at the box center.  Pixels
    close to it (in Lab) form the tile; holes (digit, logo) are filled so ink
    is searched only on the tile, never on a table seen in the box corners of a
    rotated tile.
    """
    h, w = region.shape[:2]
    center = region[int(h * 0.25) : int(h * 0.75), int(w * 0.25) : int(w * 0.75)]
    pixels = center.reshape(-1, 3)
    brightness = pixels.max(axis=1)
    bright = pixels[brightness >= np.median(brightness)]
    face_rgb = np.median(bright, axis=0).astype(np.float32)
    face_v = float(face_rgb.max())
    if face_v < 70:  # too dark to judge
        return None

    lab = cv2.cvtColor(region, cv2.COLOR_RGB2LAB).astype(np.float32)
    face_lab = cv2.cvtColor(face_rgb.reshape(1, 1, 3).astype(np.uint8), cv2.COLOR_RGB2LAB)
    distance = np.linalg.norm(lab - face_lab.reshape(1, 1, 3).astype(np.float32), axis=2)
    face_like = (distance < 38).astype(np.uint8)
    face_like = cv2.morphologyEx(face_like, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    count, labels, stats, _ = cv2.connectedComponentsWithStats(face_like, connectivity=8)
    if count <= 1:
        return None
    centre_label = labels[h // 2, w // 2]
    if centre_label == 0:
        centre_label = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    component = (labels == centre_label).astype(np.uint8)
    contours, _ = cv2.findContours(component, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    filled = np.zeros_like(component)
    cv2.drawContours(filled, contours, -1, 1, thickness=cv2.FILLED)
    if filled.sum() < 0.30 * h * w:  # not a tile-sized face
        return None
    edge = max(2, int(0.03 * min(h, w)))
    tile_mask = cv2.erode(filled, np.ones((edge, edge), np.uint8)) > 0
    return face_rgb, face_v, tile_mask


def analyze_tile(rgb: np.ndarray, box: tuple[float, float, float, float]) -> InkAnalysis | None:
    """Return the ink analysis of one tile box, or None if it is not a clean tile."""
    x1, y1, x2, y2 = (int(round(v)) for v in box)
    height, width = rgb.shape[:2]
    x1, y1, x2, y2 = max(0, x1), max(0, y1), min(width, x2), min(height, y2)
    if x2 - x1 < 16 or y2 - y1 < 24:
        return None
    region = rgb[y1:y2, x1:x2]
    h, w = region.shape[:2]
    face = _face_model(region)
    if face is None:
        return None
    face_rgb, face_v, tile_mask = face
    hsv = cv2.cvtColor(region, cv2.COLOR_RGB2HSV)

    masks = {
        name: _keep_ink_components(mask & tile_mask)
        for name, mask in _color_masks(hsv, region, face_rgb, face_v).items()
    }
    areas = {name: int((mask > 0).sum()) for name, mask in masks.items()}
    ranked = sorted(areas, key=areas.get, reverse=True)
    best, runner = ranked[0], ranked[1]
    best_area = areas[best]
    frac = best_area / float(h * w)
    if not MIN_AREA_FRAC <= frac <= MAX_AREA_FRAC:
        return None
    if areas[runner] * DOMINANCE > best_area:
        return None
    core = masks[best]
    ink_pixels = region[core > 0].astype(np.float32)
    ink_rgb = np.median(ink_pixels, axis=0).astype(np.float32)
    return InkAnalysis(best, (x1, y1, x2, y2), core, face_rgb, ink_rgb, frac)


def strong_ink_ratio(rgb: np.ndarray, analysis: InkAnalysis) -> np.ndarray:
    """Ink color as a per-channel ratio to this tile's own face color.

    A ratio is independent of exposure and color cast, so a palette built from
    dim warm photos still renders correctly on a bright photo:
    ``target_rgb = ratio * face_rgb_of_the_tile_being_recolored``.
    """
    x1, y1, x2, y2 = analysis.box
    region = rgb[y1:y2, x1:x2].astype(np.float32)
    pixels = region[analysis.core > 0]
    distance = np.linalg.norm(pixels - analysis.face_rgb, axis=1)
    keep = distance >= np.percentile(distance, 50)
    strong = np.median(pixels[keep], axis=0).astype(np.float32)
    return strong / np.maximum(analysis.face_rgb, 1.0)


def recolor_tile(
    rgb: np.ndarray, analysis: InkAnalysis, target_rgb: np.ndarray
) -> np.ndarray:
    """Return a copy of ``rgb`` where the tile's digit has the target color.

    Soft alpha along the face->ink color line keeps anti-aliased digit edges
    clean, and 60 % of the original lighting variation is kept so the new ink
    still looks like glossy printed plastic.
    """
    x1, y1, x2, y2 = analysis.box
    out = rgb.copy()
    region = rgb[y1:y2, x1:x2].astype(np.float32)
    face, ink = analysis.face_rgb, analysis.ink_rgb
    direction = ink - face
    denom = float(direction @ direction)
    if denom < 400:  # ink indistinguishable from face
        return rgb
    alpha = np.clip(((region - face) @ direction) / denom, 0.0, 1.0)
    zone = cv2.dilate(analysis.core, np.ones((5, 5), np.uint8), iterations=1) > 0
    alpha = np.where(zone, alpha, 0.0)[:, :, None]
    delta = region - ink
    recolored = region + alpha * ((target_rgb - ink) - 0.4 * delta)
    out[y1:y2, x1:x2] = np.clip(recolored, 0, 255).astype(np.uint8)
    return out
