import math

import pytest
from fastapi import HTTPException

from main import vision_group
from models import TileColor
from vision_grouping import (
    GroupingOptions,
    group_vision_detections,
    parse_detections,
    parse_tile_label,
)


def _box(
    label: str,
    x: float,
    y: float,
    *,
    width: float = 40,
    height: float = 60,
    confidence: float = 0.9,
    detection_id: str | None = None,
) -> dict:
    result = {
        "class": label,
        "x": x,
        "y": y,
        "width": width,
        "height": height,
        "confidence": confidence,
    }
    if detection_id:
        result["detection_id"] = detection_id
    return result


@pytest.mark.parametrize(
    ("label", "color", "value"),
    [
        ("Red7", TileColor.RED, 7),
        ("blue_13", TileColor.BLUE, 13),
        (" Black-1 ", TileColor.BLACK, 1),
        ("Orange4", TileColor.YELLOW, 4),
        ("yellow 12", TileColor.YELLOW, 12),
        ("Joker", TileColor.JOKER, 0),
        ("jokers", TileColor.JOKER, 0),
    ],
)
def test_parse_tile_label_accepts_model_names(label, color, value):
    parsed = parse_tile_label(label)

    assert parsed is not None
    assert (parsed.color, parsed.value) == (color, value)


@pytest.mark.parametrize("label", ["", "purple4", "red0", "blue14", "tile"])
def test_parse_tile_label_rejects_unmapped_or_out_of_range_labels(label):
    assert parse_tile_label(label) is None


def test_parses_nested_roboflow_response_and_percentage_confidence():
    payload = {
        "outputs": [
            {
                "visualization": {"predictions": [_box("not-a-tile", 1, 1)]},
                "tile_predictions": {
                    "predictions": [
                        _box("Red1", 20, 30, confidence=87),
                        _box("Red2", 70, 30, confidence=12),
                    ]
                },
            }
        ]
    }

    detections = parse_detections(payload)

    assert [d.label for d in detections] == ["Red1", "Red2"]
    assert [d.confidence for d in detections] == pytest.approx([0.87, 0.12])


def test_parses_corner_bbox_geometry():
    detections = parse_detections(
        [
            {
                "class_name": "Blue5",
                "bbox": {"left": 10, "top": 20, "right": 50, "bottom": 80},
            }
        ]
    )

    assert len(detections) == 1
    assert (detections[0].x, detections[0].y) == (30, 50)
    assert (detections[0].width, detections[0].height) == (40, 60)


def test_groups_rows_despite_small_vertical_jitter_and_sorts_left_to_right():
    payload = [
        _box("Red3", 120, 103, detection_id="three"),
        _box("Red1", 20, 100, detection_id="one"),
        _box("Red2", 70, 97, detection_id="two"),
    ]

    result = group_vision_detections(payload)

    assert len(result["board_melds"]) == 1
    meld = result["board_melds"][0]
    assert meld["detection_ids"] == ["one", "two", "three"]
    assert meld["type"] == "RUN"
    assert meld["is_valid"] is True
    assert meld["score"] > 0.9


def test_large_horizontal_gap_splits_two_board_melds():
    payload = [
        _box("Red1", 20, 100),
        _box("Red2", 65, 100),
        _box("Red3", 110, 100),
        _box("Blue8", 210, 100),
        _box("Black8", 255, 100),
        _box("Orange8", 300, 100),
    ]

    result = group_vision_detections(payload)

    assert len(result["board_melds"]) == 2
    assert [meld["type"] for meld in result["board_melds"]] == ["RUN", "GROUP"]
    assert all(meld["is_valid"] for meld in result["board_melds"])


def test_explicit_boundary_classifies_multiple_rack_rows():
    payload = [
        _box("Red1", 20, 80),
        _box("Red2", 65, 80),
        _box("Red3", 110, 80),
        _box("Blue1", 20, 300),
        _box("Blue2", 65, 300),
        _box("Black7", 20, 380),
    ]

    result = group_vision_detections(
        payload, options=GroupingOptions(rack_boundary_y=250)
    )

    assert result["metadata"]["rack_classification"] == "explicit_boundary"
    assert result["metadata"]["rack_row_count"] == 2
    assert [len(row["detection_ids"]) for row in result["rack_rows"]] == [2, 1]
    assert len(result["board_melds"]) == 1


