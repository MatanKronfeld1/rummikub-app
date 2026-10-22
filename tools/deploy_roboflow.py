#!/usr/bin/env python3
"""Upload trained YOLO11 weights to versioned Roboflow projects.

Only the detector is uploaded by default. Roboflow's supported-models table
accepts uploaded *classification* weights only for ViT and ResNet, so the
YOLO11 classifier normally stays in the FastAPI backend (CLS_WEIGHTS, see
project_rummikub_backend/local_pipeline.py). ``--try-classifier`` attempts the
upload anyway.

Run it in an environment with ``ultralytics==8.3.40`` installed: the upload
archive records the *installed* ultralytics version, and Roboflow only accepts
YOLO11 weights from ``ultralytics<=8.3.40``.

Without ``--execute`` the weights are packaged locally (no network) so path,
task and version problems show up before anything is uploaded.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import requests

MAX_ULTRALYTICS = (8, 3, 40)
MIN_ULTRALYTICS = (8, 3, 0)
DET_CANDIDATES = (Path("detect/best.pt"), Path("runs/rummikub/detect/weights/best.pt"))
CLS_CANDIDATES = (Path("classify/best.pt"), Path("runs/rummikub/classify/weights/best.pt"))


def _version_tuple(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("+")[0].split(".")[:3])


def _first_existing(candidates: tuple[Path, ...]) -> Path:
    return next((path for path in candidates if path.is_file()), candidates[0])


def check_versions(weights: Path, strict: bool) -> None:
    """Fail when the checkpoint or the installed ultralytics is outside Roboflow's range."""
    import torch
    import ultralytics

    trained = torch.load(weights, map_location="cpu", weights_only=False).get("version", "unknown")
    installed = ultralytics.__version__
    print(f"  trained with ultralytics {trained}, installed ultralytics {installed}")
    problems = []
    if trained == "unknown" or not MIN_ULTRALYTICS <= _version_tuple(trained) <= MAX_ULTRALYTICS:
        problems.append(f"checkpoint was trained with ultralytics {trained}; retrain with 8.3.40")
    if not MIN_ULTRALYTICS <= _version_tuple(installed) <= MAX_ULTRALYTICS:
        problems.append(f"installed ultralytics is {installed}; run: pip install ultralytics==8.3.40")
    if not problems:
        return
    message = "; ".join(problems)
    if strict:
        raise SystemExit(f"Roboflow rejects this upload: {message}.")
    print(f"  WARNING (would block --execute): {message}.")


def package(weights: Path, model_type: str):
    """Build roboflow_deploy.zip in a temp dir without prompting (unlike Version.deploy)."""
    from roboflow.util.model_processor import package_custom_weights

    bundle = package_custom_weights(model_type, str(weights.parent), weights.name)
    size_mb = bundle.archive_path.stat().st_size / 1e6
    print(f"  packaged as {bundle.model_type}: {bundle.archive_path} ({size_mb:.1f} MB)")
    for warning in bundle.warnings:
        print(f"  warning: {warning}")
    return bundle


def upload(api_key: str, workspace: str, project_id: str, version: int, bundle) -> None:
    """Attach the archive to a dataset version, raising on every HTTP failure.

    Mirrors roboflow's Version._upload_zip, which only prints errors and returns.
    """
    from roboflow import Roboflow
    from roboflow.config import API_URL, APP_URL
    from roboflow.util.model_processor import validate_model_type_for_project

    project = Roboflow(api_key=api_key).workspace(workspace).project(project_id)
    validate_model_type_for_project(bundle.model_type, project.type, project_id)
    try:
        project.version(version)
    except Exception as error:
        raise SystemExit(
            f"{workspace}/{project_id} has no version {version}. Upload the dataset and click "
            f"'Generate' in the Roboflow app first ({error})."
        ) from error

    response = requests.get(
        f"{API_URL}/{workspace}/{project_id}/{version}/uploadModel",
        params={"api_key": api_key, "modelType": bundle.model_type, "nocache": "true"},
        timeout=60,
    )
    if response.status_code != 200:
        raise SystemExit(f"uploadModel failed ({response.status_code}): {response.text}")
    with bundle.archive_path.open("rb") as archive:
        put = requests.put(response.json()["url"], data=archive, timeout=600)
    if put.status_code >= 300:
        raise SystemExit(f"Weights PUT failed ({put.status_code}): {put.text}")
    print(f"  uploaded. Processing status: {APP_URL}/{workspace}/{project_id}/{version}")


def deploy(args, label: str, weights: Path, project_id: str, version: int, model_type: str) -> None:
    print(f"{label}: {weights} -> {args.workspace}/{project_id}/{version}")
    if not weights.is_file():
        raise SystemExit(f"Weights not found: {weights}")
    check_versions(weights, strict=args.execute)
    bundle = package(weights, model_type)
    try:
        if args.execute:
            upload(args.api_key, args.workspace, project_id, version, bundle)
    finally:
        bundle.cleanup()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--workspace", default="matan-kronfeld")
    parser.add_argument("--det-project", default="rummikub-tiles-qu08l")
    parser.add_argument("--det-version", type=int, default=1)
    parser.add_argument("--det-weights", type=Path, default=_first_existing(DET_CANDIDATES))
    parser.add_argument(
        "--try-classifier",
        action="store_true",
        help="Also attempt the YOLO11 classifier upload (not in Roboflow's supported list).",
    )
    parser.add_argument("--cls-project", default="rummikub-tile-cls")
    parser.add_argument("--cls-version", type=int, default=1)
    parser.add_argument("--cls-weights", type=Path, default=_first_existing(CLS_CANDIDATES))
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Perform uploads. Without this flag, only package locally and validate.",
    )
    args = parser.parse_args()

    args.api_key = os.environ.get("ROBOFLOW_API_KEY", "")
    if args.execute and not args.api_key:
        raise SystemExit("Set ROBOFLOW_API_KEY in the environment before using --execute.")

    deploy(args, "Detection", args.det_weights, args.det_project, args.det_version, "yolov11")
    if args.try_classifier:
        deploy(args, "Classification", args.cls_weights, args.cls_project, args.cls_version, "yolov11-cls")

    if not args.execute:
        print("Dry run only (packaged, nothing uploaded); pass --execute to upload.")
    else:
        print(
            "Done. Once Roboflow shows the model as ready it is served at "
            f"https://detect.roboflow.com/{args.det_project}/{args.det_version}"
        )


if __name__ == "__main__":
    main()
