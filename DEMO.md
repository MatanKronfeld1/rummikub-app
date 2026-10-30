# Running the demo locally

## One command

From the repo root, in PowerShell:

```powershell
.\run_demo.ps1
```

The script:

1. starts the backend (`uvicorn main:app --port 8000`) in a second window;
2. waits until `/health` answers;
3. runs the Flutter app in Chrome against it.

Vision setup:

- If `classify\best.pt` and `detect\best.pt` exist, the backend runs the local
  detector and classifier, and **no Roboflow key is needed**.
- Otherwise, set `$env:ROBOFLOW_API_KEY` in the same shell first; the backend
  then forwards recognition to the Roboflow Workflow.

To run on another target, pass a `flutter devices` id, for example
`.\run_demo.ps1 -Device windows`. On a phone, the backend address has to be
reachable from the phone (see `SOLVER_HOST` below).

**On a phone**, connect it by USB (developer mode + USB debugging), confirm it
shows in `flutter devices`, then run:

```powershell
.\run_demo.ps1 -Lan -Device <your-phone-id>
```

`-Lan` finds this PC's Wi-Fi address, starts the backend on `0.0.0.0` so the
phone can reach it, and points the app at it — including the vision proxy, so
the phone needs no Roboflow key. Pass `-HostAddress 192.168.1.x` to choose the
address yourself, and `-DryRun` to print the commands without starting them.

Before the first run, load `http://<pc-ip>:8000/health` in the phone's browser.
If it does not open, allow the port once in an admin PowerShell:

```powershell
New-NetFirewallRule -DisplayName 'Rummikub backend 8000' -Direction Inbound -LocalPort 8000 -Protocol TCP -Action Allow
```

Prerequisites, once:

```powershell
cd project_rummikub_backend; pip install -r requirements.txt; cd ..
cd Project-Rummikub_frontend; flutter pub get; cd ..
```

Signing in uses the project's Firebase Auth. Email/password sign-up works from
the sign-in screen.

## Demo script (about 3 minutes)

1. **Play** tab → **Step 1, Table photo** → Camera or Gallery. The step card
   shows the preview, file name and size, and turns **Done**.
2. **Step 2, Rack photo** unlocks → take the rack photo.
3. **Recognize tiles** → the correction screen opens with the recognized sets.
   Tap a tile, then tap a **+** to move it. Tap it again to change its color
   or value. Invalid sets get a red border, and **Solve** stays disabled until
   every set is legal.
4. **Solve** → the result screen shows:
   - the tiles placed from the rack, highlighted;
   - the board after and before the move;
   - the solve time.

   The game is saved to **History**.
5. Back twice → both photos are still on the capture screen. Retake just one
   of them, or tap **Start over**.

**Enter tiles manually** skips the camera. **Community challenge** replays
solver puzzles from other players.

## Running the parts by hand

Backend (from `project_rummikub_backend/`):

```powershell
$env:CLS_WEIGHTS = "$PWD\..\classify\best.pt"      # optional: local vision
$env:DETECTOR_WEIGHTS = "$PWD\..\detect\best.pt"   # optional: local detector too
uvicorn main:app --port 8000
```

Quick check:

```bash
curl http://127.0.0.1:8000/health
curl -X POST http://127.0.0.1:8000/solve -H "Content-Type: application/json" \
  -d '{"board":[{"id":"reds","type":"RUN","tiles":[{"id":"r7","color":"RED","value":7},{"id":"r8","color":"RED","value":8},{"id":"r9","color":"RED","value":9}]}],"rack":[{"id":"r10","color":"RED","value":10}]}'
```

App (from `Project-Rummikub_frontend/`):

```powershell
flutter run -d chrome                                   # web: uses the backend for vision
flutter run --dart-define=ROBOFLOW_API_KEY=<key>        # phone/emulator: calls Roboflow directly
```

Tests:

