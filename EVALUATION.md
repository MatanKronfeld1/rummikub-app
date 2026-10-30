# Evaluation

All numbers below were measured on 2026-10-29 with the code in this
repository. Commands are given so every number can be reproduced.

## 1. Vision (two-stage detector + classifier)

**Data.** The held-out split is by original photo (`datasets/tiles_det/split.txt`),
so no augmented copy of a validation tile was seen in training: 11 photos,
251 labelled tiles.

**Command** (repo root, CPU, ultralytics 8.4.173 / torch 2.14.1 for inference):

```bash
python tools/evaluate_pipeline.py --detector detect/best.pt --classifier classify/best.pt --device cpu
```

The script feeds the classifier exactly the crop the Roboflow Workflow and the
backend use (`tools/tile_crops.py`: tile box + 5% margin per side, 224×224).

| Metric | Result |
|---|---|
| Detector recall @ IoU 0.50 | 237 / 251 = **0.944** |
| Classifier top-1 on matched tiles | 223 / 237 = **0.941** |
| End-to-end tile accuracy (both stages right) | 223 / 251 = **0.888** |
| Photos with every tile exactly right | 2 / 11 = **0.182** |
| Extra detections (box with no tile) | 1 |

**Top confusions** (truth → predicted; every pair occurred once):

| Kind | Pairs |
|---|---|
| Color (4) | Black7→Blue7, Blue13→Black13, Blue5→Black5, Blue5→Red5 |
| Digit (10) | Red5→Red6, Blue6→Blue5, Blue8→Blue10, Orange12→Orange4, Blue10→Blue9, Red13→Red6, Blue10→Blue5, Orange5→Orange3, Red12→Red13, Blue2→Blue4 |

"Orange" is the dataset's name for the app's YELLOW.

**Reading.** Per tile the pipeline is right about 9 times in 10. But a photo
holds about 23 tiles, so a fully correct photo is rare (2 of 11). That is why
the app has a correction screen before solving. The errors are spread out: no
single pair repeats. Blue is involved in 9 of the 14 confusions, and
Blue/Black is the main color mix-up.

**Backend check with a real photo.** The same weights, served by the backend's
local pipeline (`CLS_WEIGHTS` + `DETECTOR_WEIGHTS`). One held-out photo
(`IMG_4466`, 4032×3024) was posted to `/vision/workflow` as base64 JSON, the way
the web app sends it. Response: HTTP 200, 22 boxes. All 21 ground-truth tiles
came back with the correct label, plus 1 box labelled `Unknown`, which the app
drops.

**Not measured: the hosted Workflow.** `tools/evaluate_workflow.py` measures the
deployed Roboflow Workflow and needs the private `ROBOFLOW_API_KEY`, which was
not available in this environment. To measure it:

```powershell
$env:ROBOFLOW_API_KEY = "<key>"   # this shell only
python tools/evaluate_workflow.py --workspace matan-kronfeld --workflow rummikub-v2-two-stage
```

## 2. Solver (CP-SAT)

**Method.** The solver packs legal sets over tile types, a (color, value) pair
or the joker, with an integer count per candidate set. Candidates come from
`meld_generator`. Runs are capped at 5 tiles (a longer run is always two legal
runs) and are joined back together afterwards. The constraints:

- every board tile stays on the board;
- no tile is used twice;
- every set is a legal RUN or GROUP of 3+ tiles.

The model runs in two phases. Phase 1 maximizes rack tiles placed. Phase 2
keeps that count fixed and maximizes the number of original sets left untouched,
so the result stays readable.

A whole call never runs longer than 5 s. If no solution is found in time, or a
final self-check fails (`validate_board`, tile-id conservation), the solver
returns the input unchanged with `tiles_used_from_rack = 0`.

**Command** (from `project_rummikub_backend/`):

```bash
python benchmark_solver.py
```

Each state is solved 5 times in-process, on a laptop CPU (Intel family 6
model 140, Windows 11, Python 3.12.6, OR-Tools 9.15). The times cover the whole
`solve_rummikub` call, model building included.

| State | Board tiles | Rack tiles | Placed | CP-SAT status | Legal, board kept | Median | Worst |
|---|---|---|---|---|---|---|---|
| 1. Extend and complete | 10 | 6 | 4 | OPTIMAL | yes | 7 ms | 11 ms |
| 2. Full rearrangement | 12 | 4 | 3 | OPTIMAL | yes | 4 ms | 5 ms |
| 3. Crowded late game (seed 3) | 75 | 22 | 22 | OPTIMAL | yes | 1642 ms | 1681 ms |

1. The best move takes BLACK5 out of a full group of fives to extend the black
   run to 3–8. The joker then stands in for BLUE12 so BLUE13 fits.
2. Three groups (1s, 2s, 3s) have to become three runs to place RED4 and
   BLUE4. YELLOW8 extends a run, and BLACK13 cannot be placed.
3. A seeded random deck: 75 tiles are laid out as a legal board, then 22
   other tiles are the rack. The 1.6 s is mostly the phase-2 tie-breaker,
   which is capped at 1 s. Phase 1, the proven-optimal placement count, takes
   about 0.6 s.

**This laptop throttles under sustained load.** A fixed pure-Python loop took
205 ms before and 189 ms after the benchmark, so this run was not throttled. In
an earlier throttled session the same loop took 650–840 ms. Then the crowded
state took up to 3.6 s, still inside the 5 s budget and still OPTIMAL in phase 1.

**Live API check.** `uvicorn main:app --port 8000`, then a `curl` POST of state 1
to `/solve`: HTTP 200 in 24 ms round trip, `execution_time_ms: 17`, 4 tiles
placed. The board passed `validate_board`, every board tile id was still on
the board, and `original_state` echoed the request. An invalid board returned
HTTP 400 with the failing set named.

## 3. Test suites

| Suite | Command | Result |
|---|---|---|
| Backend | `cd project_rummikub_backend && pytest` | 94 passed |
| Root (synthetic data generator) | `pytest test_rummikub_synth_gen.py` | 2 passed |
| Flutter | `cd Project-Rummikub_frontend && flutter test` | 93 passed |
| Flutter lints | `flutter analyze` | no issues |

The Dart and Python set validators are held to one shared fixture,
`project_rummikub_backend/tests/fixtures/validator_cases.json` (25 cases).
Both `tests/test_validator.py` and `test/validator_parity_test.dart` read it.
