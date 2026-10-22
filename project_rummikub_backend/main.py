import base64
import json
import logging
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# Local two-stage pipeline (detector + classifier).  Imported lazily so the
# server still starts when ultralytics / opencv are not installed.
try:
    from local_pipeline import recognize as _local_recognize
    _LOCAL_PIPELINE_AVAILABLE = True
except ImportError:
    _LOCAL_PIPELINE_AVAILABLE = False

from models import GameState, SolveResponse
from solver import solve_rummikub
from validator import validate_board
from vision_grouping import GroupingOptions, group_vision_detections

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Rummikub Solver API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled backend error on %s %s: %s", request.method, request.url.path, exc)
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal Server Error"},
    )


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/solve", response_model=SolveResponse)
def solve(game_state: GameState) -> SolveResponse:
    is_valid, error_message = validate_board(game_state.board)
    if not is_valid:
        raise HTTPException(status_code=400, detail=error_message)

    start = time.perf_counter()
    optimal_state = solve_rummikub(game_state)
    elapsed_ms = int((time.perf_counter() - start) * 1000)

    return SolveResponse(
        original_state=game_state,
        optimal_state=optimal_state,
        is_valid=True,
        execution_time_ms=elapsed_ms,
    )


_DEFAULT_WORKFLOW_URL = (
    "https://serverless.roboflow.com/matan-kronfeld/workflows/rummikub-v1-logic"
)
_DEFAULT_WORKFLOW_FALLBACK_URL = (
    "https://serverless.roboflow.com/infer/workflows/matan-kronfeld/rummikub-v1-logic"
)

_WORKSPACE_ROOT = Path(__file__).resolve().parents[1]
_DEBUG_LOG_PATH = _WORKSPACE_ROOT / "debug-c981a2.log"
_DEBUG_DUMP_DIR = _WORKSPACE_ROOT / "debug_vision_dumps"


def _agent_log(location: str, message: str, hypothesis_id: str, data: dict[str, Any]) -> None:
    # #region agent log
    payload = {
        "sessionId": "c981a2",
        "runId": "pre-fix",
        "hypothesisId": hypothesis_id,
        "location": location,
        "message": message,
        "data": data,
        "timestamp": int(time.time() * 1000),
    }
    try:
        with _DEBUG_LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload) + "\n")
    except OSError:
        logger.exception("Failed to write debug log")
    # #endregion


def _decode_image_bytes(image: dict) -> Optional[bytes]:
    value = image.get("value")
    image_type = str(image.get("type") or "").lower()
    if not isinstance(value, str) or not value:
        return None
    if value.startswith("data:") and "," in value[:80]:
        value = value.split(",", 1)[1]
    if image_type in {"", "base64", "jpeg", "jpg", "png"}:
        try:
            return base64.b64decode(value, validate=False)
        except (ValueError, TypeError):
            return None
    return None


def _exif_orientation(tiff: bytes) -> Optional[int]:
    if len(tiff) < 8:
        return None
    endian = tiff[:2]
    little = endian == b"II"
    if not little and endian != b"MM":
        return None
    byteorder = "little" if little else "big"

    def u16(offset: int) -> int:
        return int.from_bytes(tiff[offset : offset + 2], byteorder)

    def u32(offset: int) -> int:
        return int.from_bytes(tiff[offset : offset + 4], byteorder)

    ifd0 = u32(4)
    if ifd0 + 2 > len(tiff):
        return None
    count = u16(ifd0)
    for index in range(count):
        entry = ifd0 + 2 + index * 12
        if entry + 12 > len(tiff):
            break
        if u16(entry) == 0x0112:
            return u16(entry + 8)
    return None


