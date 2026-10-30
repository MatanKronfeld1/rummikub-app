import json
from pathlib import Path

import pytest

from models import GameState, Set, SetType, Tile, TileColor
from validator import classify_tiles, validate_board, validate_tile_ids

# The Flutter test/validator_parity_test.dart reads the same file, so both
# validators are held to one set of expected answers.
_CASES = json.loads(
    (Path(__file__).parent / "fixtures" / "validator_cases.json").read_text(encoding="utf-8")
)["cases"]


def _tiles(names: list[str]) -> list[Tile]:
    tiles = []
    for index, name in enumerate(names):
        if name == "JOKER":
            tiles.append(Tile(id=f"t{index}", color=TileColor.JOKER, value=0))
            continue
        color = name.rstrip("0123456789")
        tiles.append(Tile(id=f"t{index}", color=TileColor(color), value=int(name[len(color):])))
    return tiles


@pytest.mark.parametrize("case", _CASES, ids=[case["name"] for case in _CASES])
def test_validator_matches_shared_cases(case):
    tiles = _tiles(case["tiles"])

    for declared, expected in case["valid_as"].items():
        board = [Set(id="s", type=SetType(declared), tiles=tiles)]
        is_valid, message = validate_board(board)
        assert is_valid is expected, f"declared {declared}: {message}"
    assert classify_tiles(tiles) == SetType(case["classify"])


def test_first_failing_set_is_reported():
    good = Set(id="good", type=SetType.RUN, tiles=_tiles(["RED1", "RED2", "RED3"]))
    bad = Set(id="bad", type=SetType.GROUP, tiles=_tiles(["RED5", "RED5", "BLUE5"]))

    is_valid, message = validate_board([good, bad])

    assert not is_valid
    assert message.startswith("Set 2 (id=bad)")


def test_repeated_tile_id_is_rejected():
    tile = Tile(id="same", color=TileColor.RED, value=4)
    state = GameState(
        board=[Set(id="s", type=SetType.GROUP, tiles=[
            tile,
            Tile(id="b4", color=TileColor.BLUE, value=4),
            Tile(id="k4", color=TileColor.BLACK, value=4),
        ])],
        rack=[tile],
    )

    is_valid, message = validate_tile_ids(state)

    assert not is_valid
    assert "same" in message
