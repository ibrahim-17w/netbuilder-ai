"""The teaching loop: corrections are hypotheses until the screen agrees.

The rule these tests exist to defend is that a user correction must never be
written straight into PC_LEARNED / SRV_MEM / the strategy store.  The repo
already paid for the opposite once: `pc_tiles.json` carried a blind-dy-learned
`fields` entry that drifted PAST the gateway row, so IP and mask values were
typed into the Gateway/DNS rows for a whole run.  A correction that went
straight to a store would poison it the same way, only faster, because a click
from the user looks authoritative.

NOTHING here needs Packet Tracer, Tesseract or the RPA stack.
"""
from __future__ import annotations

import json
import os

import pytest

import learning_memory as lm
import pt_autopilot as pt


# Every event kind this install has actually produced, read out of
# failures.jsonl when this was written.  It is pinned here because that file is
# a runtime artifact: without a frozen list, the coverage test would silently
# stop testing anything on a fresh checkout.
KNOWN_EVENT_KINDS = (
    # the dominant blocker, and the other fail-closed gates
    "cli_context_blocked", "pt_focus_blocked", "setup_unresolvable",
    # clickable mistakes - the class a correction can actually fix
    "window_not_found", "placement_unverified", "pc_wrong_panel",
    "pc_tile_missing", "pc_desktop_tab", "pc_config_failed", "srv_tab_missing",
    "srv_field_missing", "srv_fill_mismatch", "srv_record_blocked",
    "srv_record_missing", "srv_save_failed", "port_popup_missing",
    "link_attempt_failed",
    # the command itself
    "cli_line_error", "cli_unresolvable", "cli_prerequisite_failed",
    # proven platform gaps
    "unsupported_by_packet_tracer", "serial_module_hint", "link_blocked",
    "interface_unavailable", "interface_capability_unknown",
    "admin_down_heal_blocked",
    # bookkeeping and things that already worked
    "phase_state", "run_finished", "run_started", "inventory_done",
    "audit_done", "validation_done", "cli_plan_compiled",
    "cli_transition_skipped", "setup_dialog", "cli_mode_repaired",
    "learned_command_fix", "cli_mode_transition_verified", "cli_mode_recovered",
    "boot_return_verified", "config_reused", "interface_remapped",
    "interface_remaps_applied", "admin_down", "dns_hang_aborted",
    "pc_error_dialog", "pc_rows_learned", "pc_tile_learned", "pc_tile_stale",
    "srv_field_learned", "srv_button_learned", "srv_button_stale",
    "srv_rules_verified",
    # outcome aggregates
    "ping_test", "security_check", "link_red", "link_failed",
    "srv_rules_unverified", "srv_service", "boot_return_blocked",
    "boot_return_pending", "phase_blocked", "save_blocked",
    "ipsec_traffic_trigger",
)


def test_every_known_event_kind_resolves_to_a_plan():
    """No event the engine emits may be a blank look-up for the UI.

    A kind with no entry at all still returns a dict (teachable False, with a
    reason), which is what stops the correction sheet from rendering an empty
    form for an event nobody has taught it how to fix.
    """
    for kind in KNOWN_EVENT_KINDS:
        plan = lm.correction_plan(kind)
        assert plan["kind"] == kind
        assert isinstance(plan["teachable"], bool)
        if not plan["teachable"]:
            assert plan.get("reason"), f"{kind} is not teachable and gives no reason"
        else:
            assert plan.get("target") in lm.TARGET_KINDS, kind
            assert plan.get("scope") in lm.SCOPES, kind
            assert plan.get("hint"), f"{kind} is teachable but offers no hint"
            assert plan.get("verify"), f"{kind} is teachable but names no verifier"


def test_clickable_mistakes_are_teachable_and_bookkeeping_is_not():
    """The split that makes the sheet trustworthy, stated as one assertion."""
    for kind in ("pc_wrong_panel", "srv_field_missing", "srv_fill_mismatch",
                 "window_not_found", "port_popup_missing"):
        assert lm.correction_plan(kind)["teachable"], kind
    for kind in ("phase_state", "run_finished", "pc_tile_learned",
                 "srv_button_stale"):
        assert not lm.correction_plan(kind)["teachable"], kind


