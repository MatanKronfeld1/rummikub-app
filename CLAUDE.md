# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Capstone project "Rummikub Smart Assistant" (3-student team, see [academic_instructions.md](academic_instructions.md), in Hebrew): photograph the board and the rack, recognize tiles, let the user correct recognition, then compute the move that drops the most rack tiles. Moves only need to be legal at the end of the turn (any rearrangement of board sets is allowed). [architecture.md](architecture.md) is the original design spec (also copied into the frontend and backend folders, identical); its rules still apply:

- The CP-SAT solver has a hard 5-second limit (`solver.parameters.max_time_in_seconds = 5.0`).
- Correction UI uses tap-to-select / tap-to-move, no drag-and-drop.
- Keep it simple: tight deadline, no complex DevOps or UI animation.
- Frontend, Firestore and solver all use the same JSON shapes: Tile `{id, color: RED|BLUE|BLACK|YELLOW|JOKER, value: 1-13 (0 for joker)}`, Set `{id, type: RUN|GROUP|INVALID, tiles}`, GameState `{board: [Set], rack: [Tile]}`.

## Layout

The repo has three parts:

- [project_rummikub_backend/](project_rummikub_backend/): FastAPI service (Python 3.10, Dockerfile targets Cloud Run).
- [Project-Rummikub_frontend/](Project-Rummikub_frontend/): Flutter app (package `rummikub_assistant`) plus Firebase config and a Node 22 Cloud Function in `functions/`.
- Root and [tools/](tools/): the ML training pipeline for the vision models. Large untracked data/model folders live at the root (`datasets/`, `runs/`, `your_dataset/`, `*.pt`, zips). Don't commit them.

## Commands

Backend (run from `project_rummikub_backend/`; `pytest.ini` sets `pythonpath = .`):

```bash
pip install -r requirements.txt
uvicorn main:app --reload --port 8000        # or: python main.py
pytest                                        # all tests
pytest tests/test_meld_generator.py -k joker  # single file / test
```

Frontend (run from `Project-Rummikub_frontend/`):

```bash
flutter pub get
flutter analyze
flutter test
flutter test test/set_validator_test.dart --plain-name "some test name"
flutter run --dart-define=ROBOFLOW_API_KEY=... [--dart-define=SOLVER_URL=https://host/solve | --dart-define=SOLVER_HOST=192.168.x.x]
flutter build web && firebase deploy            # hosting serves build/web
```

Other `--dart-define`s are in [lib/config/roboflow_config.dart](Project-Rummikub_frontend/lib/config/roboflow_config.dart): `ROBOFLOW_WORKFLOW_ID` (default `rummikub-v1-logic`), `ROBOFLOW_WORKSPACE`, `ROBOFLOW_WORKFLOW_URL`, `ROBOFLOW_CONFIDENCE_CUTOFF`. API keys are only passed through env/dart-define, never written to files.

Vision training: see [TRAINING.md](TRAINING.md) for the full flow (`tools/make_detector_dataset.py`, `tools/make_classifier_dataset.py`, Colab `tools/train_models.py`, `tools/evaluate_pipeline.py`, `tools/deploy_roboflow.py`, `tools/evaluate_workflow.py`, `tools/autolabel.py`). Training requires `ultralytics>=8.3,<=8.3.40`, because Roboflow only accepts weights from that range. The root `pytest` covers `test_rummikub_synth_gen.py` (synthetic rack dataset generator).

## Architecture

### Vision path

1. Flutter `VisionService` ([lib/services/vision_service.dart](Project-Rummikub_frontend/lib/services/vision_service.dart)) sends the board photo and the rack photo separately to a Roboflow Workflow. Native builds call `serverless.roboflow.com` directly. Web builds call the same-origin `/vision/workflow` proxy to avoid CORS. That proxy is the backend endpoint locally, and on Firebase Hosting it is rewritten to the `visionWorkflow` Cloud Function ([functions/index.js](Project-Rummikub_frontend/functions/index.js)). The two requests run in parallel (`Future.wait`). Photos are prepared by [lib/services/vision_image.dart](Project-Rummikub_frontend/lib/services/vision_image.dart): a photo that is upright and within 1920 px keeps its original bytes (decided from the file header, no decode); otherwise web uses the browser's own decode / resize / JPEG encode (`vision_image_rewrite_web.dart`; `compute` runs on the UI thread on web) and other platforms use a background isolate. EXIF orientation is read from the header, because `image` 4.9.2 drops it when decoding a JPEG. `test/vision_image_web_test.dart` only runs in a browser: `flutter test --platform chrome test/vision_image_web_test.dart`.
2. Backend `/vision/workflow` forwards to Roboflow unless `CLS_WEIGHTS` is set. In that case it runs [local_pipeline.py](project_rummikub_backend/local_pipeline.py) instead: a local or hosted detector plus a local classifier, configured by the `DETECTOR_WEIGHTS`, `ROBOFLOW_API_KEY`, `DETECTOR_MODEL_ID` and `MIN_CLS_CONF` env vars. Either way the response keeps the Roboflow `{image, predictions}` shape. Only the detector can be hosted on Roboflow: Roboflow doesn't accept uploaded YOLO11 classification weights. The intended setup is the hosted detector plus the backend classifier. Upload with `tools/deploy_roboflow.py`, which must run under `ultralytics==8.3.40`.
3. The model is two-stage: a one-class tile detector, then a 53-class crop classifier. Class labels look like `Red7`, `Orange4` or `Joker`. "Orange" in labels maps to `YELLOW` in the app. Crop geometry must match everywhere (tile box + 5% margin per side, 224x224). It is defined once in [tools/tile_crops.py](tools/tile_crops.py) and used by training, evaluation and autolabel. `local_pipeline.py` loads that file by path when it exists. The Docker image only contains the backend folder, so it uses an inlined copy (`_workflow_view_inline`), and `tests/test_local_pipeline_crops.py` checks the copy gives identical pixels.
4. Detections become a GameState in Dart, in [lib/services/vision_parser.dart](Project-Rummikub_frontend/lib/services/vision_parser.dart). Rack rows are grouped by y and ordered by x. Board tiles are linked when their centers are within about one tile pitch (the median nearest-neighbor center distance, which works at any rotation). Two rule-based guardrails follow: an invalid line that splits into valid sets is cut, and fragments whose union is valid are rejoined. The backend has a parallel Python implementation, [vision_grouping.py](project_rummikub_backend/vision_grouping.py), exposed as `/vision/group`. The Flutter app currently does not call it. Keep the two in sync; both run the shared [tests/fixtures/board_grouping_cases.json](project_rummikub_backend/tests/fixtures/board_grouping_cases.json). When the correction screen shows over-merged sets, the user can fix them with the ✂ button between tiles or with Auto-split.

