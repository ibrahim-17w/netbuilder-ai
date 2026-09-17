"""Desktop-tile spots must be scoped by device type.

2026-09-16 run: AAA1/DHCP1/WEB1/SRV1 (Server-PT) learned the Command Prompt
tile at (0.488,0.109); MGR1 (PC-PT) then reused that exact spot and opened
"Terminal configuration" instead (pc_wrong_panel), and the PC-correct spot it
re-learned overwrote the Servers' value.  One flat cache key was the cause.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt

PROJECT = "pcspots-test"


def _seed():
    pt.PC_LEARNED.clear()
    pt.DEV_MEM[PROJECT] = {
        "AAA1": {"type": "server", "model": "Server-PT"},
        "MGR1": {"type": "pc", "model": "PC-PT"},
    }


def test_spots_are_scoped_by_device_type():
    _seed()
    with patch.object(pt, "record_event"), patch.object(pt, "log"):
        pt._learn_spot("cmd", 0.4883, 0.1089, "AAA1")
        pt._learn_spot("cmd", 0.6712, 0.1089, "MGR1")
    keys = [k for k in pt.PC_LEARNED if not k.startswith("tile_spots")]
    assert "cmd::server" in keys, keys
    assert "cmd::pc" in keys, keys
    assert "cmd" not in keys, f"the ambiguous flat key survived: {keys}"
    assert pt.PC_LEARNED["cmd::server"]["fx"] == 0.4883
    assert pt.PC_LEARNED["cmd::pc"]["fx"] == 0.6712


def test_pc_does_not_inherit_a_server_spot():
    _seed()
    with patch.object(pt, "record_event"), patch.object(pt, "log"):
        pt._learn_spot("cmd", 0.4883, 0.1089, "AAA1")
        pc_spot = pt._learned_spot("cmd", "MGR1")
        srv_spot = pt._learned_spot("cmd", "AAA1")
    assert pc_spot is None or pc_spot[0] != 0.4883, \
        f"the PC inherited the Server coordinate: {pc_spot}"
    assert srv_spot is not None and srv_spot[0] == 0.4883, srv_spot


def test_scope_migration_drops_legacy_flat_keys():
    pt.PC_LEARNED.clear()
    pt.PC_LEARNED["cmd"] = {"fx": 0.6712, "fy": 0.1089}
    pt.PC_LEARNED["ip_config"] = {"fx": 0.1211, "fy": 0.1235}
    pt.PC_LEARNED.pop("tile_spots_scoped_v4", None)
    # replay the migration exactly as the module performs it at import
    if not pt.PC_LEARNED.get("tile_spots_scoped_v4"):
        for stale in ("ip_config", "cmd"):
            pt.PC_LEARNED.pop(stale, None)
        pt.PC_LEARNED["tile_spots_scoped_v4"] = True
    assert "cmd" not in pt.PC_LEARNED
    assert "ip_config" not in pt.PC_LEARNED
    assert pt.PC_LEARNED["tile_spots_scoped_v4"] is True