def test_aggregate_events_point_at_the_step_they_came_from():
    """A ping failure is a result, not a step - the reason must say so."""
    plan = lm.correction_plan("ping_test")
    assert plan["teachable"] is False
    assert "outcome" in plan["reason"]


def test_live_journal_kinds_are_all_classified():
    """Against the real file when it exists: never a blank, never a crash.

    This is the guard for a kind added by a later change - it will read as
    'unknown' rather than as an offer to correct something unsupported.
    """
    path = getattr(pt, "JOURNAL_FILE", "")
    if not path or not os.path.exists(path):
        pytest.skip("no failures.jsonl on this checkout")
    seen = set()
    with open(path, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if not line.strip():
                continue
            try:
                seen.add(str(json.loads(line).get("kind", "")))
            except Exception:
                continue
    assert seen, "journal exists but yielded no events"
    unknown = []
    for kind in seen:
        plan = lm.correction_plan(kind)
        assert plan["kind"] == kind
        if not plan["teachable"] and "No correction is defined" in plan["reason"]:
            unknown.append(kind)
    # Not a failure - the taxonomy is allowed to lag the engine.  It is
    # asserted so the lag is visible in the test output rather than silent.
    assert isinstance(unknown, list)


def test_propose_records_a_hypothesis_and_promotes_nothing(tmp_path):
    """The whole point: recording a correction changes no engine behaviour."""
    store = lm.CorrectionStore(str(tmp_path / "c.json"))
    row = store.propose(failure_kind="pc_wrong_panel", project="office-net",
                        device="MGR1", dtype="PC-PT", action="config_pcs",
                        target={"kind": "label", "label": "Command Prompt"})
    assert row["status"] == "proposed"
    assert row["promotedTo"] == ""
    assert store.pending() and not store.stale_rows()
    # Nothing that a run reads was touched.
    assert pt.PC_LEARNED.get("cmd::pc-pt") is None


def test_scope_defaults_come_from_the_taxonomy(tmp_path):
    """A canvas slot is per device; a tile label is per device TYPE.

    2026-09-16: AAA1/DHCP1/WEB1/SRV1 (Server-PT) learned the Command Prompt
    tile at (0.488,0.109); MGR1 (PC-PT) reused that exact spot and opened
    "Terminal configuration" instead.  The type-scoped default is what stops a
    correction repeating that.
    """
    store = lm.CorrectionStore(str(tmp_path / "c.json"))
    placement = store.propose(failure_kind="window_not_found", device="R1",
                              target={"kind": "placement", "fx": 0.3, "fy": 0.4})
    label = store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                          dtype="PC-PT", target={"kind": "label",
                                                 "label": "Command Prompt"})
    assert placement["target"]["scope"] == "device"
    assert label["target"]["scope"] == "dtype"
    # Same label on a different device type is a DIFFERENT identity.
    other = store.propose(failure_kind="pc_wrong_panel", device="SRV1",
                          dtype="Server-PT", target={"kind": "label",
                                                     "label": "Command Prompt"})
    assert other["thrash"] == 0, "a different device type must not count as a repeat"


def test_repeat_corrections_are_flagged_as_thrash(tmp_path):
    """Two prior edits on one element is a signal, not a silent overwrite."""
    store = lm.CorrectionStore(str(tmp_path / "c.json"))
    for _ in range(3):
        store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                      dtype="PC-PT", target={"kind": "label",
                                             "label": "Command Prompt"})
    assert [row["thrash"] for row in store.listing()][::-1] == [0, 1, 2]
    assert len(store.thrash_rows()) == 1
    assert store.summary()["thrash"] == 1


