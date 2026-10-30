"""Time the solver on three fixed states (the numbers in EVALUATION.md).

Run from project_rummikub_backend/:

    python benchmark_solver.py

Each state is solved several times in-process; the table reports the median
and the worst wall time of ``solve_rummikub`` (model building included), the
CP-SAT status of the main phase, and a check that the answer is a legal board
that keeps every board tile. Laptops throttle under sustained load, so a fixed
pure-Python loop is timed before and after as a CPU reference.
"""

from __future__ import annotations

import logging
import random
import statistics
import time
from collections import Counter

import solver
from models import GameState, Set, SetType, Tile, TileColor
from validator import validate_board

RUNS = 5
COLORS = (TileColor.RED, TileColor.BLUE, TileColor.BLACK, TileColor.YELLOW)


def _tile(tile_id: str, color: TileColor, value: int) -> Tile:
    return Tile(id=tile_id, color=color, value=value)


def _set(set_id: str, kind: SetType, *tiles: Tile) -> Set:
    return Set(id=set_id, type=kind, tiles=list(tiles))


def extend_and_complete() -> GameState:
    """Small board; the best move borrows a tile from a full group."""
    return GameState(
        board=[
            _set("fives", SetType.GROUP, *(_tile(f"{c.value}5", c, 5) for c in COLORS)),
            _set("blacks", SetType.RUN, *(_tile(f"k{v}", TileColor.BLACK, v) for v in (6, 7, 8))),
            _set("blues", SetType.RUN, *(_tile(f"b{v}", TileColor.BLUE, v) for v in (9, 10, 11))),
        ],
        rack=[
            _tile("k3", TileColor.BLACK, 3),
            _tile("k4", TileColor.BLACK, 4),
            _tile("j1", TileColor.JOKER, 0),
            _tile("b13", TileColor.BLUE, 13),
            _tile("y12", TileColor.YELLOW, 12),
            _tile("r1", TileColor.RED, 1),
        ],
    )


def full_rearrangement() -> GameState:
    """Three groups must become three runs to place R4 and B4."""
    groups = [
        _set(f"g{v}", SetType.GROUP, *(_tile(f"{c.value}{v}", c, v) for c in COLORS[:3]))
        for v in (1, 2, 3)
    ]
    yellows = _set("yellows", SetType.RUN, *(_tile(f"y{v}", TileColor.YELLOW, v) for v in (5, 6, 7)))
    return GameState(
        board=[*groups, yellows],
        rack=[
            _tile("r4", TileColor.RED, 4),
            _tile("b4", TileColor.BLUE, 4),
            _tile("y8", TileColor.YELLOW, 8),
            _tile("k13", TileColor.BLACK, 13),
        ],
    )


def crowded_late_game(seed: int = 3) -> GameState:
    """Seeded deck: a 75-tile pool laid out by the solver, then a 22-tile rack."""
    deck = [
        _tile(f"{c.value}{v}-{copy}", c, v) for c in COLORS for v in range(1, 14) for copy in "ab"
    ] + [_tile("joker-a", TileColor.JOKER, 0), _tile("joker-b", TileColor.JOKER, 0)]
    random.Random(seed).shuffle(deck)
    board = solver.solve_rummikub(GameState(board=[], rack=deck[:75])).board
    on_board = {tile.id for rummikub_set in board for tile in rummikub_set.tiles}
    rest = [tile for tile in deck if tile.id not in on_board]
    return GameState(board=board, rack=rest[:22])


class _LastMessage(logging.Handler):
    def __init__(self) -> None:
        super().__init__()
        self.message = ""

    def emit(self, record: logging.LogRecord) -> None:
        self.message = record.getMessage()


def _cpu_reference_ms() -> float:
    start = time.perf_counter()
    sum(i * i for i in range(2_000_000))
    return (time.perf_counter() - start) * 1000


def _keeps_board_tiles(state: GameState, board: list[Set]) -> bool:
    before = Counter(tile.id for rummikub_set in state.board for tile in rummikub_set.tiles)
    after = Counter(tile.id for rummikub_set in board for tile in rummikub_set.tiles)
    return before <= after


def main() -> None:
    capture = _LastMessage()
    solver.logger.addHandler(capture)
    solver.logger.setLevel(logging.INFO)

    states = {
        "1. Extend and complete": extend_and_complete(),
        "2. Full rearrangement": full_rearrangement(),
        "3. Crowded late game (seed 3)": crowded_late_game(),
    }
    cpu_before = _cpu_reference_ms()

    print("| State | Board tiles | Rack tiles | Placed | CP-SAT status | Legal, board kept | Median ms | Worst ms |")
    print("|---|---|---|---|---|---|---|---|")
    for name, state in states.items():
        times = []
        for _ in range(RUNS):
            start = time.perf_counter()
            result = solver.solve_rummikub(state)
            times.append((time.perf_counter() - start) * 1000)
        status = capture.message.split("status=", 1)[-1].split()[0] if "status=" in capture.message else "n/a"
        legal = validate_board(result.board)[0] and _keeps_board_tiles(state, result.board)
        board_tiles = sum(len(rummikub_set.tiles) for rummikub_set in state.board)
        print(
            f"| {name} | {board_tiles} | {len(state.rack)} | {result.tiles_used_from_rack} "
            f"| {status} | {'yes' if legal else 'NO'} | {statistics.median(times):.0f} | {max(times):.0f} |"
        )

    cpu_after = _cpu_reference_ms()
    print()
    print(f"CPU reference loop: {cpu_before:.0f} ms before, {cpu_after:.0f} ms after.")


if __name__ == "__main__":
    main()
