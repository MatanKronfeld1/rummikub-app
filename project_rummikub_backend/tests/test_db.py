import json
import sqlite3

import pytest

import db


@pytest.fixture
def conn():
    c = db.connect(":memory:")
    db.init_db(c)
    yield c
    c.close()


BOARD = [
    {
        "id": "s1",
        "type": "RUN",
        "tiles": [
            {"id": "t1", "color": "RED", "value": 1},
            {"id": "t2", "color": "RED", "value": 2},
            {"id": "t3", "color": "JOKER", "value": 0},
        ],
    }
]
RACK = [{"id": "t4", "color": "BLUE", "value": 7}]


def test_schema_initialization(conn):
    names = {
        r["name"]
        for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    assert {"game_sessions", "turn_history", "community_challenges", "leaderboard"} <= names
    db.init_db(conn)  # idempotent


def test_session_status_constraint(conn):
    sid = db.create_session(conn, "u1")
    row = conn.execute("SELECT status FROM game_sessions WHERE id = ?", (sid,)).fetchone()
    assert row["status"] == "active"
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("UPDATE game_sessions SET status = 'bogus' WHERE id = ?", (sid,))


def test_turn_stored_as_json_with_is_joker(conn):
    sid = db.create_session(conn, "u1")
    db.record_turn(conn, sid, 0, BOARD, RACK, {"steps": []})
    row = conn.execute("SELECT * FROM turn_history WHERE game_id = ?", (sid,)).fetchone()
    board = json.loads(row["board_state_json"])
    rack = json.loads(row["rack_state_json"])
    assert board[0]["tiles"][2] == {"id": "t3", "color": "JOKER", "value": 0, "isJoker": True}
    assert board[0]["tiles"][0]["isJoker"] is False
    assert rack == [{"id": "t4", "color": "BLUE", "value": 7, "isJoker": False}]
    assert json.loads(row["move_applied_json"]) == {"steps": []}
    assert isinstance(row["board_state_json"], str)


def test_turn_requires_existing_session_and_unique_index(conn):
    with pytest.raises(sqlite3.IntegrityError):
        db.record_turn(conn, "missing", 0, BOARD, RACK)
    sid = db.create_session(conn, "u1")
    db.record_turn(conn, sid, 0, BOARD, RACK)
    with pytest.raises(sqlite3.IntegrityError):
        db.record_turn(conn, sid, 0, BOARD, RACK)


def test_challenge_dedup_by_session_turn(conn):
    sid = db.create_session(conn, "u1")
    db.create_challenge(conn, BOARD, RACK, 3, sid, 0)
    other_rack = [{"id": "t9", "color": "BLACK", "value": 5}]
    with pytest.raises(sqlite3.IntegrityError):
        db.create_challenge(conn, BOARD, other_rack, 3, sid, 0)


def test_challenge_dedup_by_board_hash_ignores_ids_and_order(conn):
    s1 = db.create_session(conn, "u1")
    s2 = db.create_session(conn, "u2")
    db.create_challenge(conn, BOARD, RACK, 3, s1, 0)
    renamed_board = [
        {
            "id": "other",
            "type": "RUN",
            "tiles": [
                {"id": "x3", "color": "JOKER", "value": 0},
                {"id": "x2", "color": "RED", "value": 2},
                {"id": "x1", "color": "RED", "value": 1},
            ],
        }
    ]
    renamed_rack = [{"id": "x4", "color": "BLUE", "value": 7}]
    with pytest.raises(sqlite3.IntegrityError):
        db.create_challenge(conn, renamed_board, renamed_rack, 3, s2, 5)


def test_challenge_json_roundtrip(conn):
    sid = db.create_session(conn, "u1")
    cid = db.create_challenge(conn, BOARD, RACK, 4, sid, 2)
    row = conn.execute("SELECT * FROM community_challenges WHERE id = ?", (cid,)).fetchone()
    assert row["ai_score"] == 4
    assert json.loads(row["initial_board_json"])[0]["tiles"][0]["isJoker"] is False
    assert json.loads(row["initial_rack_json"])[0]["value"] == 7


def test_leaderboard_defaults(conn):
    conn.execute("INSERT INTO leaderboard (user_id) VALUES ('u1')")
    row = conn.execute("SELECT * FROM leaderboard WHERE user_id = 'u1'").fetchone()
    assert (row["total_points"], row["challenges_won"]) == (0, 0)
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("INSERT INTO leaderboard (user_id) VALUES ('u1')")
