"""Shared traversal gate for file IO inside the sidecar and the tools.

Why this exists: the engine serves HTTP for another device and the CLI
tools take user args, so a path that reaches an open()/os.replace/shutil
call is not necessarily ours.  The RAW check comes first - abspath folds
`..` before os.path parts ever see it, so only the caller's own segments
prove the probe.  A legitimate caller names a real file outright; one
that smuggles `..` is probing, not working.  Mirrors `_pkt_path` in
pt_autopilot.py, which keeps its own extension and existence gates.
"""
from __future__ import annotations

import builtins
import os
from pathlib import Path


def ensure_no_traversal(path: str | os.PathLike) -> str:
    """Return the path unchanged, or raise ValueError on any '..' segment.

    Both separators are checked: on Windows the two are interchangeable,
    and a mixed-separator path is exactly what a folded abspath hides.
    """
    raw_value = str(os.fspath(path)).strip()
    if ".." in Path(raw_value.replace("\\", "/")).parts:
        raise ValueError(f"The path must not contain '..' segments: {raw_value}")
    return raw_value


def open_state(path: str | os.PathLike, mode: str = "r", **kwargs):
    """builtins.open, refusing traversal first - for our own state files."""
    return builtins.open(ensure_no_traversal(path), mode, **kwargs)