### Correction → solve → persist

- `GameProvider` ([lib/providers/game_provider.dart](Project-Rummikub_frontend/lib/providers/game_provider.dart), the single Provider) holds the state. Every update reclassifies sets through `SetValidator` ([lib/logic/set_validator.dart](Project-Rummikub_frontend/lib/logic/set_validator.dart)). The correction screen blocks submission while sets are invalid.
- `SetValidator` (Dart) and [validator.py](project_rummikub_backend/validator.py) implement the same rules. Keep them in sync: min 3 tiles, groups of up to 4 distinct colors, runs of one color with strictly consecutive values in board order, jokers fill gaps.
- `ApiService` POSTs to `/solve`. The URL comes from [lib/config/solver_config.dart](Project-Rummikub_frontend/lib/config/solver_config.dart): `127.0.0.1:8000` by default, `10.0.2.2` on the Android emulator, same-origin on hosted web. The backend validates the board (400 on an invalid board), then calls `solve_rummikub`.
- [solver.py](project_rummikub_backend/solver.py) is a CP-SAT set-packing model over tile *types*, with integer copies per candidate. Candidates come from [meld_generator.py](project_rummikub_backend/meld_generator.py), run once on a one-tile-per-type deck with runs capped at 5 tiles; pieces are joined back afterwards. Physical-id enumeration hits the generator caps on duplicate tiles, so don't feed it real pools. Phase 1 maximizes rack tiles placed, phase 2 keeps the most original sets intact. The whole call is capped at 5 s. If no solution is found in time, or a self-check fails, the input is echoed. `/solve` also returns 400 on repeated tile ids. Benchmarks and vision numbers are in [EVALUATION.md](EVALUATION.md); the local demo is in [DEMO.md](DEMO.md) / `run_demo.ps1`.
- The Dart and Python validators share [tests/fixtures/validator_cases.json](project_rummikub_backend/tests/fixtures/validator_cases.json) (`tests/test_validator.py`, `test/validator_parity_test.dart`). Add a case there when a rule changes.
- `CaptureScreen` keeps one `_Photo` per slot. Its prepared bytes are both the preview and what `VisionService` receives. It takes the picker, `VisionService` and the prepare function as constructor test seams (see `test/capture_screen_test.dart`). Coming back from the correction screen keeps both photos on purpose.
- The Play screen is a first-person tabletop, not a form. [lib/widgets/table_scene.dart](Project-Rummikub_frontend/lib/widgets/table_scene.dart) holds `SceneLayout` (all rectangles from one `Size`, unit-tested) and the painters; [photo_zones.dart](Project-Rummikub_frontend/lib/widgets/photo_zones.dart) holds the hover-reveal zones and the photo cards (Replace / Delete); [hover_reveal.dart](Project-Rummikub_frontend/lib/widgets/hover_reveal.dart) is the shared hover / focus / tap-to-toggle behavior, so touch screens work without hover. The decorative side and far racks have no behavior. All secondary actions (manual entry, community challenge, history, leaderboard, account) are in [hover_drawer.dart](Project-Rummikub_frontend/lib/widgets/hover_drawer.dart), a hover-to-open, click-to-pin drawer; they are pushed routes over the Play screen, so `AccountScreen` pops to the root before signing out. Widget tests that pump anything with the wordmark must set `brandFontsEnabled = false` (from `auth_brand.dart`): Google Fonts cannot load in tests and its failed load surfaces as an uncaught async error.
- `FirebaseService` ([lib/services/firebase_service.dart](Project-Rummikub_frontend/lib/services/firebase_service.dart)) uses the Firestore collections `users`, `games_history`, `global_arena` (community "beat the algorithm" challenges, which feed the leaderboard) and `vision_corrections` (the vision output paired with the user-corrected output, used as training data). Rules are in `firestore.rules`.

### Debug instrumentation

Off by default, so normal runs write nothing. In the backend, `VISION_DEBUG_DIR=<folder>` makes `main.py` write the forwarded JPEGs and `vision_debug.jsonl` there. In the app, `--dart-define=VISION_DEBUG=true` keeps the last recognition's JPEGs and Workflow JSON (`roboflow_debug_dump.dart`) and shows the download button on the correction screen. Old `.cursor/debug-*.log` files are output of earlier sessions.
