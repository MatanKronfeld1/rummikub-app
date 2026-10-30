import random
from collections import Counter

import solver
from meld_generator import generate_candidates
from models import GameState, OptimalState, Set, SetType, Tile, TileColor
from validator import validate_board

RED, BLUE, BLACK, YELLOW, JOKER = (
    TileColor.RED,
    TileColor.BLUE,
    TileColor.BLACK,
    TileColor.YELLOW,
    TileColor.JOKER,
)


def _tile(tile_id: str, color: TileColor, value: int) -> Tile:
    return Tile(id=tile_id, color=color, value=value)


def _joker(tile_id: str) -> Tile:
    return Tile(id=tile_id, color=JOKER, value=0)


def _run(set_id: str, *tiles: Tile) -> Set:
    return Set(id=set_id, type=SetType.RUN, tiles=list(tiles))


def _group(set_id: str, *tiles: Tile) -> Set:
    return Set(id=set_id, type=SetType.GROUP, tiles=list(tiles))


def _labels(rummikub_set: Set) -> list[str]:
    return [f"{tile.color.value}{tile.value}" for tile in rummikub_set.tiles]


def _assert_legal_move(state: GameState, result: OptimalState) -> None:
    """The end-of-turn rules every answer must satisfy."""
    is_valid, message = validate_board(result.board)
    assert is_valid, message

    board_in = [tile.id for rummikub_set in state.board for tile in rummikub_set.tiles]
    board_out = [tile.id for rummikub_set in result.board for tile in rummikub_set.tiles]
    rack_in = [tile.id for tile in state.rack]
    rack_out = [tile.id for tile in result.remaining_rack]

    # Every board tile is still on the board, nothing appears twice, nothing
    # is invented, and the rack only shrinks.
    assert Counter(board_in) <= Counter(board_out)
    assert Counter(board_in + rack_in) == Counter(board_out + rack_out)
    assert set(rack_out) <= set(rack_in)
    assert result.tiles_used_from_rack == len(rack_in) - len(rack_out)
    assert all(len(rummikub_set.tiles) >= 3 for rummikub_set in result.board)


def test_extends_a_run_and_keeps_its_id():
    state = GameState(
        board=[_run("reds", _tile("r7", RED, 7), _tile("r8", RED, 8), _tile("r9", RED, 9))],
        rack=[_tile("r10", RED, 10), _tile("b2", BLUE, 2)],
    )

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    assert result.tiles_used_from_rack == 1
    assert [tile.id for tile in result.remaining_rack] == ["b2"]
    (run,) = result.board
    assert run.id == "reds"
    assert _labels(run) == ["RED7", "RED8", "RED9", "RED10"]


def test_completes_a_group_from_the_rack():
    state = GameState(
        board=[_group("fours", _tile("k4", BLACK, 4), _tile("b4", BLUE, 4), _tile("r4", RED, 4))],
        rack=[_tile("y4", YELLOW, 4)],
    )

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    assert result.tiles_used_from_rack == 1
    (group,) = result.board
    assert group.id == "fours"
    assert group.type == SetType.GROUP
    assert len(group.tiles) == 4


def test_lays_down_a_new_run_from_the_rack_alone():
    state = GameState(
        board=[],
        rack=[_tile("r1", RED, 1), _tile("r2", RED, 2), _tile("r3", RED, 3), _tile("b9", BLUE, 9)],
    )

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    assert result.tiles_used_from_rack == 3
    assert [tile.id for tile in result.remaining_rack] == ["b9"]


def test_joker_fills_the_gap_in_a_new_run():
    state = GameState(board=[], rack=[_tile("r5", RED, 5), _joker("j1"), _tile("r7", RED, 7)])

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    assert result.tiles_used_from_rack == 3
    (run,) = result.board
    assert run.type == SetType.RUN
    assert [tile.id for tile in run.tiles] == ["r5", "j1", "r7"]


