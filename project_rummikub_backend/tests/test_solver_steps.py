from fastapi.testclient import TestClient

from main import app
from models import GameState, Set, SetType, StepType, Tile, TileColor
from solution_steps import compute_solution_steps
from solver import solve_rummikub


def t(tile_id: str, color: str, value: int) -> Tile:
    return Tile(id=tile_id, color=TileColor(color), value=value)


def s(set_id: str, kind: str, *tiles: Tile) -> Set:
    return Set(id=set_id, type=SetType(kind), tiles=list(tiles))


def replay(board: list[Set], rack: list[Tile], steps) -> dict[str, set[str]]:
    """Apply the steps to the starting state; return set id -> tile ids."""
    sets = {x.id: {tile.id for tile in x.tiles} for x in board}
    rack_ids = {tile.id for tile in rack}
    pool: dict[str, set[str]] = {}  # tiles lifted off a disbanded set, by set id
    for index, step in enumerate(steps):
        assert step.stepIndex == index
        ids = {tile.id for tile in step.tiles}
        if step.type == StepType.DISBAND_SET:
            assert sets.pop(step.sourceSetId) == ids
            pool[step.sourceSetId] = ids
        elif step.type == StepType.PLACE_FROM_RACK:
            assert ids <= rack_ids
            rack_ids -= ids
            sets[step.targetSetId] |= ids
        elif step.type == StepType.MOVE_BETWEEN_SETS:
            if step.sourceSetId in pool:
                assert ids <= pool[step.sourceSetId]
                pool[step.sourceSetId] -= ids
            else:
                assert ids <= sets[step.sourceSetId]
                sets[step.sourceSetId] -= ids
            sets[step.targetSetId] |= ids
        else:
            assert step.type == StepType.FORM_NEW_SET and step.targetSetId not in sets
            for source in [rack_ids, *pool.values(), *sets.values()]:
                source -= ids & source
            sets[step.targetSetId] = set(ids)
        assert step.description
    return {k: v for k, v in sets.items() if v}


def assert_replays_to(board, rack, final_board):
    steps = compute_solution_steps(board, rack, final_board)
    assert replay(board, rack, steps) == {x.id: {tile.id for tile in x.tiles} for x in final_board}
    return steps


def test_no_change_gives_no_steps():
    board = [s("a", "RUN", t("r1", "RED", 1), t("r2", "RED", 2), t("r3", "RED", 3))]
    assert compute_solution_steps(board, [t("y9", "YELLOW", 9)], board) == []


def test_rack_tile_extends_a_set():
    board = [s("a", "RUN", t("r1", "RED", 1), t("r2", "RED", 2), t("r3", "RED", 3))]
    rack = [t("r4", "RED", 4), t("y9", "YELLOW", 9)]
    final = [s("a", "RUN", *board[0].tiles, rack[0])]

    steps = assert_replays_to(board, rack, final)

    assert [x.type for x in steps] == [StepType.PLACE_FROM_RACK]
    assert steps[0].sourceSetId is None and steps[0].targetSetId == "a"
    assert [tile.id for tile in steps[0].tiles] == ["r4"]
    assert "Red 4" in steps[0].description


def test_borrowing_a_tile_between_sets():
    # The blue 5 moves from the run onto the group of 5s.
    run = s("run", "RUN", *(t(f"b{i}", "BLUE", i) for i in range(1, 6)))
    group = s("grp", "GROUP", t("r5", "RED", 5), t("k5", "BLACK", 5), t("y5", "YELLOW", 5))
    final = [
        s("run", "RUN", *run.tiles[:4]),
        s("grp", "GROUP", *group.tiles, run.tiles[4]),
    ]
    steps = assert_replays_to([run, group], [], final)
    assert [x.type for x in steps] == [StepType.MOVE_BETWEEN_SETS]
    assert steps[0].sourceSetId == "run" and steps[0].targetSetId == "grp"


def test_pure_restructuring_has_no_rack_placement():
    # Split one 6-run into two 3-runs: disband the old set, form two new ones.
    run = s("six", "RUN", *(t(f"r{i}", "RED", i) for i in range(1, 7)))
    final = [
        s("n1", "RUN", *run.tiles[:3]),
        s("n2", "RUN", *run.tiles[3:]),
    ]
    steps = assert_replays_to([run], [], final)
    assert [x.type for x in steps] == [
        StepType.DISBAND_SET,
        StepType.FORM_NEW_SET,
        StepType.FORM_NEW_SET,
    ]


def test_new_set_from_rack_and_board_tiles():
    run = s("run", "RUN", *(t(f"b{i}", "BLUE", i) for i in range(4, 8)))
    rack = [t("r7", "RED", 7), t("k7", "BLACK", 7)]
    final = [
        s("run", "RUN", *run.tiles[:3]),
        s("new", "GROUP", run.tiles[3], *rack),
    ]
    steps = assert_replays_to([run], rack, final)
    assert [x.type for x in steps] == [StepType.FORM_NEW_SET]
    assert {tile.id for tile in steps[0].tiles} == {"b7", "r7", "k7"}
    assert "your rack" in steps[0].description


def test_one_step_per_source_when_extending_a_set():
    a = s("a", "RUN", t("r1", "RED", 1), t("r2", "RED", 2), t("r3", "RED", 3))
    donor = s("d", "RUN", *(t(f"r{i}", "RED", i) for i in range(4, 9)))
    rack = [t("j", "JOKER", 0)]
    final = [
        s("a", "RUN", *a.tiles, donor.tiles[0], donor.tiles[1], rack[0]),
        s("d", "RUN", *donor.tiles[2:]),
    ]
    steps = assert_replays_to([a, donor], rack, final)
    assert [(x.type, x.sourceSetId) for x in steps] == [
        (StepType.MOVE_BETWEEN_SETS, "d"),
        (StepType.PLACE_FROM_RACK, None),
    ]


def test_steps_for_a_real_solver_result():
    board = [
        s("reds", "RUN", t("r7", "RED", 7), t("r8", "RED", 8), t("r9", "RED", 9)),
        s("fives", "GROUP", t("b5", "BLUE", 5), t("k5", "BLACK", 5), t("y5", "YELLOW", 5)),
    ]
    rack = [t("r10", "RED", 10), t("r5", "RED", 5), t("y2", "YELLOW", 2)]

    optimal = solve_rummikub(GameState(board=board, rack=rack))
    steps = assert_replays_to(board, rack, optimal.board)

    placed = {tile.id for x in steps if x.type == StepType.PLACE_FROM_RACK for tile in x.tiles}
    assert optimal.tiles_used_from_rack >= 2
    assert len(placed) <= optimal.tiles_used_from_rack


def test_solve_route_includes_steps():
    payload = {
        "board": [{"id": "a", "type": "RUN", "tiles": [
            {"id": "r7", "color": "RED", "value": 7},
            {"id": "r8", "color": "RED", "value": 8},
            {"id": "r9", "color": "RED", "value": 9}]}],
        "rack": [{"id": "r10", "color": "RED", "value": 10}],
    }
    body = TestClient(app).post("/solve", json=payload).json()
    steps = body["optimal_state"]["solution_steps"]
    assert [x["type"] for x in steps] == ["PLACE_FROM_RACK"]
    assert steps[0]["stepIndex"] == 0 and steps[0]["targetSetId"] == "a"
