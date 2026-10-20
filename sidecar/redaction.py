"""Credential redaction shared by the sidecar's logs and diagnostics.

Kept in its own module so the future diagnostics/LLM split has one choke point
instead of a copy in each subsystem. The patterns are deliberately broader than
the Cisco CLI secrets: provider SDKs use ``sk-...``, HTTP uses ``Bearer ...``,
and several tools print an ``api_key=``/``apiKey:`` field in errors.
"""

from __future__ import annotations

import re

_CREDENTIAL_RES = (
    (re.compile(r"\bsk-[A-Za-z0-9_-]{8,}", re.I), "sk-<redacted>"),
    (re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]+", re.I),
     "Bearer <redacted>"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{20,}"), "AIza<redacted>"),
    (re.compile(
        r"(?i)\b(api[_ -]?key|apiKey|x-goog-api-key|authorization|password|"
        r"passwd|secret|token|community)[\"']?(\s*[:=]\s*|\s+)"
        r"[^\s,;}]+"),
     r"\1=<redacted>"),
)


def redact_credentials(text: str) -> str:
    """Replace credential-shaped values with a stable marker. Idempotent."""
    out = str(text or "")
    for pattern, replacement in _CREDENTIAL_RES:
        out = pattern.sub(replacement, out)
    return out
