import json

import pytest
from fastapi.testclient import TestClient

import db
from main import app

client = TestClient(app)


@pytest.fixture(autouse=True)
def temp_db(tmp_path, monkeypatch):
    monkeypatch.setattr(db, "DB_PATH", str(tmp_path / "test.db"))


def _tile(tile_id: str, color: str, value: int) -> dict:
    return {"id": tile_id, "color": color, "value": value}


BOARD = [{
    "id": "reds",
    "type": "RUN",
    "tiles": [_tile("r7", "RED", 7), _tile("r8", "RED", 8), _tile("r9", "RED", 9)],
}]
RACK = [_tile("r10", "RED", 10), _tile("y2", "YELLOW", 2)]


def _query(sql: str, *args):
    conn = db.connect()
    try:
        return conn.execute(sql, args).fetchall()
    finally:
        conn.close()


def _turn(**extra):
    return client.post("/game/turn", json={"user_id": "u1", "board": BOARD, "rack": RACK, **extra})


def test_turn_without_session_opens_one_and_increments_indices():
    first = _turn()
    assert first.status_code == 200
    session_id = first.json()["session_id"]
    assert first.json()["turn_index"] == 0

    second = _turn(session_id=session_id, move_applied={"tiles_used_from_rack": 1})
    assert second.json() == {"session_id": session_id, "turn_index": 1}

    rows = _query("SELECT * FROM turn_history WHERE game_id = ? ORDER BY turn_index", session_id)
    assert [r["turn_index"] for r in rows] == [0, 1]
    assert json.loads(rows[0]["rack_state_json"])[0]["isJoker"] is False
    assert json.loads(rows[1]["move_applied_json"]) == {"tiles_used_from_rack": 1}
    assert rows[0]["move_applied_json"] is None


def test_turn_for_unknown_session_is_404():
    assert _turn(session_id="nope").status_code == 404


def test_end_marks_session_packed_and_blocks_further_turns():
    session_id = _turn().json()["session_id"]

    ended = client.post("/game/end", json={"session_id": session_id})

    assert ended.status_code == 200
    assert ended.json() == {"session_id": session_id, "status": "packed"}
    assert _query("SELECT status FROM game_sessions WHERE id = ?", session_id)[0]["status"] == "packed"
    assert _turn(session_id=session_id).status_code == 409
    assert client.post("/game/end", json={"session_id": session_id}).status_code == 200


def test_end_unknown_session_is_404():
    assert client.post("/game/end", json={"session_id": "nope"}).status_code == 404


def test_solve_auto_publishes_a_challenge():
    session_id = _turn().json()["session_id"]

    response = client.post(f"/solve?session_id={session_id}", json={"board": BOARD, "rack": RACK})

    assert response.status_code == 200
    ai_score = response.json()["optimal_state"]["tiles_used_from_rack"]
    rows = _query("SELECT * FROM community_challenges")
    assert len(rows) == 1
    assert rows[0]["ai_score"] == ai_score == 1
    assert rows[0]["created_from_session_id"] == session_id
    assert rows[0]["turn_index"] == 0
    assert [t["id"] for t in json.loads(rows[0]["initial_rack_json"])] == ["r10", "y2"]


def test_solving_the_same_position_twice_publishes_once():
    session_id = _turn().json()["session_id"]
    for _ in range(2):
        assert client.post(f"/solve?session_id={session_id}", json={"board": BOARD, "rack": RACK}).status_code == 200

    assert len(_query("SELECT id FROM community_challenges")) == 1


def test_solve_uses_explicit_turn_index():
    session_id = _turn().json()["session_id"]

    client.post(f"/solve?session_id={session_id}&turn_index=4", json={"board": BOARD, "rack": RACK})

    assert _query("SELECT turn_index FROM community_challenges")[0]["turn_index"] == 4


def test_solve_without_session_or_with_bad_session_publishes_nothing():
    payload = {"board": BOARD, "rack": RACK}
    assert client.post("/solve", json=payload).status_code == 200
    assert client.post("/solve?session_id=nope", json=payload).status_code == 200

    assert _query("SELECT id FROM community_challenges") == []


def test_solve_on_ended_session_or_empty_rack_publishes_nothing():
    session_id = _turn().json()["session_id"]
    assert client.post(
        f"/solve?session_id={session_id}", json={"board": BOARD, "rack": []}
    ).status_code == 200
    client.post("/game/end", json={"session_id": session_id})
    assert client.post(
        f"/solve?session_id={session_id}", json={"board": BOARD, "rack": RACK}
    ).status_code == 200

    assert _query("SELECT id FROM community_challenges") == []
