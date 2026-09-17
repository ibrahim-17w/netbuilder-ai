"""Gemini recovery loop: ask when stuck, remember only what verifies."""
from __future__ import annotations

import json
from unittest.mock import patch

import pt_autopilot as pt


def _configured(calls_used=0):
    pt.llm_configure(api_key="test-key", model="gemini-3.8-flash",
                     enabled=True)
    for _ in range(calls_used):
        pt.LLM["calls"] += 1


def _fresh(project="office-net", dev="HQ_Router"):
    pt.llm_reset_run()
    pt.RUN["llm_calls"] = 0
    pt.RUN["llm_fixes_applied"] = 0
    pt.RUN["llm_fixes_rejected"] = 0
    pt.RUN["errors_unrecovered"] = 0
    pt.BAD_CMD_MEM.pop(project, None)
    pt.RUN.setdefault("session_correction_applications", {}).pop(dev, None)


SUGGESTION = json.dumps({
    "commands": ["interface g0/2", "description to-HQ_Switch"],
    "explanation": "use the second gigabit port",
})


def _run_fix(answer, after_count=0, before_count=1, typed=True, dev="HQ_Router"):
    calls = {"configured": 0}

    def fake_ensure(win, dev_, cmd, ctx, delay):
        calls["configured"] += 1
        return typed

    with patch.object(pt, "_llm_request", return_value=answer), \
         patch.object(pt, "_term_error_signature",
                      side_effect=[(before_count, "err"), (after_count, "ok")]), \
         patch.object(pt, "_ensure_cli_context", side_effect=fake_ensure), \
         patch.object(pt, "_type_line", return_value=True), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        result = pt._llm_try_fix(object(), "office-net", dev, "router",
                                 "description to-HQ_Switch", "% Invalid input",
                                 "interface")
    return result, calls


def test_rejected_suggestion_is_counted_and_persists_nothing():
    _fresh()
    _configured()
    result, _ = _run_fix("I am not JSON at all")
    assert result == []
    assert pt.RUN["llm_fixes_rejected"] == 1
    assert pt.RUN["llm_fixes_applied"] == 0
    assert pt.RUN["errors_unrecovered"] == 0, "a platform/LLM miss is not an error"
    assert pt.BAD_CMD_MEM.get("office-net") is None, "nothing may be remembered"


def test_verified_suggestion_is_returned_and_remembered():
    _fresh()
    _configured()
    result, _ = _run_fix(SUGGESTION, after_count=0, before_count=1)
    assert result == ["interface g0/2", "description to-HQ_Switch"]
    assert pt.RUN["llm_fixes_applied"] == 1
    pt.remember_bad_command("office-net", "HQ_Router",
                            "description to-HQ_Switch", "llm verified", result)
    entry = pt.BAD_CMD_MEM["office-net"]["HQ_Router"][
        pt.command_key("description to-HQ_Switch")]
    assert entry["replacement"] == result
    assert entry["replacement_verified"] is True


def test_unverified_suggestion_is_rejected():
    _fresh()
    _configured()
    result, _ = _run_fix(SUGGESTION, after_count=3, before_count=1)
    assert result == []
    assert pt.RUN["llm_fixes_rejected"] == 1
    assert pt.BAD_CMD_MEM.get("office-net") is None


def test_budget_caps_are_enforced():
    _fresh()
    _configured()
    pt.LLM["calls"] = pt.LLM_MAX_CALLS_PER_RUN
    assert pt.llm_available("HQ_Router") is False
    assert pt._llm_try_fix(object(), "office-net", "HQ_Router", "router",
                           "x", "y", "interface") == []

    _fresh()
    _configured()
    pt.LLM_PER_DEVICE["HQ_Router"] = pt.LLM_MAX_CALLS_PER_DEVICE
    assert pt.llm_available("HQ_Router") is False

    _fresh()
    _configured()
    pt.LLM_ASKED.add(("HQ_Router", pt.command_key("description to-HQ_Switch")))
    assert pt._llm_try_fix(object(), "office-net", "HQ_Router", "router",
                           "description to-HQ_Switch", "y", "interface") == []
    assert pt.RUN["llm_calls"] == 0, "the line was already asked about"


def test_disabled_or_keyless_is_a_no_op():
    pt.llm_configure(api_key="", model="gemini-3.8-flash", enabled=True)
    assert pt.llm_available("HQ_Router") is False
    _fresh()
    assert pt._llm_try_fix(object(), "office-net", "HQ_Router", "router",
                           "x", "y", "interface") == []
    assert pt.RUN["llm_calls"] == 0
    assert pt.llm_status()["configured"] is False


def test_empty_key_never_resurrects_a_previous_one():
    """Private mode sends enabled:false with an empty key - that must clear."""
    pt.llm_configure(api_key="temp-key", model="m", enabled=True)
    assert pt.llm_available("HQ_Router") is True
    pt.llm_configure(api_key="", enabled=False)
    assert pt.llm_status()["configured"] is False
    pt.llm_configure(enabled=True)          # no apiKey field at all
    assert pt.llm_available("HQ_Router") is False
    # a body without the field keeps what is already configured
    pt.llm_configure(api_key="restored", enabled=True)
    pt.llm_configure(enabled=True)
    assert pt.llm_status()["configured"] is True


def test_secrets_are_redacted_before_sending():
    red = pt.llm_redact("tacacs-server key LabAdmin2026")
    assert "LabAdmin2026" not in red and "<redacted>" in red
    red2 = pt.llm_redact("username testuser password FtpTest2026")
    assert "FtpTest2026" not in red2 and "<redacted>" in red2
    assert pt.llm_redact("interface g0/0") == "interface g0/0"


def test_status_never_exposes_the_key():
    pt.llm_configure(api_key="super-secret", model="m", enabled=True)
    state = pt.llm_status()
    assert "super-secret" not in json.dumps(state)
    assert state["configured"] is True
    pt.llm_configure(api_key="", model="", enabled=False)
