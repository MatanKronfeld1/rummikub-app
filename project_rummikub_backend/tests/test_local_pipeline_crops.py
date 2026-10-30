import numpy as np
import pytest
from PIL import Image

import local_pipeline


def _photo() -> Image.Image:
    rng = np.random.default_rng(0)
    return Image.fromarray(rng.integers(0, 256, size=(480, 640, 3), dtype=np.uint8))


def test_repo_build_uses_the_shared_crop_module():
    assert local_pipeline._TILE_CROPS is not None
    assert local_pipeline.CLS_SIZE == local_pipeline._TILE_CROPS.CLS_SIZE == 224


@pytest.mark.parametrize(
    "box",
    [
        (100.0, 80.0, 160.0, 170.0),  # inside the photo
        (0.0, 0.0, 40.0, 60.0),  # touching the top-left corner
        (610.5, 430.25, 655.0, 500.0),  # partly outside: clipped
        (300.0, 200.0, 300.4, 200.4),  # degenerate box
    ],
)
def test_docker_fallback_crops_match_the_training_crops(box):
    """The image without tools/ must feed the classifier the same pixels."""
    photo = _photo()

    shared = local_pipeline._TILE_CROPS.workflow_view(photo, box, 224)
    inline = local_pipeline._workflow_view_inline(photo, box, 224)

    assert inline.size == shared.size == (224, 224)
    assert np.array_equal(np.asarray(inline), np.asarray(shared))