def _jpeg_meta(raw: bytes) -> dict[str, Any]:
    meta: dict[str, Any] = {
        "byte_len": len(raw),
        "is_jpeg": len(raw) >= 2 and raw[:2] == b"\xff\xd8",
        "width": None,
        "height": None,
        "exif_orientation": None,
        "has_exif": False,
        "magic": raw[:4].hex() if raw else "",
    }
    if not meta["is_jpeg"]:
        return meta
    index = 2
    length = len(raw)
    while index + 4 <= length:
        if raw[index] != 0xFF:
            index += 1
            continue
        while index < length and raw[index] == 0xFF:
            index += 1
        if index >= length:
            break
        marker = raw[index]
        index += 1
        if marker in (0xD8, 0xD9, 0x01) or 0xD0 <= marker <= 0xD7:
            continue
        if index + 2 > length:
            break
        segment_len = int.from_bytes(raw[index : index + 2], "big")
        if segment_len < 2 or index + segment_len > length:
            break
        payload = raw[index + 2 : index + segment_len]
        index += segment_len
        if marker == 0xE1 and payload.startswith(b"Exif\x00\x00"):
            meta["has_exif"] = True
            meta["exif_orientation"] = _exif_orientation(payload[6:])
        elif marker in (0xC0, 0xC1, 0xC2) and len(payload) >= 5:
            meta["height"] = int.from_bytes(payload[1:3], "big")
            meta["width"] = int.from_bytes(payload[3:5], "big")
    return meta


def _looks_like_detection(item: dict[str, Any]) -> bool:
    label = item.get("class") or item.get("class_name") or item.get("className")
    has_label = bool(label) or item.get("class_id") is not None
    has_xy = item.get("x") is not None and item.get("y") is not None
    has_bbox = item.get("bbox") is not None
    return has_label and (has_xy or has_bbox)


def _collect_predictions(node: Any, out: list[dict[str, Any]], key: Optional[str] = None) -> None:
    if isinstance(node, str) and len(node) > 200:
        return
    if isinstance(node, list):
        detections = [
            item for item in node if isinstance(item, dict) and _looks_like_detection(item)
        ]
        map_count = sum(isinstance(item, dict) for item in node)
        if detections and len(detections) == map_count:
            out.extend(detections)
            return
        if detections:
            out.extend(detections)
        for item in node:
            if isinstance(item, dict) and _looks_like_detection(item):
                continue
            _collect_predictions(item, out, key)
        return
    if not isinstance(node, dict):
        return
    key_lower = (key or "").lower()
    if "visual" in key_lower or key_lower in {"image", "output_image"}:
        return
    wrapped = node.get("predictions")
    if isinstance(wrapped, list):
        _collect_predictions(wrapped, out, "predictions")
    for child_key, value in node.items():
        if child_key == "predictions":
            continue
        _collect_predictions(value, out, str(child_key))


def _prediction_stats(parsed: Any) -> dict[str, Any]:
    predictions: list[dict[str, Any]] = []
    _collect_predictions(parsed, predictions)
    confidences: list[float] = []
    labels: list[str] = []
    for item in predictions:
        label = str(item.get("class") or item.get("class_name") or item.get("className") or "")
        if label and len(labels) < 12:
            labels.append(label)
        raw_conf = item.get("confidence", item.get("confidence_score", 1.0))
        try:
            confidence = float(raw_conf)
        except (TypeError, ValueError):
            continue
        if confidence > 1.0:
            confidence /= 100.0
        confidences.append(confidence)
    return {
        "raw_count": len(predictions),
        "sample_labels": labels,
        "conf_min": min(confidences) if confidences else None,
        "conf_max": max(confidences) if confidences else None,
        "below_015": sum(1 for value in confidences if value < 0.15),
        "between_015_and_04": sum(1 for value in confidences if 0.15 <= value < 0.4),
        "at_or_above_04": sum(1 for value in confidences if value >= 0.4),
        "top_keys": list(parsed.keys())[:12] if isinstance(parsed, dict) else [],
        "parsed_type": type(parsed).__name__,
    }