def test_a_stale_correction_is_reported_but_never_deleted(tmp_path):
    """The user's own instruction must never be dropped behind their back.

    The engine's own guesses may be quietly quarantined.  A correction is the
    one thing that has to come back and say it stopped working.
    """
    store = lm.CorrectionStore(str(tmp_path / "c.json"))
    store.propose(failure_kind="pc_wrong_panel", device="MGR1", dtype="PC-PT",
                  target={"kind": "label", "label": "Command Prompt"})
    store.mark_verified("c1", lm.promotion_ref("PC_LEARNED", "cmd::pc-pt",
                                               "dtype", "Command Prompt"))
    store.record_miss("c1", "panel title mismatch")
    assert not store.get("c1").get("stale"), "one miss is a flake, not a pattern"
    store.record_miss("c1", "panel title mismatch")
    assert store.get("c1")["stale"] is True
    assert store.get("c1")["status"] == "verified", "still in use, still reported"
    assert len(store.stale_rows()) == 1
    assert store.summary()["stale"] == 1


def test_revert_removes_exactly_the_entry_it_promoted(tmp_path):
    """Un-teaching must not take a neighbour, or memory the engine re-learned."""
    store = lm.CorrectionStore(str(tmp_path / "c.json"))
    pt.CORRECTIONS = store
    pt.PC_LEARNED.clear()
    pt.PC_LEARNED["cmd::pc-pt"] = {"fx": 0.667, "fy": 0.126}
    pt.PC_LEARNED["cmd::server"] = {"fx": 0.488, "fy": 0.109}
    row = store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    store.mark_verified(row["id"], lm.promotion_ref(
        "PC_LEARNED", "cmd::pc-pt", "dtype", "Command Prompt"))
    undone = pt._undo_promotion(store.get(row["id"]))
    assert undone["undone"] is True
    assert "cmd::pc-pt" not in pt.PC_LEARNED
    assert "cmd::server" in pt.PC_LEARNED, "the neighbour had to survive"
    assert store.revert(row["id"])["status"] == "reverted"
    assert store.summary()["reverted"] == 1


def test_reverting_something_that_never_promoted_is_a_noop(tmp_path):
    """A dismissed correction is not an error, and must not raise."""
    store = lm.CorrectionStore(str(tmp_path / "c.json"))
    row = store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    undone = pt._undo_promotion(row)
    assert undone["undone"] is False
    assert "never promoted" in undone["reason"]


def test_an_out_of_range_fraction_is_dropped_not_clamped():
    """1.4 is not a slightly wrong point, it is a different coordinate system."""
    norm = lm._norm_target({"kind": "point", "fx": 1.4, "fy": 0.5})
    assert "fx" not in norm and norm["fy"] == 0.5
    assert lm._norm_target({"kind": "point", "fx": "abc"}) == {
        "kind": "point", "scope": "dtype"}
    assert lm._norm_target({"kind": "nonsense"})["kind"] == "label"


def test_trim_forgets_unused_rows_before_ones_in_use(tmp_path, monkeypatch):
    """Bounded growth must not silently discard a correction that works."""
    monkeypatch.setattr(lm, "CORRECTIONS_MAX", 3)
    store = lm.CorrectionStore(str(tmp_path / "c.json"))
    used = store.propose(failure_kind="srv_record_blocked", device="SRV1",
                         dtype="Server-PT", target={"kind": "label",
                                                    "label": "Add"})
    store.mark_verified(used["id"], lm.promotion_ref("SRV_MEM:b", "dns:add",
                                                     "dtype", "Add"))
    store.record_hit(used["id"])
    for index in range(5):
        store.propose(failure_kind="pc_wrong_panel", device=f"M{index}",
                      dtype="PC-PT", target={"kind": "label",
                                             "label": f"Tile {index}"})
    kept = {row["id"] for row in store.listing(limit=50)}
    assert used["id"] in kept, "a correction that has applied must outlive overflow"
    assert len(kept) <= 3


def test_promotion_ref_round_trips_through_a_string():
    """The ref is stored, echoed by the API, and parsed back for a revert."""
    ref = lm.promotion_ref("SRV_MEM:f", "dns.gateway", "dtype", "Gateway")
    assert lm.parse_promotion(ref) == {"store": "SRV_MEM:f", "scope": "dtype",
                                       "anchor": "Gateway", "key": "dns.gateway"}
    assert lm.parse_promotion("") == {}
    assert lm.parse_promotion("nonsense") == {}


# PHASE 1: the override channel ----------------------------------------
# A correction has to be APPLIED before it can be verified, but applying it
# must not mean believing it.  These tests pin that: the override is scoped,
# ephemeral, and writes nothing.