```powershell
cd project_rummikub_backend; pytest; cd ..
pytest test_rummikub_synth_gen.py
cd Project-Rummikub_frontend; flutter analyze; flutter test
```

## Configuration reference

Secrets are passed only through the environment or `--dart-define`. Never
write them to a file.

### Backend environment variables

| Variable | Default | Effect |
|---|---|---|
| `ROBOFLOW_API_KEY` | unset | Key used by the `/vision/workflow` proxy and by the hosted detector. |
| `ROBOFLOW_WORKFLOW_URL` | `…/matan-kronfeld/workflows/rummikub-v1-logic` | Workflow the proxy forwards to. |
| `ROBOFLOW_WORKFLOW_FALLBACK_URL` | `…/infer/workflows/matan-kronfeld/rummikub-v1-logic` | Tried when the first URL returns 404. |
| `CLS_WEIGHTS` | unset | Path to the classifier `best.pt`. When set, `/vision/workflow` runs the local two-stage pipeline instead of forwarding. |
| `DETECTOR_WEIGHTS` | unset | Path to the detector `best.pt`. With `CLS_WEIGHTS`, runs detection locally too (no Roboflow at all). |
| `DETECTOR_MODEL_ID` | `rummikub-tiles-qu08l/1` | Hosted detector used when `DETECTOR_WEIGHTS` is unset. |
| `MIN_CLS_CONF` | `0.35` | Below this classifier confidence a tile is labelled `Unknown`, and the app drops it. |
| `VISION_DEBUG_DIR` | unset | Diagnostics, off by default. When set, every proxied request writes the JPEG it forwards and a line in `vision_debug.jsonl` to this folder. |
| `PORT` | `8000` | Port in the Docker image (Cloud Run sets it). |

The solver has no settings. Its 5-second limit is fixed in `solver.py`
(`TIME_LIMIT_SECONDS`).

### Flutter `--dart-define`s

| Define | Default | Effect |
|---|---|---|
| `ROBOFLOW_API_KEY` | empty | Needed only when the app calls Roboflow directly (phone/desktop builds). Web builds use the backend proxy. |
| `ROBOFLOW_WORKSPACE` | `matan-kronfeld` | Workspace in the Workflow URL. |
| `ROBOFLOW_WORKFLOW_ID` | `rummikub-v1-logic` | Workflow id in the URL. |
| `ROBOFLOW_WORKFLOW_URL` | derived | Full Workflow URL. Point it at `http://<backend>:8000/vision/workflow` to use the backend from a phone without a key. |
| `ROBOFLOW_IMAGE_INPUT` | `image` | Name of the Workflow's image input. |
| `ROBOFLOW_CONFIDENCE_CUTOFF` | `0.15` | Detections below this confidence are dropped. |
| `SOLVER_URL` | derived | Full `/solve` URL. On web, `/vision/workflow` is derived from it. |
| `SOLVER_HOST` | `127.0.0.1` (`10.0.2.2` on the Android emulator) | Host of the backend on port 8000, e.g. your PC's LAN IP for a phone. |
| `VISION_DEBUG` | `false` | Keeps the exact JPEGs and Workflow JSON of the last recognition and shows a download button for them on the correction screen. |

### Cloud Function (hosted web)

`functions/index.js` (`visionWorkflow`, behind the Firebase Hosting rewrite of
`/vision/workflow`) reads `ROBOFLOW_API_KEY` from its runtime environment.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "Could not reach the solver at 127.0.0.1" | Backend not running, or the app targets another host. Start it, or pass `SOLVER_URL`/`SOLVER_HOST`. |
| "Tile recognition is not set up in this build" | Phone/desktop build without `ROBOFLOW_API_KEY`. Pass it, point `ROBOFLOW_WORKFLOW_URL` at the backend, or use manual entry. |
| "Camera access is turned off for this app" | Permission was denied once. Allow it in the device settings, or use Gallery. |
| "No tiles were recognized in either photo" | Blurry or dark photo, or the wrong backend mode. Retake closer and in good light. |
