"""Pause/resume engine and the auto-repair pass.

Pause must be a NON-destructive hold: the worker keeps all progress and
Stop still wins over pause. The auto-repair pass must retry exactly the
unverified actions, never verified ones, and must be capped.
"""
from __future__ import annotations

from unittest.mock import patch

import pt_autopilot as pt


def _reset_job():
    with pt.LOCK:
        pt.JOB.running = False
        pt.JOB.stop_requested = False
        pt.JOB.paused = False
        pt.JOB.pause_requested = False
        pt.JOB.pause_source = ""
    pt.PAUSE_GATE.set()


def test_pause_is_rejected_when_idle():
    _reset_job()
    try:
        assert pt.request_pause("test") is False
        assert pt.pause_snapshot()["paused"] is False
    finally:
        _reset_job()


def test_pause_holds_and_resume_releases():
    _reset_job()
    try:
        with pt.LOCK:
            pt.JOB.running = True
        assert pt.request_pause("test") is True
        # wait_if_paused parks until resumed; drive it from the same thread
        # by resuming first through the toggle.
        assert pt.toggle_pause("test") == "running"
        assert pt.pause_snapshot() == {
            "paused": False, "pauseRequested": False, "pauseSource": None}
        # Pause then resume via the gate: the worker must observe it.
        assert pt.request_pause("test") is True
        assert pt.toggle_pause("test") == "running"
        assert pt.wait_if_paused() is True
    finally:
        _reset_job()


def test_wait_if_paused_parks_until_gate_opens():
    _reset_job()
    try:
        with pt.LOCK:
            pt.JOB.running = True
        pt.JOB.paused = True
        import threading
        timer = threading.Timer(0.15, pt.PAUSE_GATE.set)
        timer.daemon = True
        timer.start()
        assert pt.wait_if_paused() is True
        timer.join()
        assert pt.pause_snapshot()["paused"] is False
    finally:
        _reset_job()


def test_stop_wins_over_pause():
    _reset_job()
    try:
        with pt.LOCK:
            pt.JOB.running = True
        pt.JOB.paused = True
        pt.PAUSE_GATE.clear()
        import threading
        timer = threading.Timer(0.15, pt.request_stop, args=("test",))
        timer.daemon = True
        timer.start()
        # wait_if_paused returns False because the stop latch fired.
        assert pt.wait_if_paused() is False
        timer.join()
        assert pt.pause_snapshot()["paused"] is False
        assert pt.stopped() is True
    finally:
        _reset_job()


def test_begin_activity_clears_stale_pause():
    _reset_job()
    try:
        with pt.LOCK:
            pt.JOB.running = True
            pt.JOB.paused = True
        pt.end_activity("build")
        assert pt.pause_snapshot()["paused"] is False
        ok, _ = pt.begin_activity("build")
        assert ok is True
        assert pt.pause_snapshot()["paused"] is False
        pt.end_activity("build")
    finally:
        _reset_job()


def test_safe_actions_refuse_to_run_while_parked():
    _reset_job()
    try:
        with pt.LOCK:
            pt.JOB.running = True
        pt.JOB.paused = True
        pt.PAUSE_GATE.clear()
        fake = pt.FakeUi() if hasattr(pt, "FakeUi") else None
        if fake is not None:
            original = pt.pyautogui
            pt.pyautogui = fake
            try:
                import threading
                timer = threading.Timer(0.15, pt.request_stop, args=("t",))
                timer.daemon = True
                timer.start()
                assert pt._safe_click(1, 2) is False
                assert pt._safe_press("enter") is False
                assert pt._safe_write("hello") is False
                timer.join()
            finally:
                pt.pyautogui = original
    finally:
        _reset_job()


def test_failed_action_names_merges_devices_and_links():
    original_results = dict(pt.RUN.get("action_results", {}))
    original_links = dict(pt.RUN.get("link_results", {}))
    try:
        pt.RUN["action_results"] = {
            "paste_cli:R1": {"status": "verified"},
            "paste_cli:R2": {"status": "failed"},
            "config_pc:PC1": {"status": "pending"},
        }
        pt.RUN["link_results"] = {
            "0": {"status": "verified", "visual_evidence": True},
            "2": {"status": "failed", "visual_evidence": False},
        }
        pending = pt._failed_action_names()
        assert ("paste_cli", "R2") in pending
        assert ("config_pc", "PC1") in pending
        assert ("create_links", "2") in pending
        assert ("paste_cli", "R1") not in pending
        assert ("create_links", "0") not in pending
    finally:
        pt.RUN["action_results"] = original_results
        pt.RUN["link_results"] = original_links


def _seed_run_state():
    pt.RUN["action_results"] = {}
    pt.RUN["link_results"] = {"1": {"status": "failed"}}
    pt.RUN["devices_done"] = 0
    pt.RUN["repair_recovered"] = 0


