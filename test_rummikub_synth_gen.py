import argparse
import hashlib
from pathlib import Path

from PIL import Image, ImageDraw

from rummikub_synth_gen import (
    choose_meld_class_ids,
    cmd_generate_board,
    parse_tile_class,
)


def _write_tile(path, number):
    image = Image.new("RGBA", (48, 68), (238, 224, 183, 255))
    draw = ImageDraw.Draw(image)
    draw.rectangle((13, 15, 34, 52), fill=(180, 20 + number * 15, 20, 255))
    draw.rectangle((18, 20, 29, 47), fill=(245, 245, 225, 255))
    image.save(path)


def _board_args(root, out, seed=123):
    return argparse.Namespace(
        tiles=str(root / "tiles"),
        backgrounds=str(root / "backgrounds"),
        classes=str(root / "data.yaml"),
        out=str(out),
        num_images=2,
        seed=seed,
        min_melds=1,
        max_melds=1,
        min_meld_size=3,
        max_meld_size=3,
        min_loose=1,
        max_loose=1,
    )


def _fixture_inputs(root):
    (root / "backgrounds").mkdir()
    Image.new("RGB", (360, 280), (70, 110, 80)).save(root / "backgrounds" / "table.jpg")
    names = ["Red1", "Red2", "Red3"]
    (root / "data.yaml").write_text("names: [Red1, Red2, Red3]\n", encoding="utf-8")
    for number, name in enumerate(names, 1):
        class_dir = root / "tiles" / name
        class_dir.mkdir(parents=True)
        _write_tile(class_dir / "crop.png", number)


def _tree_digest(path):
    digest = hashlib.sha256()
    for file_path in sorted(p for p in Path(path).rglob("*") if p.is_file()):
        digest.update(file_path.relative_to(path).as_posix().encode())
        digest.update(file_path.read_bytes())
    return digest.hexdigest()


def test_class_parsing_and_meld_selection_are_legal():
    assert parse_tile_class("Black12") == ("black", 12)
    assert parse_tile_class("7_blue") == ("blue", 7)
    assert parse_tile_class("Joker") is None

    names = ["Red1", "Red2", "Red3", "Blue1"]
    import random
    chosen = choose_meld_class_ids(names, range(4), 3, 3, random.Random(7))
    assert chosen == [0, 1, 2]


def test_generate_board_writes_bounded_labels_and_is_deterministic(tmp_path):
    _fixture_inputs(tmp_path)
    out_a = tmp_path / "out_a"
    out_b = tmp_path / "out_b"

    cmd_generate_board(_board_args(tmp_path, out_a))
    cmd_generate_board(_board_args(tmp_path, out_b))

    assert _tree_digest(out_a) == _tree_digest(out_b)
    labels = sorted((out_a / "labels").glob("*.txt"))
    assert len(labels) == 2
    for label_path in labels:
        lines = label_path.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 4  # one three-tile meld plus one loose tile
        for line in lines:
            parts = line.split()
            assert int(parts[0]) in {0, 1, 2}
            values = [float(value) for value in parts[1:]]
            assert all(0.0 <= value <= 1.0 for value in values)
            assert values[2] > 0.0 and values[3] > 0.0
