"""Test isolation for the cross-run learning stores.

`LlmRejectionStore`, `RunLedger`, `CapabilityMap` and `CorrectionStore` are
real files in the sidecar folder, and so are the learned-coordinate caches
`pc_tiles.json` and `srv_memory.json`.  Without this fixture a test that records a rejected ask (or
a still-failed action) leaves it on disk, and the next test run inherits it.
That is not hypothetical: two `test_llm_stuck_loop.py` tests became
order-dependent because a second call for the same (line, mode, error)
triple was correctly skipped as "already asked and rejected twice", so no
suggestion was ever applied and `llm_fixes_applied` stayed at 0.

Pointing the stores at a throwaway directory per test keeps every suite
independent, and keeps the developer's own learning memory out of the
results.
"""
from __future__ import annotations

import pytest

import learning_memory as lm
import pt_autopilot as pt


@pytest.fixture(autouse=True)
def isolated_learning_stores(tmp_path_factory, monkeypatch):
    """Give every test its own empty copies of the cross-run stores."""
    root = tmp_path_factory.mktemp("learning-stores")
    monkeypatch.setattr(
        pt, "LLM_MEMORY", lm.LlmRejectionStore(str(root / "llm.json")))
    monkeypatch.setattr(
        pt, "RUN_LEDGER", lm.RunLedger(str(root / "ledger.json")))
    monkeypatch.setattr(
        pt, "CAPABILITIES", lm.CapabilityMap(str(root / "cap.json")))
    monkeypatch.setattr(
        pt, "CORRECTIONS", lm.CorrectionStore(str(root / "corrections.json")))
    # The learned-coordinate stores are files too, and a test that teaches a
    # spot (or quarantines one) otherwise writes into the developer's own
    # pc_tiles.json / srv_memory.json - and then inherits it back on the next
    # run.  Point them at the throwaway directory as well, and start empty so
    # no test can depend on what an earlier one learned.
    monkeypatch.setattr(pt, "PC_LEARNED_FILE", str(root / "pc_tiles.json"))
    monkeypatch.setattr(pt, "SRV_MEM_FILE", str(root / "srv_memory.json"))
    monkeypatch.setattr(pt, "PC_LEARNED", {})
    monkeypatch.setattr(pt, "SRV_MEM", {"fields": {}, "buttons": {}})
    # The offline .pkt generation learning store is a real file too, and
    # any test that generates a .pkt writes to it.
    monkeypatch.setenv("NETBUILDER_PKT_LEARNING",
                       str(root / "pkt_learning.json"))
    try:
        import pkt_learning as pl
        pl.reset()
    except Exception:  # noqa: BLE001 - isolation is best-effort
        pass
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()
    yield root
    pt._JSONL_CACHE.clear()
    pt._BLOCKERS_CACHE.clear()