def test_image_height_classifies_only_bottom_region_as_rack():
    result = group_vision_detections(
        [
            _box("Red1", 20, 100),
            _box("Red2", 65, 100),
            _box("Red3", 110, 100),
            _box("Blue4", 20, 820),
        ],
        options=GroupingOptions(image_height=1000),
    )

    assert result["metadata"]["rack_classification"] == "image_bottom_region"
    assert result["rack_rows"][0]["detection_ids"] == ["d3"]


def test_detached_bottom_row_is_conservatively_inferred_as_rack():
    result = group_vision_detections(
        [
            _box("Red1", 20, 80),
            _box("Red2", 65, 80),
            _box("Red3", 110, 80),
            _box("Blue1", 20, 160),
            _box("Blue2", 65, 160),
            _box("Blue3", 110, 160),
            _box("Black5", 20, 500),
        ]
    )

    assert result["metadata"]["rack_classification"] == "inferred_vertical_gap"
    assert result["rack_rows"][0]["detection_ids"] == ["d6"]


def test_unknown_and_malformed_detections_are_never_dropped():
    payload = [
        _box("mystery", 20, 100, confidence=0.01),
        {"class": "Red7"},
    ]

    result = group_vision_detections(payload)

    assert result["metadata"]["detection_count"] == 2
    assert result["metadata"]["all_detections_retained"] is True
    assert result["unassigned_detection_ids"] == ["d1"]
    assert result["board_melds"][0]["detection_ids"] == ["d0"]
    assert result["board_melds"][0]["validation_applied"] is False


def test_duplicate_source_ids_are_made_unique_without_dropping_boxes():
    payload = [
        _box("Red1", 20, 100, detection_id="same"),
        _box("Red2", 65, 100, detection_id="same"),
    ]

    result = group_vision_detections(payload)

    assert [item["id"] for item in result["detections"]] == ["same", "same-1"]
    assert "duplicate detection id" in result["detections"][1]["parse_warnings"][0]


def test_invalid_candidate_is_annotated_but_retained():
    result = group_vision_detections(
        [
            _box("Red1", 20, 100),
            _box("Blue2", 65, 100),
            _box("Black3", 110, 100),
        ]
    )

    assert len(result["board_melds"]) == 1
    assert result["board_melds"][0]["type"] == "INVALID"
    assert result["board_melds"][0]["is_valid"] is False
    assert result["board_melds"][0]["detection_ids"] == ["d0", "d1", "d2"]


def test_group_endpoint_accepts_wrapped_response_and_options():
    result = vision_group(
        {
            "response": {"predictions": [_box("Red1", 20, 800)]},
            "options": {"image_height": 1000},
        }
    )

    assert result["metadata"]["detection_count"] == 1
    assert result["rack_rows"][0]["detection_ids"] == ["d0"]


def test_group_endpoint_rejects_unknown_option():
    with pytest.raises(HTTPException) as raised:
        vision_group({"predictions": [], "options": {"magic": 1}})

    assert raised.value.status_code == 400


def _rotated_meld(
    labels: list[str],
    start: tuple[float, float],
    angle_degrees: float,
    *,
    pitch: float = 42,
    tile_width: float = 40,
    tile_height: float = 60,
    prefix: str = "t",
) -> list[dict]:
    """Tiles laid along ``angle_degrees``; boxes are the axis-aligned bounds of
    the rotated tiles, so they grow and overlap like real detections."""
    theta = math.radians(angle_degrees)
    cos, sin = math.cos(theta), math.sin(theta)
    box_w = tile_width * abs(cos) + tile_height * abs(sin)
    box_h = tile_width * abs(sin) + tile_height * abs(cos)
    return [
        _box(
            label,
            start[0] + index * pitch * cos,
            start[1] + index * pitch * sin,
            width=box_w,
            height=box_h,
            detection_id=f"{prefix}{index}-{label}",
        )
        for index, label in enumerate(labels)
    ]