def test_rack_joker_bridges_a_gap_to_extend_a_board_run():
    state = GameState(
        board=[_run("yellows", _tile("y4", YELLOW, 4), _tile("y5", YELLOW, 5), _tile("y6", YELLOW, 6))],
        rack=[_tile("y8", YELLOW, 8), _joker("j1")],
    )

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    assert result.tiles_used_from_rack == 2
    (run,) = result.board
    assert run.id == "yellows"
    assert [tile.id for tile in run.tiles] == ["y4", "y5", "y6", "j1", "y8"]


def test_takes_a_tile_from_a_group_to_extend_a_run():
    state = GameState(
        board=[
            _group("fives", _tile("r5", RED, 5), _tile("b5", BLUE, 5), _tile("k5", BLACK, 5), _tile("y5", YELLOW, 5)),
            _run("blacks", _tile("k6", BLACK, 6), _tile("k7", BLACK, 7), _tile("k8", BLACK, 8)),
        ],
        rack=[_tile("k3", BLACK, 3), _tile("k4", BLACK, 4)],
    )

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    assert result.tiles_used_from_rack == 2
    by_id = {rummikub_set.id: rummikub_set for rummikub_set in result.board}
    assert set(by_id) == {"fives", "blacks"}
    assert sorted(_labels(by_id["fives"])) == ["BLUE5", "RED5", "YELLOW5"]
    assert _labels(by_id["blacks"]) == [f"BLACK{value}" for value in range(3, 9)]


def test_rearranges_the_whole_board_when_needed():
    groups = [
        _group(f"g{value}", _tile(f"r{value}", RED, value), _tile(f"b{value}", BLUE, value), _tile(f"k{value}", BLACK, value))
        for value in (1, 2, 3)
    ]
    state = GameState(board=groups, rack=[_tile("r4", RED, 4), _tile("b4", BLUE, 4)])

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    # The only way to place R4 and B4 is to turn the three groups into runs.
    assert result.tiles_used_from_rack == 2
    assert all(rummikub_set.type == SetType.RUN for rummikub_set in result.board)
    assert sorted(_labels(rummikub_set)[0] for rummikub_set in result.board) == ["BLACK1", "BLUE1", "RED1"]


def test_long_run_comes_back_as_one_run():
    reds = [_tile(f"r{value}", RED, value) for value in range(1, 10)]
    state = GameState(board=[_run("long", *reds)], rack=[_tile("r10", RED, 10)])

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    (run,) = result.board
    assert run.id == "long"
    assert [tile.value for tile in run.tiles] == list(range(1, 11))


def test_untouched_sets_are_kept_when_there_is_a_choice():
    # Y1-Y3 can go down as its own run or join the reds/blues/blacks as three
    # groups of four. Both place 3 tiles; keeping the original runs is clearer.
    board = [
        _run(f"{color.value}-run", *(_tile(f"{color.value}{value}", color, value) for value in (1, 2, 3)))
        for color in (RED, BLUE, BLACK)
    ]
    state = GameState(board=board, rack=[_tile(f"y{value}", YELLOW, value) for value in (1, 2, 3)])

    result = solver.solve_rummikub(state)

    _assert_legal_move(state, result)
    assert result.tiles_used_from_rack == 3
    assert result.board[:3] == board


def test_no_possible_move_returns_the_board_unchanged():
    board = [_run("reds", _tile("r1", RED, 1), _tile("r2", RED, 2), _tile("r3", RED, 3))]
    state = GameState(board=board, rack=[_tile("b9", BLUE, 9)])

    result = solver.solve_rummikub(state)

    assert result.tiles_used_from_rack == 0
    assert result.board == board
    assert [tile.id for tile in result.remaining_rack] == ["b9"]