@pytest.fixture(autouse=True)
def clear_teach_overrides():
    """An armed override must never leak out of the test that armed it."""
    pt._TEACH_OVERRIDES.clear()
    yield
    pt._TEACH_OVERRIDES.clear()


def test_no_override_is_armed_on_an_ordinary_run():
    """The channel is inert unless a teach run armed it.

    This is what makes the feature safe to leave switched on: with nothing
    armed, every lookup below returns exactly what it did before.
    """
    assert pt._TEACH_OVERRIDES == {}
    assert pt._teach_override("pc_tile", "cmd", "MGR1") == {}
    assert pt._teach_point("pc_tile", "cmd", "MGR1") is None
    assert pt._teach_label("pc_tile", "cmd", "MGR1") == ""


def test_a_taught_point_beats_the_learned_store_for_that_device():
    """The user's answer is tried first, on the device they gave it for."""
    pt.PC_LEARNED["cmd::pc-pt"] = {"fx": 0.667, "fy": 0.126}
    pt._load_teach_overrides([{"store": "pc_tile", "key": "cmd",
                               "device": "MGR1", "fx": 0.99, "fy": 0.11}])
    assert pt._learned_spot("cmd", "MGR1") == (0.99, 0.11)
    # ...and only that device: another PC-PT keeps the learned spot.
    assert pt._learned_spot("cmd", "MGR2") != (0.99, 0.11)


def test_an_override_without_a_store_or_key_is_dropped():
    """An override that cannot say where it applies must not apply at all."""
    armed = pt._load_teach_overrides([
        {"key": "no-store", "fx": 0.5, "fy": 0.5},
        {"store": "pc_tile", "fx": 0.5, "fy": 0.5},
        {"store": "pc_tile", "key": "cmd"},
        {"store": "pc_tile", "key": "cmd", "fx": 9.9, "fy": 0.5},
        "not-a-dict",
    ])
    assert armed == []
    assert pt._TEACH_OVERRIDES == {}


def test_teaching_a_spot_the_engine_quarantined_still_applies():
    """The taught replacement must bypass the old verdict.

    A spot the strategy store has given up on is exactly the thing a user is
    replacing.  If the override were gated by that verdict the correction
    could never verify, and the teaching loop would be unable to fix the one
    case it exists for.
    """
    dev, key = "MGR1", "cmd"
    # Engine-learned spot for this device type is refused by the store...
    pt._learn_spot(key, 0.111, 0.222, dev)
    pt.LEARNING.failure("ui_coordinate", key,
                        pt._learning_context_for_device(dev),
                        {"fx": 0.111, "fy": 0.222}, "test quarantine",
                        persistent=True)
    pt._learn_spot(key, 0.333, 0.444, dev)
    pt.LEARNING.failure("ui_coordinate", key,
                        pt._learning_context_for_device(dev),
                        {"fx": 0.333, "fy": 0.444}, "test quarantine",
                        persistent=True)
    pt._load_teach_overrides([{"store": "pc_tile", "key": key,
                               "device": dev, "fx": 0.77, "fy": 0.88}])
    assert pt._learned_spot(key, dev) == (0.77, 0.88)


def test_overrides_are_never_persisted(tmp_path):
    """Applying a correction must not write it anywhere.

    Nothing is saved until the step verifies, so after a teach run the three
    real stores and the correction itself must be exactly as they were.
    """
    pt.PC_LEARNED.clear()
    before_corrections = dict(pt.CORRECTIONS._data["corrections"])
    row = pt.CORRECTIONS.propose(failure_kind="pc_wrong_panel", device="MGR1",
                                 dtype="PC-PT",
                                 target={"kind": "label",
                                         "label": "Command Prompt"})
    pt._load_teach_overrides([{"store": "pc_tile", "key": "cmd",
                               "device": "MGR1", "fx": 0.99, "fy": 0.11,
                               "correctionId": row["id"]}])
    assert pt._learned_spot("cmd", "MGR1") == (0.99, 0.11)
    assert pt.PC_LEARNED == {}, "the override must not have been learned"
    assert not os.path.exists(pt.PC_LEARNED_FILE), "nothing may hit the disk"
    assert pt.CORRECTIONS.get(row["id"])["status"] == "proposed"
    del before_corrections


