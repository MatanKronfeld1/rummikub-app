import base64
import io
import json
from pathlib import Path

from fastapi.testclient import TestClient

import main

client = TestClient(main.app)

_JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 9000 + b"\xff\xd9"


class _FakeResponse(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _proxy_once(monkeypatch) -> dict:
    """POST one image through the Roboflow proxy with the network faked."""
    body = {"predictions": [{"x": 1, "y": 2, "width": 3, "height": 4, "class": "Red7", "confidence": 0.9}]}
    monkeypatch.setattr(
        main.urllib.request,
        "urlopen",
        lambda request, timeout: _FakeResponse(json.dumps(body).encode()),
    )
    monkeypatch.setenv("ROBOFLOW_API_KEY", "test-key")
    monkeypatch.delenv("CLS_WEIGHTS", raising=False)
    response = client.post(
        "/vision/workflow",
        json={"inputs": {"image": {"type": "base64", "value": base64.b64encode(_JPEG).decode()}}},
    )
    assert response.status_code == 200
    return response.json()


def test_normal_runs_write_no_debug_files(monkeypatch, tmp_path):
    monkeypatch.delenv("VISION_DEBUG_DIR", raising=False)
    monkeypatch.chdir(tmp_path)
    writes: list[Path] = []
    original_open = Path.open
    original_write_bytes = Path.write_bytes

    def recording_open(self, *args, **kwargs):
        writes.append(self)
        return original_open(self, *args, **kwargs)

    def recording_write_bytes(self, data):
        writes.append(self)
        return original_write_bytes(self, data)

    monkeypatch.setattr(Path, "open", recording_open)
    monkeypatch.setattr(Path, "write_bytes", recording_write_bytes)

    result = _proxy_once(monkeypatch)

    assert result["predictions"][0]["class"] == "Red7"
    assert writes == []
    assert list(tmp_path.iterdir()) == []


def test_vision_debug_dir_collects_the_dump_and_log(monkeypatch, tmp_path):
    monkeypatch.setenv("VISION_DEBUG_DIR", str(tmp_path))

    _proxy_once(monkeypatch)

    dumps = list(tmp_path.glob("pre_infer_*.jpg"))
    assert len(dumps) == 1
    assert dumps[0].read_bytes() == _JPEG
    lines = (tmp_path / "vision_debug.jsonl").read_text(encoding="utf-8").splitlines()
    assert [json.loads(line)["message"] for line in lines] == [
        "pre-infer image dump",
        "roboflow response stats",
    ]
