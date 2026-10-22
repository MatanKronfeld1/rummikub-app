# Rummikub vision training

The pipeline is a one-class tile detector followed by a 53-class crop
classifier, chained in a Roboflow Workflow:

```
image -> Object Detection -> Detection Offset (10%) -> Dynamic Crop
      -> Classification -> Detections Classes Replacement -> boxes + class names
```

The held-out split is by original photo, so augmented versions of a tile cannot
leak into validation. Every tool shares `tools/tile_crops.py`, so training,
local evaluation, auto-labeling and the Workflow all show the classifier the
same kind of crop (tile box + 5% margin per side, resized to 224x224).

## 1. Prepare data locally

```powershell
python tools/make_detector_dataset.py
python tools/make_classifier_dataset.py
```

Results (all git-ignored, under `datasets/`):

| File | What it is |
| --- | --- |
| `tiles_det/` | one-class detector dataset, image-level train/val split |
| `tiles_cls/train` | real crops (`real_*`) + augmented/recolored crops (`aug_*`), ~180 per class |
| `tiles_cls/val` | only untouched real crops from the held-out photos |
| `tiles_cls/report.txt` | per-class counts and warnings |
| `tiles_cls/review/*.jpg` | contact sheets, one row per class — **look at them** |
| `tiles_cls/suspect_labels.csv` | source tiles whose analysed ink color disagrees with the label |

### Review the generated data (5 minutes, worth it)

1. Open `datasets/tiles_cls/review/Black.jpg`, `Blue.jpg`, `Orange.jpg`,
   `Red.jpg`. Every cell in a sheet must show that sheet's ink color. The first
   four columns are real tiles; the rest are augmentations.
2. Open `suspect_labels.csv`. These are tiles where your *tag* (not the model)
   looks wrong, e.g. a red tile tagged Blue5. Fix them in Roboflow (or ignore
   them — they are already excluded from training and validation).
3. Digit mistakes (a tile showing 8 tagged as 5) cannot be detected by color
   analysis. They show up in the sheets as a cell whose digit differs from the
   row label. After the first training run, tiles that the classifier confidently
   disagrees with are the next candidates to fix.

## 2. Train on Colab

Zip this repository (or only `datasets`, `tools`, `your_dataset`) and put it in
Google Drive. In Colab choose **Runtime > Change runtime type > T4 GPU**:

```python
from google.colab import drive
drive.mount("/content/drive")
```

```bash
%cd /content/drive/MyDrive/rummikub
!pip install -q "ultralytics>=8.3,<=8.3.40" "roboflow>=1.1,<2" pyyaml pillow opencv-python-headless requests
!python tools/train_models.py --device 0
```

`ultralytics<=8.3.40` matters: Roboflow only accepts YOLO11 weights trained with
that range.

Expected weights:

- `runs/rummikub/detect/weights/best.pt`
- `runs/rummikub/classify/weights/best.pt`

Evaluate the complete pipeline locally (same crops as the Workflow):

```bash
!python tools/evaluate_pipeline.py \
  --detector runs/rummikub/detect/weights/best.pt \
  --classifier runs/rummikub/classify/weights/best.pt \
  --device 0
```

Track all three metrics. Tile-level accuracy can look excellent while the
exact-image metric stays poor; the latter is closest to the app's requirement.

## 3. Upload models to Roboflow

Only the **detector** can be hosted. Roboflow accepts uploaded classification
weights only for ViT and ResNet, not YOLO11-cls, so the classifier runs in the
backend instead (`CLS_WEIGHTS`, ~9 ms per tile on CPU).

Project (already created): `rummikub-tiles-qu08l` (Object Detection). Upload
`datasets/tiles_det` and generate **version 1** in the Roboflow app first.

Upload from an environment with `ultralytics==8.3.40` installed: the archive
records the *installed* version, not the training version. Set the private API
key only in the environment, never in a file:

```bash
!pip install -q "ultralytics==8.3.40" "roboflow>=1.7"
!python tools/deploy_roboflow.py --det-weights detect/best.pt        # dry run: packages locally
%env ROBOFLOW_API_KEY=<paste-in-colab-only>
!python tools/deploy_roboflow.py --det-weights detect/best.pt --execute
```

The script raises on every HTTP error. The plain Roboflow SDK only prints
upload errors, so a failed upload used to look successful. Roboflow may take
several minutes to process uploaded weights. `--try-classifier` attempts the
YOLO11-cls upload anyway.

Backend with the hosted detector and local classifier:

```powershell
$env:ROBOFLOW_API_KEY = "<key>"; $env:DETECTOR_MODEL_ID = "rummikub-tiles-qu08l/1"
$env:CLS_WEIGHTS = "$PWD\..\classify\best.pt"   # from project_rummikub_backend/
uvicorn main:app --port 8000
```

Set `DETECTOR_WEIGHTS` too to run the detector locally (~250 ms on CPU) and
skip Roboflow entirely.

## 4. Build the Workflow (only if a hosted classifier exists)

Create `rummikub-v2-two-stage` in the `matan-kronfeld` workspace and import
[roboflow/workflow_two_stage.json](roboflow/workflow_two_stage.json). Steps:

1. Object Detection — `rummikub-tiles-qu08l/1`
2. Detection Offset — 10 / 10, unit "Percent (%)" (this is the 5% margin per
   side the classifier was trained on; Dynamic Crop has no padding option)
3. Dynamic Crop — on the *offset* detections
4. Classification — `rummikub-tile-cls/1`
5. Detections Classes Replacement — `object_detection_predictions` must be the
   **offset** detections too (Detection Offset creates new detection IDs), and
   unmatched boxes get the class `Unknown` (never a real tile such as a Joker)
6. Output `detections` from `recognized_tiles.predictions`

Returned boxes are therefore ~10% larger than the raw detector boxes.

Verify the real, deployed behavior on the held-out photos:

```powershell
$env:ROBOFLOW_API_KEY = "<your private key>"   # this shell only
python tools/evaluate_workflow.py --workspace matan-kronfeld `
  --workflow rummikub-v2-two-stage
```

It reports detector recall, classifier accuracy, `Unknown` count, exact-image
rate and the most common confusions. If this is clearly worse than
`evaluate_pipeline.py`, Roboflow's server-side resize differs from the training
crops — send me both outputs.

Then run Flutter with:

```powershell
flutter run --dart-define=ROBOFLOW_API_KEY=... `
  --dart-define=ROBOFLOW_WORKFLOW_ID=rummikub-v2-two-stage
```

The checked-in default remains the existing workflow until the new one exists.

## 5. Active-learning loop

After training, pre-label a folder and optionally upload it for review:

```powershell
python tools/autolabel.py --input new_photos `
  --detector runs/rummikub/detect/weights/best.pt `
  --classifier runs/rummikub/classify/weights/best.pt `
  --out autolabeled
```

Approve or correct only uncertain examples, add them to the source dataset,
then rebuild and retrain. Do not evaluate on images that have entered training.