def test_empty_rack_echoes_the_input():
    board = [_group("fives", _tile("r5", RED, 5), _tile("b5", BLUE, 5), _tile("k5", BLACK, 5))]
    state = GameState(board=board, rack=[])

    result = solver.solve_rummikub(state)

    assert result == OptimalState(board=board, tiles_used_from_rack=0, remaining_rack=[])


def test_timeout_falls_back_to_the_unchanged_state(monkeypatch):
    monkeypatch.setattr(solver, "TIME_LIMIT_SECONDS", 0.0)
    state = GameState(board=[], rack=[_tile("r1", RED, 1), _tile("r2", RED, 2), _tile("r3", RED, 3)])

    result = solver.solve_rummikub(state)

    assert result == OptimalState(board=[], tiles_used_from_rack=0, remaining_rack=state.rack)


def test_infeasible_board_falls_back_to_the_unchanged_state():
    # Not reachable through /solve (the route validates first): a 2-tile set
    # whose BLUE7 fits no legal set, so the board tiles cannot all be placed.
    board = [Set(id="broken", type=SetType.INVALID, tiles=[_tile("r1", RED, 1), _tile("b7", BLUE, 7)])]
    state = GameState(board=board, rack=[_tile("r2", RED, 2), _tile("r3", RED, 3)])

    result = solver.solve_rummikub(state)

    assert result == OptimalState(board=board, tiles_used_from_rack=0, remaining_rack=state.rack)


def test_result_failing_the_self_check_is_never_returned(monkeypatch):
    def drop_board_tiles(game_state, kept_sets, instances):
        return OptimalState(board=[], tiles_used_from_rack=0, remaining_rack=list(game_state.rack))

    monkeypatch.setattr(solver, "_build_result", drop_board_tiles)
    board = [_run("reds", _tile("r7", RED, 7), _tile("r8", RED, 8), _tile("r9", RED, 9))]
    state = GameState(board=board, rack=[_tile("r10", RED, 10)])

    result = solver.solve_rummikub(state)

    assert result == OptimalState(board=board, tiles_used_from_rack=0, remaining_rack=state.rack)


def _random_state(seed: int, board_pool: int, rack_size: int) -> GameState:
    colors = (RED, BLUE, BLACK, YELLOW)
    deck = [
        _tile(f"{color.value}{value}-{copy}", color, value)
        for color in colors
        for value in range(1, 14)
        for copy in "ab"
    ] + [_joker("joker-a"), _joker("joker-b")]
    random.Random(seed).shuffle(deck)
    # A legal board: whatever the solver lays down from an empty table.
    board = solver.solve_rummikub(GameState(board=[], rack=deck[:board_pool])).board
    on_board = {tile.id for rummikub_set in board for tile in rummikub_set.tiles}
    rest = [tile for tile in deck if tile.id not in on_board]
    return GameState(board=board, rack=rest[:rack_size])


def test_random_states_conserve_board_tiles_and_are_deterministic():
    placed = []
    for seed in range(3):
        state = _random_state(seed, board_pool=45, rack_size=14)

        first = solver.solve_rummikub(state)
        second = solver.solve_rummikub(state)

        _assert_legal_move(state, first)
        assert first == second
        placed.append(first.tiles_used_from_rack)
    # Some random racks have no legal move at all (seed 1 is one), so only the
    # total is required to be positive.
    assert sum(placed) > 0


def test_full_deck_template_enumeration_is_not_truncated():
    deck = [
        _tile(f"{color.value}-{value}", color, value)
        for color in (RED, BLUE, BLACK, YELLOW)
        for value in range(1, 14)
    ] + [_joker("joker-0"), _joker("joker-1")]

    candidates = generate_candidates(
        GameState(board=[], rack=deck),
        max_candidates=solver._MAX_TEMPLATE_CANDIDATES,
        max_run_length=solver._MAX_TEMPLATE_RUN_LENGTH,
    )

    assert len(candidates) < solver._MAX_TEMPLATE_CANDIDATES
    assert len(solver._ALL_TEMPLATES) > 0