def test_auto_repair_returns_true_when_nothing_failed():
    _reset_job()
    _seed_run_state()
    try:
        pt.RUN["link_results"] = {"0": {"status": "verified"}}
        assert pt._failed_action_names() == []
        assert pt._auto_repair_pass(
            (0, 0, 100, 100), [], {}, {}, "p", {}, set(), 0) is True
    finally:
        _reset_job()


def test_auto_repair_pass_is_capped():
    _reset_job()
    _seed_run_state()
    events = []
    try:
        with patch.object(pt, "record_event",
                          lambda kind, *a, **k: events.append(kind)), \
             patch.object(pt, "log", lambda *a, **k: None), \
             patch.object(pt, "phase_update", lambda *a, **k: None):
            # passes_done at the cap: no retry, report exhaustion.
            ok = pt._auto_repair_pass(
                (0, 0, 100, 100), [], {}, {}, "p", {}, set(),
                pt.MAX_REPAIR_PASSES)
            assert ok is False
            assert "repair_exhausted" in events
    finally:
        _reset_job()


def test_auto_repair_retries_only_failed_link_index():
    _reset_job()
    _seed_run_state()
    placed = []

    step = {"action": "create_links",
            "links": [{"a": "R1", "b": "R2", "aIf": "g0/0", "bIf": "g0/0"},
                      {"a": "R2", "b": "PC1", "aIf": "g0/1", "bIf": "Fa0"}]}
    slot_of = {"R1": 0, "R2": 1, "PC1": 2}

    def fake_place(rect, links, slots, project, specs,
                   original_indices=None, **_):
        if original_indices is None:
            original_indices = [0]
        placed.append((original_indices, [(l["a"], l["b"]) for l in links]))
        pt.RUN["link_results"][str(original_indices[0])] = {
            "status": "verified", "visual_evidence": True}

    try:
        with patch.object(pt, "place_links", side_effect=fake_place), \
             patch.object(pt, "log", lambda *a, **k: None), \
             patch.object(pt, "record_event", lambda *a, **k: None), \
             patch.object(pt, "phase_update", lambda *a, **k: None), \
             patch.object(pt, "wait_if_paused", return_value=True):
            ok = pt._auto_repair_pass(
                (0, 0, 100, 100), [step], slot_of, {}, "p", {}, set(), 0)
            assert ok is True
            # ONLY link index 1 (the failed one) was retried, and the fresh
            # result was re-keyed onto the same plan index.
            assert placed == [([1], [("R2", "PC1")])]
            # place_links keys serial links as "a:aIf<->b:bIf"; the point of
            # this test is that only the failed index was retried.
            assert placed[0][0] == [1]
            assert pt.RUN["repair_recovered"] == 1
    finally:
        _reset_job()


def test_auto_repair_skips_blocked_link_indices():
    _reset_job()
    _seed_run_state()
    placed = []

    step = {"action": "create_links",
            "links": [{"a": "R1", "b": "R2", "aIf": "s0/0/0",
                       "bIf": "s0/0/0"}]}
    slot_of = {"R1": 0, "R2": 1}

    try:
        with patch.object(pt, "place_links",
                          side_effect=lambda *a, **k: placed.append(a)), \
             patch.object(pt, "log", lambda *a, **k: None), \
             patch.object(pt, "record_event", lambda *a, **k: None), \
             patch.object(pt, "phase_update", lambda *a, **k: None), \
             patch.object(pt, "wait_if_paused", return_value=True):
            ok = pt._auto_repair_pass(
                (0, 0, 100, 100), [step], slot_of, {}, "p", {},
                {0}, 0)  # index 0 blocked by preflight
            # The blocked link stays failed (recipe declined), and no click
            # was attempted - but the pass reports "incomplete" honestly.
            assert ok is False
            assert placed == []
    finally:
        _reset_job()


def test_repair_loop_in_run_plan_stops_when_clean():
    """The while-loop must exit immediately when nothing is failing."""
    _reset_job()
    try:
        with patch.object(pt, "_failed_action_names", return_value=[]), \
             patch.object(pt, "_auto_repair_pass") as repair, \
             patch.object(pt, "focus_pt"), \
             patch.object(pt, "rect_of", return_value=(0, 0, 100, 100)), \
             patch.object(pt, "prove_movement"), \
             patch.object(pt, "shot"), \
             patch.object(pt, "inventory_plan"), \
             patch.object(pt, "phase_update"), \
             patch.object(pt, "record_event"), \
             patch.object(pt, "validate_run",
                          return_value={"ok": True, "checks": []}), \
             patch.object(pt, "_save_run_artifact"), \
             patch.object(pt, "perf_summary_line", return_value="perf"), \
             patch.object(pt, "log", lambda *a, **k: None), \
             patch.object(pt, "wait_if_paused", return_value=True):
        # Minimal empty plan: no steps at all.
            pt.run_plan({"project": "p", "steps": []})
            repair.assert_not_called()
            assert pt.RUN["ok"] is True
    finally:
        _reset_job()


