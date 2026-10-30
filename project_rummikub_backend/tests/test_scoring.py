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


R6, R7, R8, R9, R10 = (_tile(f"r{v}", "RED", v) for v in (6, 7, 8, 9, 10))
Y2 = _tile("y2", "YELLOW", 2)
BOARD = [{"id": "reds", "type": "RUN", "tiles": [R7, R8, R9]}]
RACK = [R6, R10, Y2]


def _publish(ai_score: int = 2, board=BOARD, rack=RACK) -> str:
    """Insert a challenge directly so the AI score can be chosen."""
    conn = db.connect()
    try:
        db.init_db(conn)
        session_id = db.create_session(conn, "creator")
        return db.create_challenge(conn, board, rack, ai_score, session_id, 0)
    finally:
        conn.close()


def _submit(challenge_id: str, user_id: str, *run_tiles):
    board = [{"id": "reds", "type": "RUN", "tiles": list(run_tiles)}]
    return client.post(f"/challenge/{challenge_id}/submit", json={"user_id": user_id, "board": board})


def test_score_is_human_placed_minus_ai_placed():
    challenge_id = _publish(ai_score=2)

    result = _submit(challenge_id, "ann", R7, R8, R9, R10)

    assert result.status_code == 200
    assert result.json() == {
        "challenge_id": challenge_id, "human_placed": 1, "ai_placed": 2, "score": -1
    }


def test_matching_the_ai_scores_zero_and_beating_it_wins():
    tie = _submit(_publish(ai_score=2), "ann", R6, R7, R8, R9, R10)
    win = _submit(_publish(ai_score=1, rack=RACK + [_tile("y3", "YELLOW", 3)]), "bob", R6, R7, R8, R9, R10)

    assert tie.json()["score"] == 0
    assert win.json()["score"] == 1
    board = {row["user_id"]: row for row in client.get("/leaderboard").json()}
    assert board["ann"]["challenges_won"] == 0
    assert board["bob"]["challenges_won"] == 1


def test_leaderboard_accumulates_and_ranks_by_points():
    first, second = _publish(ai_score=1), _publish(ai_score=1, rack=RACK + [_tile("y3", "YELLOW", 3)])
    _submit(first, "ann", R6, R7, R8, R9, R10)  # +1
    _submit(second, "ann", R6, R7, R8, R9, R10)  # +1
    _submit(first, "bob", R7, R8, R9, R10)  # 0
    _submit(first, "cy", R7, R8, R9)  # -1

    assert client.get("/leaderboard").json() == [
        {"rank": 1, "user_id": "ann", "total_points": 2, "challenges_won": 2},
        {"rank": 2, "user_id": "bob", "total_points": 0, "challenges_won": 0},
        {"rank": 3, "user_id": "cy", "total_points": -1, "challenges_won": 0},
    ]


def test_leaderboard_is_empty_before_any_submission():
    assert client.get("/leaderboard").json() == []


def test_second_submission_by_the_same_user_is_rejected_and_not_scored():
    challenge_id = _publish(ai_score=1)
    assert _submit(challenge_id, "ann", R7, R8, R9, R10).status_code == 200

    again = _submit(challenge_id, "ann", R6, R7, R8, R9, R10)

    assert again.status_code == 409
    assert client.get("/leaderboard").json()[0]["total_points"] == 0


def test_unknown_challenge_is_404():
    assert _submit("nope", "ann", R7, R8, R9).status_code == 404


@pytest.mark.parametrize(
    "tiles",
    [
        (R7, R8, R10),  # not consecutive
        (R8, R9, R10),  # an original board tile (r7) was removed
        (R7, R8, R9, R9),  # duplicate tile
        (R7, R8, R9, _tile("r10", "RED", 11)),  # same id, different tile
        (R7, R8, R9, _tile("zz", "RED", 10)),  # tile that is not in the challenge
    ],
)
def test_illegal_submissions_are_rejected_and_do_not_score(tiles):
    challenge_id = _publish()

    assert _submit(challenge_id, "ann", *tiles).status_code == 400
    assert client.get("/leaderboard").json() == []


def test_challenge_list_returns_published_positions_newest_first():
    older = _publish(ai_score=2)
    newer = _publish(ai_score=1, rack=RACK + [_tile("y3", "YELLOW", 3)])

    listed = client.get("/challenge/list").json()

    assert [c["id"] for c in listed] == [newer, older]
    assert listed[1]["ai_score"] == 2
    assert [t["id"] for t in listed[1]["rack"]] == ["r6", "r10", "y2"]
    assert listed[1]["board"][0]["tiles"][0]["id"] == "r7"


def test_challenge_list_is_empty_by_default():
    assert client.get("/challenge/list").json() == []
