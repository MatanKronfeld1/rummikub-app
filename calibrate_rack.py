#!/usr/bin/env python3
"""
calibrate_rack.py
==================
Click-based calibration tool for empty Rummikub rack background photos.

Instead of guessing normalized (x_start, x_end, top_y1, top_y2, bot_y1, bot_y2)
fractions by eye, this opens the image and lets you click 2 corners per row.
The result is saved into a rack_coords.yaml file that rummikub_synth_gen.py
reads automatically - so adding a 15th background photo takes 10 seconds
instead of manual trial-and-error.

------------------------------------------------------------------------
INSTALL
------------------------------------------------------------------------
pip install matplotlib pillow pyyaml
(needs a display - run this on your own machine, not a headless server)

------------------------------------------------------------------------
USAGE
------------------------------------------------------------------------
python calibrate_rack.py --image backgrounds/IMG_4484.jpeg --coords-file rack_coords.yaml

A window opens. For the TOP row: click the top-left corner of the shelf
area, then the bottom-right corner. Then for the BOTTOM row: same thing.
Close the window (or it closes automatically) and the entry is written/
updated in rack_coords.yaml, keyed by the image's filename stem (e.g.
"IMG_4484"). Run this once per background photo you add.
"""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
from PIL import Image

try:
    import yaml
except ImportError:
    yaml = None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--image", required=True, help="Path to the empty-rack background photo")
    parser.add_argument("--coords-file", default="rack_coords.yaml",
                         help="YAML file to write/update (default: rack_coords.yaml)")
    args = parser.parse_args()

    if yaml is None:
        raise SystemExit("Run: pip install pyyaml")

    img = Image.open(args.image)
    w, h = img.size

    fig, ax = plt.subplots(figsize=(10, 7))
    ax.imshow(img)
    ax.set_title("TOP row: click top-left corner, then bottom-right corner of the shelf")
    plt.tight_layout()
    print("Click the TOP row's top-left corner, then its bottom-right corner...")
    top_pts = plt.ginput(2, timeout=0)

    ax.set_title("BOTTOM row: click top-left corner, then bottom-right corner of the shelf")
    fig.canvas.draw()
    print("Click the BOTTOM row's top-left corner, then its bottom-right corner...")
    bottom_pts = plt.ginput(2, timeout=0)
    plt.close(fig)

    if len(top_pts) != 2 or len(bottom_pts) != 2:
        raise SystemExit("Expected exactly 2 clicks per row - try again.")

    (tx1, ty1), (tx2, ty2) = top_pts
    (bx1, by1), (bx2, by2) = bottom_pts

    x_start = min(tx1, bx1) / w
    x_end = max(tx2, bx2) / w
    top_y1, top_y2 = sorted([ty1 / h, ty2 / h])
    bot_y1, bot_y2 = sorted([by1 / h, by2 / h])

    # ginput returns numpy floats; round() keeps that type, and PyYAML cannot write it.
    entry = [float(round(v, 4)) for v in
             (x_start, x_end, top_y1, top_y2, bot_y1, bot_y2)]

    coords_path = Path(args.coords_file)
    data = {}
    if coords_path.exists():
        with open(coords_path) as f:
            data = yaml.safe_load(f) or {}

    key = Path(args.image).stem
    data[key] = entry
    if "default" not in data:
        data["default"] = entry

    tmp_path = coords_path.with_suffix(coords_path.suffix + ".tmp")
    with open(tmp_path, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=None, sort_keys=False)
    tmp_path.replace(coords_path)

    print(f"\nSaved calibration for '{key}' to {coords_path}:")
    print(f"  {entry}")
    print("(format: [x_start, x_end, top_y1, top_y2, bot_y1, bot_y2], all normalized 0-1)")


if __name__ == "__main__":
    main()