def test_diagonal_run_groups_into_one_ordered_meld():
    payload = _rotated_meld(["Red4", "Red5", "Red6"], (200, 200), 40)
    payload = [payload[2], payload[0], payload[1]]  # shuffled input

    result = group_vision_detections(payload)

    assert len(result["board_melds"]) == 1
    meld = result["board_melds"][0]
    assert meld["detection_ids"] == ["t0-Red4", "t1-Red5", "t2-Red6"]
    assert meld["type"] == "RUN"
    assert meld["is_valid"] is True
    assert meld["angle_degrees"] == pytest.approx(40, abs=0.5)
    assert result["metadata"]["board_row_count"] == 1


def test_run_rotated_180_degrees_is_returned_ascending_and_valid():
    # Laid out up-left from the start: reading left to right gives 6, 5, 4.
    payload = _rotated_meld(["Red4", "Red5", "Red6"], (300, 300), 220)

    result = group_vision_detections(payload)

    assert len(result["board_melds"]) == 1
    meld = result["board_melds"][0]
    assert meld["detection_ids"] == ["t0-Red4", "t1-Red5", "t2-Red6"]
    assert meld["type"] == "RUN"
    assert meld["is_valid"] is True
    assert meld["angle_degrees"] == pytest.approx(40, abs=0.5)


def test_vertical_meld_groups_top_to_bottom():
    payload = _rotated_meld(["Blue9", "Blue10", "Blue11", "Blue12"], (150, 100), 90)

    result = group_vision_detections(payload)

    assert len(result["board_melds"]) == 1
    meld = result["board_melds"][0]
    assert meld["detection_ids"] == [
        "t0-Blue9",
        "t1-Blue10",
        "t2-Blue11",
        "t3-Blue12",
    ]
    assert meld["type"] == "RUN"
    assert meld["is_valid"] is True
    assert meld["angle_degrees"] == pytest.approx(90)


def test_two_angled_melds_and_two_loose_tiles_are_separated():
    payload = [
        *_rotated_meld(["Red1", "Red2", "Red3"], (100, 100), 25, prefix="a"),
        *_rotated_meld(["Blue7", "Black7", "Orange7"], (600, 350), 130, prefix="b"),
        _box("Black5", 300, 650, detection_id="single1"),
        _box("Orange11", 800, 700, width=60, height=40, detection_id="single2"),
    ]

    result = group_vision_detections(
        payload, options=GroupingOptions(rack_boundary_y=10_000)
    )

    melds = result["board_melds"]
    assert len(melds) == 4
    assert result["metadata"]["board_row_count"] == 4
    assert sorted(len(m["detection_ids"]) for m in melds) == [1, 1, 3, 3]
    by_size = {frozenset(m["detection_ids"]): m for m in melds}
    run = by_size[frozenset({"a0-Red1", "a1-Red2", "a2-Red3"})]
    assert run["type"] == "RUN" and run["is_valid"]
    group = by_size[frozenset({"b0-Blue7", "b1-Black7", "b2-Orange7"})]
    assert group["type"] == "GROUP" and group["is_valid"]
    assert {frozenset({"single1"}), frozenset({"single2"})} <= set(by_size)
    assert by_size[frozenset({"single1"})]["angle_degrees"] == 0.0


def test_touching_parallel_rows_are_split_by_perpendicular_clustering():
    payload = [
        *[
            _box(f"Red{n}", 20 + 40 * (n - 1), 100, detection_id=f"top{n}")
            for n in range(1, 5)
        ],
        *[
            _box(f"Black{n}", 20 + 40 * (n - 3), 160, detection_id=f"bottom{n}")
            for n in range(3, 7)
        ],
    ]

    result = group_vision_detections(payload)

    assert result["metadata"]["board_row_count"] == 1  # one touching component
    melds = result["board_melds"]
    assert len(melds) == 2
    assert [m["detection_ids"] for m in melds] == [
        ["top1", "top2", "top3", "top4"],
        ["bottom3", "bottom4", "bottom5", "bottom6"],
    ]
    assert all(m["type"] == "RUN" and m["is_valid"] for m in melds)
    assert all("angle_degrees" in m for m in melds)
