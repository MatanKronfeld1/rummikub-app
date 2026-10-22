from meld_generator import Candidate, generate_candidates
from models import GameState, Set, SetType, Tile, TileColor


def _tile(tile_id: str, color: TileColor, value: int) -> Tile:
    return Tile(id=tile_id, color=color, value=value)


def _run(*tiles: Tile, set_id: str = "board-run") -> Set:
    return Set(id=set_id, type=SetType.RUN, tiles=list(tiles))


def _group(*tiles: Tile, set_id: str = "board-group") -> Set:
    return Set(id=set_id, type=SetType.GROUP, tiles=list(tiles))


def _ids(candidate: Candidate) -> set[str]:
    return set(candidate.id_key)


def _has_ids(candidates: list[Candidate], expected: set[str]) -> bool:
    return any(_ids(candidate) == expected for candidate in candidates)


def test_original_board_run_is_kept_with_its_set_id():
    t7 = _tile("r7", TileColor.RED, 7)
    t8 = _tile("r8", TileColor.RED, 8)
    t9 = _tile("r9", TileColor.RED, 9)
    state = GameState(board=[_run(t7, t8, t9, set_id="keep-me")], rack=[])

    candidates = generate_candidates(state)
    original = next(c for c in candidates if c.original_set_id == "keep-me")

    assert original.kind == SetType.RUN
    assert _ids(original) == {"r7", "r8", "r9"}


def test_extends_red_run_with_rack_ten():
    board = _run(
        _tile("r7", TileColor.RED, 7),
        _tile("r8", TileColor.RED, 8),
        _tile("r9", TileColor.RED, 9),
    )
    rack_ten = _tile("r10", TileColor.RED, 10)
    state = GameState(board=[board], rack=[rack_ten])

    candidates = generate_candidates(state)

    assert _has_ids(candidates, {"r7", "r8", "r9", "r10"})
    extended = next(c for c in candidates if _ids(c) == {"r7", "r8", "r9", "r10"})
    assert extended.kind == SetType.RUN
    assert [tile.value for tile in extended.tiles] == [7, 8, 9, 10]


def test_completes_group_of_fours_from_rack():
    board = _group(
        _tile("black4", TileColor.BLACK, 4),
        _tile("blue4", TileColor.BLUE, 4),
        _tile("red4", TileColor.RED, 4),
    )
    yellow4 = _tile("yellow4", TileColor.YELLOW, 4)
    state = GameState(board=[board], rack=[yellow4])

    candidates = generate_candidates(state)

    assert _has_ids(candidates, {"black4", "blue4", "red4", "yellow4"})
    full = next(c for c in candidates if len(c.tiles) == 4 and c.kind == SetType.GROUP)
    assert full.kind == SetType.GROUP


def test_joker_fills_gap_in_run():
    tiles = [
        _tile("r5", TileColor.RED, 5),
        _tile("j1", TileColor.JOKER, 0),
        _tile("r7", TileColor.RED, 7),
    ]
    state = GameState(board=[], rack=tiles)

    candidates = generate_candidates(state)

    assert _has_ids(candidates, {"r5", "j1", "r7"})
    run = next(c for c in candidates if _ids(c) == {"r5", "j1", "r7"})
    assert run.kind == SetType.RUN
    assert [tile.id for tile in run.tiles] == ["r5", "j1", "r7"]


def test_does_not_wrap_run_from_thirteen_to_one():
    tiles = [
        _tile("r12", TileColor.RED, 12),
        _tile("r13", TileColor.RED, 13),
        _tile("r1", TileColor.RED, 1),
    ]
    state = GameState(board=[], rack=tiles)

    candidates = generate_candidates(state)

    assert not _has_ids(candidates, {"r12", "r13", "r1"})
    assert not any(
        {tile.value for tile in candidate.tiles} == {12, 13, 1}
        and candidate.kind == SetType.RUN
        for candidate in candidates
    )


def test_does_not_invent_tiles_absent_from_the_pool():
    t7 = _tile("r7", TileColor.RED, 7)
    t8 = _tile("r8", TileColor.RED, 8)
    t9 = _tile("r9", TileColor.RED, 9)
    state = GameState(board=[_run(t7, t8, t9)], rack=[])

    pool_ids = {"r7", "r8", "r9"}
    for candidate in generate_candidates(state):
        assert _ids(candidate) <= pool_ids


def test_candidate_never_reuses_the_same_tile_id():
    joker = _tile("j1", TileColor.JOKER, 0)
    state = GameState(
        board=[],
        rack=[
            _tile("r5", TileColor.RED, 5),
            _tile("r6", TileColor.RED, 6),
            joker,
        ],
    )

    for candidate in generate_candidates(state):
        ids = [tile.id for tile in candidate.tiles]
        assert len(ids) == len(set(ids))


def test_joker_substitution_frees_a_natural_tile():
    """A Joker may stand in even when the natural exists, so packing can reuse it."""
    t5 = _tile("r5", TileColor.RED, 5)
    t6 = _tile("r6", TileColor.RED, 6)
    t7 = _tile("r7", TileColor.RED, 7)
    joker = _tile("j1", TileColor.JOKER, 0)
    state = GameState(board=[_run(t5, t6, t7)], rack=[joker])

    candidates = generate_candidates(state)

    assert _has_ids(candidates, {"r5", "r6", "r7"})
    assert any(
        candidate.kind == SetType.RUN
        and "j1" in _ids(candidate)
        and len(candidate.tiles) == 3
        for candidate in candidates
    )


def test_rack_runs_are_listed_before_board_only_runs_after_groups():
    board_run = _run(
        _tile("b1", TileColor.BLUE, 1),
        _tile("b2", TileColor.BLUE, 2),
        _tile("b3", TileColor.BLUE, 3),
        set_id="blue-run",
    )
    # A second blue run using only board tiles is unlikely here; add a red rack
    # run that cannot be formed without rack tiles.
    rack = [
        _tile("r1", TileColor.RED, 1),
        _tile("r2", TileColor.RED, 2),
        _tile("r3", TileColor.RED, 3),
    ]
    state = GameState(board=[board_run], rack=rack)
    candidates = generate_candidates(state)

    original_index = next(
        i for i, c in enumerate(candidates) if c.original_set_id == "blue-run"
    )
    rack_run_index = next(
        i for i, c in enumerate(candidates) if _ids(c) == {"r1", "r2", "r3"}
    )
    assert original_index < rack_run_index


def test_max_candidates_never_drops_original_sets_or_groups():
    board = _group(
        _tile("black4", TileColor.BLACK, 4),
        _tile("blue4", TileColor.BLUE, 4),
        _tile("red4", TileColor.RED, 4),
        set_id="fours",
    )
    # Many run windows from a long red sequence plus a rack tile.
    reds = [_tile(f"r{value}", TileColor.RED, value) for value in range(1, 14)]
    state = GameState(board=[board], rack=reds)

    candidates = generate_candidates(state, max_candidates=1)
    keys = {c.id_key for c in candidates}

    assert any(c.original_set_id == "fours" for c in candidates)
    assert frozenset({"black4", "blue4", "red4"}) in keys
    # Groups are kept even though max_candidates is tiny.
    assert any(c.kind == SetType.GROUP for c in candidates)