def _dump_pre_infer_jpeg(raw: bytes) -> Optional[str]:
    # #region agent log
    try:
        _DEBUG_DUMP_DIR.mkdir(parents=True, exist_ok=True)
        path = _DEBUG_DUMP_DIR / f"pre_infer_{int(time.time() * 1000)}.jpg"
        path.write_bytes(raw)
        return str(path)
    except OSError:
        logger.exception("Failed to dump pre-infer JPEG")
        return None
    # #endregion


def _inspect_and_dump_image(image: dict) -> None:
    raw = _decode_image_bytes(image)
    meta: dict[str, Any] = {
        "image_type": image.get("type"),
        "has_value": isinstance(image.get("value"), str),
        "value_chars": len(image["value"]) if isinstance(image.get("value"), str) else 0,
        "decoded": raw is not None,
        "dump_path": None,
    }
    if raw is not None:
        meta.update(_jpeg_meta(raw))
        meta["dump_path"] = _dump_pre_infer_jpeg(raw)
    # #region agent log
    _agent_log(
        "main.py:_inspect_and_dump_image",
        "pre-infer image dump",
        "H1",
        meta,
    )
    # #endregion


def _forward_to_roboflow(payload: dict) -> JSONResponse:
    api_key = os.environ.get("ROBOFLOW_API_KEY") or payload.get("api_key")
    if not api_key:
        raise HTTPException(status_code=400, detail="Missing Roboflow API key.")

    inputs = payload.get("inputs")
    image = None
    if isinstance(inputs, dict):
        image = inputs.get("image")
    image = image or payload.get("image")
    if not isinstance(image, dict):
        raise HTTPException(status_code=400, detail="Missing image input.")

    _inspect_and_dump_image(image)

    body = json.dumps({"api_key": api_key, "inputs": {"image": image}}).encode("utf-8")
    urls = [
        os.environ.get("ROBOFLOW_WORKFLOW_URL", _DEFAULT_WORKFLOW_URL),
        os.environ.get("ROBOFLOW_WORKFLOW_FALLBACK_URL", _DEFAULT_WORKFLOW_FALLBACK_URL),
    ]

    last_http_error: Optional[urllib.error.HTTPError] = None
    for url in urls:
        request = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                raw = response.read().decode("utf-8")
                try:
                    parsed = json.loads(raw) if raw else {}
                except json.JSONDecodeError:
                    parsed = {"detail": raw[:400]}
                boxes: list[dict[str, Any]] = []
                _collect_predictions(parsed, boxes)
                # FastAPI is a CORS proxy: no NMS, clustering, confidence, or
                # board/rack split. The JSON returned to Flutter is unchanged.
                print(f"Raw detections: {len(boxes)}")
                print(f"After filtering: {len(boxes)}")
                sample = [
                    str(item.get("class") or item.get("class_name") or item.get("className") or "")
                    for item in boxes[:12]
                ]
                logger.info("Raw detections: %s sample=%s", len(boxes), sample)
                logger.info(
                    "After filtering: %s (vision proxy does not filter detections)",
                    len(boxes),
                )
                # #region agent log
                _agent_log(
                    "main.py:_forward_to_roboflow",
                    "roboflow response stats",
                    "H3",
                    {
                        "status": response.status,
                        "url_path": url.split(".com", 1)[-1],
                        **_prediction_stats(parsed),
                    },
                )
                # #endregion
                return JSONResponse(status_code=response.status, content=parsed)
        except urllib.error.HTTPError as error:
            last_http_error = error
            if error.code == 404:
                continue
            raw = error.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(raw) if raw else {"detail": f"Roboflow HTTP {error.code}"}
            except json.JSONDecodeError:
                parsed = {"detail": raw[:400] or f"Roboflow HTTP {error.code}"}
            # #region agent log
            _agent_log(
                "main.py:_forward_to_roboflow",
                "roboflow HTTP error",
                "H4",
                {"status": error.code, **_prediction_stats(parsed)},
            )
            # #endregion
            return JSONResponse(status_code=error.code, content=parsed)
        except urllib.error.URLError as error:
            raise HTTPException(
                status_code=502,
                detail=f"Could not reach Roboflow: {error.reason}",
            ) from error

    if last_http_error is not None:
        raw = last_http_error.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw) if raw else {"detail": "Roboflow workflow not found."}
        except json.JSONDecodeError:
            parsed = {"detail": raw[:400] or "Roboflow workflow not found."}
        return JSONResponse(status_code=404, content=parsed)

    raise HTTPException(status_code=502, detail="Could not reach Roboflow.")


