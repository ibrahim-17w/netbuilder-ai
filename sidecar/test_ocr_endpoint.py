"""The /ocr evidence path: an attached screenshot, read with this engine.

The endpoint exists so the keyless chat can see an image - the same
Tesseract the live autopilot reads screens with, applied to a user upload.
These tests pin the function under it: decodes a real PNG, refuses junk
politely, and says - rather than crashes - when Tesseract is absent.
"""
from __future__ import annotations

import base64
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pt_autopilot as pt  # noqa: E402

from PIL import Image  # noqa: E402
from unittest.mock import patch  # noqa: E402


def _tiny_png() -> str:
    buf = io.BytesIO()
    Image.new("RGB", (40, 20), "white").save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def test_a_png_is_read_through_tesseract():
    with patch.object(pt, "TESSERACT_CMD", "tesseract-not-really"), \
            patch.object(pt, "_tesseract_run",
                         return_value="GigabitEthernet0/1  unassigned"):
        text, err = pt.ocr_image_data(_tiny_png())
    assert err == ""
    assert text == "GigabitEthernet0/1  unassigned"


def test_junk_base64_is_a_reason_not_a_crash():
    text, err = pt.ocr_image_data("not-an-image-at-all")
    assert text == ""
    assert "unreadable image" in err


def test_missing_tesseract_is_reported_not_raised():
    with patch.object(pt, "TESSERACT_CMD", ""):
        text, err = pt.ocr_image_data(_tiny_png())
    assert text == ""
    assert "not installed" in err


def test_the_reading_is_the_live_readers_utf8_contract():
    """The endpoint must produce the same text the golden-baseline decode
    does, or the chat would quote mojibake the rest of the app has fixed."""
    seen = {}

    def fake_run(img, psm):
        seen["psm"] = psm
        return "café\nline"

    with patch.object(pt, "TESSERACT_CMD", "tesseract-not-really"), \
            patch.object(pt, "_tesseract_run", side_effect=fake_run):
        text, err = pt.ocr_image_data(_tiny_png())
    assert (text, err) == ("café\nline", "")
    assert seen["psm"] == 6, "a screenshot panel is a uniform block"


if __name__ == "__main__":
    test_a_png_is_read_through_tesseract()
    test_junk_base64_is_a_reason_not_a_crash()
    test_missing_tesseract_is_reported_not_raised()
    test_the_reading_is_the_live_readers_utf8_contract()
    print("ALL TESTS PASSED")