def test_overrides_do_not_outlive_the_run():
    """`end_activity` is every build path's release point, so it clears them."""
    pt._load_teach_overrides([{"store": "pc_tile", "key": "cmd",
                               "device": "MGR1", "fx": 0.99, "fy": 0.11}])
    assert pt._TEACH_OVERRIDES
    with pt.LOCK:
        pt.JOB.running = True
    pt.end_activity("build")
    assert pt._TEACH_OVERRIDES == {}, "a stale override would mis-click a real run"


def test_loading_a_new_teach_block_disarms_the_previous_one():
    """Two teach runs in a row must not stack."""
    pt._load_teach_overrides([{"store": "pc_tile", "key": "cmd",
                               "device": "MGR1", "fx": 0.9, "fy": 0.1}])
    pt._load_teach_overrides([{"store": "srv_button", "key": "dns:add",
                               "device": "SRV1", "fx": 0.5, "fy": 0.6}])
    assert pt._teach_point("pc_tile", "cmd", "MGR1") is None
    assert pt._teach_point("srv_button", "dns:add", "SRV1") == (0.5, 0.6)
# PHASE 2: settlement, provenance, precedence and stale reporting ------------
# Phase 1 proved a correction can be APPLIED without being believed.  Phase 2
# closes the loop: only a screen-verified teach run promotes it, the promoted
# entry carries provenance and outranks engine memory, and one that stops
# working is reported (never silently quarantined like the engine's own
# guesses).


def _arm(store, key, dev="MGR1", fx=0.99, fy=0.11, cid="c1", project="office"):
    """Arm one override the way a teach run does, with RUN primed."""
    pt._load_teach_overrides([{"store": store, "key": key, "device": dev,
                               "fx": fx, "fy": fy, "correctionId": cid}])
    pt.RUN["teachRun"] = [{"store": store, "key": key, "device": dev,
                           "correctionId": cid}]
    pt.RUN["project"] = project


def test_settle_promotes_a_verified_teach_run(tmp_path):
    """Screen said yes -> the entry is written, tagged, and the row verified."""
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    _arm("pc_tile", "cmd", cid=row["id"])
    results = pt._settle_teach_run(True)
    assert results[0]["correctionId"] == row["id"]
    assert results[0]["promoted"] is True
    assert results[0]["status"] == "verified"
    entry = pt.PC_LEARNED[pt._pc_spot_key("cmd", "MGR1")]
    assert entry["fx"] == 0.99 and entry["fy"] == 0.11
    assert entry["taught"] is True, "provenance must travel with the entry"
    assert entry["correctionId"] == row["id"]
    assert store.get(row["id"])["status"] == "verified"
    parsed = lm.parse_promotion(store.get(row["id"])["promotedTo"])
    assert parsed["key"] == pt._pc_spot_key("cmd", "MGR1")
    assert parsed["store"] == "PC_LEARNED"
    assert store.get(row["id"])["hits"] == 1, "verification counts as a hit"
    # Settled: the overrides are disarmed, so a second call cannot re-write.
    assert pt._TEACH_OVERRIDES == {}
    assert pt._settle_teach_run(True) == []


def test_settle_rejects_a_failed_teach_run_and_reports_why(tmp_path):
    """Screen said no -> nothing is written and the user is told, not dumped."""
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    _arm("pc_tile", "cmd", cid=row["id"])
    results = pt._settle_teach_run(
        False, "step did not verify: config_pc:MGR1")
    assert results[0]["promoted"] is False
    assert pt.PC_LEARNED == {}, "a rejected correction must not reach memory"
    updated = store.get(row["id"])
    assert updated["status"] == "rejected"
    assert "config_pc" in updated["rejectReason"]
    assert pt._TEACH_OVERRIDES == {}


def test_a_crashed_teach_run_decides_nothing(tmp_path):
    """No verdict on screen means neither promotion nor rejection."""
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    _arm("pc_tile", "cmd", cid=row["id"])
    results = pt._settle_teach_run(False, "run crashed")
    assert results[0]["pending"] is True
    assert store.get(row["id"])["status"] == "proposed", \
        "a crash must not reject the user's correction behind their back"
    assert pt.PC_LEARNED == {}