@app.post("/vision/workflow")
async def vision_workflow(request: Request) -> JSONResponse:
    """Tile detection and classification endpoint.

    When ``CLS_WEIGHTS`` is set in the environment the local two-stage pipeline
    (YOLO detector + YOLO classifier) is used and the Roboflow cloud is not
    contacted at all.  Otherwise the request is forwarded to the Roboflow
    Workflow REST API unchanged.

    The response shape is always a Roboflow-style
    ``{"image": {...}, "predictions": [...]}`` dict so that ``vision_grouping.py``
    and the Flutter app do not need to change.
    """
    if _LOCAL_PIPELINE_AVAILABLE and os.environ.get("CLS_WEIGHTS"):
        content_type = request.headers.get("content-type", "")
        if "multipart/form-data" in content_type:
            # Flutter sends the image as a multipart file upload.
            form = await request.form()
            file_field = form.get("file") or next(iter(form.values()), None)
            if file_field is None:
                raise HTTPException(status_code=400, detail="No file field in multipart form.")
            image_bytes = await file_field.read()
        elif "application/json" in content_type:
            # Legacy JSON path: base64-encoded image in the usual Roboflow body.
            payload = await request.json()
            inputs = payload.get("inputs")
            image = (inputs.get("image") if isinstance(inputs, dict) else None) or payload.get("image")
            if not isinstance(image, dict):
                raise HTTPException(status_code=400, detail="Missing image input.")
            image_bytes = _decode_image_bytes(image)
            if image_bytes is None:
                raise HTTPException(status_code=400, detail="Could not decode image bytes.")
        else:
            # Raw bytes fallback.
            image_bytes = await request.body()
        try:
            result = _local_recognize(image_bytes)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return JSONResponse(content=result)

    # Fallback: forward to hosted Roboflow Workflow.
    payload = await request.json()
    return _forward_to_roboflow(payload)


@app.post("/vision/group")
def vision_group(payload: dict) -> dict[str, Any]:
    """Group a Roboflow response without changing the workflow proxy contract.

    The request may be a workflow response directly, or
    ``{"response": <workflow response>, "options": {...}}``. Supported options
    are ``image_height``, ``rack_boundary_y``, ``rack_bottom_fraction``,
    ``row_tolerance``, and ``meld_gap_width_ratio``.
    """
    raw_options = payload.get("options", {})
    if not isinstance(raw_options, dict):
        raise HTTPException(status_code=400, detail="options must be an object.")
    allowed = {
        "image_height",
        "rack_boundary_y",
        "rack_bottom_fraction",
        "row_tolerance",
        "meld_gap_width_ratio",
    }
    unknown = set(raw_options) - allowed
    if unknown:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown grouping options: {', '.join(sorted(unknown))}.",
        )
    try:
        options = GroupingOptions(
            **{
                key: float(value) if value is not None else None
                for key, value in raw_options.items()
            }
        )
    except (TypeError, ValueError) as error:
        raise HTTPException(
            status_code=400, detail="Grouping options must be numeric."
        ) from error
    if not 0 <= options.rack_bottom_fraction <= 1:
        raise HTTPException(
            status_code=400, detail="rack_bottom_fraction must be between 0 and 1."
        )
    if options.row_tolerance <= 0 or options.meld_gap_width_ratio < 0:
        raise HTTPException(
            status_code=400,
            detail="row_tolerance must be positive and meld_gap_width_ratio non-negative.",
        )
    source = payload.get("response", payload)
    return group_vision_detections(source, options=options)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
