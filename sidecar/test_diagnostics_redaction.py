"""Diagnostics exports must not carry provider credentials.

A tester bundle is copied off the machine by design.  The export path is the
last choke point, so this test puts credential-shaped values in every place a
future field could expose them and greps the archive that is actually written.
"""
from __future__ import annotations

import json
import zipfile

import pt_autopilot as pt


def test_diagnostics_export_redacts_credential_shapes(tmp_path, monkeypatch):
    secrets = (
        "sk-live-abcdefgh12345678",
        "sk-proj-abcdefgh12345678",
        "sk-ant-abcdefgh12345678",
        "AIzaabcdefghijklmnopqrstuvwxyz123456",
        "BearerTokenThatMustNotLeak123",
    )
    monkeypatch.setattr(pt, "DIAGNOSTICS_DIR", str(tmp_path))
    monkeypatch.setattr(
        pt,
        "_journal_rows",
        lambda limit: [
            {
                "ts": "2026-10-20 10:00:00",
                "kind": "llm_failed",
                "device": "R1",
                "detail": (
                    "request failed api_key=sk-live-abcdefgh12345678 "
                    "Authorization: Bearer BearerTokenThatMustNotLeak123"
                ),
            }
        ],
    )
    monkeypatch.setattr(
        pt,
        "_experience_rows",
        lambda limit: [
            {
                "ts": "2026-10-20 10:00:01",
                "kind": "model_call",
                "device": "R1",
                "result": "failed",
                "detail": '{"apiKey": "sk-ant-abcdefgh12345678"}',
            }
        ],
    )
    monkeypatch.setattr(
        pt,
        "DEV_MEM",
        {
            "R1": {
                "note": "sk-proj-abcdefgh12345678",
                "key": "AIzaabcdefghijklmnopqrstuvwxyz123456",
            }
        },
    )

    result = pt.diagnostics_export(include_screenshots=False)
    with zipfile.ZipFile(result["path"]) as archive:
        text = archive.read("diagnostics.json").decode("utf-8")

    for secret in secrets:
        assert secret not in text, secret
    assert "<redacted>" in text

    # The JSON-shaped archive stays parseable after redaction.
    payload = json.loads(text)
    assert payload["schema"] == 1