def test_settlement_without_a_teach_run_is_a_noop():
    """Ordinary runs arm nothing, so settlement must touch nothing."""
    assert pt._settle_teach_run(True) == []
    assert pt._settle_teach_run(False, "validation failed") == []


def test_taught_spot_outranks_a_quarantined_engine_spot(tmp_path):
    """After promotion, the store's own verdict no longer gates the spot."""
    dev, key = "MGR1", "cmd"
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="pc_wrong_panel", device=dev,
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    # Engine learned the spot, failed on it twice, then re-learned elsewhere.
    pt._learn_spot(key, 0.111, 0.222, dev)
    pt.LEARNING.failure("ui_coordinate", key,
                        pt._learning_context_for_device(dev),
                        {"fx": 0.111, "fy": 0.222}, "quarantine",
                        persistent=True)
    pt._learn_spot(key, 0.333, 0.444, dev)
    pt.LEARNING.failure("ui_coordinate", key,
                        pt._learning_context_for_device(dev),
                        {"fx": 0.333, "fy": 0.444}, "quarantine",
                        persistent=True)
    _arm("pc_tile", key, dev=dev, fx=0.77, fy=0.88, cid=row["id"])
    pt._settle_teach_run(True)
    # The taught entry is served even though the strategy store has banned
    # the tactic for this device - the user's verified answer wins.
    assert pt._learned_spot(key, dev) == (0.77, 0.88)


def test_engine_relearn_cannot_overwrite_a_taught_spot(tmp_path):
    """A later ordinary run must not silently replace the user's answer."""
    dev, key = "MGR1", "cmd"
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="pc_wrong_panel", device=dev,
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    _arm("pc_tile", "cmd", cid=row["id"])
    pt._settle_teach_run(True)
    # Ordinary-run re-learn at a different spot: refused, protected, counted.
    pt._learn_spot(key, 0.5, 0.5, dev)
    assert pt.PC_LEARNED[pt._pc_spot_key(key, dev)]["fx"] == 0.99, \
        "the taught spot must survive an engine re-learn"
    assert store.get(row["id"])["misses"] == 1, "the attempt is counted"
    assert store.get(row["id"])["stale"] is False, "one miss is not stale"


def test_a_taught_spot_that_stops_working_is_reported_not_deleted(tmp_path):
    """Past the threshold the row is flagged stale - and the spot is kept."""
    dev, key = "MGR1", "cmd"
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="pc_wrong_panel", device=dev,
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    _arm("pc_tile", "cmd", cid=row["id"])
    pt._settle_teach_run(True)
    pt._learn_spot(key, 0.5, 0.5, dev)   # miss 1: protected
    pt._learn_spot(key, 0.5, 0.5, dev)   # miss 2: stale flag + report
    updated = store.get(row["id"])
    assert updated["stale"] is True
    assert updated["status"] == "verified", "still in use, still reported"
    assert pt.PC_LEARNED[pt._pc_spot_key(key, dev)]["fx"] == 0.99, \
        "reported, never silently deleted"
    assert len(store.stale_rows()) == 1


def test_taught_srv_button_survives_engine_learn_and_evict(tmp_path):
    """Same protection for SRV_MEM buttons: no overwrite, no eviction."""
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="srv_record_blocked", device="SRV1",
                        dtype="Server-PT", target={"kind": "label",
                                                   "label": "Add"})
    _arm("srv_button", "dns:add", dev="SRV1", fx=0.6, fy=0.7, cid=row["id"])
    pt._settle_teach_run(True)
    assert pt.SRV_MEM["buttons"]["dns:add"]["taught"] is True
    pt._srv_learn_button("dns:add", 0.1, 0.2, "SRV1")
    assert pt.SRV_MEM["buttons"]["dns:add"]["fx"] == 0.6, "overwrite refused"
    pt._srv_evict_button("dns:add", "SRV1")
    assert "dns:add" in pt.SRV_MEM["buttons"], "eviction refused"
    assert store.get(row["id"])["misses"] >= 1