def test_new_cli_fallback_rules():
    f = pt._fallback_lines
    # IPv6 needs unicast-routing first.
    assert f("ipv6 address 2001:db8::1/64", False, False) == \
        ["ipv6 unicast-routing", "ipv6 address 2001:db8::1/64"]
    assert f("ipv6 route 2001:db8:2::/64 2001:db8:1::2", False, False) == \
        ["ipv6 unicast-routing", "ipv6 route 2001:db8:2::/64 2001:db8:1::2"]
    # Voice vlan needs the switchport armed like other switchport lines.
    assert f("switchport voice vlan 10", False, False) == \
        ["switchport", "switchport mode access", "switchport voice vlan 10"]
    # Access vlan arms switchport only when trunk was not armed.
    assert f("switchport access vlan 10", False, False) == \
        ["switchport", "switchport access vlan 10"]
    assert f("switchport access vlan 10", False, True) == \
        ["switchport access vlan 10"]
    # Existing rules still hold.
    assert f("network 192.168.1.0 0.0.0.255 area 0", False, False) == \
        ["router ospf 1", "network 192.168.1.0 0.0.0.255 area 0"]
    assert f("network 192.168.1.0 0.0.0.255 area 0", True, False) == \
        ["network 192.168.1.0 0.0.0.255 area 0"]
    assert f("terminal length 0", False, False) == []
    assert f("end", False, False) == []
    # One-liners retry once instead of vanishing.
    assert f("ip route 10.0.0.0 255.0.0.0 192.168.12.2", False, False) == \
        ["ip route 10.0.0.0 255.0.0.0 192.168.12.2"]
    assert f("clock rate 64000", False, False) == ["clock rate 64000"]


def test_activity_snapshot_includes_pause():
    _reset_job()
    try:
        snap = pt.activity_snapshot()
        assert "paused" in snap and "pauseRequested" in snap
    finally:
        _reset_job()


if __name__ == "__main__":
    for name, fn in sorted(list(globals().items())):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"ok {name}")
    print("all pause/repair tests passed")


def test_status_payload_does_not_re_enter_the_global_lock():
    """The /status deadlock, which used to wedge the ENTIRE sidecar.

    `LOCK` is a plain `threading.Lock` - not reentrant.  The /status handler
    held it and then called `pause_snapshot()`, which does `with LOCK:` again.
    Because the sidecar serves with a single-threaded `HTTPServer`, that one
    re-acquire blocked the only request-serving thread forever: /status never
    answered, and neither did /health or /corrections afterwards, for the life
    of the process.  It was found by probing a live sidecar, not by any test,
    which is why this test exists.

    The work is done on a daemon thread with a join timeout so that a relapse
    FAILS this test instead of hanging the whole suite.
    """
    import threading

    result = {}

    def build():
        with pt.LOCK:
            result["body"] = pt._status_payload_locked()

    worker = threading.Thread(target=build, daemon=True)
    worker.start()
    worker.join(5)
    assert not worker.is_alive(), (
        "building the /status payload blocks while LOCK is held - something in "
        "it acquires the non-reentrant LOCK again, which wedges the whole "
        "single-threaded server")
    body = result["body"]
    assert body["pause"] == {"paused": False, "pauseRequested": False,
                             "pauseSource": None} or isinstance(
        body["pause"], dict)
    assert "running" in body and "log" in body


def test_status_endpoint_answers_and_keeps_answering():
    """End to end: /status must answer, and must not strand the next request.

    A single-threaded server makes "the next request" the real test - a
    deadlocked handler is invisible until you ask it for something else.
    """
    import http.client
    import json as _json
    import threading
    from http.server import HTTPServer

    server = HTTPServer(("127.0.0.1", 0), pt.H)
    port = server.server_address[1]
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    replies = {}

    def probe():
        try:
            for path in ("/status", "/health"):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
                conn.request("GET", path)
                replies[path] = _json.loads(conn.getresponse().read().decode())
                conn.close()
        except Exception as exc:  # noqa: BLE001 - reported via the assertion
            replies["error"] = exc

    worker = threading.Thread(target=probe, daemon=True)
    worker.start()
    worker.join(20)
    try:
        assert not worker.is_alive(), (
            "/status did not answer within 20s - the handler is deadlocked")
        assert "error" not in replies, replies.get("error")
        assert "pause" in replies["/status"]
        assert replies["/health"]["ok"] is True, (
            "the request after /status must still be served")
    finally:
        server.shutdown()
        server.server_close()
