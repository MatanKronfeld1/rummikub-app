from collections import Counter

from fastapi.testclient import TestClient

from main import app
from models import GameState, Set
from validator import validate_board

client = TestClient(app)


def _tile(tile_id: str, color: str, value: int) -> dict:
    return {"id": tile_id, "color": color, "value": value}


def _payload(board: list[dict], rack: list[dict]) -> dict:
    return {"board": board, "rack": rack}


def test_solve_returns_a_legal_board_that_uses_the_rack():
    payload = _payload(
        board=[{
            "id": "reds",
            "type": "RUN",
            "tiles": [_tile("r7", "RED", 7), _tile("r8", "RED", 8), _tile("r9", "RED", 9)],
        }],
        rack=[_tile("r10", "RED", 10), _tile("j1", "JOKER", 0), _tile("y2", "YELLOW", 2)],
    )

    response = client.post("/solve", json=payload)

    assert response.status_code == 200
    body = response.json()
    assert body["is_valid"] is True
    assert body["original_state"] == payload
    assert 0 <= body["execution_time_ms"] <= 5000
    optimal = body["optimal_state"]
    board = [Set(**rummikub_set) for rummikub_set in optimal["board"]]
    assert validate_board(board)[0]
    assert optimal["tiles_used_from_rack"] == 2
    assert [tile["id"] for tile in optimal["remaining_rack"]] == ["y2"]
    board_ids = Counter(tile["id"] for rummikub_set in optimal["board"] for tile in rummikub_set["tiles"])
    assert board_ids == Counter(["r7", "r8", "r9", "r10", "j1"])


def test_invalid_board_is_rejected_with_400():
    payload = _payload(
        board=[{
            "id": "bad",
            "type": "GROUP",
            "tiles": [_tile("r5", "RED", 5), _tile("r5b", "RED", 5), _tile("b5", "BLUE", 5)],
        }],
        rack=[],
    )

    response = client.post("/solve", json=payload)

    assert response.status_code == 400
    assert "Set 1 (id=bad)" in response.json()["detail"]


def test_repeated_tile_id_is_rejected_with_400():
    payload = _payload(
        board=[{
            "id": "fours",
            "type": "GROUP",
            "tiles": [_tile("x", "RED", 4), _tile("b4", "BLUE", 4), _tile("k4", "BLACK", 4)],
        }],
        rack=[_tile("x", "YELLOW", 4)],
    )

    response = client.post("/solve", json=payload)

    assert response.status_code == 400
    assert "appears more than once" in response.json()["detail"]


def test_out_of_range_tile_value_is_rejected_by_the_schema():
    response = client.post("/solve", json=_payload(board=[], rack=[_tile("r14", "RED", 14)]))

    assert response.status_code == 422


def test_empty_rack_returns_the_state_unchanged():
    board = [{
        "id": "fives",
        "type": "GROUP",
        "tiles": [_tile("r5", "RED", 5), _tile("b5", "BLUE", 5), _tile("k5", "BLACK", 5)],
    }]

    response = client.post("/solve", json=_payload(board=board, rack=[]))

    assert response.status_code == 200
    optimal = response.json()["optimal_state"]
    assert optimal == {"board": board, "tiles_used_from_rack": 0, "remaining_rack": []}
    assert GameState(**response.json()["original_state"]) == GameState(board=board, rack=[])