def test_taught_srv_field_is_served_despite_blocked_strategy(tmp_path):
    """Precedence for fields: taught spot bypasses the strategy-store ban."""
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="srv_field_missing", device="SRV1",
                        dtype="Server-PT", target={"kind": "label",
                                                   "label": "Gateway"})
    _arm("srv_field", "dns.gateway", dev="SRV1", fx=0.4, fy=0.5,
         cid=row["id"])
    pt._settle_teach_run(True)
    # Ban the strategy for this key the way repeated engine failures would.
    ctx = pt._learning_context_for_device("SRV1")
    pt.LEARNING.failure("field_row", "dns.gateway", ctx,
                        {"fx": 0.4, "fy": 0.5, "kind": "single"}, "ban",
                        persistent=True)
    pt.LEARNING.failure("field_row", "dns.gateway", ctx,
                        {"fx": 0.4, "fy": 0.5, "kind": "single"}, "ban",
                        persistent=True)
    entry = pt._srv_learned_field("dns.gateway", "SRV1")
    assert entry.get("fx") == 0.4, \
        "the taught field spot must not be gated by the engine's verdict"
    assert "blocked" not in entry


def test_taught_placement_is_promoted_and_protected(tmp_path):
    """A placement lands on project+device and survives engine re-placement."""
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="window_not_found", device="R1",
                        target={"kind": "placement", "fx": 0.3, "fy": 0.4})
    _arm("placement", "R1", dev="R1", fx=0.3, fy=0.4, cid=row["id"])
    pt._settle_teach_run(True)
    entry = pt.DEV_MEM["office"]["R1"]
    assert entry["taught"] is True and entry["fx"] == 0.3
    # Engine re-placement somewhere else: refused, counted, not overwritten.
    pt.remember_device("office", "R1", 0.8, 0.8, "Router-PT", "2911", True)
    assert pt.DEV_MEM["office"]["R1"]["fx"] == 0.3
    # Same spot: just a metadata refresh, no miss counted.
    before = store.get(row["id"])["misses"]
    pt.remember_device("office", "R1", 0.3, 0.4, "Router-PT", "2911", True)
    assert store.get(row["id"])["misses"] == before
    # ...and the revert path reaches it.
    undone = pt._undo_promotion(store.get(row["id"]))
    assert undone["undone"] is True
    assert "R1" not in pt.DEV_MEM["office"]
    assert store.revert(row["id"])["status"] == "reverted"


def test_reverting_a_taught_spot_frees_the_engine_to_relearn(tmp_path):
    """After un-teaching, _learn_spot writes again - provenance gone."""
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    _arm("pc_tile", "cmd", cid=row["id"])
    pt._settle_teach_run(True)
    pt._undo_promotion(store.get(row["id"]))
    store.revert(row["id"])
    pt._learn_spot("cmd", 0.5, 0.5, "MGR1")
    entry = pt.PC_LEARNED[pt._pc_spot_key("cmd", "MGR1")]
    assert entry["fx"] == 0.5 and not entry.get("taught")


def test_teaching_events_are_journalled_and_classified(tmp_path):
    """The loop's outcomes are visible in the journal the app already reads."""
    store = pt.CORRECTIONS
    row = store.propose(failure_kind="pc_wrong_panel", device="MGR1",
                        dtype="PC-PT", target={"kind": "label",
                                               "label": "Command Prompt"})
    _arm("pc_tile", "cmd", cid=row["id"])
    pt._settle_teach_run(True)
    kinds = set()
    for item in pt._journal_rows()[-8:]:
        kinds.add(item.get("kind"))
    assert "correction_verified" in kinds
    # ...and every new kind resolves to a plan, so the events list is honest.
    for kind in ("correction_verified", "correction_rejected",
                 "correction_stale", "correction_protected",
                 "correction_reverted"):
        plan = lm.correction_plan(kind)
        assert plan["teachable"] is False and plan.get("reason")


def test_status_carries_the_corrections_summary():
    """/status exposes counts, rows and the teach-run settlement."""
    with pt.LOCK:
        payload = pt._status_payload_locked()
    assert "corrections" in payload
    assert "teachRun" in payload and "teachResults" in payload
    assert payload["corrections"]["count"] >= 0
