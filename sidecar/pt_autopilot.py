"""PT Autopilot sidecar v2 (Windows-only, experimental).

What v1 got wrong: create_nodes/create_links only LOGGED and did nothing,
and paste_cli pasted into the PT main window (not a device CLI), so the
user saw no mouse movement at all.

v2 fixes:
- EVERY run starts with a VISIBLE mouse proof (square over PT window).
  If you don't see the mouse move, it's a focus/permission issue, not plan logic.
- create_nodes now performs real visible clicks: palette best-effort +
  canvas grid placement per device (calibratable, see CAL below).
- create_links performs visible clicks between canvas slots.
- paste_cli double-clicks each device slot to open it, tabs to CLI, pastes.
- screenshots saved to sidecar/shots/ before/after for debugging.
- detailed log lines for every click; app polls GET /status to show them.
- new POST /prove endpoint: moves mouse only (no plan needed).

Run:
    pip install -r requirements.txt
    python pt_autopilot.py   (leave running)
API:
    GET  /health
    GET  /status              -> {running, pause{...}, log[]}
    POST /prove               -> visible mouse test only
    POST /start  {plan json}
    POST /stop
    POST /pause               -> hold at the next safe boundary (progress kept)
    POST /resume              -> continue the paused run
    POST /pause_toggle        -> flip pause state

Safety: PT open, maximized, focused, 100% scaling, uninterrupted.
FAILSAFE: move mouse to a screen corner to abort pyautogui.
"""
from __future__ import annotations

import json
import hashlib
import os
import re
import shutil
import subprocess
import threading
import time
import zipfile
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import pyautogui
    import pywinauto  # noqa: F401  (needed for Desktop import side effects)
    from pywinauto import Desktop
    HAS_RPA = True
    RPA_IMPORT_ERROR = ""
except Exception as exc:  # sidecar still serves /health without RPA deps
    HAS_RPA = False
    RPA_IMPORT_ERROR = str(exc)

try:
    from learning_controller import SessionLearningController, StrategyStore
except ImportError:  # pragma: no cover - package import fallback
    from .learning_controller import SessionLearningController, StrategyStore

HOST = "127.0.0.1"
PORT = 5005
SHOTS = os.path.join(os.path.dirname(__file__), "shots")


def _hidden_subprocess_options() -> dict:
    """Return Windows flags that keep helper-console windows invisible."""
    if os.name != "nt":
        return {}
    startupinfo = subprocess.STARTUPINFO()
    startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startupinfo.wShowWindow = subprocess.SW_HIDE
    return {
        "creationflags": subprocess.CREATE_NO_WINDOW,
        "startupinfo": startupinfo,
    }


def _run_hidden(command, **kwargs):
    """Run a helper process without exposing a console window on Windows."""
    options = _hidden_subprocess_options()
    options.update(kwargs)
    return subprocess.run(command, **options)

# Bump on every behaviour change. Served on /health so a stale process
# (old code, old port-holder, double instance) is detectable remotely
# instead of producing "nothing changed" mystery runs.
VERSION = "2026-09-17-gaps2"
STRATEGY_MEM_FILE = os.path.join(os.path.dirname(__file__),
                                 "strategy_memory.json")
STRATEGY_STORE = StrategyStore(STRATEGY_MEM_FILE)
LEARNING = SessionLearningController(STRATEGY_STORE)


def _safe_path(name: str) -> str:
    """Resolve a filename strictly inside the sidecar directory.

    Security: plan/device text (names, projects) flows into file paths
    (pc_tiles.json, screenshots). Normalize and enforce containment so
    a crafted '../' name can never escape the sidecar folder.
    """
    base = os.path.realpath(os.path.dirname(__file__))
    p = os.path.realpath(os.path.join(base, name))
    if not (p == base or p.startswith(base + os.sep)):
        raise ValueError(f"path escapes sidecar dir: {name!r}")
    return p


def _safe_stem(s: str) -> str:
    """Sanitize a name for use inside file paths (device names etc.)."""
    return re.sub(r"[^A-Za-z0-9_\-]", "_", (s or ""))[:60] or "unnamed"

# CALIBRATION -----------------------------------------------------------
# PT 9.0 maximized on 1080p. These are FRACTIONS of the PT window rect,
# so they scale with window size. Tune live from the app (Detail ->
# Calibration sliders) or by editing sidecar/cal.json. Bottom device
# bar ~ y 0.86, canvas centre ~ 0.45.
CAL_FILE = os.path.join(os.path.dirname(__file__), "cal.json")
CAL_DEFAULTS = {
    # palette category icons along bottom-left (router, switch, pc, connections)
    "pal_router": (0.055, 0.905),
    "pal_switch": (0.085, 0.905),
    "pal_pc": (0.115, 0.905),
    "pal_conn": (0.030, 0.905),
    # extra palette anchors for the device kinds the planner can now emit
    # (Security, Wireless Devices, WAN Emulation).  Guessed fractions in the
    # same strip as the other anchors; each is teachable, and the UIA name
    # click comes first, so a wrong value costs one fallback click.
    "pal_security": (0.145, 0.905),
    "pal_wireless": (0.175, 0.905),
    "pal_wan": (0.205, 0.905),
    # model thumbnail row: from user screenshot, router models
    # (PT8200, 4331, 4321, ...) sit at ~y 0.91, first at x ~0.125,
    # tightly packed (step ~0.022). Old default 0.845 clicked ABOVE
    # the row into dead space = category highlighted, no model armed,
    # canvas clicks dropped nothing. Fixed Sep 2026.
    "model_row": 0.910,
    "model_col0": 0.125,
    "model_col_step": 0.022,
    # cable thumbnails in the Connections list.  Only the copper-straight
    # column was ever taught (0.125); the rest are the neighbouring slots
    # at the model-column spacing, and every one of them is only a FALLBACK:
    # the cable is picked by its printed name first (see select_cable).
    "conn_copper_col": 0.125,
    "conn_copper_cross_col": 0.147,
    "conn_serial_dce_col": 0.169,
    "conn_serial_dte_col": 0.191,
    "conn_fiber_col": 0.213,
    "conn_console_col": 0.235,
    # Device window > Physical tab, for the serial-module install.  The
    # power switch and the empty HWIC slots have no reliable accessible
    # name, so these are clickable fractions like every other CAL entry -
    # and the install is only ever *believed* when the live interface table
    # afterwards proves the new port (see _install_serial_module).
    "hw_power": (0.075, 0.205),
    "hw_module_col0": 0.085,
    "hw_module_row": 0.620,
    "hw_slot0": (0.300, 0.300),
    "hw_slot1": (0.360, 0.300),
    "hw_slot2": (0.420, 0.300),
    "hw_slot3": (0.480, 0.300),
    # canvas grid: devices placed left->right, top row
    "grid_x0": 0.35,
    "grid_step": 0.10,
    "grid_y": 0.45,
}
CAL = dict(CAL_DEFAULTS)
# The geometry the taught values were recorded under (see geometry_stamp).
CAL_GEOM: dict = {}
# Last measured geometry, so a remembered device spot carries its provenance
# without every caller having to thread the window rect through.
LAST_GEOM: dict = {}
try:
    if os.path.exists(CAL_FILE):
        with open(CAL_FILE) as f:
            saved = json.load(f)
        for k, v in saved.items():
            if k in CAL_DEFAULTS:
                CAL[k] = tuple(v) if isinstance(v, list) else v
        if isinstance(saved.get("geom"), dict):
            CAL_GEOM.update(saved["geom"])
        # migrate stale pre-fix model_row (clicked dead space above models)
        if isinstance(CAL.get("model_row"), float) and CAL["model_row"] < 0.88:
            print(f"migrating stale model_row {CAL['model_row']} -> "
                  f"{CAL_DEFAULTS['model_row']}")
            CAL["model_row"] = CAL_DEFAULTS["model_row"]
            CAL["model_col_step"] = CAL_DEFAULTS["model_col_step"]
            save_cal()
except Exception as e:
    print(f"cal.json load failed: {e}")


def save_cal():
    try:
        out = {k: (list(v) if isinstance(v, tuple) else v)
               for k, v in CAL.items()}
        if CAL_GEOM:
            out["geom"] = CAL_GEOM
        with open(CAL_FILE, "w") as f:
            json.dump(out, f, indent=2)
    except Exception as e:
        log(f"cal save failed: {e}")


def teach_key(key: str, delay_s: float = 3.0) -> dict:
    """Record current mouse position as fraction of PT rect for CAL key.

    Flow: app calls /teach {key}; user has delay_s seconds to hover the
    exact icon (e.g. the Routers category in PT), then position is saved.
    Pair keys (pal_router etc) store [fx, fy]; float keys store one axis
    based on suffix (.x/.y) or the dominant movement - caller passes full
    key like 'pal_router' or 'grid_x0'.
    """
    if not HAS_RPA:
        raise RuntimeError("RPA deps missing")
    if stopped():
        raise RuntimeError("stop requested before calibration")
    w = focus_pt()
    rect = rect_of(w)
    log(f"TEACH {key}: hover the exact spot in PT... capturing in {delay_s}s - DON'T move after")
    if not _interruptible_sleep(delay_s):
        raise RuntimeError("stop requested during calibration")
    mx, my = pyautogui.position()
    l, t, r, b = rect
    fx = min(1.0, max(0.0, (mx - l) / max(1, (r - l))))
    fy = min(1.0, max(0.0, (my - t) / max(1, (b - t))))
    log(f"TEACH {key}: mouse at screen ({mx},{my}) -> frac ({fx:.3f},{fy:.3f})")
    if key in CAL and isinstance(CAL[key], tuple):
        CAL[key] = (round(fx, 4), round(fy, 4))
    elif key in CAL:
        # float key: decide axis by name suffix
        if key.endswith("_x0") or key.endswith("_step") or key.endswith("col0"):
            CAL[key] = round(fx, 4)
        else:
            CAL[key] = round(fy, 4)
    else:
        raise RuntimeError(f"unknown cal key {key}")
    # Record WHICH coordinate space this taught value belongs to: a fraction
    # of the rect survives a resize, but not a scaled display or a DPI-unaware
    # process (the preflight compares this stamp and says so).
    CAL_GEOM.clear()
    CAL_GEOM.update(geometry_stamp(rect))
    LAST_GEOM.clear()
    LAST_GEOM.update(CAL_GEOM)
    save_cal()
    shot(f"teach_{key}.png")
    return {"fx": round(fx, 4), "fy": round(fy, 4), "cal": cal_flat()}


def cal_flat() -> dict:
    """JSON-safe flat view: tuples -> lists."""
    return {k: (list(v) if isinstance(v, tuple) else v)
            for k, v in CAL.items()}


# DEVICE LOCATION MEMORY -----------------------------------------------
# Remembers exact canvas fractions per project+device so repeat builds
# drop devices in the same spots. Persists to sidecar/device_memory.json.
DEV_MEM_FILE = os.path.join(os.path.dirname(__file__), "device_memory.json")
DEV_MEM: dict = {}
try:
    if os.path.exists(DEV_MEM_FILE):
        with open(DEV_MEM_FILE) as f:
            DEV_MEM = json.load(f)
except Exception as e:
    print(f"device_memory load failed: {e}")


def save_dev_mem():
    try:
        with open(DEV_MEM_FILE, "w") as f:
            json.dump(DEV_MEM, f, indent=2)
    except Exception as e:
        log(f"device memory save failed: {e}")


def remember_device(project: str, name: str, fx: float, fy: float,
                    dtype: str = "", model: str = "", verified: bool = False):
    DEV_MEM.setdefault(project, {})[name] = {
        "fx": round(fx, 4), "fy": round(fy, 4), "type": dtype,
        "model": model or "",
        "verified": bool(verified),
        "layout": LAYOUT_VERSION,
    }
    if LAST_GEOM:
        # Provenance only (`_geom` is not a project): spots stay fractions,
        # so they still apply - the stamp is what lets the next run say that
        # the display they were learned on has changed.
        DEV_MEM["_geom"] = dict(LAST_GEOM)
    save_dev_mem()


def recall_device(project: str, name: str):
    entry = (DEV_MEM.get(project, {}) or {}).get(name)
    if not entry:
        return None
    # spots from an older layout no longer match the on-canvas placement
    if entry.get("layout") != LAYOUT_VERSION:
        return None
    return entry


# VERIFIED COMMAND MEMORY ----------------------------------------------
# A successful exact config is safe to reuse on a later FULL build.  This
# does not apply to the explicit Fixes flow: a fix is a user request to
# re-apply a command, even if the text is unchanged.
CFG_MEM_FILE = os.path.join(os.path.dirname(__file__), "config_memory.json")
CFG_MEM: dict = {}
try:
    if os.path.exists(CFG_MEM_FILE):
        with open(CFG_MEM_FILE) as f:
            CFG_MEM = json.load(f)
except Exception as e:
    print(f"config_memory load failed: {e}")


def save_cfg_mem():
    try:
        with open(CFG_MEM_FILE, "w") as f:
            json.dump(CFG_MEM, f, indent=2)
    except Exception as e:
        log(f"config memory save failed: {e}")


def config_fingerprint(cfg: str) -> str:
    """Stable hash of actual config lines, ignoring comments and wrappers."""
    body = []
    for raw in (cfg or "").splitlines():
        line = raw.strip()
        low = line.lower()
        if not line or low.startswith(SKIP_PREFIXES) or low in TAIL_COMMANDS:
            continue
        body.append(re.sub(r"\s+", " ", line))
    canonical = "\n".join(body).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()[:20]


def remember_config(project: str, name: str, cfg: str, dtype: str = ""):
    CFG_MEM.setdefault(project, {})[name] = {
        "fingerprint": config_fingerprint(cfg),
        "type": dtype or "",
        "verified": True,
        "lines": len(cli_lines_for_device(cfg)),
        "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    save_cfg_mem()


def invalidate_config(project: str, name: str):
    entry = (CFG_MEM.get(project, {}) or {}).get(name)
    if entry:
        entry["verified"] = False
        save_cfg_mem()


def cached_config_matches(project: str, name: str, cfg: str,
                          dtype: str = "") -> bool:
    entry = (CFG_MEM.get(project, {}) or {}).get(name)
    if not isinstance(entry, dict) or not entry.get("verified"):
        return False
    if entry.get("fingerprint") != config_fingerprint(cfg):
        return False
    if dtype and entry.get("type") and entry.get("type") != dtype:
        return False
    # A command cache is only useful when the device location is still a
    # current, verified location.  Placement verification below can promote
    # older memory entries when the expected device is visibly present.
    dmem = recall_device(project, name)
    return bool(dmem and dmem.get("verified"))


# COMMAND FAILURE MEMORY -----------------------------------------------
# Keep the exact command, observed error, and successful fallback separate
# from the whole-config cache. A bad line is useful training data even when
# the surrounding device configuration is otherwise valid.
CMD_MEM_FILE = os.path.join(os.path.dirname(__file__), "command_memory.json")
BAD_CMD_MEM: dict = {}
try:
    if os.path.exists(CMD_MEM_FILE):
        with open(CMD_MEM_FILE) as f:
            BAD_CMD_MEM = json.load(f)
except Exception as e:
    print(f"command_memory load failed: {e}")


def save_cmd_mem():
    try:
        with open(CMD_MEM_FILE, "w") as f:
            json.dump(BAD_CMD_MEM, f, indent=2)
    except Exception as e:
        log(f"command memory save failed: {e}")


def command_key(line: str) -> str:
    canonical = re.sub(r"\s+", " ", (line or "").strip().lower())
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:20]


def remember_bad_command(project: str, device: str, line: str,
                         reason: str, replacement: list | None = None):
    key = command_key(line)
    entry = BAD_CMD_MEM.setdefault(project, {}).setdefault(device, {}).setdefault(
        key, {"line": (line or "").strip()[:180], "failures": 0})
    entry["line"] = (line or "").strip()[:180]
    entry["failures"] = int(entry.get("failures", 0)) + 1
    entry["last_reason"] = (reason or "terminal error")[:180]
    entry["last_seen"] = time.strftime("%Y-%m-%d %H:%M:%S")
    if replacement and list(replacement) != [line]:
        entry["replacement"] = [str(x)[:180] for x in replacement[:8]]
        entry["replacement_verified"] = True
    else:
        entry.setdefault("replacement", [])
        entry["replacement_verified"] = False
    save_cmd_mem()


# --- Gemini recovery ("ask when stuck, remember only if it works") --------
# The Flutter app pushes the user's key once per run (POST /llm_config).  The
# key lives in memory only: it is never written to disk, never logged, and
# never appears in diagnostics or journal events.
LLM = {
    "apiKey": "",
    "model": "gemini-3.8-flash",
    "enabled": False,
    "calls": 0,
    "applied": 0,
    "rejected": 0,
}
LLM_MAX_CALLS_PER_RUN = 5
LLM_MAX_CALLS_PER_DEVICE = 2
LLM_TIMEOUT_S = 20
LLM_ASKED: set = set()          # (device, command key) already asked this run
LLM_PER_DEVICE: dict = {}       # device -> calls used this run
# `key <secret>` / `password <secret>` / `secret <secret>` / `md5 <secret>`
LLM_SECRET_RE = re.compile(r"(?i)\b(key|password|secret|md5)\s+\S+")


def llm_reset_run():
    """Clear the per-run LLM budget. The credential itself is left alone."""
    LLM["calls"] = 0
    LLM["applied"] = 0
    LLM["rejected"] = 0
    LLM_ASKED.clear()
    LLM_PER_DEVICE.clear()


def llm_configure(api_key=None, model: str = "",
                  enabled: bool = False) -> dict:
    """Accept (or clear) the app-supplied credential. Memory only.

    ``api_key=None`` keeps whatever is already configured (the app may send a
    body without the field); an explicit empty string clears it, and an empty
    key can never leave the loop enabled.  The key is never persisted and
    never logged.
    """
    if api_key is not None:
        LLM["apiKey"] = str(api_key or "").strip()
    if str(model or "").strip():
        LLM["model"] = str(model).strip()
    LLM["enabled"] = bool(enabled) and bool(LLM["apiKey"])
    return llm_status()


def llm_status() -> dict:
    return {
        "configured": bool(LLM["apiKey"]),
        "enabled": bool(LLM["enabled"]),
        "model": LLM["model"],
        "calls": LLM["calls"],
        "applied": LLM["applied"],
        "rejected": LLM["rejected"],
    }


def llm_redact(text: str) -> str:
    """Hide obvious secrets before anything leaves the machine."""
    return LLM_SECRET_RE.sub(lambda m: f"{m.group(1)} <redacted>",
                             str(text or ""))


def llm_available(device: str = "") -> bool:
    if not (LLM["enabled"] and str(LLM["apiKey"]).strip()):
        return False
    if LLM["calls"] >= LLM_MAX_CALLS_PER_RUN:
        return False
    return LLM_PER_DEVICE.get(device, 0) < LLM_MAX_CALLS_PER_DEVICE


def _llm_parse_commands(answer: str) -> list:
    """Strictly read {"commands": [...]}; [] when the answer is unusable."""
    match = re.search(r"\{.*\}", str(answer or ""), re.S)
    if not match:
        return []
    try:
        data = json.loads(match.group(0))
    except Exception:
        return []
    if not isinstance(data, dict):
        return []
    out = []
    for raw in (data.get("commands") or [])[:3]:
        cmd = str(raw).strip()
        if not cmd or len(cmd) > 120:
            continue
        if any(not 32 <= ord(ch) < 127 for ch in cmd):
            continue
        low = cmd.lower()
        if any(bad in low for bad in ("terminal length", "show run", "!")):
            continue
        if "<redacted>" in low or re.fullmatch(r"(yes|no)\.?", low):
            continue
        out.append(cmd)
    return out


def _llm_request(prompt: str) -> str:
    """POST one prompt to Gemini and return the text; raises on failure."""
    import urllib.request
    url = ("https://generativelanguage.googleapis.com/v1beta/models/"
           + str(LLM["model"]).strip() + ":generateContent")
    payload = json.dumps({
        "contents": [{"parts": [{"text": prompt}]}],
    }).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload, method="POST",
        headers={"Content-Type": "application/json",
                 "x-goog-api-key": str(LLM["apiKey"])},
    )
    with urllib.request.urlopen(req, timeout=LLM_TIMEOUT_S) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    candidates = data.get("candidates") or []
    parts = ((candidates[0] if candidates else {}).get("content") or {}) \
        .get("parts") or []
    return "\n".join(str(p.get("text", "")) for p in parts).strip()


def _llm_prompt(project: str, dev: str, dtype: str, line: str, sample: str,
                mode: str) -> str:
    return (
        "You are repairing a Cisco IOS configuration typed into Packet "
        "Tracer. Packet Tracer rejects some real IOS commands.\n"
        "Answer with STRICT JSON only, no prose, no code fences:\n"
        '{"commands": ["<replacement IOS command>"], "explanation": "..."}\n'
        "Rules: at most 3 commands, each a single line under 120 characters, "
        "no interactive prompts, no 'terminal length', no 'show run'.\n\n"
        f"device: {dev} ({dtype})\n"
        f"current prompt mode: {mode or 'unknown'}\n"
        f"failing line: {line}\n"
        f"terminal error seen: {sample}\n"
        f"project: {project}\n"
    )


def _llm_try_fix(win, project: str, dev: str, dtype: str, line: str,
                 sample: str, mode: str = "") -> list:
    """Ask Gemini for a replacement, type it, verify it, remember it.

    Returns the verified command list, or [] when nothing was proven.  This
    function never raises and never marks an unverified suggestion as good.
    """
    key = command_key(line)
    if (dev, key) in LLM_ASKED or not llm_available(dev):
        return []
    LLM_ASKED.add((dev, key))
    LLM_PER_DEVICE[dev] = LLM_PER_DEVICE.get(dev, 0) + 1
    LLM["calls"] += 1
    RUN["llm_calls"] = RUN.get("llm_calls", 0) + 1

    try:
        answer = _llm_request(_llm_prompt(project, dev, dtype,
                                          llm_redact(line), llm_redact(sample),
                                          mode))
    except Exception as exc:
        answer = ""
        log(f"{dev}: Gemini request failed ({str(exc)[:90]})")

    commands = _llm_parse_commands(answer)
    if not commands:
        LLM["rejected"] += 1
        RUN["llm_fixes_rejected"] = RUN.get("llm_fixes_rejected", 0) + 1
        record_event("llm_fix_rejected",
                     f"no usable Gemini suggestion for '{line[:80]}'",
                     device=dev, recovered=False)
        return []

    try:
        _OCR_CACHE.clear()
        before_count, _ = _term_error_signature(win)
    except Exception:
        before_count = 0

    typed = True
    for cmd in commands:
        if stopped():
            typed = False
            break
        if not _ensure_cli_context(win, dev, cmd, {}, 25):
            typed = False
            break
        if not _type_line(cmd, 25, win=win, dev=dev):
            typed = False
            break

    after_count = before_count
    if typed:
        try:
            _OCR_CACHE.clear()
            _interruptible_sleep(0.6)
            after_count, _ = _term_error_signature(win)
        except Exception:
            after_count = before_count
    if not (typed and after_count <= before_count):
        LLM["rejected"] += 1
        RUN["llm_fixes_rejected"] = RUN.get("llm_fixes_rejected", 0) + 1
        record_event("llm_fix_rejected",
                     f"Gemini suggestion did not clear '{line[:80]}'",
                     device=dev, recovered=False,
                     extra={"commands": commands[:3], "model": LLM["model"]})
        return []

    LLM["applied"] += 1
    RUN["llm_fixes_applied"] = RUN.get("llm_fixes_applied", 0) + 1
    record_event("llm_fix_applied",
                 f"Gemini suggestion verified for '{line[:80]}'",
                 device=dev, recovered=True,
                 extra={"commands": commands[:3], "model": LLM["model"]})
    return commands


def learned_cli_lines(project: str, device: str, cfg: str,
                     dtype: str = "") -> list:
    """Apply a previously successful line-level fallback before typing."""
    lines = cli_lines_for_device(cfg, device, report=True)
    learned = (BAD_CMD_MEM.get(project, {}) or {}).get(device, {}) or {}
    context = _learning_context(project, device, dtype=dtype)
    out = []
    for line in lines:
        immediate = _immediate_cli_fix(project, device, dtype, line)
        if immediate:
            out.extend(immediate)
            log(f"{device}: current-session CLI correction applied before "
                f"typing '{line[:100]}'")
            record_event(
                "session_correction_applied",
                f"reused verified current-session correction for "
                f"'{line[:100]}'",
                device=device,
                recovered=True,
                extra={"replacement": immediate},
            )
            _record_session_cli_application(device, line, immediate)
            RUN["session_corrections_applied"] = (
                RUN.get("session_corrections_applied", 0) + 1
            )
            continue
        entry = learned.get(command_key(line))
        replacement = (entry or {}).get("replacement", [])
        if ((entry or {}).get("replacement_verified") and replacement
                and replacement != [line]):
            chosen = LEARNING.choose(
                "cli_fallback", "command", {**context, "source": line},
                [replacement, [line]])
            selected = chosen[0] if chosen else replacement
            out.extend(selected)
            log(f"{device}: learned fallback applied before typing "
                f"for '{line[:100]}'")
            record_event("learned_command_fix",
                         f"used remembered replacement for '{line[:100]}'",
                         device=device, recovered=True)
        else:
            out.append(line)
    # Learned replacements are another input path and can contain old
    # wrapper commands saved before the verified mode state machine existed.
    # Sanitize them at the final boundary as well.
    return _remove_blind_mode_entries(out)


# LAYOUT ----------------------------------------------------------------
# v1 placed every device on ONE row (fixed grid_y) - with several devices
# the row ran off-screen and PT kept widening the canvas. v2 lays devices
# out as a type-row grid: routers top, switches middle, end devices
# bottom, columns centered per row. v3 staggers single-device rows in x
# (zigzag tree) so a 1+1+1+1 build is not one vertical line. Bump the
# version whenever the layout math changes so remembered spots are
# re-placed, not reused. NOTE: re-running an older project after a bump
# re-places on a BLANK canvas - don't rerun over an existing canvas.
LAYOUT_VERSION = 4
# Keep server icons clearly below the PC row.  The old 0.68 row was close
# enough that the server reuse crop also captured the PC icon/label above it.
LAYOUT_ROWS = {"router": 0.30, "switch": 0.45, "pc": 0.60, "server": 0.75}
LAYOUT_ROW_MAX_Y = 0.78  # extra types stack below, never past here
# AUTO-REPAIR: how many whole-plan retry passes may run after the main
# sequence before the run accepts the remaining issues and reports them.
# Each pass re-attempts ONLY failed actions, so a healthy run pays nothing.
MAX_REPAIR_PASSES = 3


def _learning_context(project: str = "default", device: str = "",
                      dtype: str = "", model: str = "") -> dict:
    """Build a stable scope for safe strategy learning.

    A strategy learned on one device type/model/layout must not silently be
    reused on a different Packet Tracer surface.  The context is deliberately
    small and JSON-safe so it can be used as a persistent key.
    """
    remembered = ((DEV_MEM.get(project, {}) or {}).get(device, {}) or {})
    return {
        "project": project or "default",
        "device": device or "",
        "type": dtype or remembered.get("type", ""),
        "model": model or remembered.get("model", ""),
        "ptVersion": "unknown",
        "layout": LAYOUT_VERSION,
    }


def _session_cli_context(project: str, device: str,
                         dtype: str = "") -> dict:
    """Return the safe cross-device scope for an immediate CLI correction."""
    remembered = ((DEV_MEM.get(project, {}) or {}).get(device, {}) or {})
    return {
        "project": project or "default",
        "type": dtype or remembered.get("type", ""),
        "model": remembered.get("model", ""),
        "layout": LAYOUT_VERSION,
    }


def _immediate_cli_fix(project: str, device: str, dtype: str,
                       line: str):
    """Read a verified correction learned earlier in this build session."""
    context = _session_cli_context(project, device, dtype)
    candidate = LEARNING.immediate_correction(
        "cli_fallback", "command", context, line)
    if (isinstance(candidate, list) and candidate
            and candidate != [line]):
        return [str(value)[:180] for value in candidate[:8]]
    return None


def _record_session_cli_application(device: str, source: str,
                                    replacement: list):
    """Keep an in-run audit trail so a failed reuse can be quarantined."""
    RUN.setdefault("session_correction_applications", {}).setdefault(
        device, []).append({
            "source": source,
            "replacement": list(replacement),
        })


def _session_cli_source_for_line(device: str, line: str):
    """Find the verified source correction that produced a typed line."""
    for row in RUN.get("session_correction_applications", {}).get(
            device, []):
        replacement = row.get("replacement") or []
        if line in replacement:
            return row
    return None


def _remember_immediate_cli_fix(project: str, device: str, dtype: str,
                                line: str, replacement: list):
    """Publish a verified CLI correction to later devices in this run."""
    if (not replacement or list(replacement) == [line]
            or not (dtype or "").strip()):
        return
    context = _session_cli_context(project, device, dtype)
    LEARNING.remember_correction(
        "cli_fallback", "command", context, line,
        [str(value)[:180] for value in replacement[:8]],
        "live fallback verified during this build",
    )
    RUN["session_corrections_learned"] = (
        RUN.get("session_corrections_learned", 0) + 1
    )
    record_event(
        "session_correction_learned",
        f"verified CLI correction is ready for later {dtype} device(s): "
        f"'{line[:100]}'",
        device=device,
        recovered=True,
        extra={"replacement": replacement},
    )
    _learning_refresh()


def _learning_context_for_device(device: str = "") -> dict:
    for project, devices in DEV_MEM.items():
        if device in (devices or {}):
            return _learning_context(project, device)
    return _learning_context("global", device)


def _learning_refresh():
    """Expose the live controller state through the existing run summary."""
    RUN["learning"] = LEARNING.summary()
    RUN["learningEvents"] = LEARNING.events(40)


def _layout_spot(nodes) -> dict:
    """Type-row grid positions per node index.

    Each device type gets its own canvas row; devices in a row are
    centered with even spacing, capped so wide rows stay on canvas.
    """
    rows = dict(LAYOUT_ROWS)
    groups: dict = {}
    for idx, n in enumerate(nodes):
        t = (n.get("type") or "pc").lower()
        if t not in rows:
            # unknown types stack on an extra row below the known ones
            rows[t] = min(LAYOUT_ROW_MAX_Y, max(rows.values()) + 0.15)
        groups.setdefault(t, []).append(idx)
    spots = {}
    # single-device rows stagger in x so a 1-router/1-switch/1-PC/
    # 1-server build forms a zigzag tree instead of one vertical line
    # (user screenshot: everything stacked on x=0.50). Row ORDER is
    # canonical by type, so reruns are stable; remembered spots still
    # win over layout for existing projects (no version bump needed).
    _SINGLE_XS = (0.50, 0.38, 0.62, 0.44, 0.56)
    _TYPE_ORDER = ("router", "switch", "pc", "server")
    ordered = [t for t in _TYPE_ORDER if t in groups]
    ordered += sorted(t for t in groups if t not in _TYPE_ORDER)
    for ri, t in enumerate(ordered):
        idxs = groups[t]
        k = len(idxs)
        if k == 1:
            spots[idxs[0]] = (_SINGLE_XS[ri % len(_SINGLE_XS)], rows[t])
            continue
        step = min(0.15, 0.50 / (k - 1))
        x0 = 0.50 - step * (k - 1) / 2
        for j, idx in enumerate(idxs):
            spots[idx] = (round(x0 + step * j, 4), rows[t])
    return spots


@dataclass
class Job:
    running: bool = False
    log: list = field(default_factory=list)
    stop_requested: bool = False
    # PAUSE: a latch of its own so the worker keeps its whole progress
    # (placed devices, typed config, learning) and simply stops taking new
    # steps until the user resumes.  Stop remains the destructive action.
    paused: bool = False
    pause_requested: bool = False
    pause_source: str = ""
    project: str = "default"
    slot_of: dict = field(default_factory=dict)

JOB = Job()
LOCK = threading.Lock()
PAUSE_GATE = threading.Event()
PAUSE_GATE.set()  # not paused: the gate is open
HOTKEY_STATE = {"available": False, "error": "not started"}
CALIBRATION = {"running": False}


def _active_activity_locked() -> str:
    """Return the single activity that currently owns Packet Tracer."""
    if JOB.running:
        return "build"
    if bool(globals().get("AUDIT", {}).get("running")):
        return "audit"
    if CALIBRATION.get("running"):
        return "calibration"
    if bool(globals().get("PKT_STATE", {}).get("running")):
        return "pkt"
    return ""


def activity_snapshot() -> dict:
    with LOCK:
        kind = _active_activity_locked()
        # pause_snapshot() is inlined: LOCK is not reentrant and this runs
        # on the HTTP thread while the worker may hold the same lock.
        return {
            "running": bool(kind),
            "kind": kind or None,
            "stopRequested": bool(JOB.stop_requested),
            "paused": bool(JOB.paused),
            "pauseRequested": bool(JOB.pause_requested),
            "pauseSource": JOB.pause_source or None,
        }


def begin_activity(kind: str) -> tuple[bool, str]:
    """Atomically claim the PT UI and clear a stale stop/pause latch."""
    with LOCK:
        busy = _active_activity_locked()
        if busy:
            return False, busy
        JOB.stop_requested = False
        # Every new activity starts unpaused; a leftover pause from an
        # earlier run must never block a fresh job the user just started.
        JOB.paused = False
        JOB.pause_requested = False
        JOB.pause_source = ""
        PAUSE_GATE.set()
        if kind == "build":
            JOB.running = True
        elif kind == "audit":
            audit = globals().get("AUDIT")
            if not isinstance(audit, dict):
                return False, "audit unavailable"
            audit["running"] = True
            audit["report"] = None
        elif kind == "calibration":
            CALIBRATION["running"] = True
        elif kind == "pkt":
            PKT_STATE["running"] = True
        else:
            return False, f"unknown activity {kind}"
        return True, ""


def end_activity(kind: str):
    """Release the PT UI owner and return the stop latch to idle."""
    with LOCK:
        if kind == "build":
            JOB.running = False
        elif kind == "audit":
            audit = globals().get("AUDIT")
            if isinstance(audit, dict):
                audit["running"] = False
        elif kind == "calibration":
            CALIBRATION["running"] = False
        elif kind == "pkt":
            PKT_STATE["running"] = False
        # Leaving the owner also clears any pause latch so the next run
        # cannot inherit a stale 'paused' state.
        JOB.paused = False
        JOB.pause_requested = False
        JOB.pause_source = ""
        PAUSE_GATE.set()
        if not _active_activity_locked():
            JOB.stop_requested = False


def log(msg: str):
    with LOCK:
        JOB.log.append(f"{time.strftime('%H:%M:%S')} {msg}")
        JOB.log[:] = JOB.log[-300:]


def stopped() -> bool:
    with LOCK:
        return JOB.stop_requested


def _interruptible_sleep(seconds: float) -> bool:
    """Sleep in short slices so Stop/Escape and Pause are observed promptly."""
    start = time.time()
    deadline = start + max(0.0, seconds)
    while time.time() < deadline:
        if stopped():
            perf_add_ms("sleep_ms", (time.time() - start) * 1000.0)
            return False
        if JOB.paused or JOB.pause_requested:
            # Park inside the sleep too: a pause requested during a long
            # settle must not silently run out the rest of the timer.
            perf_add_ms("sleep_ms", (time.time() - start) * 1000.0)
            if not wait_if_paused():
                return False
            start = time.time()  # resumed: sleep out what is left
            deadline = start + max(0.0, seconds)
        time.sleep(min(0.05, max(0.0, deadline - time.time())))
    perf_add_ms("sleep_ms", (time.time() - start) * 1000.0)
    return not stopped()


def _safe_write(text: str, interval: float = 0.02,
                chunk_size: int = 64) -> bool:
    """Type text in short chunks and stop before any new chunk."""
    value = str(text)
    for start in range(0, len(value), max(1, chunk_size)):
        if not wait_if_paused():
            return False
        if stopped():
            return False
        pyautogui.write(value[start:start + max(1, chunk_size)],
                        interval=interval)
    return not stopped()


def _safe_click(*args, **kwargs) -> bool:
    """Never start a new mouse click after Stop, or while paused."""
    if not wait_if_paused():
        return False
    if stopped():
        return False
    try:
        pyautogui.click(*args, **kwargs)
    except Exception as e:
        if "FailSafe" in type(e).__name__:
            log(_fail_msg())
            raise RuntimeError("stopped by corner failsafe")
        raise
    return not stopped()


def _safe_press(key: str) -> bool:
    """Guard one-key UI actions after Stop/Escape, or while paused."""
    if not wait_if_paused():
        return False
    if stopped():
        return False
    pyautogui.press(key)
    return not stopped()


def _safe_hotkey(*keys) -> bool:
    """Guard multi-key UI actions after Stop/Escape, or while paused."""
    if not wait_if_paused():
        return False
    if stopped():
        return False
    pyautogui.hotkey(*keys)
    return not stopped()


def request_pause(source: str = "user"):
    """Ask the active run to hold at the next safe boundary.

    Pause never cancels work: the worker finishes its current UI action,
    then parks on a gate and keeps every piece of progress (placed devices,
    typed lines, learned strategies) intact.  Safe to call when idle.
    """
    with LOCK:
        if not _active_activity_locked():
            return False
        JOB.pause_requested = True
        JOB.pause_source = source
    log(f"PAUSE requested via {source}; the worker will hold after its "
        "current step (progress is kept)")
    return True


def request_resume(source: str = "user"):
    """Release the pause gate; the run continues where it left off."""
    with LOCK:
        had_pause = bool(JOB.paused or JOB.pause_requested)
        JOB.pause_requested = False
        JOB.paused = False
        JOB.pause_source = ""
    PAUSE_GATE.set()
    if had_pause:
        log(f"RESUME via {source} - continuing the run")
    return had_pause


def toggle_pause(source: str = "user") -> str:
    """Flip between paused and running; returns the new state name."""
    with LOCK:
        want_resume = bool(JOB.paused or JOB.pause_requested)
    if want_resume:
        request_resume(source)
        return "running"
    request_pause(source)
    return "paused"


def pause_snapshot() -> dict:
    """JSON-safe pause state for /status and /health."""
    with LOCK:
        return {
            "paused": bool(JOB.paused),
            "pauseRequested": bool(JOB.pause_requested),
            "pauseSource": JOB.pause_source or None,
        }


def wait_if_paused() -> bool:
    """Block while paused; return False when a Stop arrived instead.

    Called at safe boundaries (between UI actions, inside sleeps, before
    starting a new device/line).  While parked, the gate is re-checked in
    short slices so both resume and stop are observed promptly.
    """
    if not JOB.paused and not JOB.pause_requested:
        return True
    with LOCK:
        first = not JOB.paused
        JOB.paused = True
        JOB.pause_requested = False
    if first:
        log("PAUSED - holding at a safe boundary; press the Pause button "
            "or F9 to resume (Stop/Esc still works)")
        record_event("run_paused", "worker parked at a safe boundary",
                     recovered=True)
    PAUSE_GATE.clear()
    while not PAUSE_GATE.wait(timeout=0.05):
        if stopped():
            with LOCK:
                JOB.paused = False
            PAUSE_GATE.set()
            return False
    with LOCK:
        JOB.paused = False
    # The gate may have been opened BY request_stop (Stop must win over
    # pause), so the latch is re-checked after waking up.
    if stopped():
        PAUSE_GATE.set()
        return False
    return True


def request_stop(source: str = "user"):
    """Set the stop latch without lying that the worker already finished."""
    with LOCK:
        was_active = bool(_active_activity_locked())
        # An idle Stop is harmless.  Do not leave a stale latch that can
        # poison a later Audit/Calibration request.
        JOB.stop_requested = was_active
        # Stop wins over pause: a parked worker must also be released.
        JOB.paused = False
        JOB.pause_requested = False
    PAUSE_GATE.set()
    if was_active:
        log(f"STOP requested via {source}; current UI action will be released "
            "and the worker will exit at its next safe boundary")
    try:
        # Cancel PT placement/cable popups and clear a partially typed line.
        # This is intentionally best-effort; the latch is the authoritative
        # stop signal used by every stage.
        if HAS_RPA:
            _press_esc()
    except Exception:
        pass


# EMERGENCY STOP (Esc) / PAUSE (F9) ------------------------------------
# Two keyboard buttons control a run from anywhere:
#   Esc - emergency stop: the run is cancelled after the current step
#         (worst case a few seconds, never instant mid-keystroke).
#   F9  - pause/resume toggle: the worker parks at its next safe boundary
#         and keeps all progress; F9 again (or the app's Pause button)
#         continues exactly where it stopped.
# The automation ALSO presses Esc itself (placement-mode exit, cable
# cancel), so self-presses are timestamped via _press_esc() and ignored by
# the listener for a very short window - only YOUR keys count. Needs
# `pip install pynput`; without it the old corner failsafe (slam mouse to
# a screen corner) still works.
_LAST_SELF_ESC = 0.0


def _press_esc():
    """Automation's own Esc (placement exit, cable cancel). Timestamped
    so the emergency listener tells it apart from the user's key."""
    global _LAST_SELF_ESC
    _LAST_SELF_ESC = time.time()
    try:
        pyautogui.press("esc")
    except Exception:
        pass


def _emergency_stop():
    if activity_snapshot()["running"]:
        request_stop("global Esc")


def _hotkey_pause_toggle():
    if activity_snapshot()["running"]:
        toggle_pause("global F9")


def _hotkey_loop():
    global HOTKEY_STATE
    try:
        from pynput import keyboard as _kb
    except Exception as e:
        HOTKEY_STATE = {"available": False, "error": str(e)}
        print(f"emergency Esc stop unavailable (pip install pynput): {e}")
        return
    HOTKEY_STATE = {"available": True, "error": ""}

    def on_press(key):
        try:
            if key == _kb.Key.esc:
                if time.time() - _LAST_SELF_ESC > 0.15:
                    _emergency_stop()
            elif key == _kb.Key.f9:
                _hotkey_pause_toggle()
        except Exception:
            pass

    try:
        with _kb.Listener(on_press=on_press) as lst:
            lst.join()
    except Exception as e:
        HOTKEY_STATE = {"available": False, "error": str(e)}
        print(f"hotkey listener dead: {e}")


# FAILURE JOURNAL -------------------------------------------------------
# Every mistake/problem gets a permanent structured event. This is the
# learning backbone: the app reads it (/stats, /suggest) and auto-saves
# recurring patterns as rules - failures finally persist across runs.
JOURNAL_FILE = os.path.join(os.path.dirname(__file__), "failures.jsonl")
EXPERIENCE_FILE = os.path.join(os.path.dirname(__file__),
                               "experience_memory.jsonl")

# Per-run counters (reset each run_plan); served on /run_summary.
RUN: dict = {}

# PERFORMANCE COUNTERS --------------------------------------------------
# A build run is dominated by terminal reads (each one screenshots the
# device pane, upscales it and spawns Tesseract - twice when the psm 6 pass
# reads nothing), not by typing.  These counters exist so that split is
# measured instead of guessed: they are served on /run_summary and printed
# as one log line at the end of a run.  Counting only - no call path is
# added or removed here.
PERF: dict = {}


def perf_reset():
    """Zero the per-run counters.  Called from _run_reset."""
    snapshot = {
        "ocr_reads": 0,        # _ocr_region calls that reached the screenshot
        "ocr_ttl_hits": 0,     # served by the short-lived TTL cache
        "ocr_px_hits": 0,      # served by the exact-content cache
        "ocr_spawns": 0,       # Tesseract invocations (one per pass)
        "ocr_psm6": 0,
        "ocr_psm11": 0,
        "ocr_ms": 0.0,
        "uia_reads": 0,
        "uia_ms": 0.0,
        "focus_calls": 0,
        "focus_skips": 0,      # reads that skipped re-activation entirely
        "focus_ms": 0.0,
        "type_calls": 0,
        "type_ms": 0.0,
        "sleep_ms": 0.0,
        "ocr_psmOther": 0,
    }
    # Replaced under the lock, and the key set never changes afterwards:
    # /run_summary serialises this dict on the HTTP thread while the build
    # worker is still counting, and a resize mid-serialisation would raise.
    with LOCK:
        PERF.clear()
        PERF.update(snapshot)


def perf_inc(key: str, amount: int = 1):
    if key not in PERF:
        key = "ocr_psmOther" if key.startswith("ocr_psm") else key
    with LOCK:
        PERF[key] = PERF.get(key, 0) + int(amount)


def perf_add_ms(key: str, ms: float):
    with LOCK:
        PERF[key] = round(PERF.get(key, 0.0) + float(ms), 3)


def perf_summary_line() -> str:
    """One-line cost split for the run log (and RUN['perfSummary'])."""
    lines = PERF.get("type_calls", 0)
    reads = PERF.get("ocr_reads", 0)
    per_line = (reads / lines) if lines else 0.0
    return (
        f"PERF lines={lines} reads={reads} "
        f"(ttl={PERF.get('ocr_ttl_hits', 0)}, "
        f"unchanged={PERF.get('ocr_px_hits', 0)}) "
        f"tesseract={PERF.get('ocr_spawns', 0)} "
        f"(psm6={PERF.get('ocr_psm6', 0)}, psm11={PERF.get('ocr_psm11', 0)}) "
        f"ocr={PERF.get('ocr_ms', 0)}ms focus={PERF.get('focus_ms', 0)}ms "
        f"(skipped={PERF.get('focus_skips', 0)}) "
        f"uia={PERF.get('uia_ms', 0)}ms typing={PERF.get('type_ms', 0)}ms "
        f"sleeps={PERF.get('sleep_ms', 0)}ms reads/line={per_line:.1f}"
    )


def _write_experience(evt: dict):
    """Persist a compact, reusable learning record for meaningful events."""
    kind = evt.get("kind", "")
    if evt.get("recovered") is None or kind in {
            "phase_state", "inventory_done", "audit_done", "run_finished"}:
        return
    extra = evt.get("extra") or {}
    row = {
        "schema": 1,
        "ts": evt.get("ts", ""),
        "kind": kind,
        "device": evt.get("device", ""),
        "expected": extra.get("expected", ""),
        "observed": extra.get("observed", "") or extra.get("ocr", ""),
        "correction": extra.get("fallback", "")
        or extra.get("correction", ""),
        "result": "recovered" if evt.get("recovered") else "failed",
        "detail": evt.get("detail", "")[:240],
    }
    try:
        with open(EXPERIENCE_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")
    except Exception as e:
        log(f"experience memory write failed: {e}")


def _run_reset():
    global LEARNING
    LEARNING = SessionLearningController(STRATEGY_STORE)
    for k in ("devices_done", "devices_skipped", "errors_recovered",
              "errors_unrecovered", "setup_no", "saves_retried",
              "model_autotunes", "links_red", "admin_heals",
              "pcs_configured", "pings_ok", "pings_failed",
              "srv_configured", "srv_failed", "devices_reused",
              "srv_rules_unverified",
              "srv_rules_verified",
              "pings_expected",
              "cli_mode_repairs", "cli_context_blocks",
              "session_corrections_learned",
              "session_corrections_applied",
              "session_corrections_rejected",
              "devices_placed", "devices_reuse_blocked",
              "configs_reused", "configs_verified", "links_failed",
              "placement_retries", "security_failed", "interfaces_blocked",
              "interfaces_unverified", "unsupported_features_count",
              "repair_passes", "repair_recovered"):
        RUN[k] = 0
    RUN["interface_blocked_devices"] = []
    RUN["node_outcomes"] = {}
    RUN["phases"] = {}
    RUN["action_results"] = {}
    RUN["link_results"] = {}
    RUN["security_checks"] = []
    RUN["service_results"] = []
    RUN["ping_results"] = []
    RUN["pc_config_results"] = {}
    RUN["interface_remaps"] = {}
    RUN["unsupported_features"] = []
    RUN["llm_calls"] = 0
    RUN["llm_fixes_applied"] = 0
    RUN["llm_fixes_rejected"] = 0
    llm_reset_run()
    RUN["cli_prerequisite_failed"] = False
    RUN["downstream_blocked"] = []
    RUN["fullscreen_verified"] = False
    RUN["focus_blocks"] = 0
    RUN["red_link_check_ran"] = False
    RUN["session_correction_applications"] = {}
    RUN["phase"] = "starting"
    RUN["sessionId"] = LEARNING.session_id
    # A fresh run starts unpaused; the pause counters document how much of
    # the last run was spent parked (visible on /run_summary).
    RUN["paused_events"] = 0
    RUN["paused_ms"] = 0.0
    # Where the commands were lost, and what the run left behind.
    RUN["cli_block_reasons"] = {}
    RUN["cli_prompt_rereads"] = 0
    RUN["cli_prompt_recovered"] = 0
    RUN["cli_prompt_reread_capped"] = 0
    _CLI_PROOF_MISSES.clear()
    RUN["pkt"] = {}
    RUN["srv_probe"] = {}
    RUN["coordinate_space"] = {}
    _SRV_SHADOW_SEEN.clear()
    perf_reset()
    RUN["perf"] = PERF
    _learning_refresh()


def phase_update(name: str, status: str, expected: str = "",
                 observed: str = "", attempt: int = 0):
    """Record the state-machine phase and its evidence in the run summary."""
    row = {
        "status": status,
        "expected": (expected or "")[:240],
        "observed": (observed or "")[:240],
        "attempt": int(attempt or 0),
        "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    RUN.setdefault("phases", {})[name] = row
    RUN["phase"] = name
    record_event("phase_state",
                 f"{name} -> {status}"
                 + (f" ({observed[:100]})" if observed else ""),
                 recovered=(status in ("verified", "skipped")),
                 extra={"expected": expected, "attempt": attempt})


def action_update(action: str, device: str = "", status: str = "pending",
                  expected: str = "", observed: str = "", attempt: int = 0):
    key = f"{action}:{device}" if device else action
    RUN.setdefault("action_results", {})[key] = {
        "action": action,
        "device": device,
        "status": status,
        "expected": (expected or "")[:240],
        "observed": (observed or "")[:240],
        "attempt": int(attempt or 0),
        "updated": time.strftime("%Y-%m-%d %H:%M:%S"),
    }


class _EventCounter:
    """Monotonic count of journalled events.

    Used to answer "did this step explain itself?" - a flow that fails without
    recording anything is the case that made SRV1's dns/ftp/ntp/tftp failures
    undiagnosable in the 2026-09-16 runs.
    """

    total = 0


def record_event(kind: str, detail: str, device: str = "",
                 recovered=None, extra: dict | None = None):
    """Append one structured event to failures.jsonl (never throws)."""
    evt = {"ts": time.strftime("%Y-%m-%d %H:%M:%S"),
           "kind": kind,
           "device": device,
           "detail": (detail or "")[:200],
           "recovered": recovered}
    evt["session"] = LEARNING.session_id
    if extra:
        evt["extra"] = {k: str(v)[:120]
                        for k, v in list(extra.items())[:6]}
    _EventCounter.total += 1
    _write_experience(evt)
    try:
        with open(JOURNAL_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(evt) + "\n")
    except Exception as e:
        log(f"journal write failed: {e}")
    log(f"EVENT {kind}: {evt['detail'][:100]}")


def _journal_rows(limit: int = 3000) -> list:
    try:
        with open(JOURNAL_FILE, encoding="utf-8") as f:
            rows = [json.loads(l) for l in f if l.strip()]
    except Exception:
        return []
    return rows[-limit:]


def _experience_rows(limit: int = 200) -> list:
    try:
        with open(EXPERIENCE_FILE, encoding="utf-8") as f:
            rows = [json.loads(l) for l in f if l.strip()]
    except Exception:
        return []
    return rows[-max(1, min(1000, limit)):]


DIAGNOSTICS_DIR = os.path.join(os.path.dirname(__file__), "diagnostics")


def _diagnostics_redact(value) -> str:
    """Remove obvious credentials before a tester export is created."""
    text = str(value or "")
    patterns = (
        r"(?i)(api[_ -]?key|password|passwd|secret|token|community)"
        r"(\s*[:=]\s*|\s+)[^\s,;]+",
    )
    for pattern in patterns:
        text = re.sub(pattern, r"\1=<redacted>", text)
    return text[:500]


def _diagnostics_event(row: dict) -> dict:
    """Keep diagnostics useful without exporting raw command/config text."""
    return {
        "ts": row.get("ts", ""),
        "kind": row.get("kind", ""),
        "device": row.get("device", ""),
        "recovered": row.get("recovered"),
        "detail": _diagnostics_redact(row.get("detail", "")),
    }


def _diagnostics_experience(row: dict) -> dict:
    return {
        "ts": row.get("ts", ""),
        "kind": row.get("kind", ""),
        "device": row.get("device", ""),
        "result": row.get("result", ""),
        "detail": _diagnostics_redact(row.get("detail", "")),
    }


def diagnostics_export(include_screenshots: bool = False) -> dict:
    """Create an opt-in, redacted tester bundle without raw configs."""
    os.makedirs(DIAGNOSTICS_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = os.path.join(DIAGNOSTICS_DIR, f"netbuilder-diagnostics-{stamp}.zip")
    rows = _journal_rows(500)
    safe_run = {
        key: RUN.get(key)
        for key in ("sessionId", "phase", "devices_done", "devices_skipped",
                    "errors_recovered", "errors_unrecovered", "links_red",
                    "configs_verified", "links_failed", "security_failed",
                    "srv_rules_unverified", "srv_rules_verified",
                    "cli_mode_repairs", "cli_context_blocks",
                    "learning")
        if key in RUN
    }
    payload = {
        "schema": 1,
        "created": time.strftime("%Y-%m-%d %H:%M:%S"),
        "sidecarVersion": VERSION,
        "rpa": bool(HAS_RPA),
        "ocr": bool(TESSERACT_CMD),
        "includeScreenshots": bool(include_screenshots),
        "run": safe_run,
        "journal": [_diagnostics_event(row) for row in rows],
        "experiences": [_diagnostics_experience(row)
                        for row in _experience_rows(300)],
        "learning": LEARNING.summary(),
        "deviceMemory": DEV_MEM,
        "serviceResults": RUN.get("service_results", []),
    }
    files = ["diagnostics.json"]
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("diagnostics.json", json.dumps(payload, indent=2))
        if include_screenshots and os.path.isdir(SHOTS):
            shot_paths = sorted(
                (os.path.join(SHOTS, name) for name in os.listdir(SHOTS)),
                key=lambda item: os.path.getmtime(item), reverse=True)
            total = 0
            for shot_path in shot_paths[:30]:
                if not os.path.isfile(shot_path):
                    continue
                size = os.path.getsize(shot_path)
                if total + size > 50 * 1024 * 1024:
                    continue
                archive.write(shot_path, os.path.join("shots",
                                                       os.path.basename(shot_path)))
                files.append(os.path.join("shots", os.path.basename(shot_path)))
                total += size
    return {"path": path, "files": files,
            "includeScreenshots": bool(include_screenshots)}


def journal_stats() -> dict:
    """Aggregate the journal: per-kind and per-signature hit/miss counts.

    A signature is kind + normalized detail - 'the same mistake' across
    runs (e.g. model click missed, same CLI line erroring).
    """
    rows = _journal_rows()
    kinds: dict = {}
    sigs: dict = {}
    for e in rows:
        k = e.get("kind", "?")
        rec = e.get("recovered")
        agg = kinds.setdefault(k, {"count": 0, "recovered": 0})
        agg["count"] += 1
        if rec:
            agg["recovered"] += 1
        sig = k + ":" + (e.get("detail", "") or "")[:70].strip().lower()
        s = sigs.setdefault(sig, {"count": 0, "recovered": 0, "last": ""})
        s["count"] += 1
        if rec:
            s["recovered"] += 1
        s["last"] = e.get("ts", "")
    return {"total": len(rows),
            "kinds": kinds,
            "signatures": sorted(sigs.items(),
                                 key=lambda kv: -kv[1]["count"])[:40]}


def journal_suggestions() -> list:
    """Turn recurring failure patterns into concrete suggested rules.

    This is the 'notices the model click missed 3 runs in a row' layer:
    signature counts from real runs become one-click savable rules.
    """
    st = journal_stats()
    out = []
    kinds = st["kinds"]
    if kinds.get("placement_failed", {}).get("count", 0) >= 2:
        out.append("Placement keeps failing - run 'Teach Model' once, or "
                   "let the auto-tuner re-scan the model thumbnail strip.")
    if kinds.get("model_autotuned", {}).get("count", 0) >= 2:
        out.append("Model strip drifts often - check display scaling is "
                   "100% and PT is maximized before builds.")
    if kinds.get("link_red", {}).get("count", 0) >= 1:
        out.append("Links end up red after builds - verify router "
                   "interfaces get 'no shutdown' and cables land on the "
                   "configured ports.")
    if kinds.get("ping_test", {}).get("count", 0) >= 1:
        rows = _journal_rows()
        fails = [e for e in rows if e.get("kind") == "ping_test"
                 and e.get("recovered") is False]
        if fails:
            out.append("Ping tests failed - check PC IPs (Desktop > IP "
                       "Configuration) and that OSPF is advertised for "
                       "both LANs.")
    if kinds.get("pc_config_failed", {}).get("count", 0) >= 2:
        out.append("PC Desktop IP configuration keeps failing - teach "
                   "the IP Configuration tile or configure PCs manually.")
    if kinds.get("srv_service", {}).get("count", 0) >= 2:
        out.append("Server Services flows keep failing - the service "
                   "panels vary by PT version; open Services once "
                   "manually and compare the field labels with the "
                   "sidecar log's 'service field' lines.")
    if kinds.get("srv_save_failed", {}).get("count", 0) >= 2:
        out.append("Service values type in but the pool table never "
                   "updates - the Add/Save click lands wrong. Learned "
                   "button spots are evicted automatically; re-run once "
                   "so it re-learns the button, and keep PT maximized.")
    if kinds.get("srv_fill_mismatch", {}).get("count", 0) >= 3:
        out.append("Service-panel rows keep failing read-back - check "
                   "display scaling is 100%, PT is maximized and not "
                   "covered; wrong octet rows are reported in "
                   "failures.jsonl ('srv_fill_mismatch') with what the "
                   "row actually showed.")
    if kinds.get("srv_field_missing", {}).get("count", 0) >= 3:
        out.append("Service field labels are not being read - OCR "
                   "quality issue. Make sure PT is the front window "
                   "during runs; the autopilot refuses to blind-type "
                   "when it cannot see the box (this is intentional).")
    if kinds.get("srv_record_missing", {}).get("count", 0) >= 2:
        out.append("DNS records type in but never appear in the record "
                   "table - the Add click lands wrong. Check shots/"
                   "*_dns_fail.png; re-run once so the Add spot "
                   "re-learns.")
    if kinds.get("srv_plan_suspicious", {}).get("count", 0) >= 1:
        out.append("The plan's own values look inconsistent (start IP "
                   "outside the gateway/mask subnet, or bad max-users) "
                   "- the pools were typed anyway but will misbehave; "
                   "regenerate the plan.")
    if kinds.get("pc_wrong_panel", {}).get("count", 0) >= 1:
        out.append("Wrong Desktop app opened on a PC click - the "
                   "autopilot now verifies panel titles, closes wrong "
                   "panels and auto-learns the correct tile spots; "
                   "re-run to reinforce them.")
    if kinds.get("save_retried", {}).get("count", 0) >= 2:
        out.append("'write memory' keeps getting eaten after long output "
                   "- keep the post-'show' settle delay enabled.")
    if kinds.get("repair_pass_incomplete", {}).get("count", 0) >= 2:
        out.append("Auto-repair passes keep failing on the same actions - "
                   "the retry cap stops runaway loops, but teach the "
                   "offending panel/model spot once and the next run "
                   "should verify first try.")
    if kinds.get("repair_exhausted", {}).get("count", 0) >= 1:
        out.append("Some actions stayed unverified even after all "
                   "auto-repair passes - check shots/before.png vs "
                   "after.png and the failed items in /run_summary.")
    if kinds.get("window_not_found", {}).get("count", 0) >= 2:
        out.append("Device double-clicks miss canvas slots - re-place "
                   "devices or re-check remembered spots.")
    if kinds.get("setup_unresolvable", {}).get("count", 0) >= 2:
        out.append("Setup dialog keeps resisting 'no' - re-run the "
                   "affected device (Cables + CLI only) and keep PT "
                   "focused; the boot dialog needs the console awake.")
    for sig, s in st["signatures"]:
        if s["count"] >= 2 and not s["recovered"]:
            out.append(f"Recurring UNRECOVERED failure ({s['count']}x): "
                       f"{sig} - needs a new fallback or manual fix.")
        elif s["count"] >= 3 and s["recovered"] == s["count"]:
            out.append(f"'{sig.split(':', 1)[-1]}' errors but the fallback "
                       f"recovers it every time ({s['count']}x) - keep "
                       f"one-shot retries enabled.")
    seen = set()
    uniq = []
    for t in out:
        if t not in seen:
            seen.add(t)
            uniq.append(t)
    return uniq[:12]


def _bounded_call(fn, timeout_s: float, label: str):
    """Run one potentially blocking desktop call with a hard upper bound.

    UI Automation providers can stop answering while Packet Tracer is busy
    repainting a device window.  Calling them directly from the build worker
    leaves JOB.running latched forever and prevents the Stop button from
    reaching its cleanup path.  The helper thread is daemonized so a stalled
    provider cannot keep the sidecar alive; the caller receives a normal
    timeout and can release the activity lock.
    """
    result = {}

    def invoke():
        try:
            result["value"] = fn()
        except BaseException as exc:  # preserve the original UI exception
            result["error"] = exc

    worker = threading.Thread(target=invoke,
                              name=f"pt-ui-{label[:24]}", daemon=True)
    worker.start()
    worker.join(max(0.1, float(timeout_s)))
    if worker.is_alive():
        raise TimeoutError(f"{label} timed out after {timeout_s:.1f}s")
    if "error" in result:
        raise result["error"]
    return result.get("value")


def find_pt_window():
    if not HAS_RPA:
        raise RuntimeError(f"RPA deps missing: {RPA_IMPORT_ERROR}")
    last_error = None
    # UIA is preferred because its descendants expose the named PT controls,
    # but a hung UIA provider must not prevent the simpler Win32 fallback.
    for backend in ("uia", "win32"):
        try:
            wins = _bounded_call(
                lambda backend=backend: Desktop(backend=backend).windows(
                    title_re=".*Packet Tracer.*"),
                timeout_s=5.0,
                label=f"{backend} Packet Tracer window scan",
            ) or []
        except TimeoutError as exc:
            last_error = exc
            log(f"{backend} Packet Tracer window scan timed out; "
                "trying the next backend")
            continue
        except Exception as exc:
            last_error = exc
            log(f"{backend} Packet Tracer window scan failed: {exc}")
            continue
        if wins:
            return wins[0]
    if isinstance(last_error, TimeoutError):
        raise RuntimeError("Packet Tracer window discovery timed out; "
                           "bring Packet Tracer to the foreground and retry")
    raise RuntimeError("Packet Tracer window not found. Open PT first.")


def inspect_pt(max_items: int = 120) -> list:
    """Dump PT UIA control tree: name/type/rect. Used to click by NAME."""
    w = find_pt_window()
    out = []
    try:
        for d in w.descendants():
            try:
                info = d.element_info
                name = (getattr(info, "name", "") or "")[:60]
                ctype = getattr(info, "control_type", "") or d.friendly_class_name()
                r = d.rectangle()
                out.append({
                    "name": name,
                    "type": str(ctype)[-40:],
                    "rect": [r.left, r.top, r.right, r.bottom],
                })
            except Exception:
                continue
            if len(out) >= max_items * 3:
                break
    except Exception as e:
        log(f"inspect walk failed: {e}")
    # prioritize named controls (buttons with text)
    named = [c for c in out if c["name"].strip()]
    rest = [c for c in out if not c["name"].strip()]
    return (named + rest)[:max_items]


def _click_control(d, what: str, nm: str) -> tuple:
    """Click a UIA control; returns its (cx, cy) screen center."""
    try:
        r = d.rectangle()
        cx, cy = (r.left + r.right) // 2, (r.top + r.bottom) // 2
    except Exception:
        cx = cy = None
    log(f"UIA click {what}: matched '{nm}' at ({cx},{cy})")
    try:
        d.click_input()
    except Exception:
        try:
            d.invoke()
        except Exception:
            d.click()
    _interruptible_sleep(0.9)
    return cx, cy


def click_by_names(names: list, what: str, timeout_s: float = 4.0,
                   near: tuple | None = None) -> bool:
    """Click UIA control by NAME, honoring `names` PRIORITY order.

    Previous bug: all wants were checked per control in tree order, so a
    1941 button earlier in the tree beat the requested 2911. Now each want
    is scanned in order - requested model always wins when present.

    near=(x, y, max_dist_px): only accept matches within max_dist_px of
    (x, y). Without this the port picker matched PT's status-bar clock
    ('Time: 01:12:49' contains '0') as a device port and declared ghost
    links WIRED. Far matches are skipped (logged once per want).
    """
    if not HAS_RPA:
        raise RuntimeError("RPA deps missing")
    w = find_pt_window()
    deadline = time.time() + timeout_s
    wants = [n.lower() for n in names]
    far_logged: set = set()
    while time.time() < deadline:
        if stopped():
            return False
        try:
            try:
                controls = list(w.descendants())
            except Exception as e:
                log(f"UIA scan warning: {e}")
                _interruptible_sleep(0.4)
                continue
            for want in wants:
                for d in controls:
                    try:
                        nm = (d.element_info.name or "")
                    except Exception:
                        continue
                    if want and want in nm.lower():
                        if near is not None:
                            try:
                                r = d.rectangle()
                                mx, my = ((r.left + r.right) // 2,
                                          (r.top + r.bottom) // 2)
                            except Exception:
                                continue
                            nx, ny, md = near
                            if (mx - nx) ** 2 + (my - ny) ** 2 > md * md:
                                if want not in far_logged:
                                    far_logged.add(want)
                                    log(f"UIA {what}: ignoring far match "
                                        f"'{nm}' at ({mx},{my}) "
                                        f"(endpoint at ({nx},{ny}))")
                                continue
                        _click_control(d, what, nm)
                        return True
        except Exception as e:
            log(f"UIA scan warning: {e}")
        _interruptible_sleep(0.4)
    return False


def rect_of(w):
    r = w.rectangle()
    return (r.left, r.top, r.right, r.bottom)


def to_abs(rect, fx, fy):
    l, t, r, b = rect
    return (int(l + (r - l) * fx), int(t + (b - t) * fy))


# COORDINATE SPACE -----------------------------------------------------
# Every coordinate in this file is a FRACTION of the PT window rect turned
# into pixels by `to_abs()`, and every crop/click goes through pyautogui's
# screen space.  Where those two spaces disagree - a scaled display with a
# DPI-unaware process, a per-monitor-DPI monitor, a window reaching past the
# screen space this process can see - every fraction is silently wrong:
# clicks land near-but-not-on and crops read the neighbouring row.  That is
# the same symptom family as a bad row read-back, so it is measured once at
# preflight instead of guessed at for forty minutes.
COORD_DRIFT_TOLERANCE = 0.02   # 2% of the window: room for one rounding pixel
DPI_AWARE_ENV = "NETBUILDER_DPI_AWARE"


def _screen_metrics() -> dict:
    """Win32 screen + DPI metrics for THIS process. Read-only, fail-soft."""
    out = {"screen": None, "virtual": None, "dpi": None,
           "awareness": None, "platform": os.name}
    if os.name != "nt":
        return out
    try:
        import ctypes
        user32 = ctypes.windll.user32
        out["screen"] = (int(user32.GetSystemMetrics(0)),
                         int(user32.GetSystemMetrics(1)))
        # 76..79 = the virtual screen (all monitors) THIS process can address
        out["virtual"] = (int(user32.GetSystemMetrics(76)),
                          int(user32.GetSystemMetrics(77)),
                          int(user32.GetSystemMetrics(78)),
                          int(user32.GetSystemMetrics(79)))
    except Exception as e:
        log(f"screen metrics failed: {e}")
    try:
        import ctypes
        value = ctypes.c_int(-1)
        # 0 = DPI unaware, 1 = system aware, 2 = per-monitor aware
        if ctypes.windll.shcore.GetProcessDpiAwareness(
                None, ctypes.byref(value)) == 0:
            out["awareness"] = int(value.value)
    except Exception:
        pass
    try:
        import ctypes
        out["dpi"] = int(ctypes.windll.user32.GetDpiForSystem())
    except Exception:
        pass
    return out


def coordinate_space_report(rect, screen=None, virtual=None, dpi=None,
                            awareness=None, shot=None,
                            tolerance: float = COORD_DRIFT_TOLERANCE) -> dict:
    """Do the window rect, the screenshot space and the metrics agree?

    Pure function (no Win32 calls), so the rule is unit-testable.  Each
    signal is independently sufficient to fail, and an unmeasured metric is
    "not measured" rather than "wrong":

    * the window rect reaches past the virtual screen this process can
      address, so crops/clicks would be aimed outside its coordinate space;
    * pyautogui's screen size disagrees with the Win32 metrics for the same
      screen, i.e. the click space and the crop space are not one space;
    * the display is scaled (dpi != 96) while this process is DPI unaware,
      so Windows virtualizes this process's coordinates while a DPI-aware
      Packet Tracer reports real ones.  Fraction-of-rect coordinates do not
      survive that: they are off by the scale factor.

    Returns {"ok", "drift", "signals", "message", "action"}.
    """
    r = tuple(int(v) for v in (rect or (0, 0, 0, 0)))
    w, h = r[2] - r[0], r[3] - r[1]
    if w <= 0 or h <= 0:
        return {"ok": False, "drift": 1.0, "signals": ["empty-window-rect"],
                "message": "Packet Tracer's window rect is empty; every "
                           "click would be guesswork",
                "action": "restore/maximize the Packet Tracer window",
                "rect": list(r)}
    signals, drift = [], 0.0
    if virtual and len(tuple(virtual)) == 4:
        vx, vy, vw, vh = (int(v) for v in virtual)
        overflow = max(r[2] - (vx + vw), r[3] - (vy + vh), 0)
        if overflow > 0:
            drift = max(drift, overflow / max(1, max(w, h)))
            signals.append("window-past-the-process-screen")
    if shot and screen:
        sw, sh = int(shot[0]), int(shot[1])
        cw, ch = int(screen[0]), int(screen[1])
        if sw and sh and cw and ch and (sw != cw or sh != ch):
            signals.append("pyautogui-screen-disagrees-with-win32")
            drift = max(drift, abs(sw - cw) / max(1, cw),
                        abs(sh - ch) / max(1, ch))
    scale = None
    if dpi and awareness == 0:
        scale = float(dpi) / 96.0
        if abs(scale - 1.0) > tolerance:
            signals.append("scaled-display-with-dpi-unaware-process")
            drift = max(drift, abs(scale - 1.0))
    ok = drift <= tolerance
    if ok and not signals:
        message = (f"window rect, screenshot space and screen metrics agree "
                   f"(drift {drift:.3f}, dpi={dpi}, awareness={awareness})")
    elif ok:
        message = (f"coordinate space usable, but not clean: "
                   f"{', '.join(signals)} (drift {drift:.3f})")
    elif scale is not None and abs(scale - 1.0) > tolerance:
        message = (f"display scaling is {scale * 100:.0f}% and this process "
                   f"is not DPI aware: clicks would be off by about "
                   f"{scale:.2f}x the whole run")
    else:
        message = (f"the window rect and the click/crop space disagree "
                   f"(drift {drift:.2f}: {', '.join(signals)})")
    action = ""
    if "scaled-display-with-dpi-unaware-process" in signals:
        action = ("set Packet Tracer's display scaling to 100%, or start the "
                  f"sidecar with {DPI_AWARE_ENV}=1 (and re-teach the "
                  "calibration after that change)")
    elif signals:
        action = ("maximize Packet Tracer on the primary display and keep it "
                  "there for the whole run")
    return {"ok": ok, "drift": round(drift, 4), "signals": signals,
            "message": message, "action": action, "rect": list(r),
            "screen": list(screen) if screen else None,
            "virtual": list(virtual) if virtual else None,
            "shot": list(shot) if shot else None, "dpi": dpi,
            "awareness": awareness, "tolerance": tolerance}


def geometry_stamp(rect, metrics: dict | None = None,
                   shot=None) -> dict:
    """The coordinate space a learned spot / calibration belongs to.

    Spots are stored as fractions of the window rect, so a plain resize is
    harmless - what changes their meaning is the screen space, the DPI/aware
    state of the process, and a wildly different window aspect.  This stamp
    is provenance: it is compared at preflight and reported, it is never
    used to silently reinterpret a stored value.
    """
    m = metrics if isinstance(metrics, dict) else _screen_metrics()
    return {"rect": [int(v) for v in rect],
            "screen": list(m.get("screen") or []),
            "dpi": m.get("dpi"),
            "awareness": m.get("awareness"),
            "shot": [int(v) for v in shot] if shot else None,
            "at": time.strftime("%Y-%m-%d %H:%M:%S")}


def geometry_changed(old, new, aspect_tol: float = 0.05) -> bool:
    """True when two stamps describe a different coordinate space."""
    if not isinstance(old, dict) or not isinstance(new, dict):
        return False
    for key in ("screen", "dpi", "awareness", "shot"):
        a, b = old.get(key), new.get(key)
        if a in (None, [], "") or b in (None, [], ""):
            continue
        if list(a) != list(b) if isinstance(a, (list, tuple)) else a != b:
            return True
    a, b = old.get("rect"), new.get("rect")
    if a and b and len(a) == 4 and len(b) == 4:
        def _aspect(v):
            return (v[2] - v[0]) / max(1.0, (v[3] - v[1]))
        if abs(_aspect(a) - _aspect(b)) > aspect_tol:
            return True
    return False


def enable_dpi_awareness(force: bool = False) -> dict:
    """Opt-in DPI awareness, so pyautogui and UIA share one space.

    Off by default on purpose: it changes what EVERY coordinate means, so it
    must be A/B'd against a real run first (the preflight above measures the
    difference).  `NETBUILDER_DPI_AWARE=1` or `force=True` applies the
    per-monitor setting once, before the first screenshot or click.
    """
    out = {"applied": False, "mode": None, "error": ""}
    if os.name != "nt":
        out["error"] = "not windows"
        return out
    wanted = force or str(os.environ.get(DPI_AWARE_ENV, "")).strip() in (
        "1", "true", "yes", "on")
    if not wanted:
        out["error"] = f"not requested (set {DPI_AWARE_ENV}=1)"
        return out
    try:
        import ctypes
        try:
            # 2 = PROCESS_PER_MONITOR_DPI_AWARE
            if ctypes.windll.shcore.SetProcessDpiAwareness(2) == 0:
                out.update(applied=True, mode="per-monitor")
                return out
        except Exception:
            pass
        if ctypes.windll.user32.SetProcessDPIAware():
            out.update(applied=True, mode="system")
            return out
    except Exception as e:
        out["error"] = str(e)
    return out


def coordinate_preflight(win, rect) -> dict:
    """Measure the coordinate space once per run and refuse to guess.

    Stores the report on `/run_summary.coordinate_space`, journals the two
    actionable outcomes (a proven mismatch, and learned spots recorded under
    a different geometry), and raises the concrete fix instead of clicking
    scaled-wrong spots for a whole run.
    """
    metrics = _screen_metrics()
    try:
        shot = tuple(int(v) for v in pyautogui.size())
    except Exception:
        shot = None
    report = coordinate_space_report(
        rect, screen=metrics.get("screen"), virtual=metrics.get("virtual"),
        dpi=metrics.get("dpi"), awareness=metrics.get("awareness"),
        shot=shot)
    stamp = geometry_stamp(rect, metrics, shot)
    report["stamp"] = stamp
    old = CAL_GEOM if CAL_GEOM else (DEV_MEM.get("_geom") or {})
    if isinstance(old, dict) and old and geometry_changed(old, stamp):
        report["stamp_changed"] = True
        record_event(
            "geometry_changed",
            "the display/window geometry differs from the one the learned "
            "spots and calibration were recorded under - they are "
            "fractions and still apply, but their accuracy is unproven "
            "here",
            recovered=None,
            extra={"was": old.get("screen"), "now": stamp.get("screen"),
                   "was_dpi": old.get("dpi"), "now_dpi": stamp.get("dpi"),
                   "was_rect": old.get("rect"),
                   "now_rect": stamp.get("rect")})
        log(f"coordinate space changed since the learned spots were "
            f"recorded (screen {old.get('screen')}->{stamp.get('screen')}, "
            f"dpi {old.get('dpi')}->{stamp.get('dpi')}); they still "
            f"apply, but re-teach the calibration if clicks drift")
    RUN["coordinate_space"] = report
    log(f"COORD SPACE: ok={report['ok']} drift={report['drift']} "
        f"dpi={report.get('dpi')} aware={report.get('awareness')} "
        f"shot={report.get('shot')} screen={report.get('screen')} "
        f"signals={report['signals']} - {report['message']}")
    if not report["ok"]:
        record_event(
            "coordinate_mismatch",
            f"{report['message']}; {report['action']}",
            recovered=False,
            extra={"signals": report["signals"], "drift": report["drift"]})
        raise RuntimeError(
            f"coordinate space is not usable: {report['message']}. "
            f"{report['action']}. Run blocked before any click.")
    return report


# WINDOW FOCUS SAFETY --------------------------------------------------
# Packet Tracer's device terminal is a pixel-rendered surface.  UIA can
# still return a stale device object while another application is covering
# it, so a successful UIA lookup is not proof that the next keystroke will
# reach IOS.  The run that motivated this guard had the Codex window in front
# of Packet Tracer while the sidecar believed it was reading a router CLI.
#
# Keep the check at the process boundary, not only by title: an open device
# window may be titled ``HQ_Router`` while the owning process is
# ``PacketTracer.exe``.  If Windows cannot prove the foreground process, the
# input path fails closed and records an actionable event.
_PT_PROCESS_NAMES = {"packettracer.exe", "packettracer"}


def _ui_window_handle(win) -> int:
    """Return a UIA/Win32 handle without making UI calls."""
    try:
        value = getattr(getattr(win, "element_info", None), "handle", None)
        return int(value or 0)
    except Exception:
        return 0


def _win32_window_title(hwnd: int) -> str:
    if os.name != "nt" or not hwnd:
        return ""
    try:
        import ctypes
        user32 = ctypes.windll.user32
        length = int(user32.GetWindowTextLengthW(hwnd))
        buf = ctypes.create_unicode_buffer(max(1, length + 1))
        user32.GetWindowTextW(hwnd, buf, len(buf))
        return buf.value or ""
    except Exception:
        return ""


def _win32_window_pid(hwnd: int):
    if os.name != "nt" or not hwnd:
        return None
    try:
        import ctypes
        user32 = ctypes.windll.user32
        pid = ctypes.c_ulong(0)
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        return int(pid.value) or None
    except Exception:
        return None


def _win32_process_path(pid) -> str:
    if os.name != "nt" or not pid:
        return ""
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        # PROCESS_QUERY_LIMITED_INFORMATION works for normal desktop apps
        # without requiring administrator rights.
        handle = kernel32.OpenProcess(0x1000, False, int(pid))
        if not handle:
            return ""
        try:
            size = ctypes.c_ulong(32768)
            buf = ctypes.create_unicode_buffer(size.value)
            ok = kernel32.QueryFullProcessImageNameW(
                handle, 0, buf, ctypes.byref(size))
            return buf.value if ok else ""
        finally:
            kernel32.CloseHandle(handle)
    except Exception:
        return ""


def _looks_like_packet_tracer(title: str, process_path: str) -> bool:
    title_low = str(title or "").lower()
    name = os.path.basename(str(process_path or "")).lower()
    return (name in _PT_PROCESS_NAMES
            or "packettracer" in name
            or "packet tracer" in title_low)


def _foreground_window_info(expected_win=None) -> dict:
    """Describe the current foreground window and its PT relationship."""
    active = 0
    active_title = ""
    active_pid = None
    if os.name == "nt":
        try:
            import ctypes
            active = int(ctypes.windll.user32.GetForegroundWindow() or 0)
        except Exception:
            active = 0
    if active:
        active_title = _win32_window_title(active)
        active_pid = _win32_window_pid(active)
    expected_handle = _ui_window_handle(expected_win)
    expected_pid = _win32_window_pid(expected_handle)
    active_path = _win32_process_path(active_pid)
    expected_path = _win32_process_path(expected_pid)
    is_pt = _looks_like_packet_tracer(active_title, active_path)
    # A device dialog can have no useful title. If both handles are known,
    # same-process ownership is stronger evidence than the dialog title; the
    # expected handle came from the Packet Tracer window scan, so this also
    # works when Windows denies the process-path query.
    if (not is_pt and active_pid and expected_pid
            and active_pid == expected_pid):
        is_pt = True
    # Keep a title-only fallback for environments where Windows refuses the
    # process-path query, but never treat an unrelated active title as PT.
    if not is_pt and "packet tracer" in active_title.lower():
        is_pt = True
    return {
        "active_handle": active,
        "active_title": active_title,
        "active_pid": active_pid,
        "active_path": active_path,
        "expected_handle": expected_handle,
        "expected_pid": expected_pid,
        "expected_path": expected_path,
        "is_packet_tracer": bool(is_pt),
    }


def _window_is_maximized(win) -> bool:
    """Return whether the top-level PT window is actually maximized."""
    if os.name == "nt":
        hwnd = _ui_window_handle(win)
        if hwnd:
            try:
                import ctypes
                root = int(ctypes.windll.user32.GetAncestor(hwnd, 2) or hwnd)
                return bool(ctypes.windll.user32.IsZoomed(root))
            except Exception:
                pass
    try:
        return bool(win.is_maximized())
    except Exception:
        return False


def _activate_window_handle(win, maximize: bool = False) -> bool:
    """Best-effort Win32 activation for a PT window after UIA focus.

    ``SW_RESTORE`` is deliberately used only for minimized windows.  Calling
    it unconditionally on an already-maximized Packet Tracer window changes
    the user's layout to a normal window, which was the source of the recent
    shrinking regression.
    """
    if os.name != "nt":
        return False
    hwnd = _ui_window_handle(win)
    if not hwnd:
        return False
    try:
        import ctypes
        user32 = ctypes.windll.user32
        # GA_ROOT is 2.  A device surface can be a child/top-level dialog;
        # activating both handles covers both Packet Tracer layouts.
        root = int(user32.GetAncestor(hwnd, 2) or hwnd)
        for candidate in (root, hwnd):
            if user32.IsIconic(candidate):
                user32.ShowWindow(candidate, 9)  # SW_RESTORE, only minimized
            user32.SetForegroundWindow(candidate)
        if maximize:
            user32.ShowWindow(root, 3)  # SW_MAXIMIZE; never restore first
            user32.SetForegroundWindow(root)
        return True
    except Exception:
        return False


def _win32_root_handle(hwnd: int) -> int:
    """Top-level (GA_ROOT) ancestor of a window handle, or the handle.

    A device surface can be a child window, in which case Windows reports
    the root as the foreground window.  Comparing roots is how the focus
    fast path recognises "this exact window already has the foreground".
    """
    if os.name != "nt" or not hwnd:
        return 0
    try:
        import ctypes
        return int(ctypes.windll.user32.GetAncestor(int(hwnd), 2) or hwnd)
    except Exception:
        return 0


def _focus_pt_window(win, dev: str = "", phase: str = "PT",
                     maximize: bool = False) -> bool:
    """Focus a PT window and prove the PT process owns the foreground.

    This is the only focus boundary trusted by keyboard paths.  It may bring
    Packet Tracer back in front when a user or another app covered it, but it
    never types if the foreground proof still fails.  Wrapped so the cost of
    that boundary is measured (focus_ms on /run_summary).
    """
    start = time.time()
    perf_inc("focus_calls")
    try:
        return _focus_pt_window_inner(win, dev, phase, maximize)
    finally:
        perf_add_ms("focus_ms", (time.time() - start) * 1000.0)


def _focus_pt_window_inner(win, dev: str = "", phase: str = "PT",
                           maximize: bool = False) -> bool:
    """Body of _focus_pt_window (split out only for the timing wrapper)."""
    if stopped():
        return False
    # A real Packet Tracer window must expose a native handle.  Do not let a
    # failed UIA lookup silently turn the old blind-typing bug back on.  The
    # explicit test-double escape is used only by deterministic service tests
    # that replace the native UI driver; production windows never carry it.
    if not _ui_window_handle(win):
        if not HAS_RPA or getattr(win, "_allow_unverified_focus_for_test",
                                  False):
            try:
                win.set_focus()
            except Exception:
                pass
            return True
        log(f"{dev or 'PT'}: {phase} blocked - no native Packet Tracer "
            "window handle was available")
        RUN["focus_blocks"] = RUN.get("focus_blocks", 0) + 1
        record_event(
            "pt_focus_blocked",
            "Packet Tracer native window handle was unavailable; keyboard "
            "and screenshot input were blocked",
            device=dev,
            recovered=False,
            extra={"phase": phase, "reason": "missing_native_handle"},
        )
        return False
    # Fast path: the terminal read that called us runs on EVERY config line,
    # and the slow path below pays a cross-process UIA set_focus() plus two
    # SetForegroundWindow calls just to end up asking the same question.
    # Skip that work only when the foreground window IS this window (or its
    # root) - i.e. the focus call could not have moved anything - and when
    # the caller did not ask for a maximize.  Anything else, including a
    # sibling PT window holding the foreground, still takes the full path,
    # so a blocked read fails closed exactly as before.
    info = None
    if not maximize:
        info = _foreground_window_info(win)
        active = info.get("active_handle")
        expected = info.get("expected_handle")
        if info.get("is_packet_tracer") and active and expected:
            # A root lookup that fails returns 0 for both handles, which
            # must never count as "same window", hence the != 0 guard.
            same_window = (
                active == expected
                or (_win32_root_handle(active)
                    == _win32_root_handle(expected) != 0))
            if same_window:
                perf_inc("focus_skips")
                return True
    # The read above doubles as this attempt's result, so the number of
    # foreground reads (and therefore of focus attempts) is exactly what it
    # was before the fast path existed: one on the normal path, two when the
    # window had to be re-focused and re-checked.
    last = info or {}
    for attempt in range(2):
        try:
            win.set_focus()
        except Exception as exc:
            log(f"{dev or 'PT'}: {phase} UIA focus warning: {exc}")
        try:
            _activate_window_handle(win, maximize=maximize)
        except TypeError:
            # Keep test doubles and older injected focus adapters compatible
            # with the optional maximize argument.
            _activate_window_handle(win)
        if attempt:
            _interruptible_sleep(0.2)
        if attempt or info is None:
            last = _foreground_window_info(win)
        if last.get("is_packet_tracer"):
            if attempt:
                log(f"{dev or 'PT'}: {phase} focus recovered on attempt "
                    f"{attempt + 1}")
            return True
    title = str(last.get("active_title") or "<unknown>")[:100]
    path = str(last.get("active_path") or "<unknown>")[:120]
    log(f"{dev or 'PT'}: {phase} blocked - Packet Tracer is not the "
        f"foreground process (active='{title}', process='{path}')")
    RUN["focus_blocks"] = RUN.get("focus_blocks", 0) + 1
    record_event(
        "pt_focus_blocked",
        "Packet Tracer was not foreground; keyboard and screenshot input "
        "were blocked",
        device=dev,
        recovered=False,
        extra={"phase": phase, "active_title": title,
               "active_process": path},
    )
    return False


def shot(name: str):
    try:
        os.makedirs(SHOTS, exist_ok=True)
        # device names flow into these filenames - sanitize them, but
        # KEEP the extension: _safe_stem turns 'after.png' into
        # 'after_png' (no extension), which made every PIL save fail
        # with 'unknown file extension' and blinded the visual gates.
        stem, dot, ext = str(name).rpartition(".")
        if dot and ext:
            name = _safe_stem(stem) + "." + _safe_stem(ext)
        else:
            name = _safe_stem(str(name)) + ".png"
        if HAS_RPA:
            # Encode in-process at a low compression level.  These are
            # evidence images (read back for pixel comparisons, or attached
            # to a diagnostics bundle) and PNG is lossless, so a lower level
            # changes speed only - never a decoded pixel.
            pyautogui.screenshot().save(os.path.join(SHOTS, name),
                                        compress_level=1)
            log(f"screenshot {name}")
    except Exception as e:
        log(f"screenshot failed: {e}")


def shot_path(name: str) -> str:
    return os.path.join(SHOTS, name)


def canvas_changed(path_a: str, path_b: str, threshold: float = 0.08) -> tuple:
    """Compare canvas regions of two screenshots.

    Returns (changed: bool, score: float). Score is mean abs pixel diff
    over a downsampled grayscale canvas crop. Calibrated Sep 2026 from a
    real run: 3 placed devices scored 0.18 on a 1920x1080 canvas (small
    icons on huge gray area), so threshold is 0.08. Empty->empty ~0.0-0.03.
    Guards the links stage: never cable an empty canvas.
    """
    try:
        from PIL import Image, ImageChops
    except Exception as e:
        log(f"PIL missing, skipping visual gate: {e}")
        return True, -1.0
    try:
        a = Image.open(path_a).convert("L")
        b = Image.open(path_b).convert("L")
        if a.size != b.size:
            b = b.resize(a.size)
        w, h = a.size
        # canvas crop: skip PT top menus + bottom palette
        box = (int(w * 0.05), int(h * 0.15), int(w * 0.95), int(h * 0.78))
        a = a.crop(box).resize((160, 90))
        b = b.crop(box).resize((160, 90))
        diff = ImageChops.difference(a, b)
        hist = diff.histogram()
        total = sum(i * c for i, c in enumerate(hist))
        score = total / max(1, (160 * 90))
        return score >= threshold, round(score, 2)
    except Exception as e:
        log(f"canvas diff failed: {e}")
        return True, -1.0


def _link_line_evidence(path: str, rect, project: str,
                        a: str, b: str) -> tuple[bool, dict]:
    """Prove that a dark cable line joins the two remembered device slots.

    Endpoint clicks and a generic canvas diff are not enough: the old run
    selected a port popup but still left the router links absent.  This
    samples the corridor between both endpoints in a fresh full-canvas shot.
    Missing/unreadable screenshots fail closed.
    """
    try:
        from PIL import Image
        img = Image.open(path).convert("RGB")
        W, H = img.size
        l, t, r, btm = rect
        afx, afy, _ = _spot(project, a, JOB.slot_of[a])
        bfx, bfy, _ = _spot(project, b, JOB.slot_of[b])
        x0, y0 = l + (r - l) * afx, t + (btm - t) * afy
        x1, y1 = l + (r - l) * bfx, t + (btm - t) * bfy
        dx, dy = x1 - x0, y1 - y0
        length = max(1.0, (dx * dx + dy * dy) ** 0.5)
        nx, ny = -dy / length, dx / length
        samples, hits = 0, 0
        # Avoid device icons/labels at both ends; cable pixels are normally
        # black while the PT canvas is mid-gray.
        for step in range(16, 85):
            frac = step / 100.0
            cx, cy = x0 + dx * frac, y0 + dy * frac
            found = False
            for off in range(-4, 5):
                x = int(round(cx + nx * off))
                y = int(round(cy + ny * off))
                if not (0 <= x < W and 0 <= y < H):
                    continue
                pr, pg, pb = img.getpixel((x, y))
                # Cables are black; also accept a very dark neutral line in
                # PT themes where the cable is rendered charcoal.
                if max(pr, pg, pb) < 115 or \
                        (max(pr, pg, pb) < 145 and
                         max(pr, pg, pb) - min(pr, pg, pb) < 18):
                    found = True
                    break
            samples += 1
            hits += int(found)
        needed = max(10, int(samples * 0.18))
        evidence = {"samples": samples, "dark_corridor_hits": hits,
                    "required_hits": needed, "path": os.path.basename(path)}
        return hits >= needed, evidence
    except Exception as e:
        log(f"link line evidence failed for {a}-{b}: {e}")
        return False, {"samples": 0, "dark_corridor_hits": 0,
                       "required_hits": 10, "path": os.path.basename(path)}


def focus_pt():
    log("preflight: locating Packet Tracer window")
    w = find_pt_window()
    log("preflight: Packet Tracer window located")
    try:
        if hasattr(w, "is_minimized") and w.is_minimized():
            w.restore()
    except Exception:
        pass
    try:
        w.maximize()
    except Exception as exc:
        log(f"preflight: maximize warning: {exc}")
    _interruptible_sleep(0.6)
    if not _focus_pt_window(w, phase="preflight", maximize=True):
        raise RuntimeError(
            "Packet Tracer could not be brought to the foreground; "
            "close or minimize the covering window and retry")
    # A foreground check alone cannot prove the window stayed maximized.
    # Retry the maximize operation once, then fail closed instead of starting
    # a run in a shrunken canvas with unreliable click coordinates.
    if not _window_is_maximized(w):
        log("preflight: Packet Tracer is foreground but not maximized; "
            "retrying maximize")
        try:
            w.maximize()
        except Exception:
            pass
        _activate_window_handle(w, maximize=True)
        _interruptible_sleep(0.4)
    if not _window_is_maximized(w):
        record_event(
            "pt_not_maximized",
            "Packet Tracer could not be kept maximized; run blocked before "
            "any topology or keyboard input",
            recovered=False,
        )
        raise RuntimeError("Packet Tracer must remain maximized during the run")
    RUN["fullscreen_verified"] = True
    log("preflight: Packet Tracer foreground and maximized verified")
    return w


def _fail_msg() -> str:
    return ("STOPPED by safety failsafe (mouse slammed to a screen corner). "
            "That IS the emergency stop working. Press Stop in the app to reset.")


def prove_movement(rect):
    """Visible square over the canvas. User MUST see this."""
    if not HAS_RPA:
        raise RuntimeError("RPA deps missing")
    pyautogui.FAILSAFE = True
    try:
        cx, cy = to_abs(rect, 0.5, 0.45)
        d = 120
        log(f"proof move: square around ({cx},{cy}) - WATCH THE MOUSE")
        points = ((cx - d, cy - d), (cx + d, cy - d),
                  (cx + d, cy + d), (cx - d, cy + d), (cx, cy))
        for x, y in points:
            if stopped():
                return
            pyautogui.moveTo(x, y, duration=0.15)
            if not _interruptible_sleep(0.05):
                return
        log("proof move done")
    except Exception as e:
        if "FailSafe" in type(e).__name__ or "fail" in str(e).lower():
            log(_fail_msg())
            raise RuntimeError("stopped by corner failsafe")
        raise


def click_frac(rect, fx, fy, what: str, clicks: int = 1, pause: float = 0.5):
    x, y = to_abs(rect, fx, fy)
    log(f"click {what} at ({x},{y})")
    try:
        _safe_click(x, y, clicks=clicks)
    except Exception as e:
        if "FailSafe" in type(e).__name__:
            log(_fail_msg())
            raise RuntimeError("stopped by corner failsafe")
        raise
    _interruptible_sleep(pause)


CLICK_GUARD_FX = 0.05      # the crop the land-check diff covers
CLICK_GUARD_THRESHOLD = 0.03


def click_frac_checked(rect, fx, fy, what: str, dev: str = "",
                       clicks: int = 1, pause: float = 0.5) -> dict:
    """`click_frac` plus an ADVISORY check that the click landed.

    Before/after diff of a small crop around the target, reusing the existing
    `_shot_region` + `canvas_changed` primitives.  It must never block:
    clicking an already-focused field legitimately changes nothing, so an
    unchanged crop is journalled as `click_unconfirmed` and retried once,
    then the caller continues exactly as before - the read-back still owns
    the verdict.  Returns {"changed", "score", "retried", "attempts"}.
    """
    fx0, fy0 = max(0.0, fx - CLICK_GUARD_FX), max(0.0, fy - CLICK_GUARD_FX)
    fx1, fy1 = min(1.0, fx + CLICK_GUARD_FX), min(1.0, fy + CLICK_GUARD_FX)
    before = _shot_region(rect, fx0, fy0, fx1, fy1, "_click_before.png")
    click_frac(rect, fx, fy, what, clicks=clicks, pause=pause)
    after = _shot_region(rect, fx0, fy0, fx1, fy1, "_click_after.png")
    if not before or not after:
        # No screenshot stack (or a template test double): nothing to judge,
        # so the click is exactly what it was before this check existed.
        return {"changed": True, "score": -1.0, "retried": False,
                "attempts": 1}
    changed, score = canvas_changed(before, after, CLICK_GUARD_THRESHOLD)
    attempts = 1
    if not changed:
        record_event(
            "click_unconfirmed",
            f"{what}: the target area did not change after the click - "
            "retrying once (advisory only, the read-back still decides)",
            device=dev, recovered=None,
            extra={"target": what, "score": score,
                   "rect": [round(fx, 4), round(fy, 4)]})
        log(f"click {what}: target area unchanged (diff {score}) - one "
            f"bounded retry")
        click_frac(rect, fx, fy, what, clicks=clicks, pause=pause)
        after = _shot_region(rect, fx0, fy0, fx1, fy1, "_click_after.png")
        changed, score = canvas_changed(before, after, CLICK_GUARD_THRESHOLD)
        attempts = 2
    return {"changed": bool(changed), "score": score,
            "retried": attempts > 1, "attempts": attempts}


# Common PT model names per type (tried via UIA before coordinate fallback).
ROUTER_MODELS = ["2911", "1941", "4331", "4321", "2901", "829", "1240",
                 "PT-Empty", "PT-Router", "ISR"]
SWITCH_MODELS = ["2960", "2960-24", "2950", "3560", "PT-Switch", "Switch-PT"]
PC_MODELS = ["PC-PT", "PC", "Laptop", "Server-PT"]
SERVER_MODELS = ["Server-PT", "Server", "PC", "Laptop"]
LAPTOP_MODELS = ["Laptop-PT", "Laptop"]
PRINTER_MODELS = ["Printer-PT", "Printer"]
PHONE_MODELS = ["7960", "7961", "7962", "IP Phone"]
TABLET_MODELS = ["Tablet-PT", "Tablet"]
SMARTPHONE_MODELS = ["Smartphone-PT", "Smartphone"]
TV_MODELS = ["TV-PT", "TV"]
FIREWALL_MODELS = ["5506", "5505", "ASA5505", "ASA", "Firewall-PT"]
AP_MODELS = ["AccessPoint-PT", "AccessPoint-PT-A", "AccessPoint-PT-N"]
WIRELESS_ROUTER_MODELS = ["Wireless Router-PT", "Wireless Router"]
WLC_MODELS = ["2504", "WLC-PT", "Wireless LAN Controller"]
CLOUD_MODELS = ["Cloud-PT", "Cloud"]
MODEM_MODELS = ["DSL Modem-PT", "Cable Modem-PT", "Modem-PT", "Modem"]
IOT_MODELS = ["Home Gateway-PT", "MCU-PT", "IoT Server-PT", "SBC-PT"]

# Palette path per device kind: the PT category group, the sub-list (empty
# when the category opens straight onto its model row, as Security does), the
# acceptable model names in priority order, the strip column used by the CAL
# fallback, and the taught category anchor for that group.  One table instead
# of the if/elif ladder it replaces, so a type the planner can emit is a type
# the executor can place.
DEVICE_PALETTE = {
    "router": (("Network Devices", "Network Device"),
               ("Routers", "Router"), ROUTER_MODELS, 5, "pal_router"),
    "switch": (("Network Devices", "Network Device"),
               ("Switches", "Switch"), SWITCH_MODELS, 1, "pal_switch"),
    "pc": (("End Devices", "End Device"), ("PC", "Computer"),
           PC_MODELS, 0, "pal_pc"),
    "server": (("End Devices", "End Device"), ("Server", "Server-PT"),
               SERVER_MODELS, 2, "pal_pc"),
    "laptop": (("End Devices", "End Device"), ("Laptop", "Laptop-PT"),
               LAPTOP_MODELS, 0, "pal_pc"),
    "printer": (("End Devices", "End Device"), ("Printer",), PRINTER_MODELS,
                0, "pal_pc"),
    "phone": (("End Devices", "End Device"),
              ("IP Phone", "IPPhones", "Phone"), PHONE_MODELS, 0, "pal_pc"),
    "tablet": (("End Devices", "End Device"), ("Tablet",), TABLET_MODELS,
               0, "pal_pc"),
    "smartphone": (("End Devices", "End Device"),
                   ("Smartphone", "Smart Phone"), SMARTPHONE_MODELS, 0,
                   "pal_pc"),
    "tv": (("End Devices", "End Device"), ("TV", "Television"), TV_MODELS,
           0, "pal_pc"),
    "firewall": (("Security", "Firewalls", "Firewall"), (),
                 FIREWALL_MODELS, 0, "pal_security"),
    "wireless": (("Network Devices", "Network Device"),
                 ("Wireless Devices", "Wireless"), AP_MODELS, 0,
                 "pal_wireless"),
    "wireless-router": (("Network Devices", "Network Device"),
                        ("Wireless Devices", "Wireless"),
                        WIRELESS_ROUTER_MODELS, 1, "pal_wireless"),
    "wlc": (("Network Devices", "Network Device"),
            ("Wireless Devices", "Wireless"), WLC_MODELS, 2,
            "pal_wireless"),
    "cloud": (("Network Devices", "Network Device"),
              ("WAN Emulation", "WAN", "WanEmulation"), CLOUD_MODELS, 0,
              "pal_wan"),
    "modem": (("Network Devices", "Network Device"),
              ("WAN Emulation", "WAN", "WanEmulation"), MODEM_MODELS, 1,
              "pal_wan"),
    "iot": (("Network Devices", "Network Device"),
            ("IoT Devices", "IoT", "Home Gateway"), IOT_MODELS, 0,
            "pal_wireless"),
}


def ordered_models(requested: str, catalog: list) -> list:
    """Requested node model (from instruction) first, then catalog order."""
    req = (requested or "").strip()
    if req and req in catalog:
        return [req] + [m for m in catalog if m != req]
    if req:
        return [req] + catalog
    return catalog


def _shot_region(rect, fx0, fy0, fx1, fy1, name: str) -> str:
    """Screenshot one region of the PT window; returns path or ''."""
    try:
        l, t, r, b = rect
        W, H = r - l, b - t
        x0 = int(l + W * fx0)
        y0 = int(t + H * fy0)
        x1 = int(l + W * fx1)
        y1 = int(t + H * fy1)
        # pyautogui's region is (left, top, width, height), not
        # (left, top, right, bottom). Passing the latter made a small slot
        # crop balloon into a palette/PDU crop on Windows, so the reuse gate
        # blocked valid PCs and servers after a few placements.
        img = pyautogui.screenshot(
            region=(x0, y0, max(1, x1 - x0), max(1, y1 - y0)))
        os.makedirs(SHOTS, exist_ok=True)
        p = os.path.join(SHOTS, name)
        # Lossless PNG, cheaper compression: these crops are compared by
        # pixel, so only the encode cost changes.
        img.save(p, compress_level=1)
        return p
    except Exception as e:
        log(f"region shot failed: {e}")
        return ""


def _slot_occupied(img_path: str) -> tuple[bool, int]:
    """Fast icon-presence check for a remembered canvas slot.

    Packet Tracer's empty canvas is almost uniform gray. Device icons and
    cable endpoints contain saturated pixels, so this cheap check is safer
    and much faster than opening a device just to discover that the slot is
    empty. It intentionally reports only occupancy; OCR below decides
    whether the occupied slot is the expected model.
    """
    try:
        from PIL import Image
        img = Image.open(img_path).convert("RGB")
        w, h = img.size
        # Keep the icon area and exclude most of the text labels underneath.
        box = (int(w * 0.10), int(h * 0.04),
               int(w * 0.90), int(h * 0.76))
        px = img.crop(box).getdata()
        colorful = sum(1 for r, g, b in px
                       if max(r, g, b) - min(r, g, b) > 22
                       and max(r, g, b) > 90)
        return colorful >= 20, colorful
    except Exception as e:
        log(f"slot occupancy check failed: {e}")
        return False, 0


def _slot_ocr(img_path: str) -> str:
    """OCR one small slot crop; empty/failed OCR is never treated as proof."""
    if not TESSERACT_CMD:
        return ""
    try:
        from PIL import Image, ImageOps
        img = Image.open(img_path).convert("L")
        # Upscale the tiny model/name labels so the existing OCR engine can
        # recognize them without scanning the whole Packet Tracer window.
        img = ImageOps.autocontrast(img.resize((img.width * 4, img.height * 4)))
        tmp = os.path.join(SHOTS, "_reuse_ocr.png")
        img.save(tmp)
        out = _run_hidden(
            [TESSERACT_CMD, tmp, "stdout", "--psm", "6"],
            capture_output=True, text=True, timeout=3)
        return (out.stdout or "").strip()
    except Exception as e:
        log(f"slot OCR failed: {e}")
        return ""


def _slot_expected_tokens(dtype: str, model: str) -> list[str]:
    dtype = (dtype or "").lower()
    model = (model or "").lower()
    tokens = []
    if model:
        normalized = re.sub(r"[^a-z0-9]", "", model)
        if normalized:
            tokens.append(normalized)
            # PT sometimes OCRs a model suffix imperfectly. A numeric model
            # prefix such as 2960 is still useful, but only when requested.
            tokens.extend(re.findall(r"\d{3,}", model))
            if normalized in ("pcpt", "serverpt"):
                tokens.append(normalized[:-2])
    if not model:
        tokens.extend({
            "router": ["router", "isr"],
            "switch": ["switch"],
            "pc": ["pc", "computer", "laptop"],
            "server": ["server"],
        }.get(dtype, [dtype] if dtype else []))
    return list(dict.fromkeys(tokens))


def _slot_visual_state(rect, fx: float, fy: float, name: str,
                       dtype: str, model: str) -> tuple[str, str]:
    """Return empty/match/occupied_unknown for a planned canvas slot.

    A remembered coordinate is not enough: the screen is the authority.
    ``match`` requires a visible device plus the requested model text (or
    type when no model was specified). Unknown occupied slots are blocked so
    the caller never stacks a new device on top of an existing one.
    """
    safe = _safe_stem(name)
    # PCs and servers share the End Devices row. Keep their vertical crop
    # tight so a nearby icon/label cannot make an empty slot look occupied.
    same_row = (dtype or "").lower() in ("pc", "server")
    pad_x = 0.065 if same_row else 0.075
    pad_y = 0.045 if same_row else 0.065
    p = _shot_region(rect, max(0.0, fx - pad_x), max(0.0, fy - pad_y),
                     min(1.0, fx + pad_x), min(1.0, fy + pad_y),
                     f"reuse_{safe}.png")
    if not p:
        return "unknown", ""
    occupied, pixels = _slot_occupied(p)
    if not occupied:
        return "empty", ""
    text = _slot_ocr(p)
    flat = re.sub(r"[^a-z0-9]", "", text.lower())
    tokens = _slot_expected_tokens(dtype, model)
    matched = bool(tokens) and any(token in flat for token in tokens)
    if matched:
        log(f"{name}: remembered slot contains expected device "
            f"(visual={pixels}, OCR={text[:80]!r})")
        return "match", text
    log(f"{name}: occupied slot could not be matched safely "
        f"(visual={pixels}, OCR={text[:80]!r})")
    return "occupied_unknown", text


def _strip_clusters(img_path: str, y0=0.865, y1=0.945, x0=0.02, x1=0.5,
                    thr=28.0, min_gap_px=3) -> list:
    """Find bright icon clusters in the model-thumbnail strip.

    Returns [(fx, fy)] centers as fractions of the FULL SCREENSHOT.
    The palette background is dark; thumbnails + labels are bright, so a
    column-brightness profile peaks at each model cell.
    """
    try:
        from PIL import Image
        img = Image.open(img_path).convert("L")
    except Exception:
        return []
    W, H = img.size
    band = img.crop((int(W * x0), int(H * y0), int(W * x1), int(H * y1)))
    bw, bh = band.size
    if bw < 40 or bh < 8:
        return []
    px = band.load()
    col = [sum(px[x, y] for y in range(0, bh, 2)) / max(1, len(range(0, bh, 2)))
           for x in range(bw)]
    base = sorted(col)[len(col) // 4]  # 25th pct = background level
    hot = [i for i, v in enumerate(col) if v - base > thr]
    clusters = []
    if hot:
        start = prev = hot[0]
        for c in hot[1:] + [10 ** 9]:
            if c - prev <= min_gap_px:
                prev = c
                continue
            clusters.append(x0 + ((start + prev) / 2) / bw * (x1 - x0))
            start = prev = c
    # merge clusters closer than ~half a thumbnail pitch (label text can
    # split one cell into two runs)
    merged = []
    for fx in clusters:
        if merged and fx - merged[-1] < 0.009:
            merged[-1] = (merged[-1] + fx) / 2
        else:
            merged.append(fx)
    return [(round(fx, 4), round((y0 + y1) / 2, 4)) for fx in merged]


def _model_armed(img_path: str, fx: float, fy: float) -> bool:
    """True if the thumbnail cell near (fx, fy) shows PT's blue highlight.

    A selected model in PT gets a blue halo: bluish pixels where blue
    clearly dominates red/green. Absence of proof is NOT failure - the
    caller only self-tunes when a clear 'not armed' is detected.
    """
    try:
        from PIL import Image
        img = Image.open(img_path)
    except Exception:
        return True  # can't verify -> assume ok (fail-safe)
    W, H = img.size
    box = (int(W * max(0.0, fx - 0.011)), int(H * max(0.0, fy - 0.024)),
           int(W * min(1.0, fx + 0.011)), int(H * min(1.0, fy + 0.012)))
    cell = img.crop(box).convert("RGB")
    n = 0
    for r, g, b in cell.getdata():
        if b > 90 and b - max(r, g) > 25:
            n += 1
    return n >= 30


def click_model(rect, names: list, col_idx: int, what: str) -> bool:
    """Pick an actual device MODEL (the step v1-v3 skipped).

    1) Try UIA name match (exact PT model button).
    2) Fallback: click taught CAL thumbnail.
    3) SELF-TUNE: verify the blue highlight; if the taught spot missed,
       scan the strip for real thumbnails, click the right one, and
       re-calibrate cal.json so future runs don't repeat the mistake.
    """
    if click_by_names(names, f"{what} MODEL by name", timeout_s=2.5):
        log(f"{what} model armed by NAME - must show blue highlight in PT")
        return True
    fx = CAL["model_col0"] + CAL["model_col_step"] * col_idx
    fy = CAL["model_row"]
    click_frac(rect, fx, fy, f"{what} MODEL thumbnail (must highlight blue!)",
               clicks=2, pause=0.6)
    # self-tune verification (best effort - never aborts placement)
    try:
        want = names[0] if names else ""
        p = _shot_region(rect, 0.02, 0.84, 0.55, 0.97, "model_arm.png")
        if p and not _model_armed(p, fx, fy):
            clusters = _strip_clusters(p)
            log(f"{what}: taught model spot NOT highlighted; strip scan "
                f"found {len(clusters)} thumbnail(s)")
            if len(clusters) >= 2:
                target = clusters[min(col_idx, len(clusters) - 1)]
                click_frac(rect, target[0], target[1],
                           f"{what} MODEL re-click at scanned spot "
                           f"(want {want})", clicks=2, pause=0.8)
                p2 = _shot_region(rect, 0.02, 0.84, 0.55, 0.97,
                                  "model_arm2.png")
                armed = bool(p2) and _model_armed(p2, target[0], target[1])
                # re-calibrate the strip for future runs
                old = (CAL["model_col0"], CAL["model_col_step"])
                CAL["model_col0"] = clusters[0][0]
                gaps = [round(b[0] - a[0], 4)
                        for a, b in zip(clusters, clusters[1:])]
                if gaps:
                    CAL["model_col_step"] = sorted(gaps)[len(gaps) // 2]
                save_cal()
                RUN["model_autotunes"] = RUN.get("model_autotunes", 0) + 1
                record_event("model_autotuned",
                             f"re-aimed model click ({old} -> "
                             f"({CAL['model_col0']}, {CAL['model_col_step']}))",
                             device=want, recovered=armed)
                log(f"model strip re-calibrated: col0={CAL['model_col0']} "
                    f"step={CAL['model_col_step']} armed={armed}")
    except Exception as e:
        log(f"model self-tune skipped: {e}")
    return True


def place_nodes(rect, nodes, project: str = "default"):
    """PT 9.0 placement: category -> wait for model list -> model -> canvas x2.

    Devices are laid out as a type-row grid (routers / switches / end
    devices), centered per row - NOT one line (that stretched the
    canvas). Remembers each device canvas spot per project
    (device_memory.json) and reuses it next run. Recalled spots are reused
    only after a small visual + OCR check confirms the expected device.
    Occupied-but-uncertain slots are blocked rather than duplicated.
    """
    layout = _layout_spot(nodes)
    for i, n in enumerate(nodes):
        if stopped():
            log("stop requested, aborting placement")
            return
        ntype = (n.get("type") or "").lower()
        name = n.get("name", f"dev{i}")
        model = str(n.get("model") or "")
        mem = recall_device(project, name)
        if mem:
            gx, gy = float(mem["fx"]), float(mem["fy"])
        else:
            gx, gy = layout.get(i, (CAL["grid_x0"], CAL["grid_y"]))

        # Never use memory blindly and never drop a new icon onto occupied
        # canvas coordinates. This check is deliberately done before the
        # expensive palette/model clicks, which is where repeat runs used to
        # spend most of their time.
        state, ocr = _slot_visual_state(rect, gx, gy, name, ntype, model)
        if state in ("unknown", "occupied_unknown"):
            # OCR and the canvas can be mid-refresh immediately after a
            # device window closes. Re-read twice before declaring a hard
            # safety block; a fresh read often turns a transient miss into
            # an empty or matching slot without adding another device.
            for reread in (1, 2):
                _interruptible_sleep(0.25)
                retry_state, retry_ocr = _slot_visual_state(
                    rect, gx, gy, name, ntype, model)
                if retry_state not in ("unknown", "occupied_unknown"):
                    state, ocr = retry_state, retry_ocr
                    log(f"{name}: slot re-read {reread} resolved the "
                        f"transient visual state as {state}")
                    break
                state, ocr = retry_state, retry_ocr
        if state == "match":
            remember_device(project, name, gx, gy, ntype, model, True)
            RUN["devices_reused"] = RUN.get("devices_reused", 0) + 1
            RUN["node_outcomes"][name] = "reused"
            log(f"REUSED verified {name} at ({gx:.3f},{gy:.3f}) - "
                "skipping palette/model placement")
            record_event("device_reused", "verified device already on canvas; "
                         "placement skipped", device=name, recovered=True,
                         extra={"model": model, "ocr": ocr[:80]})
            continue
        if state != "empty":
            RUN["devices_reuse_blocked"] = \
                RUN.get("devices_reuse_blocked", 0) + 1
            RUN["node_outcomes"][name] = "blocked"
            detail = ("screen read failed at planned slot" if state == "unknown"
                      else "occupied slot did not match expected device")
            log(f"BLOCKED {name}: {detail}; refusing to add another device")
            record_event("device_reuse_blocked", detail, device=name,
                         recovered=False, extra={"model": model,
                                                 "ocr": ocr[:80]})
            continue

        # 1) Try UIA name clicks first (exact PT buttons, no guessing).
        # 2) Fall back to taught CAL coordinates only if names not found.
        # 3-step PT flow: GROUP -> TYPE -> MODEL. v4 bug was stopping
        # after TYPE (category highlighted, no model armed).  Which group,
        # which sub-list and which model names belong to a kind is the
        # DEVICE_PALETTE table, so every kind the planner can emit has a
        # placement path (Server-PT lives next to the PCs; an ASA lives under
        # Security; an AP/phone/cloud has its own port vocabulary but its
        # palette path is still an ordinary name click).
        spec = DEVICE_PALETTE.get(ntype)
        if spec is None:
            # An unknown type must not silently place a ROUTER and call the
            # device done: use the router path (visible in the log) and let
            # the placement check below judge it.
            log(f"{name}: unknown device type '{ntype}' - using the router "
                "palette; the slot check will decide")
            spec = DEVICE_PALETTE["router"]
        group, only, models, col, pal_key = spec
        if not click_by_names(list(group), f"group for {name}"):
            click_frac(rect, *CAL.get(pal_key, CAL["pal_router"]),
                       f"1/3 category {ntype} for {name}", pause=1.0)
        if only and not click_by_names(list(only),
                                       f"{ntype} type for {name}"):
            log(f"{ntype} TYPE by name missed, CAL model fallback")
        click_model(rect, ordered_models(n.get("model", ""), models),
                    col, f"{ntype} {name} (want {n.get('model', '')})")
        # canvas needs TWO clicks in PT (arm placement, then drop).
        # Per-device gate: diff a tight region around the slot before
        # vs after the drop. A silent miss (wrong model armed, dead
        # click) used to be REMEMBERED as placed, and every later stage
        # then flailed at an empty spot (ghost links, missed windows).
        slot_before = _shot_region(rect, max(0.0, gx - 0.06),
                                   max(0.0, gy - 0.06),
                                   min(1.0, gx + 0.06),
                                   min(1.0, gy + 0.06),
                                   f"slot{i}_before.png")
        click_frac(rect, gx, gy, f"3/3 canvas slot for {name} (click 1 arm)",
                   pause=0.5)
        click_frac(rect, gx, gy, f"3/3 canvas slot for {name} (click 2 drop)",
                   pause=0.8)
        # escape placement mode before next device
        _press_esc()
        _interruptible_sleep(0.4)
        slot_after = _shot_region(rect, max(0.0, gx - 0.06),
                                  max(0.0, gy - 0.06),
                                  min(1.0, gx + 0.06),
                                  min(1.0, gy + 0.06),
                                  f"slot{i}_after.png")
        verified = False
        if slot_before and slot_after:
            changed, score = canvas_changed(slot_before, slot_after,
                                            threshold=0.004)
            if changed:
                verified = True
                log(f"placement VERIFIED for {name} (slot diff {score})")
            else:
                log(f"WARN {name}: slot looks UNCHANGED after drop "
                    f"(diff {score}) - model may not be armed; "
                    f"continuing, links/CLI will confirm")
                record_event("placement_unverified",
                             f"slot diff {score} after drop - device may "
                             f"be missing", device=name, recovered=False,
                             extra={"expected": f"{ntype} {model}".strip(),
                                    "observed": f"slot diff {score}",
                                    "fx": gx, "fy": gy})
        RUN["devices_placed"] = RUN.get("devices_placed", 0) + 1
        RUN["node_outcomes"][name] = "placed" if verified else "uncertain"
        shot(f"placed_{name}.png")
        remember_device(project, name, gx, gy, ntype, model, verified)
        log(f"placed {name} slot {i} at ({gx:.3f},{gy:.3f}) - "
            f"remembered ({'verified' if verified else 'uncertain'} for next time)")


def _spot(project: str, name: str, slot: int):
    """Remembered device spot preferred, grid fallback."""
    mem = recall_device(project, name)
    if mem:
        return float(mem["fx"]), float(mem["fy"]), True
    return (CAL["grid_x0"] + CAL["grid_step"] * slot, CAL["grid_y"], False)


# Non-Cisco PT devices do not name their ports like a router: an
# AccessPoint-PT and an IP Phone 7960 have "Port 1"/"Port 2", a Cloud-PT has
# "Ethernet1"/"Coaxial1"/"Modem1", a home gateway has "Internet".  The plan
# uses short specs for these ('port1', 'ethernet1'), and they are matched
# case-insensitively as SUBSTRINGS like every other name, so each spelling
# PT may print is listed rather than a bare 'port' (which would happily
# match 'Port 2' and cable the wrong interface).
PORT_NAME_VOCAB = {
    "port0": ("Port 0", "Port0"),
    "port1": ("Port 1", "Port1"),
    "port2": ("Port 2", "Port2"),
    "port3": ("Port 3", "Port3"),
    "port4": ("Port 4", "Port4"),
    "ethernet1": ("Ethernet1", "Ethernet 1"),
    "ethernet2": ("Ethernet2", "Ethernet 2"),
    "ethernet3": ("Ethernet3", "Ethernet 3"),
    "ethernet4": ("Ethernet4", "Ethernet 4"),
    "coaxial1": ("Coaxial1", "Coaxial 1"),
    "coaxial2": ("Coaxial2", "Coaxial 2"),
    "modem1": ("Modem1", "Modem 1"),
    "internet": ("Internet",),
    "console": ("Console",),
}


def iface_port_wants(spec: str) -> list:
    """Map intent iface ('g0/0', 'f0/1', 'eth0') to PT popup names.

    PT popups show full names ('GigabitEthernet0/0'). Try exact long form,
    then cross form (2911 has no FastEthernet). Proximity-guarded by the
    caller, so stray matches can't count.
    """
    s = (spec or "").strip().lower().replace(" ", "")
    named = PORT_NAME_VOCAB.get(s)
    if named:
        return list(named)
    if not s:
        return ["GigabitEthernet", "FastEthernet"]
    m = None
    for pre in ("gigabitethernet", "fastethernet", "serial", "ethernet",
                "g", "f", "s", "e"):
        if s.startswith(pre):
            m = s[len(pre):]
            kind = pre
            break
    else:
        kind, m = "", s
    if not m:
        return ["GigabitEthernet", "FastEthernet"]
    long_kind = {"g": "GigabitEthernet", "f": "FastEthernet",
                 "s": "Serial", "e": "Ethernet"}.get(kind, kind)
    wants = []
    if long_kind:
        wants.append(f"{long_kind}{m}")
    # cross-form fallback: g0/0 intent on Fa-only device and vice versa
    for alt in ("GigabitEthernet", "FastEthernet", "Serial"):
        cand = f"{alt}{m}"
        if cand not in wants:
            wants.append(cand)
    # NOTE: no bare-number fallback (e.g. '0'): substring matching made
    # it hit unrelated controls - the port picker once 'picked' PT's
    # status-bar clock ('Time: 01:12:49') as a device port. The OCR
    # popup reader remains as the fallback for odd labels.
    return wants


# CABLE SELECTION -------------------------------------------------------
# Packet Tracer's Connections palette is where the cable TYPE is chosen, and
# the type is not cosmetic: a serial WAN link cannot be made with copper at
# all (PT refuses serial-port-to-serial-port on a copper cable), and a serial
# cable additionally carries the clocking role - the palette entry names the
# end that supplies the clock (DCE), and the OTHER end must be the DTE.
#
# Until now every link was wired with `select_copper()`, so a plan that asked
# for Serial0/0/0 was either remapped to a spare GigabitEthernet port or left
# unwired - the cable kind was never a decision the run made.  These are the
# palette entries the app can choose from, with the names PT prints.
CABLE_COPPER = "copper"
CABLE_COPPER_CROSS = "copper-cross"
CABLE_SERIAL_DCE = "serial-dce"
CABLE_SERIAL_DTE = "serial-dte"
CABLE_FIBER = "fiber"
CABLE_CONSOLE = "console"

# kind -> (printed palette names to click, CAL column fallback)
CABLE_PALETTE = {
    CABLE_COPPER: (("Copper Straight", "Copper Straight-Through", "Copper"),
                   "conn_copper_col"),
    CABLE_COPPER_CROSS: (("Copper Cross", "Copper Cross-Over",
                          "Copper Crossover"), "conn_copper_cross_col"),
    CABLE_SERIAL_DCE: (("Serial DCE",), "conn_serial_dce_col"),
    CABLE_SERIAL_DTE: (("Serial DTE",), "conn_serial_dte_col"),
    CABLE_FIBER: (("Fiber",), "conn_fiber_col"),
    CABLE_CONSOLE: (("Console",), "conn_console_col"),
}
# Plan hints that name a cable.  'serial' means "a serial cable, pick the
# DCE end deterministically" - the executor decides which half of the pair.
CABLE_ALIASES = {
    "serial": CABLE_SERIAL_DCE,
    "serial-dce": CABLE_SERIAL_DCE,
    "dce": CABLE_SERIAL_DCE,
    "serial-dte": CABLE_SERIAL_DTE,
    "dte": CABLE_SERIAL_DTE,
    "copper": CABLE_COPPER,
    "straight": CABLE_COPPER,
    "straight-through": CABLE_COPPER,
    "crossover": CABLE_COPPER_CROSS,
    "cross-over": CABLE_COPPER_CROSS,
    "cross": CABLE_COPPER_CROSS,
    "fiber": CABLE_FIBER,
    "console": CABLE_CONSOLE,
}


def select_copper() -> bool:
    """Back-compat wrapper: the copper straight-through cable."""
    return select_cable(CABLE_COPPER)


def select_cable(kind: str = CABLE_COPPER) -> bool:
    """Pick one cable from PT's Connections palette.

    Name clicks first (the palette entries carry printed names), the taught
    CAL column as the fallback - the same order the model list uses.  The
    palette column is the only place a cable can be chosen, so this runs
    before EVERY link attempt (PT disarms the tool after each cable).
    """
    kind = (kind or CABLE_COPPER).strip().lower()
    names, cal_key = CABLE_PALETTE.get(kind, CABLE_PALETTE[CABLE_COPPER])
    if (click_by_names(["Connections"], "connections group") and
            click_by_names(list(names), f"{kind} cable")):
        return True
    try:
        w = find_pt_window()
        rect = rect_of(w)
    except Exception as exc:
        log(f"cable '{kind}': palette unavailable ({exc})")
        return False
    click_frac(rect, *CAL["pal_conn"], "palette connections")
    click_frac(rect, CAL.get(cal_key, CAL["conn_copper_col"]),
               CAL["model_row"], f"cable {kind} (CAL column)")
    return True


def cable_kind_for_link(link: dict, dce_end: str = "a") -> str:
    """The cable a link needs, from its EFFECTIVE interfaces.

    The interfaces decide, not a hint: a link that survived the WAN
    preflight on Serial0/0/0 needs a serial cable, while the same link
    remapped to a spare GigabitEthernet port needs copper - wiring a serial
    cable onto a remapped copper link would fail exactly like the copper
    cable onto a serial port did.  The plan's `cable` hint only refines the
    choice where the interfaces cannot (fiber/console/crossover).

    For serial links the palette entry names the role PT gives the
    FIRST-clicked port, and this run always clicks endpoint 'a' first: so
    the cable is "Serial DCE" when 'a' is the clocking end and "Serial DTE"
    when the clock belongs to 'b' (the DCE half then lands on 'b').
    """
    hint = CABLE_ALIASES.get(
        str(link.get("cable") or "").strip().lower(), "")
    if _iface_is_serial(link.get("aIf")) or _iface_is_serial(link.get("bIf")):
        if hint == CABLE_SERIAL_DTE:
            return CABLE_SERIAL_DTE
        return CABLE_SERIAL_DCE if dce_end == "a" else CABLE_SERIAL_DTE
    if hint and hint not in (CABLE_SERIAL_DCE, CABLE_SERIAL_DTE):
        return hint
    return CABLE_COPPER


def _iface_is_serial(spec) -> bool:
    """True for 's0/0/0' / 'serial0/0/0' spellings."""
    s = str(spec or "").strip().lower().replace(" ", "")
    return s.startswith(("s0/", "s1/", "s2/", "s3/", "serial"))


def serial_dce_end(link: dict) -> str:
    """Which endpoint supplies the clock on a serial link ('a' or 'b').

    A serial cable has one DCE end and one DTE end; PT rejects DCE-DCE and
    DTE-DTE.  The DCE end is the one that will carry `clock rate` in its
    interface config, so this decision is shared with the config renderer:
    the plan may name it (`dce: "HQ_Router"` or `"a"`), otherwise the 'a'
    endpoint of the link is the clock source - deterministic, so the same
    plan always lands 'clock rate' on the same side.
    """
    hint = str(link.get("dce") or "").strip()
    if hint:
        low = hint.lower()
        if low in ("a", "b"):
            return low
        if low == str(link.get("a") or "").strip().lower():
            return "a"
        if low == str(link.get("b") or "").strip().lower():
            return "b"
    return "a"


def _pick_port_by_ocr(cx: int, cy: int, wants: list) -> bool:
    """Click the wanted port inside PT's port popup via OCR word boxes.

    Why: the popup is custom-drawn and invisible to UIA, so name clicks
    failed and cables silently landed on PT's default (first) port -
    that's how R1-R2 got cabled on g0/0 instead of the requested g0/1.
    Tesseract TSV gives word pixel positions, so we click the exact
    popup row for the requested port.
    """
    if not TESSERACT_CMD:
        return False
    try:
        _interruptible_sleep(0.7)  # popup render
        l, t = cx + 3, cy + 3
        sw, sh = pyautogui.size()
        w, h = min(320, sw - l - 4), min(400, sh - t - 4)
        if w < 80 or h < 40:
            return False
        from PIL import Image, ImageOps
        img = pyautogui.screenshot(region=(l, t, w, h)).convert("L")
        img = ImageOps.invert(img)
        os.makedirs(SHOTS, exist_ok=True)
        p = os.path.join(SHOTS, "_popup.png")
        img.save(p)
        out = _run_hidden(
            [TESSERACT_CMD, p, "stdout", "--psm", "6", "tsv"],
            capture_output=True, text=True, timeout=10)
        rows = []
        for line in (out.stdout or "").splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) >= 12 and parts[11].strip():
                try:
                    rows.append((parts[11].lower(), int(parts[6]),
                                 int(parts[7]), int(parts[8]), int(parts[9])))
                except Exception:
                    continue
        for want in wants:
            wn = want.lower().replace(" ", "")
            for txt, x, y, ww, hh in rows:
                if wn and wn in txt.replace(" ", ""):
                    _safe_click(l + x + ww // 2, t + y + hh // 2)
                    _interruptible_sleep(0.5)
                    log(f"port picked by OCR: '{txt}' at popup")
                    return True
        return False
    except Exception as e:
        log(f"port OCR pick failed: {e}")
        return False


def _link_endpoint(rect, dev, spec, j, which):
    """Click one cable endpoint, then pick the port: UIA name first,
    OCR popup fallback, hard Esc-cancel if both fail. True = port set.

    The UIA name pick is proximity-guarded to the endpoint click: PT's
    port popup always spawns adjacent to the clicked device, so a match
    anywhere else on screen (status bar, other dialogs) is a false
    positive and must NOT count.
    """
    fx, fy, _ = _spot(JOB.project, dev, JOB.slot_of[dev])
    x, y = to_abs(rect, fx, fy)
    click_frac(rect, fx, fy,
               f"link {j} endpoint {dev} ({which})", pause=0.7)
    if stopped():
        return False
    if click_by_names(iface_port_wants(spec),
                      f"link {j} PORT on {dev} ({spec})", timeout_s=2.5,
                      near=(x, y, 450)):
        log(f"link {j}: {dev} port {spec} picked (by name)")
        return True
    if _pick_port_by_ocr(x, y, iface_port_wants(spec)):
        log(f"link {j}: {dev} port {spec} picked (by OCR)")
        return True
    log(f"link {j}: NO port popup on {dev} - cancelling dangling cable")
    record_event("port_popup_missing",
                 f"port picker never appeared on {dev} ({spec})",
                 device=dev, recovered=False)
    _press_esc()
    _interruptible_sleep(0.4)
    return False


def _serial_fallback_candidate(available: set, used: set) -> tuple:
    """Choose a proven spare routed port when a requested serial port is absent.

    The default Packet Tracer 2911 has three GigabitEthernet ports but no
    serial HWIC.  A WAN cable cannot be made on a port that the live CLI did
    not report.  When a spare routed port is visible, a caller may use this
    recovery to keep a disposable lab functional, but the remap must remain
    visible and must fail exact-interface validation; it is never equivalent
    to the requested Serial0/0/0 topology.
    """
    candidates = (
        ("gigabitethernet0/1", "g0/1"),
        ("gigabitethernet0/2", "g0/2"),
        ("fastethernet0/1", "f0/1"),
        ("ethernet0/1", "e0/1"),
    )
    for full, short in candidates:
        if full in available and full not in used:
            return full, short
    return "", ""


# Bounded re-attempts for one interface capability probe (privileged-mode
# proof + live interface table read).  A probe that never proves either is
# recorded as unverified and scoped to the requesting link, never widened
# into a device-wide block.
_INTERFACE_PROBE_ROUNDS = 3

# Packet Tracer ships a 2911 with three GigabitEthernet ports and no serial
# module, but HWIC-2T IS available in the Physical tab's MODULES list.  Quoting
# the proven remedy next to every "serial interface absent" report turns a dead
# end into something a later run or the user can act on.  The remap below stays
# the fallback when the module is not installed.
SERIAL_MODULE_HINT = (
    "to get serial ports: power the router off in the Physical tab, add an HWIC-2T to an empty HWIC slot, power it back on, then re-run - s0/0/0 will exist and no remap is needed"
)

# SERIAL MODULE AUTO-INSTALL -------------------------------------------
# Packet Tracer's default ISR routers (2911/1941/2901/4331) ship with no serial
# port, and HWIC-2T is what gives them Serial0/0/0.  Until now a run could only
# *report* that remedy (SERIAL_MODULE_HINT) and then either remap the WAN onto a
# spare GigabitEthernet port or leave the link unwired.  The procedure is small
# and already written down - so it is now automated:
#
#   1. open the device window and click the Physical tab
#   2. power the device OFF          (PT refuses a module in a live device)
#   3. click the module in the MODULES list (HWIC-2T first)
#   4. click an empty HWIC slot
#   5. power the device back ON and let it boot
#
# Only step 3 has a printed name in PT's own font, so the module is clicked
# through the OCR word boxes; the power switch and the slots are chassis
# images and use CAL fractions (hw_power, hw_slot0..3), which are learnable
# like every other coordinate.  None of it is believed on its own: the run then
# re-reads the live `show ip interface brief`, and the install counts only when
# a serial port actually appears there.  A failed attempt is a journaled event
# naming the step it stopped at, on top of the hand remedy above.
SERIAL_MODULE_NAMES = ("HWIC-2T", "WIC-2T", "NIM-2T", "HWIC-4T", "NIM-4T")
SERIAL_MODULE_PREFERRED = SERIAL_MODULE_NAMES[0]
# How many timed re-reads of the interface table to allow after the module
# boot; PT needs roughly 15-30 s to come back with the new port.
_SERIAL_INSTALL_ROUNDS = 4
_SERIAL_BOOT_WAIT_S = 7.0
# NETBUILDER_SERIAL_MODULE=0 turns the automation off (the report-only path
# below then behaves exactly as it did before).
SERIAL_AUTO_MODULE = os.environ.get("NETBUILDER_SERIAL_MODULE", "1").strip() \
    .lower() not in ("0", "false", "no", "off")
# One attempt per (device, interface) per run: a device that failed to take a
# module must not be power-cycled again for every later command.
_SERIAL_INSTALL_TRIED: set = set()

# Which module/slot actually worked, per project+device.  Persisted so a later
# run clicks the slot that worked instead of walking the chassis again.
HW_MEM_FILE = os.path.join(os.path.dirname(__file__), "hardware_memory.json")
HW_MEM: dict = {}
try:
    if os.path.exists(HW_MEM_FILE):
        with open(HW_MEM_FILE) as f:
            HW_MEM = json.load(f)
except Exception as e:
    print(f"hardware_memory load failed: {e}")


def save_hw_mem():
    try:
        with open(HW_MEM_FILE, "w") as f:
            json.dump(HW_MEM, f, indent=2)
    except Exception as e:
        log(f"hardware memory save failed: {e}")


def _hw_recall(project: str, dev: str) -> dict:
    entry = (HW_MEM.get(project, {}) or {}).get(dev)
    return entry if isinstance(entry, dict) else {}


def _hw_remember_module(project: str, dev: str, module: str, slot: str,
                        ports) -> None:
    HW_MEM.setdefault(project, {})[dev] = {
        "module": module,
        "slot": slot,
        "ports": sorted(str(p) for p in (ports or ())),
        "at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    save_hw_mem()


def _serial_install_skip_reason(win, dev: str) -> str:
    """Why the Physical-tab install cannot be attempted ('' means it can)."""
    if not SERIAL_AUTO_MODULE:
        return "automatic module install is off (NETBUILDER_SERIAL_MODULE=0)"
    if not HAS_RPA or not TESSERACT_CMD:
        return "no RPA/OCR stack to drive the Physical tab"
    if not callable(getattr(win, "rectangle", None)):
        return "the device window cannot be measured"
    return ""


def _physical_tab(win, dev: str) -> bool:
    """Open the device window's Physical tab (printed name first, OCR next)."""
    if click_by_names(["Physical"], f"{dev} Physical tab", timeout_s=1.5):
        _interruptible_sleep(0.7)
        return True
    spot = _click_text_in_window(win, ["physical"])
    if spot:
        _interruptible_sleep(0.7)
        return True
    return False


def _power_toggle(win, dev: str, why: str) -> bool:
    """Flip the chassis power switch (an image: CAL fraction only).

    PT shows no readable power state, so this makes no claim - the install is
    judged by the interface table afterwards.
    """
    try:
        r = win.rectangle()
    except Exception:
        return False
    fx, fy = CAL.get("hw_power", (0.075, 0.205))
    _safe_click(r.left + int((r.right - r.left) * fx),
                r.top + int((r.bottom - r.top) * fy))
    _interruptible_sleep(1.3)
    log(f"{dev}: power switch toggled ({why})")
    return True


def _select_module(win, dev: str) -> str:
    """Click a serial module in the MODULES list; return what was clicked.

    The module name is printed text, so the OCR word boxes locate it exactly;
    the CAL row is only the fallback, and it is reported as such so a wrong
    module can be told apart from a missed click.
    """
    try:
        words, l, t, w, h = _win_words(win, psm=11)
    except Exception as exc:
        log(f"{dev}: module list read failed: {exc}")
        words, l, t = [], 0, 0
    for name in SERIAL_MODULE_NAMES:
        want = _alnum(name)
        for wd, x, y, ww, hh in words or []:
            got = _alnum(wd)
            if got and (got == want or want in got):
                _safe_click(l + x + ww // 2, t + y + hh // 2)
                _interruptible_sleep(0.7)
                log(f"{dev}: module '{name}' selected (OCR row)")
                return name
    try:
        r = win.rectangle()
    except Exception:
        return ""
    _safe_click(r.left + int((r.right - r.left) * CAL["hw_module_col0"]),
                r.top + int((r.bottom - r.top) * CAL["hw_module_row"]))
    _interruptible_sleep(0.7)
    log(f"{dev}: module list OCR missed - clicked the CAL row instead")
    return f"CAL row ({SERIAL_MODULE_PREFERRED} assumed)"


def _click_hwic_slot(win, dev: str, project: str) -> str:
    """Click an empty HWIC slot; the learned one first.  '' on failure."""
    keys = [k for k in ("hw_slot0", "hw_slot1", "hw_slot2", "hw_slot3")
            if k in CAL]
    learned = str(_hw_recall(project, dev).get("slot") or "")
    if learned in keys:
        keys.remove(learned)
        keys.insert(0, learned)
    try:
        r = win.rectangle()
    except Exception:
        return ""
    for key in keys:
        if not isinstance(CAL.get(key), tuple):
            continue
        fx, fy = CAL[key]
        _safe_click(r.left + int((r.right - r.left) * fx),
                    r.top + int((r.bottom - r.top) * fy))
        _interruptible_sleep(0.9)
        log(f"{dev}: HWIC module dropped at {key}")
        return key
    return ""


def _install_serial_module(win, dev: str, project: str, wanted_full: str,
                           before: set) -> tuple:
    """Give a router its serial HWIC and prove it from the live table.

    Returns ``(available, reason)``.  On success ``available`` is the freshly
    read interface set (which now contains at least one serial port) and the
    caller decides whether the requested one is among them; on failure it is
    None and ``reason`` names the step that stopped the attempt.  Bounded to
    one attempt per (device, interface) per run.
    """
    key = (dev, wanted_full)
    if key in _SERIAL_INSTALL_TRIED:
        return None, "already attempted in this run"
    _SERIAL_INSTALL_TRIED.add(key)
    skip = _serial_install_skip_reason(win, dev)
    if skip:
        # Not a device failure: nothing was attempted, so nothing is
        # journaled against the device.  The caller still reports the hand
        # remedy for the absent interface.
        log(f"{dev}: serial module install skipped - {skip}")
        return None, skip
    if stopped():
        return None, "run stopped"
    if not _physical_tab(win, dev):
        reason = "the Physical tab could not be opened"
    else:
        _power_toggle(win, dev, "power off before the module")
        module = _select_module(win, dev)
        slot = _click_hwic_slot(win, dev, project) if module else ""
        if not module:
            reason = "no serial module was found in the MODULES list"
        elif not slot:
            reason = "no HWIC slot could be clicked"
        else:
            reason = ""
        _power_toggle(win, dev, "power on after the module")
        if not reason:
            for attempt in range(1, _SERIAL_INSTALL_ROUNDS + 1):
                if stopped():
                    reason = "run stopped"
                    break
                _interruptible_sleep(_SERIAL_BOOT_WAIT_S)
                if not _focus_cli_tab(win, dev):
                    log(f"{dev}: module install round {attempt}: CLI tab not "
                        "proven yet")
                    continue
                try:
                    _settle_boot_dialogs(win, dev)
                except Exception:
                    pass
                if not _ensure_privileged_cli(win, dev, 25):
                    continue
                _type_line("show ip interface brief", 25, win=win, dev=dev)
                _interruptible_sleep(0.8)
                available, _text = _read_interface_capabilities(win)
                gained = {i for i in (available or set())
                          if _iface_is_serial(i) and i not in (before or set())}
                if gained:
                    ports = sorted(i for i in available if _iface_is_serial(i))
                    _hw_remember_module(project, dev, module, slot, ports)
                    record_event(
                        "serial_module_installed",
                        f"added {module} at {slot}; the live table now shows "
                        f"{', '.join(ports)}",
                        device=dev, recovered=True,
                        extra={"module": module, "slot": slot,
                               "requested": wanted_full, "ports": ports})
                    log(f"{dev}: serial module installed ({module} at {slot}) "
                        f"- live ports: {', '.join(ports)}")
                    return available, ""
            reason = reason or (
                f"{SERIAL_MODULE_PREFERRED} was placed at {slot} but no serial "
                f"port appeared in the live table after "
                f"{_SERIAL_INSTALL_ROUNDS} reads")
    record_event("serial_module_install_failed", reason, device=dev,
                 recovered=False,
                 extra={"requested": wanted_full,
                        "module": SERIAL_MODULE_PREFERRED})
    log(f"{dev}: serial module install failed - {reason}; "
        f"{SERIAL_MODULE_HINT}")
    return None, reason


def _serial_spare_candidate(available: set, used: set,
                            wanted_full: str = "") -> tuple:
    """A serial port other than the requested one, if the device has one.

    Installing the module can land the port on a different slot number than
    the plan guessed (PT numbers interfaces by slot), and a serial WAN on
    Serial0/1/0 is still a serial WAN - it is a far smaller deviation than
    remapping the cable onto GigabitEthernet.  The remap stays visible and
    the exact-interface verdict still reports it.
    """
    serial = sorted(i for i in (available or set()) if _iface_is_serial(i))
    for full in serial:
        if full == wanted_full or full in (used or set()):
            continue
        short = "s" + full[len("serial"):]
        return full, short
    return "", ""



def _interface_targets(links: list, prefixes: tuple = ("s",)) -> list:
    """Ordered, de-duplicated ``(device, spec, full name)`` WAN targets."""
    targets = []
    for lnk in links or []:
        for dev, spec in ((lnk.get("a"), lnk.get("aIf", "")),
                          (lnk.get("b"), lnk.get("bIf", ""))):
            spec = str(spec or "").strip()
            if not dev or not spec.lower().startswith(prefixes):
                continue
            full = _full_ifname(spec) or spec.lower()
            item = (dev, spec, full)
            if item not in targets:
                targets.append(item)
    return targets


def _preflight_link_capabilities(rect, links: list, slot_of: dict,
                                 project: str) -> set:
    """Check optional WAN ports and recover absent serial interfaces.

    Serial hardware is optional on Packet Tracer routers.  If S0/0/0 is not
    present but a spare routed port is proven by ``show ip interface brief``,
    both cable intents may be rewritten to that actual port and the CLI config
    is rewritten later in the plan.  The exact-interface validator still
    fails and reports the mismatch.  No guessed port is ever treated as
    evidence.

    Blocking is scoped to the exact ``(device, interface)`` that failed to
    prove out, never to the whole device: a router whose serial probe is
    inconclusive must still be cabled on its LAN link in the same run.  Two
    outcomes are recorded separately:

    * probe failure - privileged mode or the live interface table was not
      proven after bounded retries.  Only the links requesting that very
      interface are held back, recorded as ``interface_probe_unverified``,
      and the device is NOT marked interface-blocked.
    * proven absence - the live table was read and the interface is missing.
      The WAN is remapped to a proven spare when one exists, otherwise the
      requesting link is blocked (``interface_unavailable``).
    """
    targets = _interface_targets(links)
    unavailable = set()   # (device, full interface) proven absent
    unverified = set()    # (device, full interface) probe never proven
    RUN["interface_remaps"] = {}
    for dev, spec, full in targets:
        if stopped():
            break

        def probe_unverified(reason: str, attempts: int = 0):
            unverified.add((dev, full))
            RUN["interfaces_unverified"] = \
                RUN.get("interfaces_unverified", 0) + 1
            record_event("interface_probe_unverified", reason,
                         device=dev, recovered=False,
                         extra={"interface": full, "attempts": attempts})
            log(f"{dev}: {full} capability unproven - holding back only the "
                "link(s) that request it")

        if dev not in slot_of:
            probe_unverified(f"{dev} has no canvas slot; {full} could not "
                             "be probed")
            continue
        win = _open_device_window(rect, dev, slot_of[dev], project)
        if win is None or not _focus_cli_tab(win, dev):
            if win is not None:
                _close_device_window(win, dev)
            probe_unverified(f"CLI window for {dev} was not verified; "
                             f"{full} could not be probed")
            continue
        try:
            available, attempts = set(), 0
            for attempts in range(1, _INTERFACE_PROBE_ROUNDS + 1):
                if stopped():
                    break
                try:
                    _settle_boot_dialogs(win, dev)
                except Exception:
                    pass
                if attempts > 1:
                    # A stalled or unfocused terminal is the usual reason a
                    # probe read nothing; re-focus it with the same helper
                    # the typing path uses before retrying.
                    _focus_cli_input(win, dev, "interface preflight retry")
                if not _ensure_privileged_cli(win, dev, 25):
                    log(f"{dev}: privileged mode was not proven during "
                        f"interface preflight (attempt {attempts}/"
                        f"{_INTERFACE_PROBE_ROUNDS})")
                    continue
                _type_line("show ip interface brief", 25, win=win, dev=dev)
                _interruptible_sleep(0.8)
                available, _ = _read_interface_capabilities(win)
                if available:
                    break
            if not available:
                probe_unverified(
                    f"could not prove privileged CLI and read the live "
                    f"interface table before checking {full}",
                    attempts)
                continue
            if full in available:
                continue  # proven present: nothing to recover or block
            used = {
                _full_ifname(other_spec)
                for lnk in links or []
                for other_dev, other_spec in (
                    (lnk.get("a"), lnk.get("aIf", "")),
                    (lnk.get("b"), lnk.get("bIf", "")),
                )
                if other_dev == dev
                and _full_ifname(other_spec)
                and _full_ifname(other_spec) != full
            }
            # 1) Do the hand remedy for the user: give the router a serial
            #    HWIC through the Physical tab, then re-read the live table.
            #    Bounded to one attempt per device, and believed only when a
            #    serial port actually appears there.
            installed, _install_reason = _install_serial_module(
                win, dev, project, full, available)
            if installed:
                available = installed
                if full in available:
                    continue          # exact port proven: nothing to remap
            # 2) A serial port under another slot number still IS the serial
            #    WAN the plan asked for - prefer it to GigabitEthernet.
            spare_full, spare_short = _serial_spare_candidate(
                available, used, full)
            if not spare_full:
                # 3) Last resort: today's proven spare routed port.  A WAN
                #    on the LAN port is a smaller lie than no WAN at all,
                #    but it is still a remap and exact-interface validation
                #    keeps reporting it.
                spare_full, spare_short = _serial_fallback_candidate(
                    available, used)
            if spare_full:
                # Remap the cable intent BEFORE the blocked-link set is
                # computed so the rewritten WAN link is still wired in this
                # run instead of being blocked as "absent".
                remap = RUN.setdefault("interface_remaps", {}) \
                    .setdefault(dev, {})
                remap[spec] = spare_short
                for lnk in links or []:
                    if lnk.get("a") == dev and \
                            _full_ifname(lnk.get("aIf", "")) == full:
                        lnk["aIf"] = spare_short
                    if lnk.get("b") == dev and \
                            _full_ifname(lnk.get("bIf", "")) == full:
                        lnk["bIf"] = spare_short
                record_event(
                    "interface_remapped",
                    f"{full} absent; WAN recovered on proven spare "
                    f"{spare_full}",
                    device=dev, recovered=True,
                    extra={"requested": full, "actual": spare_full},
                )
                # Report the real fix as its own observation (recovered=None
                # keeps it out of the unrecovered-error headline).
                record_event("serial_module_hint", SERIAL_MODULE_HINT,
                             device=dev)
                log(f"{dev}: {full} absent - using proven spare "
                    f"{spare_full} for the WAN; {SERIAL_MODULE_HINT}")
            else:
                unavailable.add((dev, full))
                _mark_interface_blocked(dev)
                record_event(
                    "interface_unavailable",
                    f"{full} absent and no proven spare routed port was "
                    "available; link blocked",
                    device=dev, recovered=False,
                )
                record_event("serial_module_hint", SERIAL_MODULE_HINT,
                             device=dev)
                log(f"{dev}: {full} is not present and no spare routed "
                    f"port was proven - the link that uses it is blocked; "
                    f"{SERIAL_MODULE_HINT}")
        finally:
            _close_device_window(win, dev)
    blocked_ifaces = unavailable | unverified
    blocked_links = {
        i for i, lnk in enumerate(links or [])
        if any((lnk.get(end), _full_ifname(lnk.get(end + "If", "")))
               in blocked_ifaces
               for end in ("a", "b"))
    }
    for i in sorted(blocked_links):
        lnk = links[i]
        endpoints = [
            (lnk.get(end), _full_ifname(lnk.get(end + "If", "")))
            for end in ("a", "b")
        ]
        reason = ("interface unavailable"
                  if any(pair in unavailable for pair in endpoints)
                  else "interface not verified")
        RUN.setdefault("link_results", {})[str(i)] = {
            "a": lnk.get("a"), "aIf": lnk.get("aIf"),
            "b": lnk.get("b"), "bIf": lnk.get("bIf"),
            "status": "blocked", "reason": reason,
        }
        record_event("link_blocked",
                     f"cable not attempted because a required interface is "
                     f"{'absent' if reason.endswith('unavailable') else 'not verified'}",
                     recovered=False,
                     extra={"link": f"{lnk.get('a')}:{lnk.get('aIf')} <-> "
                                    f"{lnk.get('b')}:{lnk.get('bIf')}",
                            "reason": reason})
    return blocked_links


def _apply_interface_remaps_to_plan(steps: list):
    """Rewrite generated CLI interface references after live WAN recovery."""
    remaps = RUN.get("interface_remaps", {}) or {}
    for st in steps or []:
        if st.get("action") != "paste_cli":
            continue
        configs = st.get("configs") or {}
        for dev, mapping in remaps.items():
            cfg = configs.get(dev)
            if not isinstance(cfg, str):
                continue
            for requested, actual in (mapping or {}).items():
                requested_full = _full_ifname(requested) or requested
                patterns = {str(requested).strip(), str(requested_full).strip()}
                for token in patterns:
                    if not token:
                        continue
                    cfg = re.sub(
                        rf"(?<![A-Za-z0-9]){re.escape(token)}"
                        rf"(?![A-Za-z0-9/])",
                        str(actual), cfg, flags=re.IGNORECASE,
                    )
            configs[dev] = cfg
    if remaps:
        record_event(
            "interface_remaps_applied",
            "rewrote the affected CLI and cable intents to the proven "
            "live WAN ports",
            recovered=True,
            extra={"remaps": remaps},
        )


def place_links(rect, links, slot_of: dict, project: str = "default",
                link_specs: dict | None = None,
                original_indices: list | None = None):
    """Wire cables END-TO-END: copper -> devA -> PORT -> devB -> PORT.

    Hardened after a run where only 2 of 5 cables landed: the port
    popup is invisible to UIA, so silent name-click failures left the
    cable on PT's default port (or dangling). Now every endpoint gets
    an OCR popup fallback, copper is re-selected for EVERY link, and
    each finished link is verified by canvas diff with ONE retry.
    """
    if not links:
        return
    link_specs = link_specs or {}
    JOB.project = project
    JOB.slot_of = slot_of
    for local_j, lnk in enumerate(links):
        j = (original_indices[local_j]
             if original_indices and local_j < len(original_indices)
             else local_j)
        attempt = 0
        if stopped():
            log("stop requested, aborting links")
            return
        a, b = lnk.get("a"), lnk.get("b")
        if a not in slot_of or b not in slot_of:
            log(f"link {j} skipped: unknown slot {a}-{b}")
            RUN.setdefault("link_results", {})[str(j)] = {
                "a": a, "aIf": lnk.get("aIf"), "b": b,
                "bIf": lnk.get("bIf"), "status": "failed",
                "attempts": 0, "visual_evidence": False,
                "reason": "canvas slot unavailable",
            }
            RUN["links_failed"] = RUN.get("links_failed", 0) + 1
            continue
        aIf, bIf = link_specs.get((a, b), ("g0/0", "g0/0"))
        # The cable kind follows the interfaces the link will ACTUALLY be
        # wired on - a WAN that the preflight remapped off Serial0/0/0 must
        # not be cabled with a serial cable (PT refuses serial-to-serial on
        # copper, and copper-to-copper on a serial cable), and a link that
        # stayed on its serial ports needs one clocking end, which is also
        # the end whose config carries `clock rate`.
        dce_end = serial_dce_end(lnk)
        dce_dev = a if dce_end == "a" else b
        cable = cable_kind_for_link(
            {"aIf": aIf, "bIf": bIf, "cable": lnk.get("cable"),
             "a": a, "b": b, "dce": lnk.get("dce")}, dce_end)
        if cable in (CABLE_SERIAL_DCE, CABLE_SERIAL_DTE):
            RUN.setdefault("serial_links", {})[f"{a}:{aIf}<->{b}:{bIf}"] = {
                "dce": dce_dev, "cable": cable,
            }
            record_event(
                "serial_cable_selected",
                f"{a}:{aIf} <-> {b}:{bIf} wired with a {cable} cable "
                f"({dce_dev} supplies the clock)",
                recovered=True,
                extra={"link": j, "cable": cable, "dce": dce_dev})
            log(f"link {j}: serial cable ({cable}); {dce_dev} is the DCE "
                "end and will carry the clock rate")
        wired = False
        visual = False
        visual_evidence = {}
        before_visual = False
        # If a fixes/retry run already has the exact cable, verify and reuse
        # it instead of adding a duplicate cable. This still requires a real
        # line corridor, not just remembered coordinates.
        try:
            main = find_pt_window()
            if not _focus_pt_window(main, phase=f"link {j} precheck"):
                raise RuntimeError("Packet Tracer focus not proven")
            before_full = shot_path(f"link_{j}_canvas_before.png")
            shot(f"link_{j}_canvas_before.png")
            before_visual, before_evidence = _link_line_evidence(
                before_full, rect, project, a, b)
            if before_visual:
                RUN.setdefault("link_results", {})[str(j)] = {
                    "a": a, "aIf": aIf, "b": b, "bIf": bIf,
                    "status": "verified", "attempts": 0,
                    "reused": True, "visual_evidence": True,
                    "evidence": before_evidence,
                }
                record_event("link_reused",
                             f"existing cable visually joins {a}:{aIf} "
                             f"and {b}:{bIf}", recovered=True,
                             extra={"link": j, "evidence": before_evidence})
                continue
        except Exception as exc:
            log(f"link {j}: existing-cable precheck unavailable: {exc}")
        for attempt in (1, 2, 3):
            if stopped():
                return
            try:
                main = find_pt_window()
                if not _focus_pt_window(main, phase=f"link {j} attempt {attempt}"):
                    record_event("link_focus_blocked",
                                 "cable input blocked because Packet Tracer "
                                 "was not foreground",
                                 recovered=False,
                                 extra={"link": j, "attempt": attempt})
                    continue
            except Exception as exc:
                log(f"link {j}: focus before cable failed: {exc}")
                continue
            # PT deselects the tool after every attempt, so the cable is
            # re-picked for each one - this is the only place a cable TYPE
            # (copper vs serial) is chosen at all.
            select_cable(cable)
            before_p = _shot_region(rect, 0.05, 0.12, 0.95, 0.82,
                                    f"link{j}_before.png")
            ok_a = _link_endpoint(rect, a, aIf, j, f"{a}:{aIf}")
            if stopped():
                return
            ok_b = False
            if ok_a:
                ok_b = _link_endpoint(rect, b, bIf, j, f"{b}:{bIf}")
            _interruptible_sleep(0.5)
            after_p = _shot_region(rect, 0.05, 0.12, 0.95, 0.82,
                                   f"link{j}_after.png")
            changed, score = canvas_changed(before_p, after_p,
                                            threshold=0.004)
            full_after = shot_path(f"link_{j}_canvas_after.png")
            try:
                shot(f"link_{j}_canvas_after.png")
                visual, visual_evidence = _link_line_evidence(
                    full_after, rect, project, a, b)
            except Exception as exc:
                visual, visual_evidence = False, {"error": str(exc)[:120]}
            if ok_a and ok_b and changed and visual:
                log(f"link {j}: {a}:{aIf} <-> {b}:{bIf} WIRED "
                    f"(canvas diff {score}, line evidence "
                    f"{visual_evidence.get('dark_corridor_hits', 0)}/"
                    f"{visual_evidence.get('required_hits', 0)})")
                wired = True
                break
            record_event("link_attempt_failed",
                         f"{a}:{aIf} <-> {b}:{bIf} attempt {attempt} "
                         f"(a={'ok' if ok_a else 'miss'}, "
                         f"b={'ok' if ok_b else 'miss'}, diff={score}, "
                         f"line={'ok' if visual else 'missing'})",
                         recovered=False,
                         extra={"expected": f"{a}:{aIf} <-> {b}:{bIf}",
                                "observed": f"a={ok_a}, b={ok_b}, diff={score}, "
                                           f"line={visual_evidence}",
                                "attempt": attempt})
            if attempt < 3:
                log(f"link {j} attempt {attempt} failed - retrying "
                    f"({3 - attempt} attempt(s) left)")
                _interruptible_sleep(0.6)
        shot(f"link_{j}.png")
        RUN.setdefault("link_results", {})[str(j)] = {
            "a": a, "aIf": aIf, "b": b, "bIf": bIf,
            "cable": cable,
            "status": "verified" if wired else "failed",
            "attempts": attempt,
            "visual_evidence": bool(visual or before_visual),
            "evidence": visual_evidence,
        }
        if not wired:
            RUN["links_failed"] = RUN.get("links_failed", 0) + 1
            log(f"link {j}: STILL UNWIRED after 3 attempts - continuing "
                "with the remaining task")
            record_event("link_failed", f"{a}:{aIf} <-> {b}:{bIf} unwired "
                         "after 3 attempts", recovered=False,
                         extra={"expected": f"{a}:{aIf} <-> {b}:{bIf}",
                                "correction": "reselect cable and ports; retry"})


# CLI ENGINE ------------------------------------------------------------
# Why bulk-paste failed: PT's emulated terminal drops chars on long
# pastes, `!` separator lines error as invalid input, configs assume
# config-mode but PT boots at user mode, and paging halts on --More--.
# This engine: filters non-commands, wraps with enable/conf-t/length-0,
# types LINE-BY-LINE via clipboard, scans the terminal for % errors,
# and retries each failed line once with a fallback.

# CLI SCREEN READING (OCR) ----------------------------------------------
# Why UIA alone was blind: PT's Qt terminal exposes almost no text
# through UI Automation, so the setup dialog went undetected and the
# first `no` was never typed (user screenshot: every config line eaten
# as a yes/no answer). Tesseract reads the device window PIXELS
# directly - install-free detection at the standard paths.
def _find_tesseract() -> str:
    cands = [os.environ.get("TESSERACT_CMD"),
             r"C:\Program Files\Tesseract-OCR\tesseract.exe",
             r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"]
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return shutil.which("tesseract") or ""


TESSERACT_CMD = _find_tesseract()

# OCR TUNING (golden-gated) ---------------------------------------------
# A build run is dominated by terminal reads, and the cost of a read is
# roughly proportional to Tesseract's input area.  These knobs are the main
# speed lever, so they are deliberately pinned to the values the accuracy
# work was validated with.  Change them ONLY after the golden comparison
# reports zero text diffs against the recorded baseline:
#
#     python ocr_baseline.py --record        (once, on a real machine)
#     python ocr_baseline.py --compare --variant=fast
#
# `--variant=fast` also reports the per-read time for each variant, so the
# speed win is measured before the default is flipped.
OCR_UPSCALE = 3            # 3 -> 2 halves Tesseract's input area
OCR_RESAMPLE = "LANCZOS"   # LANCZOS is the slowest filter PIL offers
OCR_PSM_PRIMARY = 6
OCR_PSM_FALLBACK = 11      # sparse read; None disables the second pass
OCR_MAX_PIXELS_WIDE = 4500  # width cap; above it the upscale is reduced

_OCR_CACHE: dict = {}  # (win_key, fy0, fy1, invert, psm) -> (timestamp, text)
# Exact-content cache.  Tesseract is deterministic for identical input, so
# the SAME crop pixels can only produce the SAME text: a byte-identical
# frame never needs another spawn, a changed frame always misses.  That is
# strictly safer than the TTL layer above (which can only go stale) and it
# is what makes the repeated reads inside one config line free.  Entries
# hold text only, and the oldest are evicted so a long run cannot grow.
_PX_CACHE: dict = {}
_PX_CACHE_MAX = 96
def ocr_cache_clear():
    """Drop both OCR caches.

    The TTL half is what the behaviour sites clear when they expect a fresh
    read after typing.  The exact-content half is safe to keep (identical
    pixels cannot produce different text), but it is dropped here too so a
    caller that asks for "no cached OCR" gets exactly that.
    """
    _OCR_CACHE.clear()
    _PX_CACHE.clear()


def _tesseract_run(img, psm: int) -> str:
    """Run Tesseract once on a prepared PIL image; returns its stdout.

    The image goes through the temp file on purpose.  Piping the PNG over
    stdin instead was tried and REJECTED by the golden gate for a real
    reason: writing to a pipe makes Tesseract emit CRLF line endings and
    ANSI-encoded bytes, while a file gets LF and UTF-8, so the same crop
    produced different text (a `\\r` on every terminal line, mojibake where
    the CLI had punctuation) and every multi-line read changed.  Measured at
    the same time: it saved ~1% of the read.  Not worth a text change.
    The temp file also stays the evidence file when a read fails.
    """
    flag = str(int(psm))
    try:
        os.makedirs(SHOTS, exist_ok=True)
        tmp = os.path.join(SHOTS, "_ocr_tmp.png")
        img.save(tmp, compress_level=1)
        out = _run_hidden(
            [TESSERACT_CMD, tmp, "stdout", "--psm", flag],
            capture_output=True, text=True, timeout=10)
        return out.stdout or ""
    except Exception as e:
        log(f"tesseract temp-file read failed: {e}")
        return ""


def _ocr_region(win, fy0: float = 0.40, fy1: float = 0.94,
                fx0: float = 0.035, fx1: float = 0.955,
                ttl: float = 0.5, invert: bool = True,
                psm: int = 6) -> str:
    """OCR the bottom part of the device window (its live CLI lines).

    Crop MUST stay inside the terminal pane: including the window
    borders/scrollbar made Tesseract return NOTHING on some windows
    (real run: error retries never fired because the read was empty).
    fy1 extends just below the terminal's last text row. The previous
    crop ended at the last prompt on some Packet Tracer windows, so OCR
    kept seeing the older ``Router>`` and repeatedly sent ``enable``.
    The Copy/Paste labels in the small lower margin are harmless because
    prompt parsing only accepts IOS-shaped lines. Packet Tracer can show
    either a dark or light CLI theme, so invert=True means "auto-select the
    terminal polarity"; panel callers can still pass invert=False. Result
    cached briefly, then by exact crop content (see _PX_CACHE).
    """
    if not TESSERACT_CMD:
        return ""
    try:
        r = win.rectangle()
    except Exception:
        return ""
    try:
        from PIL import Image, ImageOps, ImageStat
    except Exception as e:
        log(f"PIL missing, OCR disabled: {e}")
        return ""
    key = (str(getattr(r, "handle", id(win))), round(fy0, 2),
           round(fy1, 2), bool(invert), int(psm))
    now = time.time()
    t0 = now
    perf_inc("ocr_reads")
    hit = _OCR_CACHE.get(key)
    if hit and now - hit[0] < ttl:
        perf_inc("ocr_ttl_hits")
        return hit[1]
    try:
        l, t, rr, b = r.left, r.top, r.right, r.bottom
        w0, h0 = rr - l, b - t
        x = l + int(w0 * fx0)
        y = t + int(h0 * fy0)
        w = max(60, int(w0 * (fx1 - fx0)))
        h = max(30, int(h0 * (fy1 - fy0)))
        img = pyautogui.screenshot(region=(x, y, w, h)).convert("L")
        # Exact-content cache: hash the raw crop before the invert/upscale
        # work, so re-reading an unchanged frame skips that too.  The key
        # carries everything that can change the text (pixels, psm,
        # polarity, and the read band the pixels came from); the TTL is not
        # part of it because it cannot change the result.
        px_key = ("px", int(psm), bool(invert), round(fy0, 2),
                  round(fy1, 2), round(fx0, 2), round(fx1, 2),
                  hashlib.sha1(img.tobytes()).hexdigest())
        px_hit = _PX_CACHE.get(px_key)
        if px_hit is not None:
            perf_inc("ocr_px_hits")
            _OCR_CACHE[key] = (now, px_hit)
            return px_hit
        # Tesseract is most reliable with dark text on a light background.
        # PT screenshots vary: the user's light CLI must stay as-is, while
        # a dark terminal needs inversion. Use the observed mean instead of
        # blindly inverting every CLI crop.
        if invert and _terminal_ocr_should_invert(
                ImageStat.Stat(img).mean[0]):
            img = ImageOps.invert(img)
        # PT's CLI font is tiny.  Tesseract silently returns NOTHING for the
        # light-theme terminal at native scale (real run: every prompt read
        # came back empty, so no config line was ever proven and the whole
        # CLI phase was blocked).  Upscale so glyph height reaches
        # Tesseract's working range; cap the width so large crops stay
        # inside a sane runtime.
        scale = int(OCR_UPSCALE)
        resample = getattr(Image, str(OCR_RESAMPLE), Image.LANCZOS)
        w0, h0 = img.size
        while scale > 1 and w0 * scale > OCR_MAX_PIXELS_WIDE:
            scale -= 1
        if scale > 1:
            img = img.resize((w0 * scale, h0 * scale), resample)
        # One spawn per pass.  Counted here rather than inside
        # _tesseract_run so the number is the decision the reader made.
        perf_inc("ocr_spawns")
        perf_inc("ocr_psm" + str(int(psm)))
        txt = _tesseract_run(img, int(psm))
        if (not txt.strip() and int(psm) == OCR_PSM_PRIMARY
                and OCR_PSM_FALLBACK):
            # psm 6 assumes a dense uniform block and can return nothing on
            # a sparse terminal; the sparse psm 11 read still finds the
            # isolated prompt rows in exactly those frames.
            perf_inc("ocr_spawns")
            perf_inc("ocr_psm" + str(int(OCR_PSM_FALLBACK)))
            txt = _tesseract_run(img, int(OCR_PSM_FALLBACK)) or txt
        _OCR_CACHE[key] = (now, txt)
        _PX_CACHE[px_key] = txt
        if len(_PX_CACHE) > _PX_CACHE_MAX:
            _PX_CACHE.pop(next(iter(_PX_CACHE)), None)
        return txt
    except Exception as e:
        log(f"ocr failed: {e}")
        return ""
    finally:
        perf_add_ms("ocr_ms", (time.time() - t0) * 1000.0)


def _terminal_ocr_should_invert(mean_luma: float) -> bool:
    """Return whether a terminal crop is dark enough to require inversion."""
    return float(mean_luma) < 128.0


def _uia_texts(win, cap: int = 80) -> str:
    """Read visible terminal text via every UIA text source.

    PT's terminal is custom-drawn but exposes chunks through element names,
    window texts and legacy accessible values. Concatenated tail is the
    engine's eyes: dialog detection, error counting, pager handling.

    The descendant walk is bounded with a hard timeout: a stalled UIA
    provider used to hang the build worker silently (no log, no event) and
    the run froze right after the interface capability probe. The wrapper
    is resolved inside the worker thread so no COM pointer crosses
    apartments.
    """
    try:
        handle = win.element_info.handle
    except Exception:
        return ""

    def read():
        device = Desktop(backend="uia").window(handle=handle)
        chunks = []
        for d in list(device.descendants())[:cap]:
            for src in (_uia_name(d), _uia_window_text(d), _uia_value(d)):
                if src and len(src.strip()) > 1:
                    chunks.append(src.strip()[:300])
        seen = set()
        uniq = []
        for c in chunks:
            if c not in seen:
                seen.add(c)
                uniq.append(c)
        return "\n".join(uniq)

    start = time.time()
    perf_inc("uia_reads")
    try:
        return (_bounded_call(read, 6.0, "terminal uia text") or "")[-4000:]
    except Exception:
        return ""
    finally:
        perf_add_ms("uia_ms", (time.time() - start) * 1000.0)


def _term_texts(win, cap: int = 80) -> str:
    """Screen truth first (OCR); UIA text only when OCR reads nothing.

    UIA used to be appended unconditionally, but PT's custom terminal
    exposes little useful text there while every extra descendant walk
    risks a stalled UIA provider. OCR (now upscaled) is the reliable
    source, so the UIA walk is reserved for the frames OCR cannot read.
    """
    if (_ui_window_handle(win)
            and not _focus_pt_window(win, phase="CLI text read")):
        return ""
    ocr = _ocr_region(win)
    if ocr.strip():
        return ocr.strip()[-4000:]
    return _uia_texts(win, cap)[-4000:]


SKIP_PREFIXES = ("!", "#", "echo", "pause", "rem ")
# `exit` is a real IOS mode transition and must be preserved between
# interface/ACL/line/crypto blocks.  Only final-session commands are removed
# and re-added by the executor.
TAIL_COMMANDS = ("end", "write", "write memory", "quit")
MODE_ENTRY_COMMANDS = {"enable", "configure terminal", "conf t"}
# Mode transitions must never be typed from a latched guess: a stale
# latch made the 2026-09-15 run type `configure terminal` inside a
# (config-if) prompt and `end` at a privileged prompt, where Packet
# Tracer answered `Translating "end"` (a DNS lookup) instead.
MODE_TRANSITION_LINES = {"enable", "configure terminal", "conf t",
                         "end", "exit", "quit"}


# Commands the Packet Tracer IOS emulation does not implement.  The terminal
# echoes them correctly and Packet Tracer answers "% Invalid input detected",
# so they must never be counted as automation errors: they are elided from the
# typed queue and reported instead (see _elide_pt_unsupported).
_PT_UNSUPPORTED_PATTERNS = (
    (re.compile(r"^crypto\s+isakmp\b", re.I), "crypto isakmp (IPsec ISAKMP)"),
    (re.compile(r"^crypto\s+ipsec\b", re.I), "crypto ipsec transform-set"),
    (re.compile(r"^crypto\s+map\b", re.I), "crypto map"),
    (re.compile(r"^(?:encr|encryption)\s+\S+", re.I),
     "ISAKMP policy encryption"),
    (re.compile(r"^hash\s+\S+", re.I), "ISAKMP policy hash"),
    (re.compile(r"^(?:set\s+(?:transform-set|peer|pfs)|match\s+address)\b",
                re.I), "crypto-map sub-mode"),
    (re.compile(r"^time-range\b", re.I), "time-range"),
    (re.compile(r"^ip\s+sla\b", re.I), "IP SLA"),
    (re.compile(r"^(?:class-map|policy-map|shape\s+|bandwidth\s+percent)\b",
                re.I), "QoS class/policy maps"),
    (re.compile(r"^zone\s+security\b", re.I), "zone-based firewall"),
    (re.compile(r"^zone-pair\s+security\b", re.I), "zone-based firewall"),
)
# QoS/zone submode children that only serve a dropped parent.
_PT_QOS_SUBMODE = re.compile(
    r"^(?:shape\s+|bandwidth\s+|fair-queue|random-detect|police\s+)\b", re.I)
# `time-range <name>` also appears as a keyword inside ACL entries.
_PT_UNSUPPORTED_ACL_TIME_RANGE = re.compile(r"\btime-range\s+\S+", re.I)
# crypto-map sub-mode payload that only serves the dropped map line.
# Children of an elided mode anchor.  Dropping only the parent left these in
# the queue and, with the anchor gone, each one produced
# `cli_context_blocked  no remembered anchor for crypto mode` (4 per router in
# the 2026-09-16 run) - noise that inflated the run's failure surface.
_PT_ISAKMP_SUBMODE = re.compile(
    r"^(?:authentication|encryption|encr|hash|group|lifetime)\b", re.I)
_PT_TIME_RANGE_SUBMODE = re.compile(r"^(?:periodic|absolute)\b", re.I)
_PT_CRYPTO_MAP_SUBMODE = re.compile(
    r"^(?:set\s+(?:transform-set|peer|pfs)|match\s+address)\b", re.I)


def _remove_blind_mode_entries(lines: list) -> list:
    """Remove mode-wrapper lines from generated and learned CLI sequences."""
    out = []
    for raw in lines or []:
        line = str(raw).strip()
        if not line:
            continue
        if line.lower() in MODE_ENTRY_COMMANDS:
            continue
        out.append(line)
    return out


def _pt_unsupported_reason(line: str, dtype: str = "") -> str:
    """Reason Packet Tracer cannot execute this line, or "" when it can.

    Only commands observed rejected by the live Packet Tracer CLI are listed:
    the terminal echo shows the text arrived intact, so these are platform
    gaps rather than typing problems.
    """
    t = str(line or "").strip()
    if not t:
        return ""
    for pat, reason in _PT_UNSUPPORTED_PATTERNS:
        if pat.match(t):
            return reason
    if _PT_UNSUPPORTED_ACL_TIME_RANGE.search(t):
        return "time-range keyword inside an ACL entry"
    return ""


def _record_unsupported(device: str, reason: str, dropped: list) -> None:
    """Report one elided Packet Tracer-unsupported command family."""
    record_event(
        "unsupported_by_packet_tracer",
        f"{reason} is not implemented by Packet Tracer; "
        f"{len(dropped)} command(s) elided instead of retried: "
        f"{'; '.join(dropped[:4])}",
        device=device, recovered=False,
        extra={"reason": reason, "count": len(dropped),
               "commands": dropped[:4]},
    )
    RUN.setdefault("unsupported_features", []).extend(dropped)
    RUN["unsupported_features_count"] = \
        RUN.get("unsupported_features_count", 0) + len(dropped)


def _drop_empty_interface_blocks(lines: list) -> list:
    """Remove `interface X` / `exit` pairs left with no payload."""
    out, i, total = [], 0, len(lines or [])
    while i < total:
        text = str(lines[i]).strip()
        if text.lower().startswith("interface "):
            body, j = [], i + 1
            while j < total:
                nxt = str(lines[j]).strip()
                if nxt.lower() == "exit" or nxt.lower().startswith("interface "):
                    break
                body.append(nxt)
                j += 1
            if (not [b for b in body if b] and j < total
                    and str(lines[j]).strip().lower() == "exit"):
                i = j + 1
                continue
        out.append(lines[i])
        i += 1
    return out


def _elide_pt_unsupported(lines: list, device: str = "",
                          report: bool = True) -> list:
    """Drop PT-unsupported commands and the sub-mode block that serves them.

    Each dropped family is reported once, never counted as an error, and never
    typed.  `report=False` keeps the filter usable for read-only line counts.
    """
    kept, families = [], {}
    idx, total = 0, len(lines or [])
    while idx < total:
        raw = lines[idx]
        text = str(raw).strip()
        reason = _pt_unsupported_reason(text)
        if not reason:
            kept.append(raw)
            idx += 1
            continue
        dropped = [text]
        idx += 1
        if reason == "crypto map":
            # `crypto map <tag> <seq> ipsec-isakmp` opens a sub-mode block
            # whose only payload is set/match; drop it as one family.  The
            # trailing `exit` only belongs to the family when something was
            # actually consumed: a bare `crypto map <name>` inside an
            # `interface ...` block must keep its `exit`, otherwise the
            # empty-interface-block cleanup below cannot remove the pair.
            while idx < total:
                nxt = str(lines[idx]).strip()
                if nxt and _PT_CRYPTO_MAP_SUBMODE.match(nxt):
                    dropped.append(nxt)
                    idx += 1
                    continue
                if nxt.lower() == "exit" and len(dropped) > 1:
                    dropped.append(nxt)
                    idx += 1
                break
        elif reason.startswith("crypto isakmp") \
                or reason.startswith("ISAKMP"):
            # `crypto isakmp policy <n>` opens the ISAKMP policy sub-mode.
            # Dropping the anchor alone orphaned `authentication pre-share`
            # and `group 5`, which then had no mode anchor to enter.
            while idx < total:
                nxt = str(lines[idx]).strip()
                if nxt and _PT_ISAKMP_SUBMODE.match(nxt):
                    dropped.append(nxt)
                    idx += 1
                    continue
                if nxt.lower() == "exit" and len(dropped) > 1:
                    dropped.append(nxt)
                    idx += 1
                break
        elif reason == "time-range":
            # `time-range <name>` opens a sub-mode holding periodic/absolute.
            while idx < total:
                nxt = str(lines[idx]).strip()
                if nxt and _PT_TIME_RANGE_SUBMODE.match(nxt):
                    dropped.append(nxt)
                    idx += 1
                    continue
                if nxt.lower() == "exit" and len(dropped) > 1:
                    dropped.append(nxt)
                    idx += 1
                break
        elif reason == "QoS class/policy maps":
            # `policy-map X` opens a sub-mode whose payload is shape/bandwidth/
            # police; `class-map X` opens one holding match lines. Drop the
            # payload as one family so the queue never hits a missing anchor.
            # NOTE: `match ...` alone is NOT dropped here unless a class-map
            # anchor was just consumed, so ACL match lines stay intact.
            while idx < total:
                nxt = str(lines[idx]).strip()
                if nxt and (_PT_QOS_SUBMODE.match(nxt)
                            or nxt.lower().startswith(("class ",
                                                       "match "))):
                    dropped.append(nxt)
                    idx += 1
                    continue
                if nxt.lower() == "exit" and len(dropped) > 1:
                    dropped.append(nxt)
                    idx += 1
                break
        families.setdefault(reason, []).extend(dropped)
    kept = _drop_empty_interface_blocks(kept)
    if report:
        for reason, dropped in families.items():
            _record_unsupported(device, reason, dropped)
    return kept


def cli_lines_for_device(cfg: str, device: str = "",
                      report: bool = False) -> list:
    """Filter + wrap raw config text into safe live-CLI lines.

    ``report`` is enabled by the typing path (learned_cli_lines)
    so a Packet Tracer-unsupported family is journaled exactly
    once per device build; read-only line counts stay silent.
    """
    body = []
    for raw in (cfg or "").splitlines():
        t = raw.strip()
        if not t:
            continue
        low = t.lower()
        if low.startswith(SKIP_PREFIXES):
            continue  # `!` dividers error as % Invalid input in live CLI
        if low in TAIL_COMMANDS:
            continue  # re-appended in order below
        body.append(t)
    body = _elide_pt_unsupported(body, device, report=report)
    body = _remove_blind_mode_entries(body)
    # trailing `show` proves interfaces up in the cli_<dev>.png screenshot.
    # NO `terminal length 0`: PT (routers AND switches) rejects it as
    # % Invalid - the user rightly flagged it recurring every run - and
    # PT's show output never pages anyway, so it is simply dropped.
    # Mode entry is handled by the verified state machine immediately before
    # each command. Do not prepend blind enable/configure commands: the
    # capability probe may already have left the device privileged.
    return body + ["end", "show ip interface brief"]


def _type_line(line: str, delay_ms: int, win=None, dev: str = ""):
    """One line via char typing.

    PT's terminal IGNORES Ctrl+V clipboard pastes (user screenshot: bare
    Switch> prompts from empty pastes). pyautogui.write sends real
    keystrokes which PT accepts.

    First-char insurance: PT's terminal sometimes eats the FIRST
    keystroke right after a large output burst ('write memory' became
    'rite memory'). A leading space is typed first - IOS trims leading
    whitespace, so if PT is busy it eats the throwaway space, and the
    command still arrives complete.
    """
    if stopped():
        return False
    start = time.time()
    perf_inc("type_calls")
    try:
        return _type_line_inner(line, delay_ms, win, dev)
    finally:
        perf_add_ms("type_ms", (time.time() - start) * 1000.0)


def _type_line_inner(line: str, delay_ms: int, win=None, dev: str = ""):
    """Body of _type_line (split out only so its cost is measured once)."""
    if stopped():
        return False
    if win is not None and not _focus_cli_input(
            win, dev, f"type '{str(line)[:40]}'"):
        return False
    _safe_press("space")
    if not _interruptible_sleep(0.12):
        return False
    # Type in short chunks instead of one uninterruptible pyautogui.write.
    # Escape can therefore stop a long ACL/crypto command within a few
    # characters rather than waiting for the whole line to finish.
    for start in range(0, len(line), 4):
        if stopped():
            return False
        _safe_write(line[start:start + 4], interval=0.015)
    if not _interruptible_sleep(0.1):
        return False
    if stopped():
        return False
    _safe_press("enter")
    _interruptible_sleep(min(1.4, 0.35 + len(line) * 0.008 + delay_ms / 1000.0))
    return not stopped()


def _uia_name(d) -> str:
    try:
        return d.element_info.name or ""
    except Exception:
        return ""


def _uia_window_text(d) -> str:
    try:
        t = d.window_text()
        return t or ""
    except Exception:
        return ""


def _uia_value(d) -> str:
    try:
        if hasattr(d, "iface_value"):
            return d.iface_value.CurrentValue or ""
    except Exception:
        pass
    try:
        if hasattr(d, "legacy_properties"):
            return d.legacy_properties().get("Value", "") or ""
    except Exception:
        pass
    return ""


SETUP_MARKERS = ("initial configuration dialog", "would you like to enter",
                 "[yes/no]", "(yes/no)", "[yes/no]")


_IOS_PROMPT_RE = re.compile(
    # Packet Tracer OCR sometimes inserts a space into a hostname, for
    # example ``BR_ Router`` or ``BR Router``.  Keep the prompt boundary
    # explicit so ordinary boot text still cannot be mistaken for a prompt.
    r"^\s*(?P<name>[a-z0-9][a-z0-9_.-]*"
    r"(?:\s*(?:[_-])\s*[a-z0-9][a-z0-9_.-]*"
    r"|\s+[a-z0-9][a-z0-9_.-]*)*)"
    r"\s*(?P<context>\(\s*(?:conf(?:ig|ic|iq)|cfg)"
    r"(?:\s*-\s*[a-z0-9-]+)?\s*\))?"
    r"\s*(?P<marker>[#>+gt$4?}])(?=\s|$)",
    re.IGNORECASE,
)


def _ios_prompt_parts(line: str):
    """Return the IOS prompt pieces without matching ordinary words.

    OCR can turn ``#``/``>`` into ``g``/``t``.  The old matcher removed all
    whitespace and accepted any prefix ending in one of those letters, so
    ``Press RETURN to get started!`` was misread as a live prompt at the
    ``t`` in ``return``.  Keep the prompt boundary visible and only accept
    the OCR-only markers for recognizable Cisco device names.
    """
    raw = str(line or "").strip()
    if not raw or len(raw) > 80:
        return None
    match = _IOS_PROMPT_RE.match(raw)
    if not match:
        return None
    marker = match.group("marker").lower()
    name = match.group("name")
    if marker in "gt$4?}+":
        lowered = re.sub(r"[\s_]", "", name.lower())
        if not (lowered.startswith((
                "router", "route", "jouter", "switch", "swit",
                "hq", "br", "aaa", "dhcp", "web", "srv", "mgr",
                "pc", "server", "ri", "rig"))
                or any(ch.isdigit() for ch in name)):
            return None
    context = match.group("context") or ""
    # Tesseract commonly turns the final `g` in `config` into `c`/`q`.
    # Normalize only inside a prompt context; ordinary command text never
    # reaches this parser because the device-name boundary is mandatory.
    context = re.sub(r"\s+", "", context.lower())
    context = context.replace("(confic", "(config").replace(
        "(confiq", "(config").replace("(cfg", "(config")
    return {
        "name": name,
        "context": context,
        "marker": marker,
    }


def _last_prompt_pos(lines: list) -> int:
    """Index of the last line that looks like a live CLI prompt.

    OCR mangles prompts: 'SW1#' often reads as 'swig'/'swit'/'SWig'
    ('#' -> 'g'/'t'). Keep the prompt boundary intact so ordinary boot text
    such as ``Press RETURN`` cannot be mistaken for a prompt.
    """
    pos = -1
    for i, l in enumerate(lines):
        s = l.strip()
        if not s or len(s) > 40:
            continue
        # The current prompt can share a line with the command that was
        # just echoed (for example ``Router# enable``) while the next
        # repaint is still in progress. Treat that prompt prefix as live;
        # otherwise the older Router> line wins and enable is sent again.
        if _ios_prompt_parts(s):
            pos = i
    return pos


def _last_marker_pos(lines: list, markers) -> int:
    pos = -1
    for i, l in enumerate(lines):
        if any(m in l for m in markers):
            pos = i
    return pos


def _term_state(text: str) -> str:
    """Classify terminal screen: setup dialog, boot prompt, or live CLI.

    OCR reads the whole visible scrollback, so old boot markers stay on
    screen. The ACTIVE state is whichever marker sits LATEST in the
    text (after the last live prompt line) - a fixed priority order
    mis-called the dialog->prompt transition: for a moment the screen
    shows the dialog echo AND 'Press RETURN' before 'Router>' renders,
    and setup-first priority answered `no` at the unborn prompt
    (user screenshot: Router>no -> Translating hang).
    """
    low = (text or "").lower()
    if not low.strip():
        return "unknown"
    lines = [l for l in low.splitlines() if l.strip()]
    prompt_pos = _last_prompt_pos(lines)
    candidates = []
    setup_pos = _last_marker_pos(lines, SETUP_MARKERS)
    auto_pos = _last_marker_pos(lines, ("terminate autoinstall",))
    ret_pos = _last_marker_pos(lines, ("press return",
                                       "return to get started"))
    if setup_pos > prompt_pos:
        candidates.append((setup_pos, "setup"))
    if auto_pos > prompt_pos:
        candidates.append((auto_pos, "autoinstall"))
    if ret_pos > prompt_pos:
        candidates.append((ret_pos, "return"))
    if candidates:
        candidates.sort()
        return candidates[-1][1]
    if prompt_pos >= 0:
        return "cli"
    return "unknown"


def _term_error_signature(win) -> tuple:
    """Count % errors + pager/password markers from terminal readout.

    Returns (count, sample). Count grows when new errors appear, driving
    the per-line fallback retry.
    """
    try:
        text = _term_texts(win)
    except Exception:
        return 0, ""
    low = text.lower()
    # OCR renders '%' as '$' or drops it, so count the phrase, not the '%'
    errs = (low.count("invalid input") + low.count("incomplete command")
            + low.count("ambiguous command") + low.count("% invalid")
            + low.count("unknown command or computer name")
            + low.count("translating \""))
    sample = ""
    for marker in ("--more--", "password:", "translating \"",
                   "unknown command or computer name", "invalid input",
                   "incomplete command"):
        if marker in low:
            idx = low.rfind(marker)
            sample = text[max(0, idx - 40):idx + 60].replace("\n", " ")
            break
    return errs, sample.strip()[:160]


def _fallback_lines(line: str, in_ospf: bool, trunk_armed: bool) -> list:
    """One-shot recovery lines for a failed command (no loops).

    Every rule here is deterministic and context-free to evaluate; the
    executor still verifies the live prompt after typing.  Failed rules are
    recorded in command memory, so repeated misses are quarantined by the
    learning controller rather than retried forever.
    """
    low = line.strip().lower()
    if low.startswith("terminal length"):
        # PT switches (2960) reject `terminal length 0` outright; routers
        # accept it. Failure is benign - never retry, just move on.
        return []
    if low in {"end", "exit", "quit"}:
        # A mode transition must never be retried at a stale privileged
        # prompt: `end` there triggers IOS DNS translation when lookup is on.
        return []
    if low.startswith("network ") and not in_ospf:
        return ["router ospf 1", line]  # process context missing
    if low.startswith("switchport mode") and not trunk_armed:
        return ["switchport", line]  # enable switchport first
    if low.startswith("encapsulation dot1q"):
        return ["switchport", "switchport mode trunk", line]
    if low.startswith("ip address"):
        return [line]  # transient paste glitch: single retry
    if low.startswith("no shutdown") or low.startswith("no shut"):
        return ["no shutdown"]
    # --- additional fallback rules (Sep 2026) ----------------------------
    if low.startswith("standby "):
        # HSRP is an interface submode command; when it is typed while the
        # prompt is still global config the line errors, and the live mode
        # repair pass re-establishes the interface context for the retry.
        return [line]
    if low.startswith(("description ", "banner ")):
        return [line]  # free-text lines can fail on a transient paste glitch
    if low.startswith("ipv6 address") or low.startswith("ipv6 route "):
        # IPv6 needs unicast-routing enabled first on routers.
        return ["ipv6 unicast-routing", line]
    if low.startswith("ip route "):
        return [line]  # single retry for a transient paste glitch
    if low.startswith("ip default-gateway "):
        return [line]  # switch management plane: retry once in place
    if low.startswith("ip default-network "):
        return [line]
    if low.startswith(("router eigrp ", "router rip")):
        return [line]  # entering the routing process is its own mode entry
    if low.startswith(("passive-interface ", "no passive-interface ")):
        return [line]  # only valid inside a process; retry once
    if low.startswith("router-id "):
        return [line]  # process submode; retry once after mode repair
    if low.startswith(("ip dhcp excluded", "ip dhcp pool ")):
        return [line]  # global-config DHCP scaffolding: retry once
    if low.startswith(("ip helper-address ", "ip nat ", "ip domain-name ",
                       "ip name-server ")):
        return [line]  # interface/global one-liners: retry once
    if low.startswith("clock rate "):
        return [line]  # only valid on the DCE end; retry once then skip
    if low.startswith("switchport voice vlan "):
        return ["switchport", "switchport mode access", line]
    if low.startswith("switchport access vlan "):
        if not trunk_armed:
            return ["switchport", line]
        return [line]
    if low.startswith("vlan ") and not low.startswith("vlan database"):
        # VLANs must exist before access ports reference them.
        return [line]  # PT usually auto-creates; single retry
    if low.startswith(("spanning-tree ", "channel-group ", "udld ")):
        return [line]  # interface-range one-liners: retry once
    if low.startswith("login local") or low == "login":
        return [line]  # line submode: retry once
    if low.startswith(("enable secret", "enable password", "service ")):
        return [line]  # global one-liners: retry once
    if low.startswith(("aaa ", "crypto ")):
        # AAA/ISAKMP lines commonly fail on PT's reduced feature set; retry
        # once so command memory learns the verdict instead of looping.
        return [line]
    if low.startswith(("access-list ", "ip access-list ")):
        return [line]  # ACL scaffolding: retry once, then quarantine via memory
    if low.startswith(("snmp-server ", "ntp server ", "logging ")):
        return [line]  # management one-liners: retry once
    if low.startswith("hostname"):
        return [line]  # global one-liner: retry once
    if low.startswith("banner"):
        return [line]
    return [line]  # default: single retry, then skip


def _planned_cli_mode_after(line: str, mode: str) -> str:
    """Predict the prompt mode after one planned IOS command.

    This is planning metadata only.  The executor still verifies the actual
    prompt after typing each command before it advances the queue.
    """
    low = (line or "").strip().lower()
    if low == "enable":
        return "privileged"
    if low == "disable":
        return "user"
    if low in {"configure terminal", "conf t"}:
        return "config"
    if low == "end":
        return "privileged"
    if low in {"exit", "quit"}:
        if mode in _CLI_SUBMODES:
            return "config"
        if mode == "config":
            return "privileged"
        return "user"
    if low.startswith("interface "):
        return "interface"
    if low.startswith("router "):
        return "router"
    if low.startswith(("ip access-list ", "ipv6 access-list ")):
        return "acl"
    if low.startswith("line "):
        return "line"
    if low.startswith("vlan "):
        return "vlan"
    if low.startswith("time-range "):
        return "time_range"
    if low.startswith("ip dhcp pool "):
        return "dhcp"
    if low.startswith(("crypto isakmp policy ",
                       "crypto ipsec transform-set ")):
        return "crypto"
    if low.startswith("crypto map ") and "ipsec-isakmp" in low:
        # `crypto map ... ipsec-isakmp` enters crypto-map submode when it is
        # issued from global config.  The shorter `crypto map NAME` command
        # used later under an interface stays in interface mode.
        return "interface" if mode == "interface" else "crypto"
    return mode


def _compile_cli_queue(lines: list) -> list:
    """Compile the device's primary commands and bounded fallbacks first.

    Mode-entry commands are intentionally not injected here: the live mode
    state machine inserts them only when the verified prompt says they are
    needed.  The queue nevertheless records the required mode, planned mode
    after the command, and its precomputed fallback candidates.  This lets
    the executor avoid a second full OCR/context read when the previous
    command already proved that the next command can run in the same mode.
    """
    queue = []
    planned_mode = "privileged"
    planned_context = {}
    in_ospf = False
    trunk_armed = False
    for source_index, raw in enumerate(lines or []):
        source = str(raw).strip()
        if not source:
            continue
        low = source.lower()
        # A learned plan or an old generated prompt may still contain
        # `enable`/`configure terminal`.  These are state-machine operations,
        # never executable configuration items.  Filtering at compilation is
        # the last boundary that prevents a duplicate `configure terminal`
        # from being typed after the verified transition already succeeded.
        if low in MODE_ENTRY_COMMANDS:
            continue
        blocked = False
        if low == "end":
            # The final wrapper is useful only when the plan ended inside a
            # config mode.  Sending `end` at Router# is an avoidable error.
            if planned_mode == "privileged":
                continue
            required = planned_mode
        elif low in {"exit", "quit"}:
            # `exit` is valid only from an IOS submode in this executor.
            # Preserve the guard as a planned blocked item instead of letting
            # a mode mismatch turn it into an unsafe blind keystroke.
            blocked = planned_mode not in _CLI_SUBMODES
            required = planned_mode if not blocked else "blocked"
        else:
            required = _command_requirement(source, planned_context)
        after_mode = _planned_cli_mode_after(source, planned_mode)
        fallbacks = ([] if blocked else
                     _fallback_lines(source, in_ospf, trunk_armed))
        queue.append({
            "index": source_index,
            "source": source,
            "command": source,
            "required": required,
            "after_mode": after_mode,
            "fallbacks": list(fallbacks),
            "blocked": blocked,
        })
        if not blocked:
            planned_mode = after_mode
            _update_cli_context(planned_context, source, after_mode)
            if low.startswith("router ospf"):
                in_ospf = True
            if low == "switchport":
                trunk_armed = True
    return queue


def _open_device_window(rect, dev: str, slot: int, project: str):
    """Double-click canvas slot; return device window or None."""
    # The canvas click is just as dangerous as a CLI keystroke when another
    # app is covering Packet Tracer: it can open the wrong window or do
    # nothing while the run records an apparently valid click.
    try:
        main = find_pt_window()
        if not _focus_pt_window(main, phase=f"open {dev}"):
            log(f"{dev}: device open blocked - Packet Tracer is not in "
                "front")
            return None
    except Exception as exc:
        log(f"{dev}: could not verify Packet Tracer before open: {exc}")
        return None
    gx, gy, reused = _spot(project, dev, slot)
    log(f"open {dev} (double-click {'remembered' if reused else 'grid'} slot)")
    try:
        before = {str(getattr(w.element_info, "handle", id(w)))
                  for w in Desktop(backend="uia").windows()}
    except Exception:
        before = set()
    x, y = to_abs(rect, gx, gy)
    pyautogui.doubleClick(x, y)
    _interruptible_sleep(1.4)
    win = None
    try:
        after = Desktop(backend="uia").windows()
        for w in after:
            try:
                h = str(getattr(w.element_info, "handle", id(w)))
            except Exception:
                continue
            if h not in before:
                win = w
                break
    except Exception as e:
        log(f"window scan failed: {e}")
    if win is None:
        log(f"WARN {dev}: no new window after double-click "
            f"(spot may be empty or covered) - skipping CLI for {dev}")
        return None
    if not _focus_pt_window(win, dev, "device window"):
        log(f"{dev}: newly opened window is not owned by foreground "
            "Packet Tracer - skipping input")
        try:
            win.close()
        except Exception:
            pass
        return None
    # A newly opened device is a new CLI session.  Clear transition evidence
    # from a previous window, but do not clear it from helpers that keep the
    # same window open (capability probes, healing, and verification).
    _reset_cli_transition_state(dev)
    _interruptible_sleep(0.4)
    return win


def _handle_of(win) -> str:
    try:
        return str(getattr(win.element_info, "handle", ""))
    except Exception:
        return ""


def _close_device_window(win, dev: str):
    """Close a device window after its CLI run.

    Why: a leftover window covers the canvas, so the NEXT device's
    double-click lands on this window instead of the slot - no new
    window appears and every following device is skipped (user report:
    'configures one device then stops').
    """
    if win is None:
        return
    h = _handle_of(win)
    for attempt in (1, 2):
        try:
            win.close()
        except Exception:
            try:
                win.set_focus()
                win.type_keys("%{F4}")
            except Exception as e:
                log(f"{dev}: window close failed: {e}")
        _interruptible_sleep(0.8)
        gone = True
        if h:
            try:
                gone = all(_handle_of(w) != h
                           for w in Desktop(backend="uia").windows())
            except Exception:
                gone = True
        if gone:
            log(f"{dev}: device window closed (attempt {attempt})")
            return
    log(f"{dev}: WARN device window may still be open - continuing")


def _click_terminal_body(win, dev: str):
    """Focus keystrokes into the terminal pane itself (not just the tab)."""
    try:
        r = win.rectangle()
        w, h = r.right - r.left, r.bottom - r.top
        ok = _safe_click(r.left + int(w * 0.5), r.top + int(h * 0.55))
        _interruptible_sleep(0.4)
        return bool(ok and not stopped())
    except Exception as e:
        log(f"{dev}: terminal body click failed: {e}")
        return False


def _focus_cli_input(win, dev: str, phase: str = "CLI input") -> bool:
    """Focus PT plus the terminal body before any IOS keystroke."""
    if not _focus_pt_window(win, dev, phase):
        return False
    if not _click_terminal_body(win, dev):
        record_event("cli_focus_blocked",
                     "terminal body could not be focused; input blocked",
                     device=dev, recovered=False,
                     extra={"phase": phase})
        return False
    # Clicking the body should retain the PT foreground.  Recheck it because
    # an overlay can appear between the first focus operation and the click.
    return _focus_pt_window(win, dev, phase)


def _focus_cli_tab(win, dev: str) -> bool:
    """Land on the device CLI tab: UIA 'CLI' first, tab-strip fallback."""
    if not _focus_pt_window(win, dev, "CLI tab"):
        return False
    try:
        handle = win.element_info.handle
    except Exception:
        handle = None

    def cli_tab_is_active() -> bool:
        """Read Packet Tracer's active tab, not merely a tab item name."""
        try:
            source = (Desktop(backend="uia").window(handle=handle)
                      if handle is not None else win)
            for item in source.descendants():
                if item.element_info.control_type != "Tab":
                    continue
                name = (_uia_name(item) or _uia_window_text(item)).strip()
                if name:
                    return name.lower() == "cli"
        except Exception:
            pass
        return False

    def find_and_select_cli() -> bool:
        # The whole find+click runs on one bounded worker thread: a UIA
        # element created on another thread can be unusable from the main
        # thread, and a stalled provider must not freeze the CLI phase.
        source = (Desktop(backend="uia").window(handle=handle)
                  if handle is not None else win)
        target = None
        for d in source.descendants():
            try:
                nm = (d.element_info.name or "")
            except Exception:
                continue
            if nm.strip().lower() != "cli":
                continue
            if d.element_info.control_type != "TabItem":
                continue
            target = d
            break
        if target is None:
            return False
        try:
            r = target.rectangle()
            log(f"{dev}: CLI tab at ({(r.left + r.right)//2},"
                f"{(r.top + r.bottom)//2})")
        except Exception:
            pass
        # Packet Tracer exposes SelectionItem on this Qt tab. A mouse click
        # can return successfully while leaving the parent on Config; that
        # false-positive made the executor read Equivalent IOS Commands and
        # skip router configuration. Verify the parent tab after each
        # bounded activation method.
        for action in ("select", "click_input", "invoke", "click"):
            try:
                getattr(target, action)()
            except Exception:
                continue
            _interruptible_sleep(0.35)
            if cli_tab_is_active():
                return True
        return False

    try:
        clicked = _bounded_call(find_and_select_cli, 6.0, "CLI tab scan")
    except Exception as e:
        log(f"{dev}: CLI tab scan failed: {e}")
        clicked = False
    if clicked:
        _interruptible_sleep(0.8)
        return _focus_cli_input(win, dev, "CLI tab")
    # fallback: use the actual tab strip, then verify the parent tab. The
    # previous 55%/16% coordinate landed in the Config pane on PT 9.0.
    try:
        r = win.rectangle()
        w, h = r.right - r.left, r.bottom - r.top
        _safe_click(r.left + int(w * 0.22), r.top + int(h * 0.02))
        _interruptible_sleep(0.4)
        for _ in range(5):
            _safe_hotkey("ctrl", "tab")
            _interruptible_sleep(0.2)
            if cli_tab_is_active():
                return _focus_cli_input(win, dev, "CLI tab fallback")
        # click terminal body to focus keystrokes
        if not _focus_cli_input(win, dev, "CLI tab fallback"):
            return False
        if not cli_tab_is_active():
            log(f"{dev}: CLI tab fallback did not verify active CLI tab")
            return False
        log(f"{dev}: CLI tab via fallback clicks")
        return True
    except Exception as e:
        log(f"{dev}: CLI focus failed: {e}")
        return False


def _answer_line(win, dev: str, text: str, delay_ms: int):
    """Type one short answer (no/error recovery needed).

    The boot console drops keystrokes while rendering - a 0.3s settle
    + slower interval keeps the answer from being eaten (user
    screenshot: empty answer -> '% Please answer yes or no').
    """
    # The setup dialog is not a normal IOS prompt. Re-focus the actual
    # terminal immediately before answering; the device window can lose
    # keyboard focus while OCR is reading it. A leading space is deliberate
    # first-character insurance for Packet Tracer's freshly-rendered console.
    if not _focus_cli_input(win, dev, "boot answer"):
        return False
    _interruptible_sleep(0.3)
    _safe_press("space")
    _interruptible_sleep(0.12)
    answer = str(text).strip()
    for start in range(0, len(answer), 2):
        if stopped():
            return False
        _safe_write(answer[start:start + 2], interval=0.08)
        _interruptible_sleep(0.08)
    _interruptible_sleep(0.2)
    _safe_press("enter")
    _interruptible_sleep(max(1.2, 0.8 + delay_ms / 1000.0))
    return not stopped()


def _confirmed_state(win, dev: str = "") -> tuple:
    """Read the terminal and return (state, text).

    OCR (screen pixels) is primary, but a non-empty startup crop is not
    enough evidence by itself. If the main crop is still user mode or has
    no recognizable mode, read a tighter lower prompt band and combine it
    with UIA text before falling back to the bounded double-read path. This
    handles both light PT CLI themes and the common repaint where OCR sees
    ``Router> enable`` but misses the newer ``Router#`` row.
    """
    # Do not OCR a covering Codex/browser window and then use that text as
    # evidence for an IOS prompt.  Deterministic tests may use a marked UI
    # double, but a production window must pass the native focus boundary
    # before its pixels can be treated as IOS evidence.
    if _ui_window_handle(win) and not _focus_pt_window(win, dev,
                                                       "CLI read"):
        return "unknown", ""
    try:
        ocr = _ocr_region(win)
    except Exception:
        ocr = ""
    ocr_state = _term_state(ocr) if ocr.strip() else "unknown"
    ocr_mode = _cli_prompt_mode(ocr) if ocr_state == "cli" else "unknown"
    if ocr_state != "unknown" and ocr_mode not in {"user", "unknown"}:
        return ocr_state, ocr
    prompt_ocr = ""
    try:
        # The final prompt is small and sits near the bottom of the pane.
        # A tight psm-6 read preserves the '#' in Router# on light PT
        # screenshots; the sparse psm-11 read catches isolated prompt rows.
        prompt_reads = [
            _ocr_region(win, 0.82, 0.94, ttl=0, psm=6),
            _ocr_region(win, 0.82, 0.94, ttl=0, psm=11),
        ]
        prompt_ocr = "\n".join(value for value in prompt_reads
                                if value.strip())
    except Exception:
        pass
    if prompt_ocr.strip():
        combined_ocr = "\n".join(
            value for value in (ocr, prompt_ocr) if value.strip()
        )
        prompt_state = _term_state(combined_ocr)
        if prompt_state != "unknown":
            return prompt_state, combined_ocr
    if ocr_state != "unknown":
        return ocr_state, ocr
    try:
        t1 = _term_texts(win)
    except Exception:
        t1 = ""
    _interruptible_sleep(0.5)
    try:
        t2 = _term_texts(win)
    except Exception:
        t2 = ""
    combined1 = "\n".join(value for value in (ocr, t1) if value.strip())
    combined2 = "\n".join(value for value in (ocr, prompt_ocr, t2)
                            if value.strip())
    s1, s2 = _term_state(combined1), _term_state(combined2)
    if s1 == s2 and t2.strip():
        return s1, combined2
    if not t2.strip():
        return "unknown", combined2
    return "unknown", combined2  # texts disagree (screen mid-refresh)


def _prompt_seen(text: str) -> bool:
    lines = [line for line in (text or "").splitlines() if line.strip()]
    return _last_prompt_pos(lines) >= 0


def _live_prompt_after_boot(text: str) -> bool:
    """Return true only when an IOS prompt is newer than boot-dialog text."""
    lines = [line for line in (text or "").lower().splitlines()
             if line.strip()]
    if not lines:
        return False
    prompt_pos = _last_prompt_pos(lines)
    boot_pos = max(
        _last_marker_pos(lines, SETUP_MARKERS),
        _last_marker_pos(lines, ("terminate autoinstall",)),
        _last_marker_pos(lines, ("press return", "return to get started")),
    )
    return prompt_pos >= 0 and prompt_pos > boot_pos and _prompt_seen(text)


_CLI_MODE_LATCH: dict = {}       # dev -> last verified CLI mode
_CLI_ENABLE_ATTEMPTS: dict = {}  # dev -> bounded enable attempts
_BOOT_RETURN_ATTEMPTS: dict = {} # dev -> presses sent while at Press RETURN


def _reset_cli_transition_state(dev: str):
    """Forget prompt/boot transition evidence for a newly opened window."""
    _CLI_MODE_LATCH.pop(dev, None)
    _CLI_ENABLE_ATTEMPTS.pop(dev, None)
    _BOOT_RETURN_ATTEMPTS.pop(dev, None)


def _focus_boot_terminal(win, dev: str) -> bool:
    """Refocus the actual console before sending the boot Return key."""
    return _focus_cli_input(win, dev, "boot Return")


def _finish_boot_return(win, dev: str, delay_ms: int = 25) -> bool:
    """Release a confirmed ``Press RETURN`` prompt and verify IOS CLI.

    Packet Tracer can leave the terminal focused on the tab chrome after the
    setup answer.  Sending Return through that focus does nothing, leaving
    the run visibly stopped at ``Press RETURN``.  This helper focuses the
    terminal itself, sends at most two bounded Return attempts, and requires a
    fresh live-prompt read before reporting success.
    """
    try:
        _OCR_CACHE.clear()
        state, text = _confirmed_state(win, dev)
    except Exception:
        state, text = "unknown", ""
    if state == "cli" and _prompt_seen(text):
        return True
    if state != "return":
        return False
    attempts = int(_BOOT_RETURN_ATTEMPTS.get(dev, 0))
    if attempts >= 2:
        record_event("boot_return_blocked",
                     "Press RETURN stayed active after bounded attempts",
                     device=dev, recovered=False)
        return False
    if not _focus_boot_terminal(win, dev):
        record_event("boot_return_blocked",
                     "Packet Tracer terminal focus was not proven before "
                     "sending Return",
                     device=dev, recovered=False)
        return False
    _BOOT_RETURN_ATTEMPTS[dev] = attempts + 1
    log(f"{dev}: confirmed Press RETURN - sending Enter "
        f"(attempt {attempts + 1}/2)")
    if not _safe_press("enter"):
        return False
    _interruptible_sleep(max(1.2, 1.0 + delay_ms / 1000.0))
    _OCR_CACHE.clear()
    for _ in range(3):
        try:
            state, text = _confirmed_state(win, dev)
        except Exception:
            state, text = "unknown", ""
        if state == "cli" and _prompt_seen(text):
            log(f"{dev}: boot Return completed - live CLI verified")
            record_event("boot_return_verified",
                         "Press RETURN released and live CLI verified",
                         device=dev, recovered=True)
            return True
        if state != "return":
            _interruptible_sleep(0.8)
        else:
            _interruptible_sleep(0.8)
        _OCR_CACHE.clear()
    record_event("boot_return_pending",
                 "Return was sent but live CLI is not visible yet",
                 device=dev, recovered=False)
    return False


_NO_ANSWERS: dict = {}  # dev -> count of `no` answers (cap per device)
_NO_SENT: set = set()   # hard latch: never type a duplicate `no` for a device


def _answer_no_once(win, dev: str, delay_ms: int, why: str,
                    budget: int = 4) -> bool:
    """Answer one `no` to a CONFIRMED setup dialog, then VERIFY exit.

    Exit now REQUIRES a live prompt to be visible - the old check
    (anything != setup) counted blank/garbage OCR reads during boot
    rendering as 'exited', burned the budget, and left the dialog
    active (user log: R2 typed entirely into the dialog). Budget is 4:
    the scrollback-aware classifier only routes CONFIRMED dialogs here,
    so extra answers are safe; the cap still prevents spamming.
    """
    # Refresh immediately before typing. OCR used by the caller can be one
    # repaint behind: the first `no` may already have produced Router>, and
    # blindly answering a stale setup read at Router> becomes `Router> no`
    # and starts IOS DNS translation.
    try:
        _OCR_CACHE.clear()
        pre_state, pre_text = _confirmed_state(win, dev)
    except Exception:
        pre_state, pre_text = "unknown", ""
    if _live_prompt_after_boot(pre_text):
        log(f"{dev}: live prompt already visible before `no`; skipping "
            f"stale setup answer ({why})")
        record_event("setup_dialog", "stale setup read ignored; live prompt "
                     "already visible", device=dev, recovered=True,
                     extra={"why": why})
        return True
    if dev in _NO_SENT:
        log(f"{dev}: setup answer already sent; refusing duplicate `no` "
            f"({why})")
        record_event("setup_dialog", "duplicate setup answer blocked",
                     device=dev, recovered=True, extra={"why": why})
        return False
    used = _NO_ANSWERS.get(dev, 0)
    if used >= budget:
        log(f"{dev}: no-answer budget spent ({used}) - NOT answering ({why})")
        return False
    _NO_ANSWERS[dev] = used + 1
    _NO_SENT.add(dev)
    log(f"{dev}: setup CONFIRMED - answering `no` (#{used + 1}, {why})")
    if not _answer_line(win, dev, "no", delay_ms):
        return False
    # Patient verification: right after `no` the echo renders slowly, so
    # quick reads classified the (already answered) dialog as still
    # present - 8 false 'still present' events in the journal. Wait for
    # the prompt line to appear instead.
    for v in range(6):
        _interruptible_sleep(1.2)
        try:
            st, text = _confirmed_state(win, dev)
        except Exception:
            st, text = "unknown", ""
        if _live_prompt_after_boot(text):
            log(f"{dev}: dialog exited after `no` (live prompt seen)")
            RUN["setup_no"] = RUN.get("setup_no", 0) + 1
            record_event("setup_dialog", "answered no, dialog exited",
                         device=dev, recovered=True, extra={"why": why})
            return True
        if st == "return" and _finish_boot_return(win, dev, delay_ms):
            RUN["setup_no"] = RUN.get("setup_no", 0) + 1
            record_event("setup_dialog", "answered no and boot Return exited",
                         device=dev, recovered=True, extra={"why": why})
            return True
    log(f"{dev}: dialog STILL present after `no` (state unclear) - "
        f"continuing anyway")
    record_event("setup_dialog", "no answered but dialog still present",
                 device=dev, recovered=False, extra={"why": why})
    return False


def _abort_dns_hang(win, dev: str, text: str = "") -> bool:
    """Abort an IOS DNS 'Translating' hang with the break key.

    A stray command at a live prompt (e.g. the transition race that
    typed `Router>no`) hangs the console on 'Translating "no"...domain
    server (255.255.255.255)' for ~30s+. Ctrl+Shift+6 (IOS break)
    cancels it immediately. Returns True if a hang was found+aborted.
    """
    low = (text or "").lower()
    if "domain server" not in low and "translating \"" not in low:
        try:
            _OCR_CACHE.clear()
            low = (_ocr_region(win) or "").lower()
        except Exception:
            return False
    if "domain server" not in low and "translating \"" not in low:
        return False
    try:
        if not _focus_cli_input(win, dev, "DNS hang recovery"):
            return False
        _safe_hotkey("ctrl", "shift", "6")
        _interruptible_sleep(1.0)
        _safe_press("enter")
        _interruptible_sleep(0.8)
        log(f"{dev}: DNS Translating hang detected - aborted with "
            f"Ctrl+Shift+6")
        record_event("dns_hang_aborted",
                     "stray command at prompt aborted via break key",
                     device=dev, recovered=True)
        return True
    except Exception as e:
        log(f"{dev}: DNS abort failed: {e}")
        return False


def _settle_boot_dialogs(win, dev: str, rounds: int = 12) -> bool:
    """Drive boot Q&A until live CLI. Returns False if stuck.

    Fresh 2911: [Press RETURN] -> setup dialog [yes/no] -> (answer no) ->
    Router>. Empty/unreadable screens NEVER count as ready on early
    rounds (that miss caused every config line to be eaten as dialog
    answers). `no` answers are confirmed + verified + capped (see above).

    Unreadable-screen fix (user screenshot: commands typed INTO the
    [yes/no] prompt, first `no` never sent): when UIA text stays
    "unknown" for 3 straight rounds, answer one budget-capped `no`
    anyway - a freshly booted PT router ALWAYS shows the setup dialog
    right after RETURN, so an unreadable screen at this point is that
    dialog, not a live prompt. _answer_no_once verifies the exit after.
    """
    _NO_ANSWERS[dev] = 0
    _NO_SENT.discard(dev)
    unknown_streak = 0
    for r in range(rounds):
        if stopped():
            return False
        try:
            st, text = _confirmed_state(win, dev)
        except Exception:
            st, text = "unknown", ""
        tail = text[-120:].replace("\n", " ") if text.strip() else "<unreadable>"
        # a stray command may have hung the console on a DNS lookup
        if "domain server" in (text or "").lower():
            _abort_dns_hang(win, dev, text)
            continue
        if st == "setup":
            unknown_streak = 0
            dl = next((l.strip()[:90] for l in text.lower().splitlines()
                       if any(m in l for m in SETUP_MARKERS)), "setup dialog")
            log(f"{dev}: SETUP DIALOG seen: '{dl}' - answering no")
            if not _answer_no_once(win, dev, 25, f"settle round {r + 1}"):
                # budget spent but dialog STILL confirmed: never hot-spin
                _interruptible_sleep(1.5)
            continue
        if st == "autoinstall":
            unknown_streak = 0
            log(f"{dev}: autoinstall prompt - Enter for default yes ({r + 1})")
            if not _focus_cli_input(win, dev, "autoinstall prompt"):
                log(f"{dev}: autoinstall response blocked - terminal "
                    "focus was not proven")
                return False
            _safe_press("enter")
            _interruptible_sleep(1.5)
            continue
        if st == "return":
            unknown_streak = 0
            log(f"{dev}: boot prompt detected ({r + 1})")
            _finish_boot_return(win, dev, 25)
            continue
        if st == "cli" and _prompt_seen(text):
            log(f"{dev}: live CLI ready: ...{tail[-90:]}")
            return True
        if st == "unknown":
            unknown_streak += 1
            log(f"{dev}: settle round {r + 1}: screen unreadable "
                f"({unknown_streak}x) - waiting")
            if unknown_streak >= 3:
                # unreadable this long right after boot = setup dialog
                # we cannot see. Budget-capped + exit-verified `no`:
                log(f"{dev}: screen unreadable {unknown_streak} rounds "
                    f"after boot - assuming setup dialog, answering `no`")
                if _answer_no_once(win, dev, 25,
                                   f"unreadable-screen fallback r{r + 1}"):
                    log(f"{dev}: `no` accepted, screen now readable - "
                        f"continuing settle")
                unknown_streak = 0
            _interruptible_sleep(1.2)
            continue
        unknown_streak = 0
        log(f"{dev}: settle round {r + 1}: {st} (...{tail[-60:]}) - waiting")
        _interruptible_sleep(1.0)
    # LAST RESORT GUARD: if the setup dialog is STILL the active prompt,
    # never type the config into it (that wasted 2 minutes typing garbage
    # into the dialog - user log). Try Ctrl+C (aborts IOS setup), then
    # abort the device cleanly.
    try:
        st, final_text = _confirmed_state(win, dev)
    except Exception:
        st, final_text = "unknown", ""
    if st == "setup":
        try:
            log(f"{dev}: dialog active after settle - trying Ctrl+C abort")
            if not _focus_cli_input(win, dev, "setup abort"):
                return False
            _safe_hotkey("ctrl", "c")
            _interruptible_sleep(2.0)
            st, _ = _confirmed_state(win, dev)
        except Exception:
            pass
        if st == "setup":
            log(f"{dev}: setup dialog UNRESOLVABLE - aborting this device")
            record_event("setup_unresolvable",
                         "dialog active after 4 no-answers + Ctrl+C - "
                         "device skipped (re-run Cables + CLI)",
                         device=dev, recovered=False)
            return False
    if st == "return":
        # Never fall through to blind configuration while the console is
        # still waiting for Return.  That would leave the router appearing
        # frozen and could feed the first config line into the boot prompt.
        # Capture the screen first: the 2026-09-16 run reached this dead end
        # ten times on HQ_Router and left no evidence, so a genuinely
        # un-booted console could not be told apart from an OCR ordering
        # artefact.  The shot plus the OCR tail settle it next time.
        shot = f"{_safe_stem(dev)}_boot_return_fail.png"
        _fail_shot(win, shot)
        log(f"{dev}: Press RETURN still active after bounded attempts - "
            "aborting device safely")
        record_event("boot_return_unresolvable",
                     "device remained at Press RETURN; CLI config skipped",
                     device=dev, recovered=False,
                     extra={"shot": f"shots/{shot}",
                            "tail": (final_text or "")[-180:]})
        return False
    # A repaint that does not contain a recognizable prompt is not proof of
    # CLI readiness.  Never type configuration into an unknown boot screen.
    log(f"{dev}: no verified live CLI after {rounds} rounds - aborting device")
    shot = f"{_safe_stem(dev)}_cli_unresolvable.png"
    _fail_shot(win, shot)
    record_event("cli_unresolvable",
                 "live IOS prompt was not verified after boot transition",
                 device=dev, recovered=False,
                 extra={"state": st, "shot": f"shots/{shot}",
                        "tail": (final_text or "")[-180:]})
    return False


def _full_ifname(spec: str):
    """'g0/0' -> 'gigabitethernet0/0', 'f0/1' -> 'fastethernet0/1'."""
    s = (spec or "").strip().lower().replace(" ", "")
    for pre, full in (("gigabitethernet", "gigabitethernet"),
                      ("fastethernet", "fastethernet"),
                      ("serial", "serial"),
                      ("g", "gigabitethernet"),
                      ("f", "fastethernet"),
                      ("s", "serial")):
        if s.startswith(pre):
            return full + s[len(pre):]
    return None


def _iface_no_shut_lines(cfg: str) -> list:
    """(interface X, no shutdown) pairs for every iface the CONFIG wanted
    up. Names come from the config text (exact), never from OCR."""
    out, cur = [], None
    for raw in (cfg or "").splitlines():
        t = raw.strip()
        tl = t.lower()
        if tl.startswith("!") or not t:
            continue
        if tl.startswith("interface "):
            cur = t
            continue
        if cur and (tl.startswith(("router ", "line ", "end"))
                    or tl.startswith("!")):
            cur = None
            continue
        if cur and tl.startswith("no shut"):
            out.extend([cur, "no shutdown"])
            cur = None
    return out


def _heal_admin_down(win, dev: str, cfg: str, delay_ms: int,
                     cabled: list):
    """Re-apply no-shutdown ONLY on CABLED ports that show admin-down.

    Bug this fixes: unused router ports (Gi0/1, Gi0/2, Vlan1) ALWAYS show
    'administratively down' in show ip int brief - the old check healed
    on ANY admin-down text, typed 'interface g0/0' at the EXEC prompt
    (Invalid input) and never entered config mode. Now: match the
    interface's FULL name + 'administratively' in the same screen, wrap
    in conf t/end, and only touch ports the intent actually cabled.
    """
    if not cabled:
        return
    try:
        _OCR_CACHE.clear()
        vtxt = _term_texts(win)
    except Exception:
        return
    flat = " ".join((vtxt or "").split()).lower()
    to_heal = []
    for spec in cabled:
        full = _full_ifname(spec)
        if full and re.search(re.escape(full) + r".{0,60}?administrat",
                              flat):
            to_heal.append(spec)
    if not to_heal:
        return
    lines = ["configure terminal"]
    for spec in to_heal:
        lines.extend([f"interface {spec}", "no shutdown"])
    lines.append("end")
    log(f"{dev}: ADMIN-DOWN on cabled port(s) {to_heal} - healing")
    heal_context = {}
    for h in lines:
        if stopped():
            break
        try:
            # `end` is a state transition, not an ordinary line.  The
            # previous heal path could trust its local context and type it
            # after OCR had already repainted Router#, which either produced
            # an error or, with DNS lookup enabled, a translation hang.
            if h.strip().lower() in {"end", "exit", "quit"}:
                transition, observed = _guard_cli_transition(
                    win, dev, h, heal_context.get("mode", ""))
                if observed != "unknown":
                    heal_context["mode"] = observed
                    _CLI_MODE_LATCH[dev] = observed
                    _update_cli_context(heal_context, h, observed)
                if transition == "skip":
                    continue
                if transition != "allow":
                    record_event(
                        "admin_down_heal_blocked",
                        f"skipped '{h}' because its CLI transition was not "
                        "proven",
                        device=dev, recovered=False,
                    )
                    break
            if not _ensure_cli_context(win, dev, h, heal_context, delay_ms):
                record_event("admin_down_heal_blocked",
                             f"skipped '{h}' because its CLI mode was not "
                             "verified",
                             device=dev, recovered=False)
                break
            _type_line(h, delay_ms, win=win, dev=dev)
            _OCR_CACHE.clear()
            try:
                _, heal_text = _confirmed_state(win, dev)
                _update_cli_context(heal_context, h,
                                    _cli_prompt_mode(heal_text))
            except Exception:
                heal_context.clear()
        except Exception:
            break
    RUN["admin_heals"] = RUN.get("admin_heals", 0) + 1
    record_event("admin_down", f"healed cabled ports {to_heal}",
                 device=dev, recovered=True)


def _interface_specs(cfg: str) -> list:
    specs = []
    for raw in (cfg or "").splitlines():
        line = raw.strip()
        if line.lower().startswith("interface "):
            spec = line.split(None, 1)[1].strip()
            if not spec.lower().startswith("range "):
                specs.append(spec)
    return specs


def _mark_interface_blocked(dev: str) -> bool:
    """Count one device once even when link and CLI preflight both see it."""
    devices = RUN.setdefault("interface_blocked_devices", [])
    if dev in devices:
        return False
    devices.append(dev)
    RUN["interfaces_blocked"] = RUN.get("interfaces_blocked", 0) + 1
    return True


def _available_interfaces(text: str) -> set:
    """Extract physical interface names visible in `show ip int brief`.

    Packet Tracer's light terminal is small enough that Tesseract may read
    ``Gi0/1`` as ``GigabitEtherneto/1`` or put spaces around the slashes.
    Normalize those OCR-only variations, but require a device-interface
    prefix and numeric path before accepting a capability.  An unreadable
    row therefore remains a safety block instead of becoming a guessed port.
    """
    found = set()
    low = (text or "").lower()

    def number(value: str) -> str:
        value = (value or "").lower().translate(str.maketrans({
            "o": "0", "l": "1", "i": "1", "|": "1", "s": "5",
        }))
        return value if value.isdigit() else ""

    def add(prefix: str, parts: tuple[str, ...]):
        nums = tuple(number(part) for part in parts)
        if not nums or any(not part for part in nums):
            return
        found.add(prefix + "/".join(nums))

    # Read complete names first.  The shortened `...Etherne` forms cover a
    # frequent final-character drop at the right edge of an OCR row.
    full_patterns = (
        ("gigabitethernet", r"gigabitethernet|gigabitetherne"),
        ("fastethernet", r"fastethernet|fastetherne"),
        ("serial", r"serial"),
        ("ethernet", r"ethernet"),
        ("port-channel", r"port[ -]?channel"),
    )
    path = r"([o0-9il|s]+)\s*/\s*([o0-9il|s]+)"
    path3 = path + r"\s*/\s*([o0-9il|s]+)"
    for canonical, pattern in full_patterns:
        for m in re.finditer(
                r"(?<![a-z0-9])(?:" + pattern + r")\s*"
                r"(?:" + path3 + r"|" + path + r")",
                low, re.IGNORECASE):
            groups = m.groups()
            # The alternation places the three-part capture before the
            # two-part capture.  Ignore empty groups from the unused branch.
            parts = tuple(value for value in groups if value is not None)
            add(canonical, parts)

    # Short IOS abbreviations are useful when the full interface name was
    # clipped or OCR'd as `Gi`/`Fa`/`Se`.
    short_prefixes = (
        ("gigabitethernet", r"gi|gig|g"),
        ("fastethernet", r"fa|fast|f"),
        ("serial", r"se|ser|s"),
        ("ethernet", r"eth|e"),
        ("port-channel", r"po"),
    )
    for canonical, pattern in short_prefixes:
        for m in re.finditer(
                r"(?<![a-z0-9])(?:" + pattern + r")\s*"
                r"(?:" + path3 + r"|" + path + r")",
                low, re.IGNORECASE):
            groups = m.groups()
            parts = tuple(value for value in groups if value is not None)
            add(canonical, parts)
    return found


def _read_interface_capabilities(win) -> tuple[set, str]:
    """Read the interface table with bounded, lower-pane OCR fallbacks."""
    reads = []
    # The normal read is retained for UIA text and the established crop.
    try:
        reads.append(_term_texts(win))
    except Exception:
        pass
    available = _available_interfaces("\n".join(reads))
    if available:
        return available, "\n".join(reads)

    # Interface rows sit below the boot banner and can be outside the first
    # crop after a long IOS banner.  These six bounded reads cover both the
    # whole lower terminal and the compact final prompt/table band.  Stop as
    # soon as one scan proves a real interface name.
    bands = (
        (0.12, 0.99, 6),
        (0.55, 0.99, 6),
        (0.68, 0.995, 6),
        (0.78, 0.995, 6),
        (0.55, 0.99, 11),
        (0.68, 0.995, 11),
    )
    for fy0, fy1, psm in bands:
        try:
            value = _ocr_region(win, fy0, fy1, fx0=0.02, fx1=0.98,
                                ttl=0, psm=psm)
        except Exception:
            value = ""
        if value.strip():
            reads.append(value)
            available = _available_interfaces("\n".join(reads))
            if available:
                break
    return available, "\n".join(reads)


def _filter_unavailable_interface_blocks(lines: list, cfg: str, dev: str,
                                         available: set) -> tuple:
    """Remove only blocks for interfaces absent on the live device.

    This prevents a missing 2911 serial module from turning one bad
    `interface s0/0/0` into dozens of follow-on errors.  The run remains
    failed with a precise prerequisite instead of pretending the WAN exists.
    """
    wanted = _interface_specs(cfg)
    blocked = set()
    for spec in wanted:
        full = _full_ifname(spec)
        if full and full not in available:
            blocked.add(full)
    if not blocked:
        return lines, []
    out = []
    skip = False
    current = None
    for line in lines:
        low = line.strip().lower()
        if low.startswith("interface "):
            current = line.split(None, 1)[1].strip()
            skip = (_full_ifname(current) in blocked
                    if not current.lower().startswith("range ") else False)
            if not skip:
                out.append(line)
            continue
        if skip:
            if low == "exit":
                skip = False
            continue
        out.append(line)
    for full in sorted(blocked):
        log(f"{dev}: interface {full} is absent on the live device - "
            f"skipping its config block; {SERIAL_MODULE_HINT}")
        record_event("serial_module_hint", SERIAL_MODULE_HINT, device=dev)
        record_event("interface_unavailable",
                     f"{full} absent; dependent commands were not typed",
                     device=dev, recovered=False)
    _mark_interface_blocked(dev)
    return out, sorted(blocked)


def _cli_prompt_mode(text: str) -> str:
    """Classify the newest IOS prompt into a safe command context."""
    lines = [line.strip().lower() for line in (text or "").splitlines()
             if line.strip()]
    # In the light Packet Tracer repaint shown by the user, Tesseract reads
    # `Router> enable Router#` as `Router> enable Routert`/`Router?`.  Check
    # this before the ordinary prompt loop, because that loop would quite
    # correctly classify the echoed `Router> enable` prefix as user mode.
    low = " ".join((text or "").lower().split())
    if re.search(
            r"(?:router|route|jouter|switch|swit)[^\s]{0,8}[>t]\s+enable\b"
            r".*(?:router|route|jouter|switch|swit)[a-z0-9_-]{0,3}[?:tf]"
            r"(?:\s|$)", low):
        return "privileged"
    for raw in reversed(lines):
        # OCR may insert spaces around the prompt marker and may capture the
        # command echo on the same row (``Router# enable``). Parse the IOS
        # prompt prefix instead of requiring the whole OCR row to be only a
        # prompt. This prevents an older Router> row from causing repeated
        # enable commands after the device is already at Router#.
        prompt = _ios_prompt_parts(raw)
        if not prompt:
            continue
        context_name = prompt["context"]
        marker = prompt["marker"]
        if context_name:
            if "(config-if" in context_name:
                return "interface"
            if "(config-router" in context_name:
                return "router"
            if "(config-ext-nacl" in context_name or \
                    "(config-std-nacl" in context_name:
                return "acl"
            if "(config-line" in context_name:
                return "line"
            if "(config-vlan" in context_name:
                return "vlan"
            if "config-isakmp" in context_name or \
                    "config-crypto" in context_name or \
                    "config-pmap" in context_name or \
                    "config-ipsec" in context_name:
                return "crypto"
            if "config-time-range" in context_name:
                return "time_range"
            if "config-dhcp" in context_name:
                return "dhcp"
            if context_name.startswith("(config"):
                return "config"
        if marker in {"#", "g", "+", "$", "4", "}"}:
            return "privileged"
        if marker == ">" or marker in {"t", "?"}:
            # In the light Packet Tracer terminal a real `>` is often read
            # as `t` or `?`.  Treat the uncertain glyph as user mode, not as
            # privileged mode: a harmless `enable` retry can recover it,
            # while treating it as `#` could send configuration at Router>.
            return "user"
        # Keep the loop conservative if a future OCR marker is introduced.
        continue
    return "unknown"


def _command_requirement(line: str, context: dict) -> str:
    """Return the prompt mode required before one IOS command."""
    low = (line or "").strip().lower()
    if not low:
        return "live"
    if low in {"enable", "disable", "end", "exit", "quit"}:
        # Never send `end` at Router>; IOS interprets it as an unknown
        # command and Packet Tracer may start DNS translation.
        return "privileged" if low == "end" else "live"
    if low in {"configure terminal", "conf t"}:
        return "privileged"
    if low.startswith(("show ", "write ", "copy ", "erase ")):
        return "privileged"
    if low.startswith((
            "encr ", "hash ", "authentication pre-share", "group ",
            "set peer ", "set transform-set ", "match address ")):
        return "crypto"
    if low.startswith("periodic "):
        return "time_range"
    if context.get("kind") == "dhcp" and low.startswith((
            "network ", "default-router ", "dns-server ", "lease ")):
        return "dhcp"
    if low.startswith("crypto map "):
        # A crypto map entry is created at global config, while applying the
        # completed map to an interface remains an interface command.
        return "interface" if context.get("kind") == "interface" \
            else "config"
    if low.startswith((
            "interface ", "router ", "ip access-list ",
            "ipv6 access-list ", "line ", "vlan ",
            "crypto isakmp policy", "crypto ipsec transform-set",
            "ip dhcp pool ", "ip route ", "ip default-network ",
            "ip dhcp excluded-address ", "access-list ", "aaa ",
            "crypto ", "snmp-server ", "logging ", "service ",
            "hostname ", "no ip domain-lookup")):
        return "config"
    if low.startswith(("network ", "passive-interface ",
                       "default-information ", "redistribute ")):
        return "router"
    if low.startswith(("permit ", "deny ")):
        return "acl"
    if low.startswith(("login ", "login", "transport input", "access-class ",
                       "exec-timeout ", "password ")):
        return "line"
    if low.startswith(("enable secret", "enable password")):
        # Typed at Router# the secret silently errors; it is a global
        # config command like hostname.
        return "config"
    if low.startswith(("banner ", "ip domain-name ", "ip name-server ",
                       "ip default-gateway ")):
        return "config"
    if low.startswith((
            "description ", "ip address ", "ipv6 address ",
            "no shutdown", "shutdown", "switchport", "encapsulation ",
            "ip helper-address ", "duplex ", "speed ",
            "ip ospf ")):
        # These are interface commands in the generated Packet Tracer
        # configurations. If the interface anchor was lost, the caller must
        # block the command instead of typing it at global config mode.
        return "interface"
    return "live"


def _prompt_matches(required: str, actual: str) -> bool:
    if required in {"live", "any"}:
        return actual != "unknown"
    if required == "privileged":
        return actual == "privileged"
    if required == "config":
        return actual == "config"
    return actual == required


def _mode_send(win, dev: str, command: str, delay_ms: int,
               expected: str | None = None) -> str:
    """Send one context-repair command and return the observed prompt mode."""
    if stopped():
        return "unknown"
    try:
        baseline_errors, _ = _term_error_signature(win)
    except Exception:
        baseline_errors = 0
    if not _type_line(command, delay_ms, win=win, dev=dev):
        record_event("cli_context_blocked",
                     f"mode repair '{command}' was not typed because "
                     "Packet Tracer focus was not proven",
                     device=dev, recovered=False,
                     extra={"command": command, "expected": expected or ""})
        return "unknown"
    # Do not trust the first OCR frame after a mode command. Packet Tracer
    # often paints the old ``Switch>`` row before the new ``Switch#`` row.
    # Poll a small, bounded number of fresh frames; never answer an old user
    # prompt by sending another enable.
    mode = "unknown"
    text = ""
    for pause in (0.55, 0.70, 0.90):
        _interruptible_sleep(pause)
        _OCR_CACHE.clear()
        try:
            _, text = _confirmed_state(win, dev)
            mode = _cli_prompt_mode(text)
        except Exception:
            pass
        if expected and _prompt_matches(expected, mode):
            _CLI_MODE_LATCH[dev] = mode
            if command.strip().lower() == "enable":
                _CLI_ENABLE_ATTEMPTS[dev] = max(
                    1, int(_CLI_ENABLE_ATTEMPTS.get(dev, 0)))
            return mode

        # A mode-entry command has a deterministic IOS transition.  The
        # terminal frequently repaints an older prompt over the fresh one,
        # so requiring OCR to name the new mode made a valid `configure
        # terminal` look like Router# and caused the next repair to type a
        # second `configure terminal` at Router(config)#.  Accept the
        # transition only when Packet Tracer is still a live CLI, no new
        # terminal error appeared, and no DNS/setup hang is visible.  This
        # is stronger evidence than a stale prompt row and still fails
        # closed for rejected/boot commands.
        try:
            current_errors, _ = _term_error_signature(win)
        except Exception:
            current_errors = baseline_errors
        lower_text = (text or "").lower()
        deterministic_ok = (
            expected in {"privileged", "config", "interface", "router",
                         "acl", "line", "vlan", "crypto", "time_range",
                         "dhcp"}
            and _term_state(text) == "cli"
            and _prompt_seen(text)
            and current_errors <= baseline_errors
            and "translating \"" not in lower_text
            and "domain server" not in lower_text
        )
        if deterministic_ok:
            _CLI_MODE_LATCH[dev] = expected
            if command.strip().lower() == "enable":
                _CLI_ENABLE_ATTEMPTS[dev] = max(
                    1, int(_CLI_ENABLE_ATTEMPTS.get(dev, 0)))
            record_event(
                "cli_mode_transition_verified",
                f"'{command}' accepted; using deterministic {expected} "
                "transition despite repaint",
                device=dev, recovered=True,
                extra={"command": command, "expected": expected},
            )
            return expected
    log(f"{dev}: mode repair '{command}' reached {mode}, wanted "
        f"{expected}")
    return mode


_CLI_SUBMODES = {
    "config", "interface", "router", "acl", "line", "vlan",
    "crypto", "time_range", "dhcp",
}


def _guard_cli_transition(win, dev: str, line: str,
                          current_mode: str = "") -> tuple[str, str]:
    """Prove that an ``end``/``exit`` transition is safe to type.

    A stale planned mode must never be enough to send a transition.  In IOS,
    ``exit`` at Router# returns to Router> and ``end`` at Router> can start
    DNS translation when lookup is enabled.  Read the live prompt immediately
    before either command and return ``(decision, observed_mode)`` where the
    decision is ``allow``, ``skip`` (already outside configuration), or
    ``block`` (the prompt was not proven).
    """
    low = (line or "").strip().lower()
    if low not in {"end", "exit", "quit"}:
        return "allow", current_mode or "unknown"
    try:
        _OCR_CACHE.clear()
        state, text = _confirmed_state(win, dev)
        observed = _cli_prompt_mode(text) if state == "cli" else "unknown"
    except Exception:
        state, observed = "unknown", "unknown"

    if state != "cli" or observed == "unknown":
        record_event(
            "cli_context_blocked",
            f"'{line}' was not typed because its transition prompt was "
            "not proven",
            device=dev, recovered=False,
            extra={"line": line, "state": state,
                   "observed": observed},
        )
        RUN["cli_context_blocks"] = RUN.get("cli_context_blocks", 0) + 1
        return "block", observed

    if observed in {"privileged", "user"}:
        # Both commands are unsafe/unnecessary outside configuration.  A
        # skipped transition is a successful safety decision, not a reason to
        # press another key or to disconnect the console.
        record_event(
            "cli_transition_skipped",
            f"'{line}' skipped at {observed} prompt",
            device=dev, recovered=True,
            extra={"line": line, "observed": observed},
        )
        return "skip", observed
    if observed in _CLI_SUBMODES:
        return "allow", observed

    record_event(
        "cli_context_blocked",
        f"'{line}' was not typed from unrecognized CLI mode",
        device=dev, recovered=False,
        extra={"line": line, "observed": observed},
    )
    RUN["cli_context_blocks"] = RUN.get("cli_context_blocks", 0) + 1
    return "block", observed


def _read_prompt_fresh(win, dev: str) -> tuple:
    """One cache-free prompt read for the places a latch must not decide."""
    try:
        _OCR_CACHE.clear()
        return _confirmed_state(win, dev)
    except Exception:
        return "unknown", ""


def _normalize_to_privileged(win, dev: str, actual: str,
                             delay_ms: int) -> str:
    """Move to Router# with verified, bounded transitions only.

    The caller's ``actual`` is a fresh read, so this function only has to walk
    the prompt back down to privileged.  It deliberately does not consult the
    mode latch while leaving a sub-mode: see the sub-mode branch below.
    """
    end_sent = False
    for _ in range(3):
        if stopped():
            return "unknown"
        if actual == "user":
            # A fresh OCR frame can still expose the old Switch> line after
            # enable already produced Switch#. Reuse verified transition
            # evidence instead of typing enable again at a privileged prompt.
            if _CLI_MODE_LATCH.get(dev) == "privileged":
                log(f"{dev}: stale user prompt ignored; privileged mode was "
                    "already verified")
                return "privileged"
            attempts = int(_CLI_ENABLE_ATTEMPTS.get(dev, 0))
            if attempts >= 2:
                record_event(
                    "cli_context_blocked",
                    "two enable attempts reached no verified privileged "
                    "prompt; duplicate enable blocked",
                    device=dev, recovered=False,
                )
                log(f"{dev}: refusing third enable after two unverified "
                    "attempts")
                return "unknown"
            _CLI_ENABLE_ATTEMPTS[dev] = attempts + 1
            actual = _mode_send(win, dev, "enable", delay_ms,
                                expected="privileged")
            if actual != "privileged":
                # One OCR flake must not permanently blind the device: a
                # second bounded enable is safe (enable is a valid no-op at
                # both Router> and Router# and never triggers DNS
                # translation). The attempts counter above still caps it.
                continue
            _CLI_MODE_LATCH[dev] = "privileged"
            continue
        if actual in _CLI_SUBMODES:
            # The latch is NOT proof here.  It records an earlier verified
            # transition and goes stale as soon as a later `interface ...`
            # entry re-enters a sub-mode; trusting it made the sidecar type
            # `configure terminal` into a live (config-if) prompt, which
            # Packet Tracer rejected ("% Invalid input detected") and which
            # failed the whole CLI stage on 2026-09-15/16 - leaving every
            # router interface unconfigured and all pings timing out.
            if end_sent:
                # A second `end` at a privileged prompt makes Packet Tracer
                # answer `Translating "end"` (a DNS lookup), so only send one
                # per call and require fresh evidence of a sub-mode before
                # considering another.
                fresh_state, fresh_text = _read_prompt_fresh(win, dev)
                if fresh_state == "cli" and \
                        _cli_prompt_mode(fresh_text) == "privileged":
                    return "privileged"
                return actual
            end_sent = True
            before = actual
            actual = _mode_send(win, dev, "end", delay_ms,
                                expected="privileged")
            if actual == before:
                # `end` produced no observable change.  Packet Tracer can
                # still repaint the older (config)# / (config-if)# row for a
                # frame, and giving up here made the caller refuse the next
                # command: on 2026-09-16 that blocked `interface g0/0`, so
                # `ip address` and `no shutdown` were never typed, no router
                # interface got an address and all 14 pings timed out.  One
                # extra cache-free read costs no keystrokes and cannot type
                # anything, so it is safe to spend it before concluding.
                fresh_state, fresh_text = _read_prompt_fresh(win, dev)
                if fresh_state == "cli":
                    fresh_mode = _cli_prompt_mode(fresh_text)
                    if fresh_mode and fresh_mode != before:
                        actual = fresh_mode
                        continue
                return actual
            continue
        break
    return actual


def _ensure_privileged_cli(win, dev: str, delay_ms: int = 25) -> bool:
    """Prove Router#/Switch# before any privileged-only probe.

    A user-mode prompt is enough for a few harmless ``show`` commands, but
    it is not enough evidence for configuration or security verification.
    The old callers treated an attempted ``enable`` as proof and then typed
    the rest of the run at ``Router>``.  This helper makes the transition
    explicit and bounded.
    """
    try:
        _OCR_CACHE.clear()
        state, text = _confirmed_state(win, dev)
    except Exception:
        state, text = "unknown", ""
    if state != "cli":
        record_event("cli_context_blocked",
                     "privileged mode requested before a live IOS prompt "
                     "was proven",
                     device=dev, recovered=False)
        RUN["cli_context_blocks"] = RUN.get("cli_context_blocks", 0) + 1
        return False
    actual = _cli_prompt_mode(text)
    if actual == "unknown" and _CLI_MODE_LATCH.get(dev) == "privileged":
        actual = "privileged"
    if actual != "privileged":
        actual = _normalize_to_privileged(win, dev, actual, delay_ms)
    ok = actual == "privileged"
    if ok:
        _CLI_MODE_LATCH[dev] = "privileged"
        return True
    record_event("cli_context_blocked",
                 "enable did not reach a verified privileged prompt; "
                 "privileged commands were blocked",
                 device=dev, recovered=False,
                 extra={"observed_mode": actual})
    RUN["cli_context_blocks"] = RUN.get("cli_context_blocks", 0) + 1
    return False


# CLI BLOCK EVIDENCE + ONE EXTRA LOOK ------------------------------------
# 592 of the 1477 events in the journal before this change were
# cli_context_blocked, every one unrecovered: the engine refused to type a
# command because the prompt could not be proven, and the event recorded only
# the command text.  That left the single biggest cause of partial builds
# undiagnosable.  Every block now carries what the screen actually showed,
# and - only on the path that was about to be blocked - the engine takes one
# more, read-only look before giving up.
# Consecutive unreadable reads for one device: the extra look is bounded so a
# dead terminal cannot make a run pay for it once per command.
_CLI_PROOF_MISSES: dict = {}
_CLI_PROOF_MAX_MISSES = 3


def _cli_probe_detail(state: str, text: str, mode: str) -> str:
    """Compact, greppable description of what a terminal read showed."""
    flat = " ".join(str(text or "").split())
    return (f"state={state or 'unknown'} mode={mode or 'unknown'} "
            f"chars={len(flat)} tail={flat[-70:]!r}")


def _note_cli_block(reason: str):
    """Count a blocked command by reason (served on /run_summary)."""
    counts = RUN.setdefault("cli_block_reasons", {})
    counts[reason] = counts.get(reason, 0) + 1
    RUN["cli_context_blocks"] = RUN.get("cli_context_blocks", 0) + 1


def _cli_proof_capped(dev: str) -> bool:
    """True once this device has burned its extra looks.

    A device whose terminal is genuinely unavailable (powered off, no CLI tab,
    wrong device window) fails every one of its commands.  Without a cap the
    extra look would run for each of them and add its settle delay to a run
    that was already going to drop those lines - so the look is spent a few
    times per device and then abandoned until a read actually succeeds.
    """
    return _CLI_PROOF_MISSES.get(dev, 0) >= _CLI_PROOF_MAX_MISSES


def _reread_prompt_once(win, dev: str) -> tuple:
    """One extra, READ-ONLY look at the terminal.

    Deliberately types nothing.  A bare Enter is harmless at an IOS prompt but
    is an *answer* in front of the initial-configuration / autoinstall dialog,
    and when a read fails the engine cannot prove which frame it is looking
    at - so this settles and re-reads instead of poking the keyboard.  The
    boot-dialog paths already own the keystrokes they need.

    Returns (state, text, mode); unknowns when the look could not be taken.
    """
    if stopped():
        return "unknown", "", "unknown"
    try:
        if not _interruptible_sleep(0.4):
            return "unknown", "", "unknown"
        _OCR_CACHE.clear()
        state, text = _confirmed_state(win, dev)
    except Exception as exc:
        log(f"{dev}: prompt re-read failed: {str(exc)[:90]}")
        return "unknown", "", "unknown"
    mode = _cli_prompt_mode(text) if state == "cli" else "unknown"
    return state, text, mode


def _ensure_cli_context(win, dev: str, line: str, context: dict,
                        delay_ms: int) -> bool:
    """Detect the current prompt and repair context before one command.

    Repairs are deliberately bounded: at most one return to privileged mode,
    one configure-terminal, and one requested submode entry. A screen that
    cannot prove a live prompt blocks the command instead of typing blindly.
    """
    try:
        _OCR_CACHE.clear()
        state, text = _confirmed_state(win, dev)
    except Exception:
        state, text = "unknown", ""
    # One extra, read-only look when this read cannot prove a terminal.  The
    # retry only ever REPLACES the first read when it proves strictly more
    # (a live CLI with a readable mode), so every downstream decision below -
    # the staleness latches included - keeps seeing the best evidence
    # available.  A healthy run never reaches this branch.
    if state != "cli" or _cli_prompt_mode(text) == "unknown":
        first = _cli_probe_detail(state, text,
                                  _cli_prompt_mode(text) if state == "cli"
                                  else "unknown")
        if _cli_proof_capped(dev):
            RUN["cli_prompt_reread_capped"] = \
                RUN.get("cli_prompt_reread_capped", 0) + 1
        else:
            r_state, r_text, r_mode = _reread_prompt_once(win, dev)
            RUN["cli_prompt_rereads"] = RUN.get("cli_prompt_rereads", 0) + 1
            if r_state == "cli" and r_mode != "unknown":
                state, text = r_state, r_text
                _CLI_PROOF_MISSES.pop(dev, None)
                RUN["cli_prompt_recovered"] = \
                    RUN.get("cli_prompt_recovered", 0) + 1
                log(f"{dev}: a settled re-read proved the prompt the first "
                    f"read could not ({_cli_probe_detail(state, text, r_mode)})")
                record_event("cli_prompt_recovered",
                             "a second read proved the live CLI prompt after "
                             "an unreadable first read",
                             device=dev, recovered=True,
                             extra={"line": line[:80], "first": first})
            else:
                _CLI_PROOF_MISSES[dev] = _CLI_PROOF_MISSES.get(dev, 0) + 1
    if state != "cli":
        _note_cli_block("prompt_not_proven")
        record_event("cli_context_blocked",
                     "live CLI prompt was not proven",
                     device=dev, recovered=False,
                     extra={"line": line[:80],
                            "reason": "prompt_not_proven",
                            "why": _cli_probe_detail(state, text,
                                                     "unknown")})
        return False
    actual = _cli_prompt_mode(text)
    # A mode-transition line is the one case where a latched mode must NEVER
    # stand in for a fresh read: the latch is exactly what let the previous
    # run type `configure terminal` inside a sub-mode and `end` at Router#.
    transition_line = (str(line or "").strip().lower()
                       in MODE_TRANSITION_LINES)
    if (not transition_line and actual == "user"
            and _CLI_MODE_LATCH.get(dev) == "privileged"):
        # The terminal can briefly repaint an older Switch> row after a
        # successful enable. The latch is only written after a verified
        # privileged read, so this is safe and prevents repeated enable.
        log(f"{dev}: using verified privileged-mode latch over stale user "
            "prompt")
        actual = "privileged"
    elif not transition_line:
        latched = _CLI_MODE_LATCH.get(dev)
        if actual in {"unknown", "user"} and latched in _CLI_SUBMODES:
            # The same repaint race occurs after `configure terminal` and
            # interface/router anchors.  Reusing the last verified submode
            # prevents a stale Switch> row from causing a second configure
            # terminal, while a fresh recognized submode still wins above.
            log(f"{dev}: using verified {latched} latch over stale "
                f"{actual} prompt")
            actual = latched
    required = _command_requirement(line, context)
    if actual == "unknown":
        _note_cli_block("mode_unreadable")
        record_event("cli_context_blocked", "CLI mode was unreadable",
                     device=dev, recovered=False,
                     extra={"line": line[:80],
                            "reason": "mode_unreadable",
                            "required": required,
                            "why": _cli_probe_detail(state, text, actual)})
        return False
    if transition_line and str(line).strip().lower() == "end" \
            and actual == "privileged":
        # `end` only means something from configuration mode.  At a freshly
        # verified privileged prompt Packet Tracer treats the stray `end` as a
        # hostname (the 2026-09-15 run saw `Translating "end"` and
        # "% Unknown command or computer name"), so treat it as satisfied
        # instead of typing it again.
        log(f"{dev}: 'end' skipped - a verified privileged prompt is already "
            "live")
        return True
    if line.strip().lower() in {"exit", "quit"} \
            and actual not in _CLI_SUBMODES:
        # `exit` at Router# returns to Router> and can disconnect the console
        # in Packet Tracer. It is only valid for leaving config/submode.
        record_event("cli_context_blocked",
                     f"'{line}' skipped outside configuration mode",
                     device=dev, recovered=False,
                     extra={"line": line, "actual": actual})
        RUN["cli_context_blocks"] = RUN.get("cli_context_blocks", 0) + 1
        return False
    if _prompt_matches(required, actual):
        # A usable prompt clears the evidence debt for this device.
        _CLI_PROOF_MISSES.pop(dev, None)
        return True

    repairs = 0
    if required == "privileged":
        old = actual
        actual = _normalize_to_privileged(win, dev, actual, delay_ms)
        repairs += int(old != actual)
    if required == "config":
        old = actual
        actual = _normalize_to_privileged(win, dev, actual, delay_ms)
        repairs += int(old != actual)
        if actual == "privileged":
            actual = _mode_send(win, dev, "configure terminal", delay_ms,
                                expected="config")
            repairs += 1
    elif required in {
            "interface", "router", "acl", "line", "vlan", "crypto",
            "time_range", "dhcp"}:
        anchor = str(context.get("anchor", "")).strip()
        if not anchor:
            record_event("cli_context_blocked",
                         f"no remembered anchor for {required} mode",
                         device=dev, recovered=False,
                         extra={"line": line[:160], "required": required})
            RUN["cli_context_blocks"] = RUN.get("cli_context_blocks", 0) + 1
            return False
        if actual != "config":
            old = actual
            actual = _normalize_to_privileged(win, dev, actual, delay_ms)
            repairs += int(old != actual)
            if actual == "privileged":
                actual = _mode_send(win, dev, "configure terminal", delay_ms,
                                    expected="config")
                repairs += 1
        if actual == "config":
            actual = _mode_send(win, dev, anchor, delay_ms,
                                expected=required)
            repairs += 1

    ok = _prompt_matches(required, actual)
    if repairs:
        RUN["cli_mode_repairs"] = RUN.get("cli_mode_repairs", 0) + repairs
        record_event(
            "cli_mode_repaired" if ok else "cli_context_blocked",
            f"{line[:100]}: {actual} after {repairs} mode repair(s)",
            device=dev,
            recovered=ok,
            extra={"required": required, "actual": actual,
                   "repairs": repairs},
        )
    return ok


def _update_cli_context(context: dict, line: str, mode: str):
    """Track the last explicit IOS submode anchor for the next command."""
    low = (line or "").strip().lower()
    if low in {"end", "exit", "quit"}:
        if low == "end" or mode in {"privileged", "user"}:
            context.clear()
        elif low in {"exit", "quit"}:
            context.clear()
        return
    if low.startswith("interface "):
        if mode == "interface":
            context.update({"kind": "interface", "anchor": line.strip()})
        else:
            context.clear()
    elif low.startswith("router "):
        if mode == "router":
            context.update({"kind": "router", "anchor": line.strip()})
        else:
            context.clear()
    elif low.startswith(("ip access-list ", "ipv6 access-list ")):
        if mode == "acl":
            context.update({"kind": "acl", "anchor": line.strip()})
        else:
            context.clear()
    elif low.startswith("line "):
        if mode == "line":
            context.update({"kind": "line", "anchor": line.strip()})
        else:
            context.clear()
    elif low.startswith("vlan "):
        if mode == "vlan":
            context.update({"kind": "vlan", "anchor": line.strip()})
        else:
            context.clear()
    elif low.startswith(("crypto isakmp policy ",
                         "crypto ipsec transform-set ")):
        if mode == "crypto":
            context.update({"kind": "crypto", "anchor": line.strip()})
        else:
            context.clear()
    elif low.startswith("crypto map ") and mode == "crypto":
        context.update({"kind": "crypto", "anchor": line.strip()})
    elif low.startswith("time-range "):
        if mode == "time_range":
            context.update({"kind": "time_range", "anchor": line.strip()})
        else:
            context.clear()
    elif low.startswith("ip dhcp pool "):
        if mode == "dhcp":
            context.update({"kind": "dhcp", "anchor": line.strip()})
        else:
            context.clear()


def _recover_cli_mode(win, dev: str, delay_ms: int):
    """Return to a verified privileged prompt after a rejected command."""
    if stopped():
        return "unknown"
    try:
        _OCR_CACHE.clear()
        _, current_text = _confirmed_state(win, dev)
        actual = _cli_prompt_mode(current_text)
        final = _normalize_to_privileged(win, dev, actual, delay_ms)
        ok = final == "privileged"
        record_event(
            "cli_mode_recovered" if ok else "cli_context_blocked",
            "reset to a verified privileged prompt after a rejected command"
            if ok else
            "could not prove a privileged prompt after a rejected command",
            device=dev, recovered=ok,
            extra={"before": actual, "after": final},
        )
        return final if ok else "unknown"
    except Exception as e:
        log(f"{dev}: CLI mode recovery failed: {e}")
        return "unknown"


# A trailing row that looks like a lower-case command echo is the only
# evidence of partially typed input; IOS output rows ([OK], %LINK-3-UPDOWN,
# Building configuration..., Translating "end") never look like this.
_PENDING_ECHO_RE = re.compile(r"^[a-z][a-z0-9_\-/\. ]*$")


def _pending_command_echo(text: str) -> str:
    """Return the trailing partial command echo, or "" when the prompt is clean.

    Handles both shapes Packet Tracer produces: a partial command on its own
    row, and a partial command sharing the prompt row (``Router# writ``).
    """
    rows = [row.strip() for row in (text or "").splitlines() if row.strip()]
    if not rows:
        return ""
    tail = re.split(r"[#>]", rows[-1])[-1].strip()
    if tail and _PENDING_ECHO_RE.match(tail):
        return tail
    return ""


def _clear_pending_command(win, dev: str, delay_ms: int) -> bool:
    """Abandon a partially typed CLI line before the final save.

    The 2026-09-15 run sent the save while a partial line was pending, so
    Packet Tracer received `writ write memory` and rejected it.  One Ctrl+C at
    the prompt discards the partial input; the prompt is then re-read so the
    caller types the save exactly once.
    """
    try:
        _OCR_CACHE.clear()
        state, text = _confirmed_state(win, dev)
    except Exception:
        state, text = "unknown", ""
    if state != "cli":
        return False
    pending = _pending_command_echo(text)
    if not pending:
        return True
    log(f"{dev}: clearing a pending partial line before saving")
    record_event("pending_line_cleared",
                 f"partial input '{pending[:80]}' was cleared before the save",
                 device=dev, recovered=True)
    _safe_hotkey("ctrl", "c")
    _interruptible_sleep(0.4)
    _OCR_CACHE.clear()
    try:
        state_after, _ = _confirmed_state(win, dev)
    except Exception:
        state_after = "unknown"
    return state_after == "cli"


def paste_to_device(rect, dev: str, slot: int, cfg: str, delay_ms: int,
                    project: str = "default", dtype: str = "",
                    cabled=None):
    """Full CLI scenario for one device with error recovery.

    Scenarios covered:
    0. FRESH BOOT setup dialog ("initial configuration dialog? [yes/no]")
       -> answer `no` first (user's screenshot: every line was eaten by it)
    1. empty/wrong spot (no window) -> skip with log, continue others
    2. lands on Config tab not CLI -> UIA CLI click + fallback
    3. user-mode boot -> auto enable + conf-t + length-0 prefix
    4. `!`/blank lines -> filtered (they error live)
    5. --More-- paging -> terminal length 0 up front + space pump
    6. per-line readout: terminal re-read before/after EVERY line via UIA
       text (setup re-check, % Invalid/Incomplete count) -> 1 retry with
       context fallback (ospf process, switchport arming, transient retype)
    7. Password: prompt -> empty enter
    8. window closed properly after (leftover windows blocked the canvas)
    9. routers: CABLED ports showing admin-down re-healed (red cable fix)
    10. PCs AND servers: SKIPPED - no CLI tab exists; typing there was
        the random-click hang the user saw on PC0. Their IPs go through
        the config_pcs step (Desktop > IP Configuration).
    """
    if dtype in ("pc", "server"):
        log(f"{dev}: {dtype.upper()} has no CLI tab - skipping (configure "
            f"via Desktop > IP Configuration)")
        record_event("pc_skipped", f"{dtype.upper()} window opened but has "
                     f"no CLI; config must go through Desktop tab",
                     device=dev, recovered=True)
        RUN["devices_skipped"] = RUN.get("devices_skipped", 0) + 1
        return False
    if stopped():
        return False
    lines = learned_cli_lines(project, dev, cfg, dtype=dtype)
    learning_context = _learning_context(project, dev, dtype=dtype)
    session_replacements = {}
    blocked_interfaces = []
    log(f"{dev}: {len(lines)} CLI lines (filtered+wrapped+learned)")
    _OCR_CACHE.clear()  # fresh screen reads for this window
    win = _open_device_window(rect, dev, slot, project)
    if win is None:
        RUN["devices_skipped"] = RUN.get("devices_skipped", 0) + 1
        record_event("window_not_found", "no device window after "
                     "double-click (spot empty or covered)",
                     device=dev, recovered=False)
        return False
    if stopped():
        return False
    if not _focus_cli_tab(win, dev):
        log(f"{dev}: cannot focus CLI - skipping")
        RUN["devices_skipped"] = RUN.get("devices_skipped", 0) + 1
        record_event("cli_focus_failed", "CLI tab would not focus",
                     device=dev, recovered=False)
        return False
    # WAKE + SETUP DIALOG: fresh PT devices boot to "Press RETURN" then the
    # System Configuration Dialog which EATS typed lines as yes/no answers.
    # Read the terminal and answer `no` until a real CLI prompt appears.
    try:
        if _focus_cli_input(win, dev, "boot wake"):
            _safe_press("enter")
            _interruptible_sleep(1.2)
        else:
            log(f"{dev}: boot wake skipped - Packet Tracer focus was "
                "not proven")
    except Exception:
        pass
    if not _settle_boot_dialogs(win, dev):
        log(f"{dev}: boot dialogs would not clear - skipping (not typing "
            f"the config into the setup dialog)")
        RUN["devices_skipped"] = RUN.get("devices_skipped", 0) + 1
        record_event("setup_unresolvable",
                     "settle could not clear the boot dialog - device "
                     "skipped", device=dev, recovered=False)
        _close_device_window(win, dev)
        return False
    # Capability gate before any config command: a default 2911 has only
    # GigabitEthernet ports.  If the plan asks for S0/0/0 without a serial
    # module, remove that whole block instead of feeding description/IP/no
    # shutdown at config-global and generating a cascade of false errors.
    try:
        if not _ensure_privileged_cli(win, dev, delay_ms):
            raise RuntimeError("could not prove privileged mode for "
                               "interface capability probe")
        if not _type_line("show ip interface brief", delay_ms,
                          win=win, dev=dev):
            raise RuntimeError("interface capability probe was not typed "
                               "with a verified CLI focus")
        _interruptible_sleep(0.8)
        # `show` does not change IOS context. The latch remains valid because
        # _ensure_privileged_cli proved Router#/Switch# immediately before
        # this probe; it is never inferred from a typed command alone.
        _OCR_CACHE.clear()
        available, capability_text = _read_interface_capabilities(win)
        if available:
            lines, blocked_interfaces = _filter_unavailable_interface_blocks(
                lines, cfg, dev, available)
        else:
            physical_wanted = [
                spec for spec in _interface_specs(cfg)
                if not spec.lower().startswith("range ")
            ]
            if physical_wanted:
                _mark_interface_blocked(dev)
                record_event(
                    "interface_capability_unknown",
                    "live interface list was unreadable; CLI config was "
                    "blocked instead of typing unverified interfaces",
                    device=dev, recovered=False,
                    extra={"interfaces": physical_wanted})
                log(f"{dev}: live interface list unreadable - blocking CLI "
                    "for safety; no interface config was typed")
                _close_device_window(win, dev)
                invalidate_config(project, dev)
                return False
            log(f"{dev}: no physical interfaces requested; capability "
                "check not required")
    except Exception as e:
        log(f"{dev}: interface capability check failed: {e} - CLI config "
            "blocked")
        record_event(
            "cli_context_blocked",
            "CLI configuration was not typed because privileged mode and "
            "the capability probe were not both verified",
            device=dev,
            recovered=False,
            extra={"reason": str(e)[:200]},
        )
        RUN["errors_unrecovered"] = RUN.get("errors_unrecovered", 0) + 1
        _close_device_window(win, dev)
        invalidate_config(project, dev)
        return False
    queue = _compile_cli_queue(lines)
    fallback_count = sum(1 for item in queue if item["fallbacks"])
    log(f"{dev}: compiled CLI plan ({len(lines)} primary commands, "
        f"{len(queue)} executable items, {fallback_count} fallbacks ready)")
    record_event(
        "cli_plan_compiled",
        f"compiled {len(lines)} primary CLI commands before execution",
        device=dev,
        recovered=True,
        extra={"primary_commands": len(lines),
               "queue_items": len(queue),
               "fallback_candidates": fallback_count},
    )
    in_ospf = False
    trunk_armed = False
    cli_context = {}
    errors = 0
    unrecovered_errors = 0
    setup_hits = 0
    current_mode = "privileged"  # capability probe proved Router#
    last_state = "cli"
    last_text = ""
    try:
        _OCR_CACHE.clear()
        error_floor, _ = _term_error_signature(win)
    except Exception:
        error_floor = 0
    queue_pos = 0
    while queue_pos < len(queue):
        item = queue[queue_pos]
        idx = item["index"]
        source_line = item["source"]
        if stopped():
            log(f"{dev}: stopped mid-CLI at planned item {queue_pos}")
            break
        item = queue[queue_pos]
        line = session_replacements.get(source_line, item["command"])
        low = line.strip().lower()
        if low in MODE_ENTRY_COMMANDS:
            original_low = source_line.strip().lower()
            if original_low in MODE_ENTRY_COMMANDS:
                # Defensive only: compilation normally removes this item.
                log(f"{dev}: skipped stray mode-wrapper queue item '{line}'")
                queue_pos += 1
                continue
            # Never let a learned/session correction turn a real command into
            # a second context transition.  Use the original planned line;
            # the verified state machine will enter the needed mode once.
            record_event(
                "cli_plan_sanitized",
                f"ignored mode-wrapper correction for '{source_line[:100]}'",
                device=dev, recovered=True,
                extra={"source": source_line, "replacement": line},
            )
            line = source_line
            low = line.strip().lower()
        if item.get("blocked"):
            errors += 1
            unrecovered_errors += 1
            RUN["errors_unrecovered"] = RUN.get("errors_unrecovered", 0) + 1
            record_event(
                "cli_context_blocked",
                f"'{line}' was rejected during CLI plan compilation",
                device=dev,
                recovered=False,
                extra={"line": line, "required": item["required"]},
            )
            queue_pos += 1
            continue

        # The previous command already proved the next prompt in the normal
        # path.  Re-read only after an unknown/non-CLI result; this removes
        # the repeated pre-command OCR delay while keeping the boot guard.
        if last_state != "cli" or current_mode == "unknown":
            try:
                _OCR_CACHE.clear()
                st, gtext = _confirmed_state(win, dev)
                last_state, last_text = st, gtext
                if "domain server" in (gtext or "").lower():
                    _abort_dns_hang(win, dev, gtext)
                    current_mode = "unknown"
                elif st == "setup":
                    if _answer_no_once(win, dev, delay_ms,
                                       f"planned item {idx} guard"):
                        setup_hits = 0
                        _OCR_CACHE.clear()
                        st, gtext = _confirmed_state(win, dev)
                        last_state, last_text = st, gtext
                    else:
                        setup_hits += 1
                if st == "cli":
                    current_mode = _cli_prompt_mode(gtext)
                    if current_mode == "unknown":
                        # A repaint may contain only a distorted final
                        # prompt (for example `R1#` -> `Rig`).  A previously
                        # verified latch is safer than treating that repaint
                        # as a reason to send another mode command.
                        current_mode = _CLI_MODE_LATCH.get(dev, "unknown")
                else:
                    current_mode = "unknown"
            except Exception:
                last_state, last_text, current_mode = "unknown", "", "unknown"
            if last_state != "cli" or current_mode == "unknown":
                errors += 1
                unrecovered_errors += 1
                RUN["errors_unrecovered"] = RUN.get("errors_unrecovered", 0) + 1
                record_event(
                    "cli_context_blocked",
                    f"'{line}' was not typed because the live prompt was "
                    "not proven after the previous command",
                    device=dev,
                    recovered=False,
                    extra={"line": line, "state": last_state},
                )
                queue_pos += 1
                continue

        required = item["required"]
        if line != source_line:
            required = _command_requirement(line, cli_context)
        # Mode transitions are checked against the live prompt immediately
        # before typing.  The planned mode is not sufficient: a stale mode
        # after a rejected command used to send `end`/`exit` at Router# and
        # either disconnect the console or start DNS translation.
        if low in {"end", "exit", "quit"}:
            transition, observed_transition = _guard_cli_transition(
                win, dev, line, current_mode)
            if observed_transition != "unknown":
                current_mode = observed_transition
                _CLI_MODE_LATCH[dev] = observed_transition
                _update_cli_context(
                    cli_context, line, observed_transition)
            if transition == "skip":
                queue_pos += 1
                continue
            if transition != "allow":
                errors += 1
                unrecovered_errors += 1
                RUN["errors_unrecovered"] = \
                    RUN.get("errors_unrecovered", 0) + 1
                record_event(
                    "cli_context_blocked",
                    f"'{line}' was not typed because the mode transition "
                    "was not proven",
                    device=dev, recovered=False,
                    extra={"line": line,
                           "observed": observed_transition},
                )
                current_mode = "unknown"
                last_state, last_text = "unknown", ""
                queue_pos += 1
                continue
        if not _prompt_matches(required, current_mode):
            if not _ensure_cli_context(win, dev, line, cli_context, delay_ms):
                errors += 1
                unrecovered_errors += 1
                RUN["errors_unrecovered"] = RUN.get("errors_unrecovered", 0) + 1
                record_event(
                    "cli_context_blocked",
                    f"'{line}' was not typed because the required CLI mode "
                    "could not be proven",
                    device=dev,
                    recovered=False,
                    extra={"line": line, "context": dict(cli_context),
                           "required": required},
                )
                current_mode = "unknown"
                queue_pos += 1
                continue
            if required not in {"live", "any"}:
                current_mode = _CLI_MODE_LATCH.get(dev, required)
        if low.startswith("router ospf"):
            in_ospf = True
        if low == "switchport":
            trunk_armed = True
        before_count = error_floor
        try:
            if not _type_line(line, delay_ms, win=win, dev=dev):
                errors += 1
                unrecovered_errors += 1
                RUN["errors_unrecovered"] = \
                    RUN.get("errors_unrecovered", 0) + 1
                record_event(
                    "cli_input_blocked",
                    f"'{line}' was not typed because Packet Tracer focus "
                    "was not proven",
                    device=dev,
                    recovered=False,
                    extra={"line": line, "required": required},
                )
                last_state, last_text, current_mode = \
                    "unknown", "", "unknown"
                queue_pos += 1
                continue
        except Exception as e:
            log(f"{dev}: type failed line {idx} '{line}': {e}")
            errors += 1
            unrecovered_errors += 1
            RUN["errors_unrecovered"] = \
                RUN.get("errors_unrecovered", 0) + 1
            record_event(
                "cli_input_blocked",
                f"'{line}' raised while typing; command was not verified",
                device=dev,
                recovered=False,
                extra={"line": line, "error": str(e)[:200]},
            )
            last_state, last_text, current_mode = \
                "unknown", "", "unknown"
            queue_pos += 1
            continue
        after_state, after_text = "unknown", ""
        try:
            _OCR_CACHE.clear()
            after_state, after_text = _confirmed_state(win, dev)
            last_state, last_text = after_state, after_text
            actual_after = _cli_prompt_mode(after_text)
            transition = low in {"end", "exit", "quit", "disable"}
            planned_after = _planned_cli_mode_after(line, current_mode)
            # A stale OCR frame after a normal config command used to move
            # the executor back to Router# even though IOS was still in
            # (config)# or (config-if)#.  The next line then redundantly sent
            # `configure terminal` and the whole block drifted.  Use the
            # planned mode only for a deterministic submode/configuration
            # transition when the live CLI produced no new terminal error.
            # Never infer Router# for an ordinary show/write command from a
            # stale frame; that would make a later `end` unsafe.
            try:
                post_count, post_sample = _term_error_signature(win)
            except Exception:
                post_count, post_sample = before_count, ""
            lower_after = (after_text or "").lower()
            stable_cli = (
                after_state == "cli"
                and post_count <= before_count
                and "translating \"" not in lower_after
                and "domain server" not in lower_after
            )
            deterministic_submode = planned_after in _CLI_SUBMODES
            deterministic_transition = (
                transition and planned_after not in {"live", "unknown"}
            )
            if stable_cli and (deterministic_submode or
                               deterministic_transition):
                current_mode = planned_after
                _CLI_MODE_LATCH[dev] = planned_after
                _update_cli_context(cli_context, line, planned_after)
                if actual_after != planned_after:
                    log(f"{dev}: trusted planned mode {planned_after} for "
                        f"'{line}' over OCR mode {actual_after}")
                if post_sample:
                    last_text = after_text
            elif actual_after != "unknown":
                current_mode = actual_after
                _CLI_MODE_LATCH[dev] = actual_after
                _update_cli_context(cli_context, line, actual_after)
            else:
                current_mode = "unknown"
        except Exception:
            last_state, last_text, current_mode = "unknown", "", "unknown"
        # let large output (show ...) finish rendering before the next
        # keystroke - the backlog is what made PT eat first characters
        if low.startswith("show "):
            _interruptible_sleep(0.9)
        # pager + password pumps
        try:
            _, sample = _term_error_signature(win)
            slam = sample.lower()
            if "more" in slam or "password" in slam:
                if not _focus_cli_input(win, dev, "CLI response"):
                    queue_pos += 1
                    continue
            if "more" in slam:
                _safe_press("space")
                _interruptible_sleep(0.4)
                log(f"{dev}: pager --More-- fed with space")
            if "password" in slam:
                _safe_press("enter")
                _interruptible_sleep(0.4)
        except Exception:
            pass
        # error check -> single fallback retry (fresh read AFTER typing,
        # never the cached pre-typing screen)
        _OCR_CACHE.clear()
        try:
            after_count, sample = _term_error_signature(win)
        except Exception:
            after_count, sample = before_count, ""
        if after_count > before_count and "translat" in sample.lower():
            _abort_dns_hang(win, dev, after_text)
        if after_count > before_count:
            errors += 1
            fb = list(item["fallbacks"])
            if line != source_line:
                fb = _fallback_lines(line, in_ospf, trunk_armed)
            if fb:
                log(f"{dev}: line {idx} '{line}' errored ({sample}) - "
                    f"fallback {fb}")
            else:
                log(f"{dev}: line {idx} '{line}' errored ({sample}) - "
                    f"known-benign on this device, not retried")
            for fline in fb:
                if stopped():
                    break
                try:
                    flow = fline.strip().lower()
                    fallback_required = _command_requirement(
                        fline, cli_context)
                    fallback_ok = _prompt_matches(
                        fallback_required, current_mode)
                    if not fallback_ok:
                        fallback_ok = _ensure_cli_context(
                            win, dev, fline, cli_context, delay_ms)
                        if fallback_ok and fallback_required not in {
                                "live", "any"}:
                            current_mode = fallback_required
                    if fallback_ok and flow in {"end", "exit", "quit"}:
                        transition, observed = _guard_cli_transition(
                            win, dev, fline, current_mode)
                        if observed != "unknown":
                            current_mode = observed
                            _CLI_MODE_LATCH[dev] = observed
                            _update_cli_context(
                                cli_context, fline, observed)
                        if transition == "skip":
                            continue
                        if transition != "allow":
                            current_mode = "unknown"
                            continue
                    if fallback_ok:
                        _type_line(fline, delay_ms, win=win, dev=dev)
                        _OCR_CACHE.clear()
                        _, fallback_text = _confirmed_state(win, dev)
                        fallback_mode = _cli_prompt_mode(fallback_text)
                        last_state, last_text = _term_state(fallback_text), \
                            fallback_text
                        current_mode = fallback_mode
                        if fallback_mode != "unknown":
                            _CLI_MODE_LATCH[dev] = fallback_mode
                            _update_cli_context(
                                cli_context, fline,
                                fallback_mode,
                            )
                except Exception:
                    current_mode = "unknown"
                if flow.startswith("router ospf"):
                    in_ospf = True
                if flow == "switchport":
                    trunk_armed = True
            still = after_count
            try:
                still, _ = _term_error_signature(win)
            except Exception:
                pass
            error_floor = max(error_floor, still)
            session_application = _session_cli_source_for_line(dev, line)
            if session_application and not session_application.get("rejected"):
                session_application["rejected"] = True
                session_context = _session_cli_context(
                    project, dev, dtype)
                LEARNING.failure(
                    "cli_fallback",
                    "command",
                    session_context,
                    session_application["replacement"],
                    "current-session correction failed on this device",
                    persistent=False,
                )
                RUN["session_corrections_rejected"] = (
                    RUN.get("session_corrections_rejected", 0) + 1
                )
                record_event(
                    "session_correction_rejected",
                    f"current-session correction failed for "
                    f"'{session_application['source'][:100]}'",
                    device=dev,
                    recovered=True,
                    extra={"replacement": session_application["replacement"]},
                )
            if still > after_count and not stopped():
                # Last resort before writing the line off: ask Gemini for a
                # replacement and verify it with the same terminal evidence
                # the fallback used.  A verified answer takes the place of the
                # fallback below, so the existing accounting and learning paths
                # store it and it is applied first on the next run.
                llm_commands = _llm_try_fix(win, project, dev, dtype, line,
                                            sample, current_mode)
                if llm_commands:
                    fb = llm_commands
                    still = after_count
            remember_bad_command(
                project, dev, line,
                sample or "terminal command error",
                fb if still <= after_count else None)
            command_context = {**learning_context, "source": line}
            LEARNING.failure("cli_fallback", "command", command_context,
                            [line], sample or "terminal command error",
                            persistent=True)
            if fb and still <= after_count:
                LEARNING.success("cli_fallback", "command", command_context,
                                 fb, "fallback verified", persistent=True)
                _remember_immediate_cli_fix(
                    project, dev, dtype, line, fb)
                if len(fb) == 1 and fb[0] != line:
                    session_replacements[line] = fb[0]
            elif fb:
                LEARNING.failure("cli_fallback", "command", command_context,
                                fb, "fallback still produced terminal error",
                                persistent=True)
            _learning_refresh()
            if still > after_count:
                unrecovered_errors += 1
                log(f"{dev}: line {idx} still failing - skipped")
                RUN["errors_unrecovered"] = RUN.get("errors_unrecovered", 0) + 1
                record_event("cli_line_error", f"'{line}' still failing "
                             f"after fallback ({sample})", device=dev,
                             recovered=False,
                             extra={"line": line, "fallback": fb})
            else:
                RUN["errors_recovered"] = RUN.get("errors_recovered", 0) + 1
                record_event("cli_line_error", f"'{line}' errored ({sample})",
                             device=dev, recovered=bool(fb),
                             extra={"line": line, "fallback": fb})
            # Do not let one rejected command poison the IOS mode for the
            # next block.  The recovery is bounded to one reset; the command
            # memory still records the original failure and fallback.
            if not stopped():
                recovered_mode = _recover_cli_mode(win, dev, delay_ms)
                cli_context.clear()
                if recovered_mode == "privileged":
                    current_mode = "privileged"
                    _CLI_MODE_LATCH[dev] = "privileged"
                    last_state, last_text = "cli", ""
                else:
                    # Recovery is not proof.  Do not re-enter the queue with
                    # an invented Router# state after a failed reset; the
                    # next item must obtain a fresh prompt or be blocked.
                    current_mode = "unknown"
                    last_state, last_text = "unknown", ""
        else:
            error_floor = max(error_floor, after_count)
        queue_pos += 1
    # RED CABLE HEAL: re-apply no shutdown on CABLED ports still showing
    # administratively down (wrapped in conf t/end this time).
    if dtype == "router" and not stopped():
        try:
            safe_cabled = [
                spec for spec in list(cabled or [])
                if _full_ifname(spec) not in blocked_interfaces
            ]
            _heal_admin_down(win, dev, cfg, delay_ms, safe_cabled)
        except Exception as e:
            log(f"{dev}: admin-down heal failed: {e}")
    # SAVE: one unconditional, idempotent write AFTER any heal, so the
    # healed config is saved too. (The old OCR 'save verify' mistook
    # '[OK]' for missing and typed a second write - now deterministic.)
    if stopped():
        log(f"{dev}: stop requested - closing CLI without saving more commands")
        _close_device_window(win, dev)
        invalidate_config(project, dev)
        return False
    try:
        # Never extend a pending partial line into the save command.
        _clear_pending_command(win, dev, delay_ms)
        save_context = {}
        if not _ensure_cli_context(win, dev, "write memory", save_context,
                                   delay_ms):
            record_event("save_blocked",
                         "write memory was not typed because privileged mode "
                         "could not be proven",
                         device=dev, recovered=False)
            RUN["errors_unrecovered"] = RUN.get("errors_unrecovered", 0) + 1
        else:
            save_typed = _type_line("write memory", delay_ms,
                                    win=win, dev=dev)
            if not save_typed:
                unrecovered_errors += 1
                RUN["errors_unrecovered"] = \
                    RUN.get("errors_unrecovered", 0) + 1
                record_event(
                    "save_blocked",
                    "write memory was not typed because Packet Tracer "
                    "focus was not proven",
                    device=dev,
                    recovered=False,
                )
                raise RuntimeError("write memory input was blocked")
            _interruptible_sleep(0.8)
            _OCR_CACHE.clear()
            vtxt = _term_texts(win).lower()
            if vtxt.strip() and "building configuration" not in vtxt \
                    and "ok]" not in vtxt and not stopped():
                log(f"{dev}: save confirmation not visible - one more write")
                if _ensure_cli_context(win, dev, "write memory", {},
                                       delay_ms):
                    retry_typed = _type_line("write memory", delay_ms,
                                             win=win, dev=dev)
                    if not retry_typed:
                        unrecovered_errors += 1
                        RUN["errors_unrecovered"] = \
                            RUN.get("errors_unrecovered", 0) + 1
                        record_event(
                            "save_blocked",
                            "retry write memory was not typed because "
                            "Packet Tracer focus was not proven",
                            device=dev,
                            recovered=False,
                        )
                        raise RuntimeError("retry write memory blocked")
                    _interruptible_sleep(0.6)
    except Exception:
        pass
    # FINISH VERIFICATION: re-read terminal before closing. All-lines-typed
    # is not success - prompt must be live and error count stable.
    try:
        fin_count, fin_sample = _term_error_signature(win)
    except Exception:
        fin_count, fin_sample = 0, ""
    try:
        fin_state, fin_text = _confirmed_state(win, dev)
    except Exception:
        fin_state, fin_text = "unknown", ""
    # Capture CLI evidence while the verified device window is still open.
    # The old order closed the device first, so cli_<device>.png could show
    # the canvas or a covering app instead of the prompt that was just read.
    if _focus_pt_window(win, dev, "CLI evidence"):
        shot(f"cli_{dev}.png")
    else:
        record_event("cli_evidence_blocked",
                     "final CLI screenshot was not captured because "
                     "Packet Tracer was not foreground",
                     device=dev, recovered=False)
    _close_device_window(win, dev)
    _interruptible_sleep(0.4)
    RUN["devices_done"] = RUN.get("devices_done", 0) + 1
    if fin_state == "setup":
        log(f"VERIFY {dev}: FAIL - setup dialog back at end; "
            f"device needs re-run (Cables + CLI only)")
        record_event("cli_verify_fail", "setup dialog back at end",
                     device=dev, recovered=False)
    elif fin_count > 0 and errors == 0:
        log(f"VERIFY {dev}: REVIEW - {fin_count} terminal error(s), "
            f"none recovered ({fin_sample[:80]}); check cli_{dev}.png")
    else:
        log(f"done {dev} VERIFIED ({len(lines)} lines, "
            f"~{errors} recovered errors, prompt live)")
    verified = (fin_state == "cli" and fin_count == 0
                and unrecovered_errors == 0 and not stopped())
    if verified:
        remember_config(project, dev, cfg, dtype)
        RUN["configs_verified"] = RUN.get("configs_verified", 0) + 1
        log(f"{dev}: exact command set VERIFIED and cached for the next "
            "FULL build")
    else:
        invalidate_config(project, dev)
        log(f"{dev}: command cache not updated (verification was not "
            "fully clean)")
    return verified


def _red_link_check(rect, links, slot_of: dict, project: str,
                    link_specs: dict):
    """Pixel-check each link endpoint for PT's RED status triangle.

    Red = that port is still down (admin-down or wrong port). Feeds the
    journal so recurring 'link still red' patterns become suggestions.
    """
    p = shot_path("after.png")
    if not p:
        return
    try:
        from PIL import Image
        img = Image.open(p).convert("RGB")
    except Exception as e:
        log(f"link check: screenshot unreadable: {e}")
        return
    W, H = img.size
    l, t, r, b = rect
    px = img.load()
    for j, lnk in enumerate(links):
        a, bdev = lnk.get("a"), lnk.get("b")
        for end, dev in (("a", a), ("b", bdev)):
            if dev not in slot_of:
                continue
            fx, fy, _ = _spot(project, dev, slot_of[dev])
            # triangle sits just outside the icon, toward the link line
            cx = int(l + (r - l) * fx)
            cy = int(t + (b - t) * fy) - int((b - t) * 0.02)
            red = 0
            for dx in range(-45, 46, 3):
                for dy in range(-30, 31, 3):
                    x, y = cx + dx, cy + dy
                    if 0 <= x < W and 0 <= y < H:
                        pr, pg, pb = px[x, y]
                        if pr > 170 and pg < 80 and pb < 80:
                            red += 1
            if red >= 3:
                aIf, bIf = link_specs.get((a, bdev), ("?", "?"))
                ival = aIf if end == "a" else bIf
                RUN["links_red"] = RUN.get("links_red", 0) + 1
                record_event("link_red", f"link {a}:{aIf} <-> {bdev}:{bIf} "
                             f"shows RED at {dev}:{ival} end",
                             device=dev, recovered=False,
                             extra={"red_px": red})
                log(f"LINK CHECK {j}: RED at {dev} ({ival}) - port down?")


# PC DESKTOP AUTOMATION -------------------------------------------------
# PCs have no IOS CLI (typing there caused the random-click hang). Their
# IP settings go through Desktop > IP Configuration.
#
# Bug this fixes (user screenshots): the panel OPENED but the fields
# stayed empty - the UIA 'Edit' path typed into invisible controls and
# reported success, so the coordinate fallback never ran. Now: the three
# light input boxes are DETECTED VISUALLY (row-brightness bands), each
# is clicked, ctrl+a, typed, and the result is OCR-VERIFIED (IP digits
# visible) with one full retry before declaring failure.

_PC_FIELD_FRACS = {"ip": 0.245, "mask": 0.275, "gw": 0.305,
                   "dns": 0.335}
# The Static/DHCP radio pair sits just above the IP row in PT's IP
# Configuration panel; 'DHCP' is the lower of the two labels.  Used only
# as the search band for _pc_select_dhcp - the live OCR position wins.
_PC_DHCP_RADIO_FY = 0.215
_PC_DHCP_SEARCH_TOP = 0.14
_PC_DHCP_SEARCH_BOTTOM = 0.26


def _pc_select_dhcp(win, dev: str) -> bool:
    """Switch the PC to DHCP client and prove a lease (or 'Requesting').

    Bounded: click the 'DHCP' radio found by OCR inside a narrow band,
    then accept ONLY readable evidence - an IPv4 lease in the (disabled)
    IP row, or PT's own 'Requesting'/'checking' lease status.  One extra
    click inside the band, then report honestly.
    """
    words, l, t, w, h = _win_words(win)
    top = int(h * _PC_DHCP_SEARCH_TOP)
    bottom = int(h * _PC_DHCP_SEARCH_BOTTOM)

    def _band_words():
        hits = [(x, y, ww, hh) for wd, x, y, ww, hh in words
                if wd.lower().startswith("dhcp")
                and top <= y <= bottom]
        return hits

    hits = _band_words()
    if not hits:
        # one sparse re-read before giving up on the label
        try:
            alt, al, at, aw, ah = _win_words(win, psm=11)
            words = alt
            l, t, w, h = al, at, aw, ah
            hits = [(x, y, ww, hh) for wd, x, y, ww, hh in words
                    if wd.lower().startswith("dhcp")
                    and int(h * _PC_DHCP_SEARCH_TOP) <= y
                    <= int(h * _PC_DHCP_SEARCH_BOTTOM)]
        except TypeError:
            hits = []
    if not hits:
        log(f"{dev}: DHCP radio label not found in the IP Configuration "
            "panel - not clicking blind")
        record_event("pc_dhcp_radio_missing",
                     "DHCP radio not found; PC left unconfigured",
                     device=dev, recovered=False)
        return False
    hits.sort(key=lambda z: z[1])
    x, y, ww, hh = hits[0]
    _safe_click(l + x + ww // 2, t + y + hh // 2)
    _interruptible_sleep(1.6)
    _OCR_CACHE.clear()
    panel = (_ocr_region(win, 0.10, 0.50) or "").lower()

    def _leased():
        # any IPv4-looking lease or PT's lease-in-progress text
        if re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", panel):
            if "255.255.255.0" in panel or re.search(
                    r"\b(?!255\.255\.255\.255)\d{1,3}(?:\.\d{1,3}){3}\b",
                    panel):
                return True
        if "requesting" in panel or "dhcp" in panel and (
                "checking" in panel or "lease" in panel):
            return True
        return False

    if _leased():
        log(f"{dev}: DHCP client selected - panel shows lease/status")
        record_event("pc_dhcp_client",
                     "DHCP radio selected; lease/status visible",
                     device=dev, recovered=True)
        return True
    # one nudge: PT sometimes needs a second click to commit the radio
    _safe_click(l + x + ww // 2, t + y + hh // 2)
    _interruptible_sleep(1.6)
    _OCR_CACHE.clear()
    panel = (_ocr_region(win, 0.10, 0.50) or "").lower()
    if _leased():
        log(f"{dev}: DHCP client selected (after retry)")
        record_event("pc_dhcp_client",
                     "DHCP radio selected; lease/status visible",
                     device=dev, recovered=True)
        return True
    _fail_shot(win, f"{dev}_dhcp_client.png")
    record_event("pc_dhcp_unverified",
                 "DHCP radio clicked but no lease/status became readable",
                 device=dev, recovered=False)
    return False

# AUTO-LEARNED PC TILE SPOTS -------------------------------------------
# When a tile click is VERIFIED (the RIGHT panel opened), the exact
# screen spot is saved to pc_tiles.json and used FIRST on future runs -
# the autopilot teaches itself tile positions from its own mistakes
# (user request: auto-learn / auto-click).
PC_LEARNED_FILE = _safe_path("pc_tiles.json")
PC_LEARNED: dict = {}
try:
    if os.path.exists(PC_LEARNED_FILE):
        with open(PC_LEARNED_FILE) as f:
            PC_LEARNED = json.load(f)
except Exception as e:
    print(f"pc_tiles load failed: {e}")

# MIGRATION (Sep 2026): the old 'fields' entry stored per-field click fys
# learned by blind dy-nudging. Real runs poisoned it (journal: mask row
# drifted to 0.311, PAST the gw row at 0.305) so the IP/mask values were
# typed into the Gateway/DNS rows over and over. It is dropped on load;
# field rows are now grounded on OCR label positions (see
# _resolve_pc_field_rows) and only exact label rows are ever learned.
if isinstance(PC_LEARNED.pop("fields", None), dict):
    try:
        with open(PC_LEARNED_FILE, "w") as f:
            json.dump(PC_LEARNED, f, indent=2)
    except Exception as e:
        print(f"pc_tiles migration save failed: {e}")
    else:
        print("pc_tiles migration: dropped poisoned legacy 'fields' entry")

# MIGRATION 2 (Sep 2026): tile spots learned before the icon-offset fix
# point at the tile LABEL (not clickable) instead of the icon above it.
# Drop them once so the fixed text strategy runs and re-learns exact
# icon spots from verified opens.
if not PC_LEARNED.get("tile_spots_reset_v2"):
    dropped = [k for k in ("ip_config", "cmd") if k in PC_LEARNED]
    for k in dropped:
        PC_LEARNED.pop(k, None)
    PC_LEARNED["tile_spots_reset_v2"] = True
    try:
        with open(PC_LEARNED_FILE, "w") as f:
            json.dump(PC_LEARNED, f, indent=2)
    except Exception as e:
        print(f"pc_tiles migration save failed: {e}")
    else:
        if dropped:
            print(f"pc_tiles migration: dropped stale label spots {dropped}")

# MIGRATION 3 (Sep 2026): 'field_rows' learned while row_of() used the
# word WIDTH instead of HEIGHT are all biased ~+0.03 (one row down) yet
# still pass validation, so they would be reused whenever live OCR
# flakes. Drop once; the fixed detector re-learns exact rows.
if not PC_LEARNED.get("field_rows_reset_v3"):
    if "field_rows" in PC_LEARNED:
        PC_LEARNED.pop("field_rows", None)
        print("pc_tiles migration: dropped width-biased field_rows")
    PC_LEARNED["field_rows_reset_v3"] = True
    try:
        with open(PC_LEARNED_FILE, "w") as f:
            json.dump(PC_LEARNED, f, indent=2)
    except Exception as e:
        print(f"pc_tiles migration save failed: {e}")

# v4: desktop-tile spots are scoped by device type.  A spot learned on a
# Server-PT desktop was being reused on a PC-PT desktop, where the tile grid is
# laid out differently, so the same coordinate opened a different panel: MGR1
# (PC) was sent to "Terminal configuration" instead of Command Prompt in the
# 2026-09-16 run, and the re-learned PC spot then overwrote the Servers' one.
# Drop the ambiguous unscoped entries; the per-type ladders re-learn them.
if not PC_LEARNED.get("tile_spots_scoped_v4"):
    for _stale in ("ip_config", "cmd"):
        PC_LEARNED.pop(_stale, None)
    PC_LEARNED["tile_spots_scoped_v4"] = True
    try:
        with open(PC_LEARNED_FILE, "w") as f:
            json.dump(PC_LEARNED, f, indent=2)
    except Exception as e:
        print(f"pc_tiles scope migration save failed: {e}")


def _pc_spot_key(key: str, dev: str = "") -> str:
    """Scope a desktop-tile spot to the device type (PC-PT vs Server-PT).

    The two desktops lay their tiles out differently, so a coordinate learned
    on one is a wrong-panel click on the other.  The strategy store already
    keys by type/model; this makes the fast-path cache agree with it.
    """
    try:
        dtype = str(_learning_context_for_device(dev).get("type") or "")
    except Exception:
        dtype = ""
    dtype = dtype.strip().lower()
    return f"{key}::{dtype}" if dtype else key


def _learned_spot(key: str, dev: str = ""):
    scoped = _pc_spot_key(key, dev)
    e = PC_LEARNED.get(scoped)
    if isinstance(e, dict):
        try:
            spot = (float(e["fx"]), float(e["fy"]))
            allowed = LEARNING.choose(
                "ui_coordinate", key, _learning_context_for_device(dev),
                [{"fx": round(spot[0], 4), "fy": round(spot[1], 4)}])
            return spot if allowed else None
        except Exception:
            return None
    return None


def _learn_spot(key: str, fx: float, fy: float, dev: str = ""):
    scoped = _pc_spot_key(key, dev)
    old = PC_LEARNED.get(scoped)
    PC_LEARNED[scoped] = {"fx": round(fx, 4), "fy": round(fy, 4)}
    try:
        with open(PC_LEARNED_FILE, "w") as f:
            json.dump(PC_LEARNED, f, indent=2)
    except Exception as e:
        log(f"pc_tiles save failed: {e}")
    moved = (not isinstance(old, dict)
             or abs(float(old.get("fx", 0)) - fx) > 0.01
             or abs(float(old.get("fy", 0)) - fy) > 0.01)
    if moved:
        record_event("pc_tile_learned", f"{scoped} spot "
                     f"({fx:.3f},{fy:.3f}) saved for future runs",
                     device=dev, recovered=True)
        log(f"LEARNED {scoped} tile spot ({fx:.3f},{fy:.3f}) - will be "
            f"used first next time")
    LEARNING.success("ui_coordinate", scoped,
                     _learning_context_for_device(dev),
                     {"fx": round(fx, 4), "fy": round(fy, 4)},
                     "desktop panel verified", persistent=True)
    _learning_refresh()

# ROOT CAUSE (user screenshot): the UIA window rect EXCLUDES the title
# bar, so fractions calibrated on the outer window landed ~35px too low -
# tab clicks hit the content edge and the Desktop tab never opened.
# Fix: click the actual TEXT (OCR word boxes) instead of guessing
# coordinates. Coordinate fallbacks below are UIA-rect-relative.
_PC_DESKTOP_TAB = (0.277, 0.032)
_PC_TILES = {"ip_config": (0.112, 0.126), "cmd": (0.667, 0.126)}
# Text that only appears when the Desktop GRID is open (tile labels).
# 'terminal'/'command' hit because OCR joins the tile label row.
_PC_GRID_MARKERS = ("web browser", "dial-up", "pc wireless",
                    "traffic generator", "terminal")


def _fuzzy_word_match(word: str, candidates: list) -> bool:
    """Tolerant word match: OCR mangles words (user's annotation dot
    turned 'Desktop' into 'Desktdp'). Same first 3 letters + high
    similarity + near-equal length. The length+ratio guards keep
    'Config' (tab) from matching 'configuration' (tile)."""
    import difflib
    for c in candidates:
        if word == c:
            return True
        if (len(word) >= 4 and abs(len(word) - len(c)) <= 2
                and word[:3] == c[:3]
                and difflib.SequenceMatcher(None, word, c).ratio() >= 0.8):
            return True
    return False


# Desktop tile geometry (measured on a real PC window): each tile is a
# large clickable ICON with its label rendered BELOW it. The label text
# itself is NOT clickable - clicking the OCR word box hits dead space
# (user report: mouse hovered 'IP Configuration' forever, panel never
# opened). Tile text-clicks must therefore aim ABOVE the word, at the
# icon center: ~0.085 window-heights above the label's bottom line.
_PC_TILE_ICON_ABOVE = 0.085


def _click_text_in_window(win, candidates: list, click_above: float = 0.0):
    """Click a rendered word inside the window by OCR word boxes.

    candidates: word list to try (e.g. ['desktop'] for the tab strip,
    or ['configuration'] for the IP Configuration tile label). Returns
    the ACTUAL click spot as (fx, fy) fractions of the window, or None.
    Words are matched fuzzily (see _fuzzy_word_match) anywhere in the
    window's top half (tabs + desktop grid live there).

    click_above: fraction of the window height to shift the click UP
    from the word center. Pass _PC_TILE_ICON_ABOVE for Desktop TILES
    (clicks the icon above the label); 0 for TAB STRIP words, which are
    themselves the clickable control.
    """
    if not TESSERACT_CMD:
        return False
    try:
        r = win.rectangle()
        l, t = r.left, r.top
        w, h = r.right - r.left, r.bottom - r.top
        from PIL import Image, ImageOps
        img = pyautogui.screenshot(region=(l, t, w, h)).convert("L")
        img = ImageOps.invert(img)
        os.makedirs(SHOTS, exist_ok=True)
        p = os.path.join(SHOTS, "_text.png")
        img.save(p)
        out = _run_hidden(
            [TESSERACT_CMD, p, "stdout", "--psm", "6", "tsv"],
            capture_output=True, text=True, timeout=10)
        for line in (out.stdout or "").splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) < 12 or not parts[11].strip():
                continue
            try:
                x, y = int(parts[6]), int(parts[7])
                ww, hh = int(parts[8]), int(parts[9])
            except Exception:
                continue
            word = re.sub(r"[^a-z0-9]", "", parts[11].lower())
            if word and _fuzzy_word_match(word, candidates):
                cx = x + ww // 2
                cy = y + hh // 2
                if click_above:
                    # tile label -> shift up onto the clickable icon;
                    # clamp so the click stays inside the window.
                    cy = min(max(cy - int(h * click_above), 2), h - 2)
                fx = cx / w if w else 0.0
                fy = cy / h if h else 0.0
                _safe_click(l + cx, t + cy)
                _interruptible_sleep(0.8)
                log(f"text-clicked '{word}' at window ({cx},{cy})"
                    + (" (icon above label)" if click_above else ""))
                return (round(fx, 4), round(fy, 4))
        return None
    except Exception as e:
        log(f"text click failed {candidates}: {e}")
        return None


def _panel_title(win) -> str:
    """OCR the open panel's title strip ('IP Configuration', 'MIB
    Browser', 'Command Prompt'...). Empty when no panel is open - the
    strip sits just below the tab row."""
    try:
        _OCR_CACHE.clear()
        return (_ocr_region(win, 0.045, 0.105, fx0=0.02, fx1=0.88, ttl=0)
                or "").strip().lower()
    except Exception:
        return ""


def _close_open_panel(win):
    """Click the X at the top-right of an open Desktop app panel."""
    try:
        r = win.rectangle()
        _safe_click(r.left + int((r.right - r.left) * 0.945),
                        r.top + int((r.bottom - r.top) * 0.073))
        _interruptible_sleep(0.6)
    except Exception as e:
        log(f"panel close failed: {e}")


def _pc_open_desktop_app(win, dev: str, tile_key: str, tile_names: list,
                         tile_words: list, verify_markers: list) -> bool:
    """Open the Desktop tab, then launch a desktop app tile.

    Self-correcting ladder (user request: auto-learn from mistakes):
      learned spot -> UIA name -> OCR text click -> taught coordinates.
    After every click the PANEL TITLE is read: right panel = verify +
    LEARN the spot; wrong panel (e.g. MIB Browser) = close it, journal
    it, and try the next strategy.
    """
    r = win.rectangle()

    def click_frac_win(fx, fy):
        _safe_click(r.left + int((r.right - r.left) * fx),
                        r.top + int((r.bottom - r.top) * fy))
        _interruptible_sleep(0.8)

    def grid_visible() -> bool:
        _OCR_CACHE.clear()
        txt = (_ocr_region(win, 0.08, 0.55) or "").lower()
        hit = any(m in txt for m in _PC_GRID_MARKERS)
        if not hit:
            tail = " ".join(txt.split())[:130]
            log(f"{dev}: grid OCR check missed - saw: '{tail}'")
        return hit

    opened = False
    for attempt, how in enumerate(("uia", "text", "coord"), 1):
        # Re-focus before EVERY attempt: if any other window (the app,
        # a browser...) covered PT, clicks and OCR hit the wrong window.
        if not _focus_pt_window(win, dev, f"Desktop tab {how}"):
            continue
        _interruptible_sleep(0.3)
        if how == "uia":
            click_by_names(["Desktop"], f"{dev} Desktop tab",
                           timeout_s=1.5)
        elif how == "text":
            spot = _click_text_in_window(win, ["desktop"])
            if not spot:
                continue
        else:
            click_frac_win(*_PC_DESKTOP_TAB)
        if grid_visible():
            log(f"{dev}: Desktop grid open (via {how})")
            opened = True
            break
        if how == "text":
            # The word 'desktop' exists ONLY in the tab strip - clicking
            # it switches the tab by construction. The grid OCR check
            # can flake on transition frames (user run: grid visibly
            # open, OCR missed it 3x), so trust a confirmed text-click.
            log(f"{dev}: grid OCR unclear but 'desktop' text-click "
                f"landed in the tab strip - trusting it")
            opened = True
            break
        log(f"{dev}: Desktop grid not visible (attempt {attempt}: {how})")
    if not opened:
        record_event("pc_desktop_tab",
                     "Desktop tab would not open - is another window "
                     "covering Packet Tracer? Keep PT in front during "
                     "the whole run.", device=dev, recovered=False)
        return False
    # tile: self-correcting ladder. Extra evidence: opening a panel
    # REPLACES the tile grid, so "grid gone" after a text-click also
    # proves the tile launched. Wrong panels are closed and journalled;
    # every VERIFIED click is saved as a learned spot.
    strategies = []
    learned = _learned_spot(tile_key, dev)
    if learned:
        strategies.append(("learned", learned))
        log(f"{dev}: using LEARNED {tile_key} spot "
            f"({learned[0]:.3f},{learned[1]:.3f})")
    strategies += [("uia", None), ("text", None),
                   ("coord", _PC_TILES[tile_key])]
    for attempt, (how, arg) in enumerate(strategies, 1):
        if not _focus_pt_window(win, dev, f"{tile_key} tile {how}"):
            continue
        _interruptible_sleep(0.3)
        spot = None
        if how == "learned":
            click_frac_win(*arg)
        elif how == "uia":
            click_by_names(tile_names, f"{dev} {tile_names[0]} tile",
                           timeout_s=1.5)
        elif how == "text":
            # tiles: aim at the ICON above the label (the label text
            # itself is not clickable in PT).
            spot = _click_text_in_window(win, tile_words,
                                         click_above=_PC_TILE_ICON_ABOVE)
            if not spot:
                continue
        else:
            click_frac_win(*arg)
        _interruptible_sleep(0.9)
        used_spot = (arg if how in ("learned", "coord") else spot)
        title = _panel_title(win)
        _OCR_CACHE.clear()
        txt = (_ocr_region(win, 0.08, 0.60) or "").lower()
        verified = (any(m in title for m in verify_markers)
                    or any(m in txt for m in verify_markers)
                    or (how == "text" and not grid_visible()))
        # A tile click is accepted only while PT still owns the foreground;
        # otherwise a covering app can make the subsequent OCR read the
        # wrong window and falsely validate a stale panel.
        verified = verified and _focus_pt_window(
            win, dev, f"verify {tile_key} panel")
        if verified:
            if used_spot:
                _learn_spot(tile_key, used_spot[0], used_spot[1], dev)
            log(f"{dev}: {tile_names[0]} panel open (via {how}, "
                f"attempt {attempt})")
            return True
        if how == "learned":
            # STALE-SPOT EVICTION: the remembered click just failed, so
            # forget it NOW instead of retrying the same miss on every
            # future run. The working strategy below re-learns.
            if PC_LEARNED.pop(tile_key, None) is not None:
                try:
                    with open(PC_LEARNED_FILE, "w") as f:
                        json.dump(PC_LEARNED, f, indent=2)
                except Exception as e:
                    log(f"pc_tiles evict save failed: {e}")
                record_event("pc_tile_stale",
                             f"learned {tile_key} spot missed - evicted, "
                             f"falling through to other strategies",
                             device=dev, recovered=True)
                log(f"{dev}: LEARNED {tile_key} spot STALE - evicted")
            LEARNING.failure(
                "ui_coordinate", tile_key,
                _learning_context_for_device(dev),
                {"fx": round(arg[0], 4), "fy": round(arg[1], 4)},
                "panel was not verified", persistent=True)
            _learning_refresh()
        if title.strip():
            # WRONG app opened (e.g. MIB Browser): close it and try the
            # next strategy - this is the self-correction loop.
            log(f"{dev}: WRONG PANEL '{title.strip()[:60]}' - closing "
                f"and retrying with next strategy")
            record_event("pc_wrong_panel", title.strip()[:80],
                         device=dev, recovered=False)
            _close_open_panel(win)
        else:
            log(f"{dev}: {tile_names[0]} panel not confirmed "
                f"(attempt {attempt}: {how})")
    record_event("pc_tile_missing", f"{tile_names[0]} tile would not open",
                 device=dev, recovered=False)
    return False


def _light_field_bands(img_path: str, y0=0.18, y1=0.42, x0=0.28,
                       x1=0.95) -> list:
    """Find the IPv4 input boxes in the IP Config panel via BORDER rows.

    Measured on a real panel: the boxes are dark (57) like the panel,
    outlined by subtle ~1px border rows (>62) spanning the input column.
    Border-line rows cluster at each box top; the Interface combo and
    IPv6 section fall outside the y range. Returns click points (fx, fy)
    centered inside each of the IPv4 boxes (ip, mask, gateway, DNS server).
    """
    try:
        from PIL import Image
        img = Image.open(img_path).convert("L")
    except Exception:
        return []
    W, H = img.size
    x0i, x1i = int(W * x0), int(W * x1)
    xs = list(range(x0i, x1i, 3))
    if not xs:
        return []
    px = img.load()
    lines = []
    for y in range(int(H * y0), int(H * y1)):
        frac = sum(1 for x in xs if px[x, y] > 62) / len(xs)
        if frac > 0.5:
            if lines and y - lines[-1][-1] <= 2:
                lines[-1].append(y)
            else:
                lines.append([y])
    tops = [sum(l) / len(l) for l in lines if l]
    # a box needs ~20px headroom below its top border for the next line
    boxes = [t for t in tops
             if not any(0 < (u - t) * H < 18 for u in tops)]
    merged = []
    for t in boxes:
        if merged and (t - merged[-1]) * H < 15:
            continue
        merged.append(t)
    cx = round((x0 + x1) / 2 + 0.03, 4)
    return [(cx, round(t / H + 12.0 / H, 4)) for t in merged[:4]]


def _digits(s: str) -> str:
    return re.sub(r"\D", "", s or "")


def _learned_field_rows() -> dict:
    e = PC_LEARNED.get("field_rows")
    if isinstance(e, dict) and all(k in e for k in ("ip", "mask", "gw")):
        rows = {k: float(v) for k, v in e.items()}
        rows.setdefault("dns", _PC_FIELD_FRACS["dns"])
        return rows
    return {}


def _learn_field_rows(rows: dict, dev: str = ""):
    """Save verified label-row positions for the IP panel fields.

    Replaces the old 'fields' entry (which got poisoned when a value
    verified in a NEIGHBOR row - the user run where the IP landed in
    Gateway/DNS). Row detection is label-based now, so this only ever
    stores exact rows.
    """
    old = PC_LEARNED.get("field_rows")
    PC_LEARNED.pop("fields", None)  # drop legacy poisoned data
    PC_LEARNED["field_rows"] = {k: round(v, 4) for k, v in rows.items()}
    try:
        with open(PC_LEARNED_FILE, "w") as f:
            json.dump(PC_LEARNED, f, indent=2)
    except Exception as e:
        log(f"pc_rows save failed: {e}")
    if old != PC_LEARNED["field_rows"]:
        record_event("pc_rows_learned",
                     f"label rows {PC_LEARNED['field_rows']} saved",
                     device=dev, recovered=True)
        log(f"LEARNED IP panel field rows {PC_LEARNED['field_rows']} - "
            f"next PCs click straight")


def _detect_field_rows_by_labels(win) -> dict:
    """Find the IPv4 field rows via their left-column LABELS.

    Tesseract TSV word boxes: 'Address' (topmost = IPv4 Address),
    'Mask' (Subnet Mask - only exists in the IPv4 section), 'Gateway'
    (topmost = IPv4 Default Gateway). The value box is vertically
    centered on its label row, so the label's y IS the click row.
    Search is limited to the label column and top 45% of the window so
    IPv6 section duplicates can't interfere.
    """
    if not TESSERACT_CMD:
        return {}
    try:
        r = win.rectangle()
        l, t = r.left, r.top
        w, h = r.right - r.left, r.bottom - r.top
        from PIL import Image, ImageOps
        img = pyautogui.screenshot(region=(l, t, w, h)).convert("L")
        img = ImageOps.invert(img)
        os.makedirs(SHOTS, exist_ok=True)
        p = os.path.join(SHOTS, "_labels.png")
        img.save(p)
        out = _run_hidden(
            [TESSERACT_CMD, p, "stdout", "--psm", "6", "tsv"],
            capture_output=True, text=True, timeout=10)
        words = []
        for line in (out.stdout or "").splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) >= 12 and parts[11].strip():
                try:
                    wd = (re.sub(r"[^a-z0-9]", "", parts[11].lower()),
                          int(parts[6]), int(parts[7]), int(parts[8]),
                          int(parts[9]))
                except Exception:
                    continue
                if wd[0] and wd[1] < w * 0.45 and wd[2] < h * 0.45:
                    words.append(wd)
        def row_of(token, nth=1):
            hits = sorted((wd for wd in words if token in wd[0]),
                          key=lambda z: z[2])
            if len(hits) >= nth:
                wd = hits[nth - 1]
                # wd = (text, left, top, width, height): vertical center
                # is top + HEIGHT/2 (wd[4]). Using wd[3] (width) here
                # shifted every row ~+0.03 - a full row down - so the IP
                # landed in Subnet Mask and the gateway in DNS (user
                # screenshots: 'Invalid subnet address entered').
                return round((wd[2] + wd[4] / 2) / h + 0.004, 4)
            return None
        rows = {}
        ip_row = row_of("address")          # first = IPv4 Address
        mask_row = row_of("mask")           # only Subnet Mask has it
        gw_row = row_of("gateway")          # first = IPv4 section
        if ip_row:
            rows["ip"] = ip_row
        if mask_row:
            rows["mask"] = mask_row
        if gw_row:
            rows["gw"] = gw_row
        dns_row = row_of("dns")
        if dns_row:
            rows["dns"] = dns_row
        return rows
    except Exception as e:
        log(f"label row scan failed: {e}")
        return {}


def _valid_field_rows(rows: dict) -> bool:
    """Sanity gate for a candidate {ip, mask, gw} row set.

    Rejects the exact poisoning seen in real runs: rows out of order,
    two rows on the same line (pitch < 0.02), rows outside the IPv4
    section (fy >= 0.42 is IPv6/DNS territory), or an implausible
    spread. A rejected set falls back to fixed fractions - it is NEVER
    learned and NEVER clicked as-is, so Gateway/DNS cross-typing from
    drifted rows cannot recur.
    """
    try:
        ip, mask, gw = float(rows["ip"]), float(rows["mask"]), \
            float(rows["gw"])
    except Exception:
        return False
    if not all(0.10 < v < 0.42 for v in (ip, mask, gw)):
        return False
    if not (ip < mask < gw):
        return False
    if min(mask - ip, gw - mask) < 0.02:
        return False
    if gw - ip > 0.15:
        return False
    if "dns" in rows:
        try:
            dns = float(rows["dns"])
        except Exception:
            return False
        if not (gw < dns < 0.42) or dns - gw < 0.02:
            return False
    return True


def _resolve_pc_field_rows(win, dev: str = "") -> tuple:
    """Return (fx, rows, source) for the IPv4 ip/mask/gw value boxes.

    Priority: live OCR label rows (validated) -> learned label rows
    (validated) -> visual band detection (sorted + validated) -> fixed
    fractions. Only validated sets are used; label-detected sets are
    saved via _learn_field_rows so the next PC clicks straight.
    Source is one of live/learned/visual/fixed - the caller evicts
    learned rows when a fill using them ultimately fails.
    """
    fx = 0.60
    live = _detect_field_rows_by_labels(win)
    if live and _valid_field_rows(live):
        log(f"{dev}: label rows {live} (live OCR)")
        _learn_field_rows(live, dev)
        return fx, live, "live"
    if live:
        log(f"{dev}: live label rows {live} FAILED validation - ignoring")
    learned = _learned_field_rows()
    if learned and _valid_field_rows(learned):
        log(f"{dev}: using LEARNED label rows {learned}")
        return fx, learned, "learned"
    if learned:
        log(f"{dev}: learned rows {learned} FAILED validation - ignoring")
    try:
        r = win.rectangle()
        os.makedirs(SHOTS, exist_ok=True)
        p = os.path.join(SHOTS, f"{_safe_stem(dev)}_panel.png")
        pyautogui.screenshot(region=(r.left, r.top, r.right - r.left,
                                     r.bottom - r.top)).save(p)
    except Exception as e:
        log(f"{dev}: panel screenshot failed: {e}")
        p = ""
    spots = _light_field_bands(p) if p else []
    if len(spots) >= 3:
        cand = {"ip": spots[0][1], "mask": spots[1][1], "gw": spots[2][1]}
        if len(spots) >= 4:
            cand["dns"] = spots[3][1]
        if _valid_field_rows(cand):
            fx = spots[0][0]
            log(f"{dev}: detected input fields {cand} (visual bands)")
            return fx, cand, "visual"
        log(f"{dev}: visual bands {cand} FAILED validation - ignoring")
    else:
        log(f"{dev}: field detection found {len(spots)} band(s)")
    rows = {"ip": _PC_FIELD_FRACS["ip"], "mask": _PC_FIELD_FRACS["mask"],
            "gw": _PC_FIELD_FRACS["gw"], "dns": _PC_FIELD_FRACS["dns"]}
    log(f"{dev}: using fixed fallback rows {rows}")
    return fx, rows, "fixed"


def _dismiss_error_dialog(win, dev: str = ""):
    """Dismiss PT's modal error box ('Invalid subnet address entered.')."""
    try:
        _OCR_CACHE.clear()
        txt = (_ocr_region(win, 0.35, 0.68, fx0=0.25, fx1=0.8) or "").lower()
        if "invalid" in txt or "error" in txt:
            r = win.rectangle()
            _safe_click(r.left + int((r.right - r.left) * 0.48),
                            r.top + int((r.bottom - r.top) * 0.55))
            _interruptible_sleep(0.5)
            log(f"{dev}: dismissed PT error dialog (OK)")
            record_event("pc_error_dialog", "invalid-value modal dismissed",
                         device=dev, recovered=True)
            return True
    except Exception:
        pass
    return False


def _fill_field(win, dev: str, fx: float, fy: float, val: str,
                check: str) -> tuple:
    """Click one field row, type ONCE, verify in that same row.

    Bounded by design (this is the anti-thrash fix): a maximum of TWO
    keystroke passes per call - the initial type plus ONE nudge retry
    when the row still shows the untouched default. It never cycles
    through dy offsets retyping the value, which is what produced the
    visible loop of 192.../255... being entered, deleted and re-entered
    in the Gateway/DNS rows. Returns (fy_used, verified).

    Row-aware verification (band narrower than the row pitch) means a
    value typed into a NEIGHBOR row can no longer 'verify' - that was
    the Gateway/DNS cross-typing bug.
    """
    if not (val or "").strip() or (val or "").strip() == "0.0.0.0":
        return fy, True  # nothing to set - leave PT's default alone
    r = win.rectangle()

    def _type_once(at_fy: float):
        x = r.left + int((r.right - r.left) * fx)
        y = r.top + int((r.bottom - r.top) * at_fy)
        _safe_click(x, y)
        _interruptible_sleep(0.25)
        _safe_hotkey("ctrl", "a")
        _interruptible_sleep(0.12)
        _safe_write(val, interval=0.02)
        _interruptible_sleep(0.35)
        try:
            _safe_press("tab")  # commit so PT accepts/auto-mask fires
            _interruptible_sleep(0.25)
        except Exception:
            pass
        _dismiss_error_dialog(win, dev)

    def _row_verified(at_fy: float) -> bool:
        _OCR_CACHE.clear()
        band = (_ocr_region(win, max(0.05, at_fy - 0.018),
                            min(0.95, at_fy + 0.022)) or "").lower()
        if not check:
            return True
        if re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", str(check)):
            return _value_in_text(str(check), band)
        return str(check).lower() in band

    _type_once(fy)
    if _row_verified(fy):
        return fy, True
    # single nudge: the click may have landed on the row edge. One small
    # retry, then STOP - never loop typings into this or other rows.
    log(f"{dev}: '{val}' not verified in its row at fy {fy:.3f} - "
        f"one nudge retry, then moving on")
    _type_once(round(fy + 0.006, 4))
    if _row_verified(fy):
        return fy, True
    log(f"{dev}: '{val}' STILL not verified at fy {fy:.3f} - leaving it, "
        f"will report (not retrying into neighbor rows)")
    return fy, False


def _config_pc_desktop(rect, dev: str, slot: int, ipcfg: dict,
                       project: str) -> bool:
    """Fill Desktop > IP Configuration on a PC: static ip/mask/gateway,
    then OCR-verify the IP is actually visible in the panel."""
    win = _open_device_window(rect, dev, slot, project)
    if win is None:
        return False
    try:
        # Desktop tab + IP Configuration tile, verified at every step
        if not _pc_open_desktop_app(win, dev, "ip_config",
                                    ["IP Configuration"],
                                    ["configuration"],
                                    ["ip configuration", "subnet mask",
                                     "fastethernet0"]):
            return False
        _interruptible_sleep(1.0)
        # Field rows come from _resolve_pc_field_rows: live OCR label
        # positions first, validated learned rows next, visual bands,
        # fixed fractions last. Every candidate set must pass
        # _valid_field_rows (strictly increasing, inside the IPv4
        # section) - unvalidated rows are NEVER clicked, so the
        # Gateway/DNS cross-typing loop cannot recur.
        fx, rows, row_source = _resolve_pc_field_rows(win, dev)
        # DHCP CLIENT: the plan asks this PC to lease its address from the
        # network's DHCP server.  PT's IP Configuration panel has a radio
        # pair - the 'DHCP' radio sits just above the static IP row, and
        # selecting it disables the static fields and starts the lease.
        # Filling static fields onto a DHCP panel typed 192.168... into a
        # dead box, so the client choice is handled HERE and verified by
        # reading a lease back from the panel.
        if str(ipcfg.get("dhcp", "")).strip().lower() in {"1", "true",
                                                          "yes", "dhcp"}:
            ok_dhcp = _pc_select_dhcp(win, dev)
            RUN["pcs_configured"] = RUN.get("pcs_configured", 0) \
                + (1 if ok_dhcp else 0)
            RUN.setdefault("pc_config_results", {})[dev] = {
                "status": "verified" if ok_dhcp else "failed",
                "mode": "dhcp_client",
                "row_source": row_source,
            }
            return ok_dhcp
        keys = ("ip", "mask", "gw")
        if str(ipcfg.get("dns", "")).strip() not in {"", "0.0.0.0"}:
            keys = (*keys, "dns")
        vals = [ipcfg.get(k, "") for k in keys]
        checks = [str(v or "") for v in vals]

        def _panel_shows_config() -> bool:
            # OCR-VERIFY every requested IPv4 value, not only the address.
            # The previous IP-only gate allowed a blank gateway/DNS field to
            # pass while the screenshot still displayed 0.0.0.0.
            _OCR_CACHE.clear()
            txt = _ocr_region(win, 0.10, 0.45) or ""
            for val in vals:
                value = str(val or "").strip()
                if not value or value == "0.0.0.0":
                    continue
                if not _value_in_text(value, txt):
                    return False
            return bool(vals and str(vals[0]).strip() and
                        str(vals[0]).strip() != "0.0.0.0")

        # single fill pass: each field typed at most twice (see
        # _fill_field) - no refill storms.
        verified = {}
        for k, val, chk in zip(keys, vals, checks):
            _, ok_row = _fill_field(
                win, dev, fx, rows.get(k, _PC_FIELD_FRACS[k]), val, chk,
            )
            verified[k] = ok_row
        if _panel_shows_config() and all(
                verified.get(k, False) for k in keys):
            log(f"{dev}: PC IPv4 configuration VERIFIED on panel")
            ok = True
        else:
            # ONE targeted second pass over the rows that failed only -
            # never a blind refill of all fields (that retyped 192... /
            # 255... into Gateway/DNS in a loop). Then stop: report.
            failed = [k for k in keys if not verified.get(k, False)]
            if failed:
                log(f"{dev}: IP not visible - single retry of "
                    f"failed row(s) {failed} only")
                _interruptible_sleep(0.5)
                for k in failed:
                    i = keys.index(k)
                    _, ok_row = _fill_field(
                        win, dev, fx,
                        rows.get(k, _PC_FIELD_FRACS[k]),
                        vals[i], checks[i],
                    )
                    verified[k] = ok_row
                _interruptible_sleep(0.5)
            ok = (_panel_shows_config() and all(
                verified.get(k, False) for k in keys))
            if ok:
                log(f"{dev}: PC IPv4 configuration VERIFIED on panel "
                    "(after retry)")
            else:
                log(f"{dev}: IP still not visible - STOPPING (rows "
                    f"{verified}), not retyping into neighbor fields")
        if ok:
            RUN["pcs_configured"] = RUN.get("pcs_configured", 0) + 1
            RUN.setdefault("pc_config_results", {})[dev] = {
                "status": "verified", "values": dict(zip(keys, vals)),
                "row_source": row_source,
            }
            record_event("pc_config", f"static {vals[0]} / {vals[1]} "
                         f"gw {vals[2]}"
                         + (f" dns {vals[3]}" if len(vals) > 3 else "")
                         + " (verified)", device=dev, recovered=True)
        else:
            RUN.setdefault("pc_config_results", {})[dev] = {
                "status": "failed", "values": dict(zip(keys, vals)),
                "verified_rows": verified, "row_source": row_source,
            }
            record_event("pc_config_failed",
                         f"rows {verified} filled but IP {vals[0]} not "
                         f"visible (single targeted retry done - "
                         f"check {dev}_panel.png shot)", device=dev,
                         recovered=False)
            if row_source == "learned" and "field_rows" in PC_LEARNED:
                # the remembered rows just failed a full fill: evict so
                # the next run re-detects instead of repeating the miss.
                PC_LEARNED.pop("field_rows", None)
                try:
                    with open(PC_LEARNED_FILE, "w") as f:
                        json.dump(PC_LEARNED, f, indent=2)
                except Exception as e:
                    log(f"pc_rows evict save failed: {e}")
                record_event("pc_rows_stale",
                             "learned field rows failed - evicted",
                             device=dev, recovered=True)
                log(f"{dev}: LEARNED field rows STALE - evicted")
        return ok
    except Exception as e:
        log(f"{dev}: PC config failed: {e}")
        record_event("pc_config_failed", str(e)[:120], device=dev,
                     recovered=False)
        return False
    finally:
        _close_device_window(win, dev)


def _pc_ping(rect, dev: str, slot: int, targets: list,
             project: str, results: list | None = None,
             count_run: bool = True) -> int:
    r"""Ping targets from a PC's Desktop > Command Prompt.

    Fixes: clicks the console BODY first (keystrokes were going nowhere
    - the user's screenshot showed an empty C:\>), and verifies each
    ping by OCR (the 'Pinging x.x.x.x' echo / 'Reply from') with one
    re-click + retype retry.
    """
    targets = [str(target).strip() for target in (targets or []) if str(target).strip()]
    if count_run:
        RUN["pings_expected"] = RUN.get("pings_expected", 0) + len(targets)

    def record_unopened(reason: str):
        if count_run:
            RUN["pings_failed"] = RUN.get("pings_failed", 0) + len(targets)
        for target in targets:
            row = {"source": dev, "target": target, "ok": False,
                   "attempts": 0, "evidence": reason}
            if results is not None:
                results.append(row)
            record_event("ping_test" if count_run else "audit_ping",
                         f"ping {target} from {dev}: {reason}",
                         device=dev, recovered=False)

    win = _open_device_window(rect, dev, slot, project)
    if win is None:
        record_unopened("device window unavailable")
        return 0
    successes = 0
    try:
        # Desktop tab + Command Prompt tile, verified at every step
        if not _pc_open_desktop_app(win, dev, "cmd", ["Command Prompt"],
                                    ["prompt", "command"],
                                    ["command prompt", "command line",
                                     "c:"]):
            record_unopened("Command Prompt panel unavailable")
            return 0
        _interruptible_sleep(1.0)

        def click_body():
            r = win.rectangle()
            _safe_click(r.left + int((r.right - r.left) * 0.5),
                            r.top + int((r.bottom - r.top) * 0.45))
            _interruptible_sleep(0.4)

        click_body()
        for t in targets:
            ok = False
            tail = ""
            for attempt in (1, 2):
                typed = _type_line(f"ping {t}", 25, win=win, dev=dev)
                _interruptible_sleep(3.5)  # let the 4 echo requests finish
                _OCR_CACHE.clear()
                txt = (_ocr_region(win, 0.10, 0.92) or "").lower() \
                    if typed else ""
                tail = txt[txt.rfind("pinging"):] if "pinging" in txt \
                    else txt[-600:]
                tdig = _digits(t)
                got = (typed and "reply from" in tail and
                       tdig in _digits(tail) and
                       ("ttl" in tail or "bytes" in tail) and
                       "request timed out" not in tail)
                # A typed command or echoed IP is not reachability evidence;
                # require a real reply line from the current ping output.
                if got:
                    ok = True
                    log(f"{dev}: ping {t} -> SUCCESS (attempt {attempt})")
                    break
                log(f"{dev}: ping {t} no result (attempt {attempt}) - "
                    f"re-clicking console and retrying")
                click_body()
            if ok:
                successes += 1
            if count_run:
                RUN["pings_ok" if ok else "pings_failed"] = \
                    RUN.get("pings_ok" if ok else "pings_failed", 0) + 1
            if results is not None:
                results.append({
                    "source": dev,
                    "target": t,
                    "ok": ok,
                    "attempts": attempt,
                    "evidence": tail[-260:],
                })
            record_event("ping_test" if count_run else "audit_ping",
                         f"ping {t} from {dev}",
                         device=dev, recovered=ok)
    except Exception as e:
        log(f"{dev}: ping stage failed: {e}")
    finally:
        _close_device_window(win, dev)
    return successes


def _audit_reachability(rect, devices: list, names: list, project: str) -> dict:
    """Run bounded endpoint reachability tests against the live PT network.

    Each PC/server tests its configured gateway and the other discovered
    endpoint addresses. This changes no configuration; it only types ping in
    Command Prompt and reads the result. The cap prevents a large .pkt from
    turning Analyze into an unbounded test storm.
    """
    endpoint_devices = [
        d for d in devices if d.get("type") in ("pc", "server")
    ][:8]
    ip_by_name = {}
    for device in endpoint_devices:
        ipcfg = device.get("ipcfg") or {}
        ip = str(ipcfg.get("ip") or "").strip()
        if re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", ip) and ip != "0.0.0.0":
            ip_by_name[device.get("name")] = ip
    results = []
    skipped = []
    for device in endpoint_devices:
        if stopped():
            break
        source = str(device.get("name") or "")
        ipcfg = device.get("ipcfg") or {}
        source_ip = ip_by_name.get(source, "")
        if not source_ip:
            skipped.append({"source": source, "reason": "no readable IPv4 address"})
            continue
        targets = []
        gateway = str(ipcfg.get("gw") or "").strip()
        if (re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", gateway)
                and gateway not in ("0.0.0.0", source_ip)):
            targets.append(gateway)
        for peer, peer_ip in ip_by_name.items():
            if peer != source and peer_ip not in targets:
                targets.append(peer_ip)
        if not targets:
            skipped.append({"source": source,
                            "reason": "no gateway or peer endpoint was readable"})
            continue
        targets = targets[:4]
        slot = names.index(source) if source in names else -1
        if slot < 0:
            skipped.append({"source": source, "reason": "canvas slot unavailable"})
            continue
        log(f"AUDIT PING TEST: {source} -> {targets}")
        _pc_ping(rect, source, slot, targets, project,
                 results=results, count_run=False)
    passed = sum(1 for result in results if result.get("ok"))
    failed = len(results) - passed
    return {
        "enabled": True,
        "attempted": len(results),
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "results": results,
        "note": "Ping results are live Packet Tracer evidence; a skipped test means the endpoint IP/gateway or slot was unreadable.",
    }


# SERVER SERVICES -----------------------------------------------------
# Server-PT has a Services TAB (HTTP, DHCP, DNS, AAA, EMAIL, FTP, ...)
# with a left service list and per-service panels (On/Off radios, label
# + value-box rows, Add/Save buttons). All automation here is
# OCR-driven and bounded: every step verifies, failures are logged and
# journalled, never looped.
_SVC_TITLES = {"dhcp": "dhcp", "dns": "dns", "http": "http",
               "aaa": "aaa", "email": "email", "ftp": "ftp",
               "ntp": "ntp", "tftp": "tftp", "syslog": "syslog",
               "dhcpv6": "dhcpv6", "iot": "iot", "prp": "prp"}


def _win_words(win, psm: int = 6) -> tuple:
    """OCR word boxes for the whole device window.

    Returns (words, l, t, w, h): words = [(word, x, y, ww, hh)] in
    window pixels. One fresh screenshot per call (no cache).
    """
    try:
        r = win.rectangle()
        l, t = r.left, r.top
        w, h = r.right - r.left, r.bottom - r.top
        if w < 60 or h < 60 or not TESSERACT_CMD:
            return [], l, t, w, h
        from PIL import Image, ImageOps
        img = pyautogui.screenshot(region=(l, t, w, h)).convert("L")
        img = ImageOps.invert(img)
        os.makedirs(SHOTS, exist_ok=True)
        p = os.path.join(SHOTS, "_srv.png")
        img.save(p)
        out = _run_hidden(
            [TESSERACT_CMD, p, "stdout", "--psm", str(psm), "tsv"],
            capture_output=True, text=True, timeout=15)
        words = []
        for line in (out.stdout or "").splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) >= 12 and parts[11].strip():
                try:
                    words.append(
                        (re.sub(r"[^a-z0-9]", "", parts[11].lower()),
                         int(parts[6]), int(parts[7]),
                         int(parts[8]), int(parts[9])))
                except Exception:
                    continue
        return [wd for wd in words if wd[0]], l, t, w, h
    except Exception as e:
        log(f"word scan failed: {e}")
        return [], 0, 0, 0, 0


def _srv_open_services(win, dev: str) -> bool:
    """Click the Services tab; verify the service list is visible."""
    for how in ("uia", "text"):
        if not _focus_pt_window(win, dev, f"Services tab {how}"):
            continue
        _interruptible_sleep(0.3)
        if how == "uia":
            click_by_names(["Services"], f"{dev} Services tab",
                           timeout_s=2.0)
        else:
            if not _click_text_in_window(win, ["services"]):
                continue
        _interruptible_sleep(0.8)
        _OCR_CACHE.clear()
        txt = (_ocr_region(win, 0.08, 0.95, fx0=0.02, fx1=0.40) or ""
               ).lower()
        if all(m in txt for m in ("dhcp", "dns")) and "http" in txt:
            log(f"{dev}: Services list open (via {how})")
            return True
        if how == "text":
            log(f"{dev}: service list OCR unclear but 'services' "
                f"text-click landed in the tab strip - trusting it")
            return True
        log(f"{dev}: Services list not visible (via {how})")
    record_event("srv_tab_missing", "Services tab would not open",
                 device=dev, recovered=False)
    return False


# Every label Packet Tracer puts in the Services sidebar.  The list is
# alphabetical-ish but DHCP/DHCPv6 and HTTP/HTTPS sit next to each other, and
# a substring test cannot tell them apart.
_SVC_LABELS = ("http", "https", "dhcp", "dhcpv6", "tftp", "dns", "syslog",
               "aaa", "ntp", "email", "ftp", "iot", "vm management",
               "radius eap", "prp")


def _svc_word_matches(word: str, token: str) -> bool:
    """True only when a sidebar word really names the requested service.

    Exact match wins.  A containing word is accepted only when it does not
    actually spell a *longer* known service: "dhcpv6" must never satisfy
    "dhcp", otherwise the DHCPv6 panel is clicked and - because the title
    check used the same substring test - accepted as the DHCP panel.
    """
    w = str(word or "").strip().lower()
    t = str(token or "").strip().lower()
    if not w or not t:
        return False
    if w == t:
        return True
    if t not in w:
        return False
    for label in _SVC_LABELS:
        if label != t and len(label) > len(t) and w.startswith(label):
            return False
    return True


# Where the Services LIST ends and the panel body begins.  `_srv_select`
# only ever clicks a row left of this edge; the field-label search used to
# reach out to 0.50, which put the list's own service words inside the label
# candidates.  The 2026-09-16 DHCP run failed exactly there: the sidebar row
# reads as the word 'dns' - an EXACT token match - so it outranked the real
# 'DNS Server' field row, that line supplied the ``fx`` and the fill landed
# in whatever panel was open (the read-back showed the DNS panel:
# '| AAA | DNS Server: Domain Name:').  One edge, one truth.
SRV_SIDEBAR_MAX_FX = 0.35
# Bottom of the panel's entry FORM when its own button row cannot be read.
SRV_BODY_FALLBACK_FY = 0.58
# The Add/Save/Remove row IS the form's bottom edge; the table sits under it.
_SRV_FORM_BUTTONS = ("add", "save", "remove")
# First time per run that the list and a field row spell one word.
_SRV_SHADOW_SEEN: set = set()


def _srv_sidebar_word(word: str) -> bool:
    """True when one OCR word spells a Services-list entry verbatim.

    Deliberately exact: a field label such as 'DNS Server' or 'Subnet Mask'
    is read as separate words, so a bare 'dns' word can be either the sidebar
    row or the field row - and the value-box evidence decides between those
    two, never the word itself.
    """
    w = _alnum(word)
    return bool(w) and any(_alnum(label) == w for label in _SVC_LABELS)


def _srv_form_bottom(words: list, h: float) -> float:
    """Bottom of the panel's entry form, read from the panel itself.

    The old fixed 0.58 clipped the label search above the DHCP pool form:
    the failing run reported 'start', 'mask', 'gateway' and 'user' as
    missing labels while 'dns' resolved, because on a maximized window the
    form sits lower than 0.58.  The panel's own Add/Save/Remove row is that
    bottom edge, so it is read from the same OCR pass instead of guessed.
    Clamped, and falls back to the old constant when no button row is
    visible, so a panel that reads nothing keeps today's behaviour.
    """
    if not words or not h:
        return SRV_BODY_FALLBACK_FY
    rows = [y for wd, x, y, ww, hh in words
            if wd in _SRV_FORM_BUTTONS and y > h * 0.20]
    if not rows:
        return SRV_BODY_FALLBACK_FY
    return round(min(0.92, max(0.30, min(rows) / h - 0.02)), 4)


def _srv_row_boxes(words: list, lx: float, lw: float, cy: float,
                   lh: float) -> list:
    """Digit boxes sitting on the same line, right of the label."""
    out = []
    for wd, x, y, ww, hh in words:
        if x <= lx + lw:      # the value box sits RIGHT of the label
            continue
        if abs((y + hh / 2) - cy) > max(6, lh * 0.75):
            continue          # different row
        # _win_words strips dots: '192', '168', '192168100'...
        if not re.fullmatch(r"\d{1,12}", wd):
            continue
        out.append((x, y, ww, hh))
    out.sort()
    return out


def _srv_cell_span(label_left: float, box_right: float, w: float) -> tuple:
    """Read-back band for one field cell: label -> right of its box.

    `_row_text` OCRs 0.02-0.97 of the window width, which is why a DHCP row
    read back with the sidebar's '| AAA |' inside it.  The typed value can
    only sit in the box right of the label, so the band is cut to that cell
    plus a small margin.  A span too narrow to contain a value falls back to
    the old full band rather than cropping the value away.
    """
    if not w:
        return (0.02, 0.97)
    fx0 = max(0.02, label_left / w - 0.03)
    fx1 = min(0.97, box_right / w + 0.04)
    if fx1 - fx0 < 0.05:
        return (0.02, 0.97)
    return (round(fx0, 4), round(fx1, 4))


def _srv_span_without_boxes() -> tuple:
    """Band used when the row's box x is unknown (tab / rowclick fills).

    Starts right of the Services list edge: the sidebar text is what leaked
    into read-backs, and no field cell starts to its left.
    """
    return (round(SRV_SIDEBAR_MAX_FX - 0.03, 4), 0.97)


def _srv_note_sidebar_shadow(token: str, chosen: str, count: int):
    """Journal the first time the list and a field row spell one word.

    Without this the DHCP1 run's only evidence was a read-back that
    mentioned the DNS panel - the collision itself was invisible.
    """
    key = f"{token}:{chosen}"
    if key in _SRV_SHADOW_SEEN:
        return
    _SRV_SHADOW_SEEN.add(key)
    record_event(
        "srv_sidebar_shadow",
        f"'{token}': the Services list and a field row both spelled "
        f"'{chosen}' - the value box on the line picked the panel row",
        recovered=True,
        extra={"token": token, "word": chosen, "candidates": count})
    log(f"service label '{token}': '{chosen}' appears in the list and on a "
        f"panel row - value-box evidence chose the panel row ({count} "
        f"candidate(s))")


def _srv_panel_service(title: str) -> str:
    """The service a Services-panel title names, or '' when it names none.

    Only a title whose FIRST word is a known services-list entry counts as
    naming one.  A strip that reads anything else (an empty read, a dialog,
    page text) is not evidence about which panel is open, so it must never
    block a fill.
    """
    head = _alnum((str(title or "").strip().split() or [""])[0])
    if not head:
        return ""
    for label in _SVC_LABELS:
        if _alnum(label) == head:
            return label
    return ""


def _srv_select(win, dev: str, svc: str) -> bool:
    """Click a service name in the left list; verify its panel opened."""
    token = _SVC_TITLES.get(svc, svc)
    for attempt in (1, 2):
        if not _focus_pt_window(win, dev, f"select {svc}"):
            continue
        words, l, t, w, h = _win_words(win)
        cands = [(wd, x, y, ww, hh) for wd, x, y, ww, hh in words
                 if _svc_word_matches(wd, token)
                 and x < w * SRV_SIDEBAR_MAX_FX]
        cands.sort(key=lambda c: (c[2], c[1]))
        if cands:
            _, x, y, ww, hh = cands[0]
            _safe_click(l + x + ww // 2, t + y + hh // 2)
            _interruptible_sleep(0.9)
            title = _panel_title(win)
            # Verify against the panel's own name, not a substring of it:
            # "DHCPv6" contains "dhcp" but is a different service.
            title_head = (title.strip().split() or [""])[0]
            if _svc_word_matches(title_head, token):
                log(f"{dev}: {svc.upper()} panel open "
                    f"(attempt {attempt})")
                return True
            log(f"{dev}: {svc} list click landed but panel shows "
                f"'{title.strip()[:50]}'")
            # Journal it: without this the failure only existed in the log
            # ring buffer, so "srv_service <svc> FAILED" arrived with no
            # explanation (2026-09-16, AAA1 aaa).
            record_event("srv_panel_mismatch",
                         f"{svc}: a sidebar row was clicked but the panel "
                         f"shows '{title.strip()[:60]}'",
                         device=dev, recovered=False,
                         extra={"service": svc,
                                "title": (title or "").strip()[:80]})
            if attempt == 1:
                _close_open_panel(win)
                continue
        if attempt == 1:
            # service may sit below the fold - one page-down, rescan once
            try:
                _safe_click(l + int(w * 0.15), t + int(h * 0.50))
                _interruptible_sleep(0.3)
                _safe_press("pagedown")
                _interruptible_sleep(0.6)
            except Exception:
                pass
    shot = f"{_safe_stem(dev)}_{_safe_stem(svc)}_select_fail.png"
    _fail_shot(win, shot)
    tail = ""
    try:
        _OCR_CACHE.clear()
        tail = (_ocr_region(win, 0.08, 0.95) or "")[-180:]
    except Exception:
        tail = ""
    log(f"{dev}: service '{svc}' not found in Services list")
    # The AAA failure in both 2026-09-16 runs reached exactly here and left no
    # event, so the cause could not be recovered. Record the service, the
    # screen and a shot so the next run can be diagnosed.
    record_event("srv_select_failed",
                 f"service '{svc}' could not be opened from the Services list",
                 device=dev, recovered=False,
                 extra={"service": svc, "shot": f"shots/{shot}",
                        "tail": tail})
    return False


def _srv_radio_on(win, dev: str) -> bool:
    """Click the topmost 'On' radio (idempotent - harmless if on)."""
    if not _focus_pt_window(win, dev, "service On control"):
        return False
    words, l, t, w, h = _win_words(win)
    ons = [(x, y, ww, hh) for wd, x, y, ww, hh in words
           if wd == "on" and y < h * 0.60]
    if not ons:
        log(f"{dev}: no 'On' radio found")
        return False
    ons.sort()
    x, y, _, hh = ons[0]
    _safe_click(max(2, l + x - 16), t + y + hh // 2)
    _interruptible_sleep(0.5)
    log(f"{dev}: service radio set On")
    return True


def _srv_named_radio_state(win, label: str) -> str:
    """Read the selected radio in a named Server-PT service group."""
    wanted = (label or "").strip().lower()
    if not wanted:
        return "unknown"
    try:
        groups = win.descendants(control_type="Group")
    except Exception:
        return "unknown"
    for group in groups:
        try:
            name = (group.element_info.name or "").strip().lower()
        except Exception:
            continue
        if name != wanted:
            continue
        try:
            radios = group.descendants(control_type="RadioButton")
        except Exception:
            continue
        for radio in radios:
            try:
                radio_name = (radio.element_info.name or "").strip().lower()
            except Exception:
                continue
            if radio_name not in {"on", "off"}:
                continue
            try:
                selected = radio.iface_selection_item.CurrentIsSelected
                if bool(selected):
                    return radio_name
            except Exception:
                pass
            try:
                state = int(radio.iface_toggle.CurrentToggleState)
                if state == 1:
                    return radio_name
            except Exception:
                pass
        return "unknown"
    return "unknown"


def _srv_radio_on_named(win, dev: str, label: str) -> bool:
    """Enable a specific service radio and prove its selected state.

    HTTP and HTTPS are separate groups in Packet Tracer.  Choosing the first
    OCR ``On`` label can therefore enable HTTP while leaving HTTPS untouched.
    Prefer the live UIA group named by the service and accept the change only
    after the group's selected radio reads back as ``on``.  An unverified OCR
    coordinate is deliberately not treated as success.
    """
    wanted = (label or "").strip().lower()
    if not wanted or not _focus_pt_window(win, dev,
                                          f"{label} service On control"):
        return False
    try:
        groups = win.descendants(control_type="Group")
    except Exception:
        groups = []
    for group in groups:
        try:
            name = (group.element_info.name or "").strip().lower()
        except Exception:
            continue
        if name != wanted:
            continue
        try:
            radios = group.descendants(control_type="RadioButton")
        except Exception:
            radios = []
        on_controls = []
        for radio in radios:
            try:
                radio_name = (radio.element_info.name or "").strip().lower()
            except Exception:
                continue
            if radio_name == "on":
                on_controls.append(radio)
        if not on_controls:
            break
        # If already on, this is an idempotent success with live evidence.
        if _srv_named_radio_state(win, wanted) == "on":
            log(f"{dev}: {label.upper()} service already On (UIA verified)")
            return True
        on = on_controls[0]
        for action in ("select", "click_input", "invoke", "click"):
            try:
                fn = getattr(on, action, None)
                if not callable(fn):
                    continue
                fn()
            except Exception:
                continue
            _interruptible_sleep(0.45)
            if _srv_named_radio_state(win, wanted) == "on":
                log(f"{dev}: {label.upper()} service set On (UIA verified)")
                return True
        break
    log(f"{dev}: named {label.upper()} On control was not verified")
    record_event(
        "srv_rule_unverified",
        f"{label.upper()} service On state could not be read back from its "
        "named Packet Tracer service group",
        device=dev,
        recovered=False,
    )
    return False


# SERVICE-PANEL MEMORY -------------------------------------------------
# Learns, per service+field, WHERE the value box sits (window fractions)
# after a VERIFIED fill, so the next run clicks straight instead of
# re-guessing x offsets - the old fixed-fx ladder typed DHCP Start IP
# across the wrong octet boxes (192|192|10|0 in the user's screenshot)
# and a missed click let Ctrl+A retype the PREVIOUS row's box. A learned
# spot is only trusted while the live label row agrees (+-0.012 fy);
# repeated misses evict it so a stale spot costs one run, never forever.
SRV_MEM_FILE = _safe_path("srv_memory.json")
SRV_MEM: dict = {"fields": {}, "buttons": {}}
try:
    if os.path.exists(SRV_MEM_FILE):
        with open(SRV_MEM_FILE) as f:
            _loaded_srv = json.load(f)
        if isinstance(_loaded_srv, dict):
            SRV_MEM["fields"] = _loaded_srv.get("fields", {}) or {}
            SRV_MEM["buttons"] = _loaded_srv.get("buttons", {}) or {}
        del _loaded_srv
except Exception as e:
    print(f"srv_memory load failed: {e}")


def _save_srv_mem():
    try:
        with open(SRV_MEM_FILE, "w") as f:
            json.dump(SRV_MEM, f, indent=2)
    except Exception as e:
        log(f"srv memory save failed: {e}")


def _srv_learned_field(key: str, dev: str = "") -> dict:
    e = SRV_MEM["fields"].get(key)
    if isinstance(e, dict):
        try:
            fx, fy = float(e["fx"]), float(e["fy"])
            if 0 < fx < 1 and 0 < fy < 1:
                out = {"fx": fx, "fy": fy,
                       "kind": str(e.get("kind", "single"))}
                boxes = e.get("boxes")
                if (out["kind"] == "octets" and isinstance(boxes, list)
                        and len(boxes) >= 2):
                    out["boxes"] = [float(b) for b in boxes
                                    if isinstance(b, (int, float))]
                candidate = {"fx": round(out["fx"], 4),
                             "fy": round(out["fy"], 4),
                             "kind": out["kind"]}
                if not LEARNING.choose(
                        "field_row", key,
                        _learning_context_for_device(dev), [candidate]):
                    # Keep a sentinel so the older miss counter can still
                    # evict the same stale entry on its bounded second miss.
                    return {"blocked": True}
                return out
        except Exception:
            pass
    return {}


def _srv_learn_field(key: str, fx: float, fy: float, kind: str,
                     dev: str = "", boxes=None):
    old = SRV_MEM["fields"].get(key)
    entry = {"fx": round(fx, 4), "fy": round(fy, 4),
             "kind": kind, "misses": 0}
    if kind == "octets" and boxes and len(boxes) >= 2:
        entry["boxes"] = [round(float(b), 4) for b in boxes[:4]]
    SRV_MEM["fields"][key] = entry
    _save_srv_mem()
    if (not isinstance(old, dict)
            or abs(float(old.get("fx", 0)) - fx) > 0.01
            or abs(float(old.get("fy", 0)) - fy) > 0.01):
        record_event("srv_field_learned", f"{key} value-box spot "
                     f"({fx:.3f},{fy:.3f}) saved for future runs",
                     device=dev, recovered=True)
        log(f"LEARNED {key} box ({fx:.3f},{fy:.3f}) - used first "
            f"next time")
    LEARNING.success("field_row", key,
                     _learning_context_for_device(dev),
                     {"fx": round(fx, 4), "fy": round(fy, 4),
                      "kind": kind},
                     "server field verified", persistent=True)
    _learning_refresh()


def _srv_field_miss(key: str, dev: str = "") -> bool:
    """Count a failed fill against a learned spot; evict at 2 misses."""
    e = SRV_MEM["fields"].get(key)
    if not isinstance(e, dict):
        return False
    LEARNING.failure(
        "field_row", key, _learning_context_for_device(dev),
        {"fx": e.get("fx"), "fy": e.get("fy"),
         "kind": e.get("kind", "single")},
        "server field read-back missed", persistent=True)
    e["misses"] = int(e.get("misses", 0)) + 1
    if e["misses"] < 2:
        _save_srv_mem()
        _learning_refresh()
        return False
    SRV_MEM["fields"].pop(key, None)
    _save_srv_mem()
    record_event("srv_spot_stale",
                 f"learned {key} spot missed twice - evicted, will "
                 f"re-detect live", device=dev, recovered=True)
    log(f"{key}: LEARNED spot STALE - evicted")
    _learning_refresh()
    return True


def _srv_learned_button(key: str, dev: str = "") -> dict:
    e = SRV_MEM["buttons"].get(key)
    if isinstance(e, dict):
        try:
            fx, fy = float(e["fx"]), float(e["fy"])
            if 0 < fx < 1 and 0 < fy < 1:
                candidate = {"fx": round(fx, 4), "fy": round(fy, 4)}
                if not LEARNING.choose(
                        "server_button", key,
                        _learning_context_for_device(dev), [candidate]):
                    return {}
                return {"fx": fx, "fy": fy, "learned": True}
        except Exception:
            pass
    return {}


def _srv_learn_button(key: str, fx, fy, dev: str = ""):
    if fx is None or fy is None:
        return
    SRV_MEM["buttons"][key] = {"fx": round(fx, 4), "fy": round(fy, 4)}
    _save_srv_mem()
    record_event("srv_button_learned", f"{key} button spot "
                 f"({fx:.3f},{fy:.3f}) saved", device=dev, recovered=True)
    LEARNING.success("server_button", key,
                     _learning_context_for_device(dev),
                     {"fx": round(float(fx), 4), "fy": round(float(fy), 4)},
                     "server button verified", persistent=True)
    _learning_refresh()


def _srv_evict_button(key: str, dev: str = ""):
    old = SRV_MEM["buttons"].pop(key, None)
    if old is not None:
        _save_srv_mem()
        record_event("srv_button_stale",
                     f"learned {key} button spot failed - evicted",
                     device=dev, recovered=True)
        candidate = ({"fx": old.get("fx"), "fy": old.get("fy")}
                     if isinstance(old, dict) else {"key": key})
        LEARNING.failure("server_button", key,
                         _learning_context_for_device(dev), candidate,
                         "server button failed", persistent=True)
        _learning_refresh()


# OCR digit confusables: Tesseract reads 0 as O, 1 as l/I/|, 8 as B...
# Normalize BEFORE digit extraction so a misread never fails a verify -
# a false FAIL costs one bounded retry, a false PASS ships a broken
# pool exactly like the user's screenshot (192|192|10|0 "verified").
_DIGIT_FIX = str.maketrans({"O": "0", "o": "0", "l": "1", "I": "1",
                            "|": "1", "S": "5", "B": "8", "Z": "2",
                            "z": "2"})


def _value_in_text(val: str, text: str) -> bool:
    """Order-aware read-back check: the value's digit groups appear
    CONSECUTIVELY in the text. Strictly stronger than the old
    digit-substring check, which passed '192.168.10.1' inside a row
    showing '...10.100' and passed octet soup like 192|192|10|0."""
    exp = re.findall(r"\d+", val or "")
    if not exp:
        return True
    toks = re.findall(r"\d+", (text or "").translate(_DIGIT_FIX))
    n = len(exp)
    return any(toks[i:i + n] == exp
               for i in range(len(toks) - n + 1))


def _prefix_in_text(val: str, text: str, ndig: int = 6) -> bool:
    """Prefix match for TRUNCATED table cells ('192.168...')."""
    d = _digits(val)
    return (not d) or d[:ndig] in _digits(
        (text or "").translate(_DIGIT_FIX))


def _srv_find_field_live(win, token: str,
                         max_fy: float | None = None) -> dict:
    """Locate a service-panel field row by its LABEL plus the digit
    boxes sitting on the same line.

    Returns:
      {}                          label not found (caller: type nothing)
      {"fy": ...}                 label found, box digits unreadable
      {"fx","fy","kind","boxes","span"}
                                  clickable value box: fx is the LEFT
                                  EDGE of the leftmost digit box, boxes
                                  is every detected box's click x (fx
                                  fractions, left->right) - with DHCP's
                                  4 octet boxes the flow types each
                                  octet into its own box instead of
                                  trusting PT's dotted auto-advance
                                  (real run: '.100' never reached box
                                  4 that way).  span is the read-back
                                  band for this cell (label -> box).

    The pool TABLE also contains the label words ('Default Gateway', 'Start
    IP Address'...).  max_fy keeps it out of the label candidates; when the
    caller does not pass one, the panel's own Add/Save/Remove row supplies
    the form's bottom edge (`_srv_form_bottom`), because a fixed 0.58 sat
    above the real pool form and made 'start'/'mask'/'gateway'/'user'
    unreadable while 'dns' still resolved (to the sidebar).
    """
    words, l, t, w, h = _win_words(win)
    if not words or not w or not h:
        return {}
    lim_x = w * 0.50
    lim_y = h * (max_fy if max_fy else _srv_form_bottom(words, h))
    labels = [wd for wd in words if token in wd[0]
              and wd[1] < lim_x and wd[2] < lim_y]
    if not labels:
        # Service labels are sometimes missed by block OCR even though the
        # field is visibly present (the DNS Address row did this in the
        # failed run). Retry with sparse OCR before declaring the field
        # absent; callers still require a read-back before continuing.
        try:
            words, l, t, w, h = _win_words(win, psm=11)
        except TypeError:
            # Preserve compatibility with one-argument test doubles and
            # older integrations that provide their own word scanner.
            pass
        if not words or not w or not h:
            return {}
        lim_y = h * (max_fy if max_fy else _srv_form_bottom(words, h))
        labels = [wd for wd in words if token in wd[0]
                  and wd[1] < lim_x and wd[2] < lim_y]
        if not labels:
            return {}

    def _evidence(z: tuple) -> tuple:
        """Rank one label candidate.  Primary keys first.

        1. a word that spells a services-list entry loses to one that does
           not (the list talking, not the panel) - the DHCPv6-vs-DHCP rule;
        2. the panel body beats the sidebar band: this is the plan's
           "labels must sit right of the list" as a demotion instead of a
           hard cut, so a panel whose real rows are read where they are
           still resolves (the real DHCP form's labels sit between the
           list edge and 0.50, which is why 0.50 admitted the list's own
           words);
        3. a service word with a value box on its line beats one without:
           this separates the sidebar's 'DNS' from the 'dns' word of the
           panel's own 'DNS Server' row when the two words are identical.
           Consulted only between service words, which is what keeps it
           safe for the empty rows (Pool Name, a DNS record's Name) whose
           box holds no digits yet;
        4. exact label before containing label: 'Name' beats 'Domain Name';
        5. topmost, then leftmost (unchanged tie-break).
        """
        wd, x, y, ww, hh = z
        suspect = 1 if _srv_sidebar_word(wd) else 0
        boxes = _srv_row_boxes(words, x, ww, y + hh / 2, hh) \
            if suspect else []
        band = 0 if x >= w * SRV_SIDEBAR_MAX_FX else 1
        no_box = 1 if (suspect and not boxes) else 0
        # z[0] is this same word (kept as the indexed form the label-rank
        # contract names): exact match before containing match.
        return (suspect, band, no_box, _label_rank(token, z[0]), y, x)

    labels.sort(key=_evidence)
    if len(labels) > 1 and _srv_sidebar_word(labels[0][0]):
        _srv_note_sidebar_shadow(token, labels[0][0], len(labels))
    _, lx, ly, lw, lh = labels[0]
    cy = ly + lh / 2
    boxes = _srv_row_boxes(words, lx, lw, cy, lh)
    fy = round(cy / h, 4)
    if not boxes:
        return {"fy": fy}
    fxs = [round((bx + max(2, bw // 6)) / w, 4) for bx, by, bw, bh
           in boxes]
    right = max(bx + bw for bx, by, bw, bh in boxes)
    return {"fx": fxs[0], "fy": fy, "boxes": fxs,
            "kind": "octets" if len(boxes) >= 2 else "single",
            "span": _srv_cell_span(lx, right, w)}


def _row_text(win, fy: float, fx0: float = 0.02,
              fx1: float = 0.97) -> str:
    """OCR one narrow field-row band (read-back for verification).

    fx0/fx1 narrow the band to the field's own cell (`_srv_cell_span`): a
    full-width band read the Services sidebar into the row, which is how a
    DHCP pool row "read back" with '| AAA | DNS Server: Domain Name:' in it.
    """
    _OCR_CACHE.clear()
    return _ocr_region(win, max(0.05, fy - 0.016),
                       min(0.95, fy + 0.020), fx0=fx0, fx1=fx1) or ""


def _row_read(win, fy: float, span=None) -> str:
    """Read back one field row, narrowed to the cell when its span is known.

    Deterministic test doubles and older integrations provide a two-argument
    `_row_text`; fall back to it rather than raising, the same way the word
    scanner tolerates one-argument doubles.
    """
    if span:
        try:
            return _row_text(win, fy, span[0], span[1])
        except TypeError:
            pass
    return _row_text(win, fy)


# Field tokens worth measuring per service, for the /srv/probe endpoint.
_SRV_PROBE_TOKENS = {
    "dhcp": ("pool", "start", "mask", "gateway", "dns", "user"),
    "dns": ("name", "type", "address"),
    "http": ("file", "text"),
    "aaa": ("username", "password"),
    "email": ("domain", "smtp", "pop3", "user"),
    "ftp": ("username", "password"),
    "ntp": ("server", "key"),
}


def _srv_probe_window(device: str = ""):
    """The open device window to probe: the named one, else the first PT one."""
    if not HAS_RPA:
        return None
    want = _alnum(device)
    wins = []
    try:
        for w in Desktop(backend="uia").windows():
            try:
                title = str(getattr(w.element_info, "name", "") or "")
            except Exception:
                continue
            pid = _win32_window_pid(_ui_window_handle(w))
            path = os.path.basename(_win32_process_path(pid)).lower()
            if path and path not in _PT_PROCESS_NAMES:
                continue
            wins.append((w, title))
    except Exception as e:
        log(f"srv probe window scan failed: {e}")
        return None
    if want:
        for w, title in wins:
            if want in _alnum(title):
                return w
        return None
    return wins[0][0] if wins else None


def _srv_probe_field(words: list, token: str, w: float, h: float) -> dict:
    """Every candidate label row for one token, with the ranking evidence."""
    limit_fy = _srv_form_bottom(words, h)
    lim_x, lim_y = w * 0.50, h * limit_fy
    rows = []
    for wd, x, y, ww, hh in words:
        if token not in wd or x >= lim_x or y >= lim_y:
            continue
        suspect = _srv_sidebar_word(wd)
        boxes = _srv_row_boxes(words, x, ww, y + hh / 2, hh)
        rows.append({
            "word": wd,
            "x": x,
            "y": y,
            "fy": round((y + hh / 2) / h, 4),
            "service_word": suspect,
            "value_box_on_line": bool(boxes),
            "rank": _label_rank(token, wd),
            "in_sidebar_band": bool(x < w * SRV_SIDEBAR_MAX_FX),
            "picked": False,
        })
    if rows:
        def _key(r):
            # Same order as _srv_find_field_live's _evidence: service word,
            # sidebar band, value box (service words only), exact rank, then
            # position.  Kept in step deliberately - the probe exists to
            # explain the search, so it must rank exactly like the search.
            return (1 if r["service_word"] else 0,
                    1 if r["in_sidebar_band"] else 0,
                    1 if (r["service_word"]
                          and not r["value_box_on_line"]) else 0,
                    r["rank"],
                    r["y"], r["x"])

        min(rows, key=_key)["picked"] = True
    return {"form_bottom": limit_fy,
            "resolved": bool(rows),
            "candidates": rows,
            "picked": next((r for r in rows if r["picked"]), None)}


def srv_probe(device: str = "", service: str = "", tokens=None) -> dict:
    """Measure the open Services panel. Read-only: clicks and types nothing.

    Exists so a failing panel is *measured* instead of inferred - the
    2026-09-16 DHCP diagnosis had to be reconstructed from a read-back
    string ('| AAA | DNS Server: Domain Name:').  It reports the title, the
    service that title names, the form bottom and sidebar edge the search
    used, and for every field token each candidate label row together with
    the evidence the ranking consults (service word, value box on the line,
    exact rank, sidebar band) and which row won.
    """
    svc = str(service or "").strip().lower()
    want = [str(x).strip().lower() for x in (tokens or ()) if str(x).strip()]
    if not want:
        want = list(_SRV_PROBE_TOKENS.get(svc, ()))
    if not want:
        return {"ok": False,
                "error": "pass ?tokens=pool,start or a known ?service= "
                         f"(one of: {', '.join(sorted(_SRV_PROBE_TOKENS))})"}
    win = _srv_probe_window(device)
    if win is None:
        return {"ok": False,
                "error": "no open Packet Tracer device window"
                         + (f" titled like '{device}'" if device else "")}
    words, l, t, w, h = _win_words(win)
    title = _panel_title(win)
    fields = {tok: _srv_probe_field(words, tok, w, h) for tok in want}
    report = {
        "ok": True,
        "device": device,
        "service": svc,
        "panel_title": title,
        "panel_names": _srv_panel_service(title),
        "window": [l, t, w, h],
        "words": len(words),
        "form_bottom": _srv_form_bottom(words, h),
        "sidebar_max_fx": SRV_SIDEBAR_MAX_FX,
        "resolved": sorted(k for k, v in fields.items() if v["resolved"]),
        "unresolved": sorted(k for k, v in fields.items()
                             if not v["resolved"]),
        "fields": fields,
    }
    RUN["srv_probe"] = report
    log("SRV PROBE: " + json.dumps({
        "device": device, "service": svc, "panel": title,
        "form_bottom": report["form_bottom"],
        "resolved": report["resolved"],
        "unresolved": report["unresolved"],
    })[:400])
    return report


def _srv_fill(win, dev: str, svc: str, token: str, val: str,
              tab_from_ok: bool = False) -> tuple:
    """Fill one service-panel field; return (verified, spot_used).

    Spot ladder (accuracy fix for the DHCP run that typed Start IP
    across the wrong octet boxes and let a missed click + Ctrl+A retype
    whatever row still had focus):
      1. live    - label+digits row detected: click the detected box
      2. learned - remembered spot, ONLY while it sits on the live
                   label row (+-0.012 fy); misses evict it
      3. tab     - focus is still in the PREVIOUS verified row's box,
                   one Tab lands on this row's box
      4. rowclick- click ON this row at a known-box x and let the
                   read-back judge it (for empty boxes: DNS/AAA fields)
    A FAILED tab fill retries as a rowclick - Tab can land on a combo
    (the DNS panel's 'Type' dropdown sits between Name and Address and
    silently ate the address), while a click relocates focus exactly.
    Max two typings per call, then stop and journal what the row showed.
    """
    if not (val or "").strip() or val.strip() == "0.0.0.0":
        return True, None
    key = f"{svc}:{token}"
    # Panel identity before a single keystroke.  The DHCP run's rows and the
    # Services list share words ('dns' is both the list entry and the first
    # word of the panel's 'DNS Server' row), so a fill could only ever prove
    # where it typed by reading the row back - after typing.  Refuse instead:
    # re-select the requested service once, and only type when the open panel
    # is either provably that service or unreadable (never guess a mismatch).
    named = _srv_panel_service(_panel_title(win))
    if named and not _svc_word_matches(named, _SVC_TITLES.get(svc, svc)):
        recovered = _srv_select(win, dev, svc)
        record_event(
            "srv_panel_mismatch",
            f"{svc}: the open panel was '{named}', not {svc} - "
            + ("re-selected before typing" if recovered else
               "and it could not be re-selected, so nothing was typed"),
            device=dev, recovered=recovered,
            extra={"service": svc, "panel": named, "field": token})
        log(f"{dev}: {svc} field '{token}' - the open panel was {named}, "
            + ("re-selected" if recovered else "and re-selection failed; "
               "NOT typing"))
        if not recovered:
            return False, None
    live = _srv_find_field_live(win, token)
    if not live:
        # one immediate rescan: this run's journal logged
        # "label 'address' not found" on a panel that clearly has it -
        # a single tesseract flake, and a rescan is free (no clicks)
        _interruptible_sleep(0.4)
        live = _srv_find_field_live(win, token)
    if not live:
        log(f"{dev}: service field '{token}' label not found - NOT "
            f"typing (no safe target box)")
        record_event("srv_field_missing", f"label '{token}' not found",
                     device=dev, recovered=False)
        return False, None
    fy = live["fy"]
    spot, source = None, ""
    if "fx" in live:
        spot, source = dict(live), "live"
    else:
        mem = _srv_learned_field(key, dev)
        if mem.get("blocked"):
            _srv_field_miss(key, dev)
            mem = {}
        if mem and abs(mem["fy"] - fy) <= 0.012:
            spot, source = dict(mem), "learned"
            boxes = spot.get("boxes") or []
            if not spot.get("span"):
                spot["span"] = (round(max(0.02, boxes[0] - 0.06), 4),
                                 round(min(0.97, boxes[-1] + 0.06), 4)) \
                    if boxes else _srv_span_without_boxes()
        elif mem:
            log(f"{dev}: learned {key} spot is off the live label row "
                f"- ignoring it")
            _srv_field_miss(key, dev)
        if spot is None and tab_from_ok:
            spot, source = {"fx": None, "fy": fy,
                            "span": _srv_span_without_boxes()}, "tab"
        if spot is None:
            # empty box (DNS/AAA record fields, Pool Name): no digits
            # to detect. Click ON this row and let the read-back judge
            # it - a dead click types nowhere, it can never retype a
            # NEIGHBOR row because fy is locked to the label. 0.60 sits
            # inside the wide single boxes (gateway/DNS/pool-name rows
            # start at fx~0.58; the old 0.42 first guess was DEAD SPACE
            # on the Pool Name row), 0.42 is the octet rows' first box.
            spot, source = {"fx": 0.60, "fy": fy, "kind": "rowclick",
                            "span": _srv_span_without_boxes()}, \
                "rowclick"
    if spot is None:
        log(f"{dev}: {key} value box not detectable - skipping the "
            f"typing (would risk retyping a neighbor row)")
        record_event("srv_field_missing",
                     f"'{token}' box unreadable and no safe fallback",
                     device=dev, recovered=False)
        return False, None

    def _type(at_spot: dict):
        if not _focus_pt_window(win, dev, f"service field {token}"):
            return
        _interruptible_sleep(0.2)
        boxes = at_spot.get("boxes") or []
        if (at_spot.get("kind") == "octets" and len(boxes) >= 4
                and re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", val.strip())):
            # PT's DHCP octet boxes silently drop dotted typing (real
            # run: '192.168.1.100' landed as 192.168.1.0 - the last
            # octet never reached box 4). Click EACH box and type its
            # octet: one pass, no reliance on '.' auto-advance.
            r = win.rectangle()
            for i, oc in enumerate(re.findall(r"\d{1,3}", val.strip())):
                _safe_click(
                    r.left + int((r.right - r.left) * boxes[i]),
                    r.top + int((r.bottom - r.top) * fy))
                _interruptible_sleep(0.25)
                _safe_hotkey("ctrl", "a")
                _interruptible_sleep(0.1)
                _safe_write(oc, interval=0.04)
                _interruptible_sleep(0.2)
            try:
                _safe_press("tab")  # commit the row
                _interruptible_sleep(0.3)
            except Exception:
                pass
            _dismiss_error_dialog(win, dev)
            return
        if at_spot.get("fx") is not None:
            r = win.rectangle()
            _safe_click(
                r.left + int((r.right - r.left) * at_spot["fx"]),
                r.top + int((r.bottom - r.top) * fy))
            _interruptible_sleep(0.3)
        else:
            _safe_press("tab")  # walk from the previous row
            _interruptible_sleep(0.3)
        _safe_hotkey("ctrl", "a")
        _interruptible_sleep(0.12)
        _safe_write(val, interval=0.04)
        _interruptible_sleep(0.35)
        try:
            _safe_press("tab")  # commit so PT accepts the value
            _interruptible_sleep(0.3)
        except Exception:
            pass
        _dismiss_error_dialog(win, dev)

    def _row_matches(row: str) -> bool:
        if _value_in_text(val, row):
            return True
        # name-ish values (pool names, record names) carry letters the
        # octet window can't match -> confusable-tolerant alnum
        # containment. Digits-only values NEVER take this branch:
        # '192168101' inside '19216810100' (10.1 vs 10.100) is exactly
        # the false pass this engine bans.
        if re.search(r"[a-z]", (val or "").lower()):
            want = _confusable_alnum(val)
            return bool(want) and want in _confusable_alnum(row)
        return False

    def _row_ok() -> bool:
        row = _row_read(win, fy, spot.get("span"))
        ok = _row_matches(row)
        if (not ok and re.search(r"\d", val or "")
                and not re.search(r"\d", _digits(row))):
            # band OCR came back digitless junk ('ons OMe @aner' - real
            # run) - one FREE re-read before counting a typing retry
            ok = _row_matches(_row_read(win, fy, spot.get("span")))
        return ok

    def _learn():
        if source in ("live", "rowclick") and spot.get("fx") is not None:
            _srv_learn_field(key, spot["fx"], fy,
                             spot.get("kind", "single"), dev,
                             boxes=spot.get("boxes"))
        elif source == "learned":
            e = SRV_MEM["fields"].get(key)
            if isinstance(e, dict):
                e["misses"] = 0
                _save_srv_mem()

    _type(spot)
    if _row_ok():
        _learn()
        log(f"{dev}: {key} <- '{val}' (verified, {source})")
        return True, {"fx": spot.get("fx"), "fy": fy}
    log(f"{dev}: {key} read-back shows "
        f"'{' '.join(_row_read(win, fy, spot.get('span')).split())[:40]}' "
        f"- one retry")
    if source == "learned":
        _srv_field_miss(key, dev)
        live2 = _srv_find_field_live(win, token)
        if "fx" in live2 and abs(live2["fx"] - spot["fx"]) > 0.004:
            spot, source = dict(live2), "live"
    if source == "rowclick" and abs(spot.get("fx", 0) - 0.60) < 1e-6:
        spot = dict(spot, fx=0.42)  # wide-box guess missed -> octet x
    if source == "tab":
        # the Tab may have landed on a NON-TEXT control (real case: the
        # DNS panel's 'Type' dropdown sits between Name and Address and
        # silently ate the address). A CLICK relocates focus exactly,
        # so retry once as a rowclick - still bounded at two typings.
        spot = {"fx": 0.60, "fy": fy, "kind": "rowclick",
                "span": _srv_span_without_boxes()}
        source = "rowclick"
    _type(spot)
    if _row_ok():
        _learn()
        log(f"{dev}: {key} <- '{val}' (verified on retry)")
        return True, {"fx": spot.get("fx"), "fy": fy}
    seen = " ".join(_row_read(win, fy, spot.get("span")).split())[:80]
    record_event("srv_fill_mismatch",
                 f"{key} wanted '{val}', row OCR: {seen}",
                 device=dev, recovered=False)
    log(f"{dev}: {key} <- '{val}' UNVERIFIED - moving on")
    return False, None


def _srv_button(win, dev: str, label: str, below_fy: float = 0.0,
                svc: str = "") -> dict:
    """Click a panel button (Add/Save) below the filled rows.

    Learned spot first (per service:button), else the OCR word box.
    Returns the spot used ({fx, fy, learned}) or {} - the caller proves
    the click's EFFECT (pool table) and learns/evicts accordingly.
    """
    key = f"{svc}:{label.lower()}" if svc else label.lower()
    if not _focus_pt_window(win, dev, f"service button {label}"):
        return {}
    mem = _srv_learned_button(key, dev)
    if mem:
        try:
            r = win.rectangle()
            _safe_click(r.left + int((r.right - r.left) * mem["fx"]),
                            r.top + int((r.bottom - r.top) * mem["fy"]))
            _interruptible_sleep(0.7)
            log(f"{dev}: clicked '{label}' (learned spot)")
            return mem
        except Exception as e:
            log(f"{dev}: learned '{label}' spot click failed: {e}")
            _srv_evict_button(key, dev)
    words, l, t, w, h = _win_words(win)
    ref_y = below_fy * h
    hits = [(x, y, ww, hh) for wd, x, y, ww, hh in words
            if wd == label.lower() and y > ref_y]
    # PT's light button text is intermittently invisible to the normal
    # block OCR (the real DHCP run typed every field but missed Add).  A
    # sparse OCR pass usually sees the neighboring Save/Remove labels. If
    # Add itself is missing, infer its center by extrapolating the equal
    # button spacing; the table-readback below still decides whether the
    # click actually committed anything.
    if not hits and label.lower() in {"add", "save", "remove"}:
        try:
            alt, al, at, aw, ah = _win_words(win, psm=11)
        except TypeError:
            # Test doubles and older integrations may expose the original
            # one-argument signature; keep their behavior unchanged.
            alt, al, at, aw, ah = [], l, t, w, h
        neighbors = {}
        for want in ("add", "save", "remove"):
            found = [(x, y, ww, hh) for wd, x, y, ww, hh in alt
                     if wd == want and y > ref_y]
            if found:
                x, y, ww, hh = sorted(found, key=lambda z: (z[1], z[0]))[0]
                neighbors[want] = (x + ww / 2, y + hh / 2, ww, hh)
        if len(neighbors) >= 2 and label.lower() not in neighbors:
            order = ("add", "save", "remove")
            known = sorted(
                ((order.index(k), v[0], v[1], v[2], v[3])
                 for k, v in neighbors.items()),
                key=lambda z: z[0],
            )
            target = order.index(label.lower())
            # Use the nearest known pair and their measured center spacing.
            i0, x0, y0, ww0, hh0 = min(
                known, key=lambda z: abs(z[0] - target))
            pairs = [z for z in known if z[0] != i0]
            if pairs:
                i1, x1, y1, ww1, hh1 = min(
                    pairs, key=lambda z: abs(z[0] - target))
                step = (x1 - x0) / (i1 - i0) if i1 != i0 else 0
                if step:
                    cx = x0 + (target - i0) * step
                    cy = (y0 + y1) / 2
                    hits = [(int(cx - ww0 / 2), int(cy - hh0 / 2),
                             ww0, hh0)]
                    l, t, w, h = al, at, aw, ah
                    log(f"{dev}: inferred '{label}' button from "
                        f"neighbor OCR at ({cx:.0f},{cy:.0f})")
    if not hits:
        log(f"{dev}: button '{label}' not found")
        return {}
    hits.sort(key=lambda z: (z[1], z[0]))
    x, y, ww, hh = hits[0]
    _safe_click(l + x + ww // 2, t + y + hh // 2)
    _interruptible_sleep(0.7)
    log(f"{dev}: clicked '{label}'")
    return {"fx": round((x + ww / 2) / w, 4),
            "fy": round((y + hh / 2) / h, 4), "learned": False}


def _dhcp_pool_saved(win, p: dict) -> tuple:
    """Acceptance check: the POOL TABLE (not the form!) shows the values.

    The user's screenshot shipped a run where every form box looked
    typed but the serverPool row still held the defaults (gateway
    0.0.0.0, 512 users) because the Add/Save click never landed.
    Returns (ok, row_text) so failures journal what the table showed.

    Region note (real bug): the table row sits at fy~0.53 in a tall
    device window and ~0.56 in a short one - a scan that STARTS at 0.56
    can miss the row entirely, so even a SUCCESSFUL save reads as
    unsaved. Scan from just below the form fields and take the LAST
    matching line - the form's own 'Pool Name' box is above 0.42 and
    never matches.
    Truncated cells ('192.168...') fall back to a 6-digit prefix match;
    maxUsers (typed 100 vs default 512) is the strong discriminator.
    """
    pool = (p.get("poolName") or "serverPool").strip().lower()
    gw, start = p.get("gateway", ""), p.get("startIp", "")
    users = str(p.get("maxUsers", "") or "").strip()
    row = ""
    want_raw = pool.lower()
    # the Pool Name column truncates ('pool192_168...') - match the
    # name by its raw text OR its 8-char alnum prefix ('pool1921')
    want_pref = _alnum(pool)[:8]
    for _ in range(2):  # transition frames flake one OCR read
        _OCR_CACHE.clear()
        txt = (_ocr_region(win, 0.42, 0.97) or "").lower()
        cands = []
        for ln in txt.splitlines():
            flat = " ".join(ln.split())
            # raw text for the name (the digit fix would mangle it:
            # 'serverpool' -> '5erverp001'), translated only for digits
            if want_raw in flat or (want_pref
                                    and want_pref in _alnum(flat)):
                cands.append(flat)
        if cands:
            row = cands[-1]  # bottom-most match = the table row
            break
        _interruptible_sleep(0.6)
    if not row:
        return False, ""
    fixed = row.translate(_DIGIT_FIX)
    toks = re.findall(r"\d+", fixed)
    ok = True
    if users:
        ok = ok and users in toks
    if gw:
        ok = ok and (_value_in_text(gw, row) or _prefix_in_text(gw, row))
    if start:
        ok = ok and (_value_in_text(start, row)
                     or _prefix_in_text(start, row))
    return ok, row


def _srv_select_pool_row(win, p: dict) -> bool:
    """Click the pool's ROW in the table so Save binds the form to it.

    PT's Save applies the form to the SELECTED pool - if the selection
    was lost, Save silently discards everything ('typed all settings,
    back to how they were'). The form's Pool Name box sits at fy~0.23,
    the table row at fy>0.44, so the y filter can't hit the form.
    """
    pool = (p.get("poolName") or "serverPool").strip().lower()
    want = re.sub(r"[^a-z0-9]", "", pool)
    if not want:
        return False
    words, l, t, w, h = _win_words(win)
    hits = [(x, y, ww, hh) for wd, x, y, ww, hh in words
            if want in wd and y > h * 0.44]
    if not hits:
        log(f"pool row '{pool}' not visible in the table - saving "
            f"without re-selecting")
        return False
    hits.sort(key=lambda z: (z[2], z[1]))
    x, y, ww, hh = hits[0]
    _safe_click(l + x + ww // 2, t + y + hh // 2)
    _interruptible_sleep(0.5)
    log(f"selected pool row '{pool}' in the table")
    return True


def _fail_shot(win, name: str):
    """Save the device window as shots/<name> for failure diagnosis."""
    try:
        base, ext = os.path.splitext(name)
        fname = _safe_stem(base) + (ext if ext == ".png" else ".png")
        os.makedirs(SHOTS, exist_ok=True)
        r = win.rectangle()
        pyautogui.screenshot(
            region=(r.left, r.top, r.right - r.left,
                    r.bottom - r.top)
        ).save(os.path.join(SHOTS, fname))
        log(f"failure screenshot saved: shots/{fname}")
    except Exception as e:
        log(f"failure screenshot failed: {e}")


def _alnum(s: str) -> str:
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def _label_rank(token: str, word: str) -> int:
    """0 when the word IS the requested label, 1 when it merely contains it.

    Used to rank field-label candidates so an exact "Name" row beats a
    "Domain Name" row.  Returns 1 when either side is empty, so a blank token
    can never claim an exact hit.
    """
    want = _alnum(token)
    return 0 if want and _alnum(word) == want else 1


# symmetric OCR-confusable fold for NAME-ish comparisons (pool names,
# record names): applied to BOTH sides, so 'pool192_168_1' read back as
# 'poolt92_168_1' (t for 1 - real run) still verifies, while a genuinely
# different value still fails.
_CONFUSABLE = str.maketrans({"l": "1", "i": "1", "I": "1", "|": "1",
                             "t": "1", "o": "0", "O": "0", "s": "5",
                             "S": "5", "b": "8", "B": "8", "z": "2",
                             "Z": "2"})


def _confusable_alnum(s: str) -> str:
    return _alnum(s).translate(_CONFUSABLE)


def _derive_pool_name(p: dict) -> str:
    """Give the entered settings a NAME (user direction: never dump
    them into the default serverPool again). Explicit plan name wins;
    otherwise derive a stable, readable one from the start IP prefix:
    192.168.10.100 -> 'pool192_168_10' (PT-safe charset, <= 16 chars).
    """
    custom = (p.get("poolName") or "").strip()
    if custom:
        return _safe_stem(custom).lower().replace("-", "_")
    octs = re.findall(r"\d{1,3}", p.get("startIp", "") or "")
    if len(octs) == 4:
        return f"pool{octs[0]}_{octs[1]}_{octs[2]}"
    return "poolLAN"


def _validate_pool_plan(p: dict, dev: str):
    """Smart-guard: sanity-check the pool values BEFORE typing so a
    wrong plan is flagged instead of silently committed. Journals a
    'srv_plan_suspicious' warning (does not block the run)."""
    gw, start = p.get("gateway", ""), p.get("startIp", "")
    mask, users = p.get("mask", ""), str(p.get("maxUsers", "") or "")

    def _octs(s):
        o = re.findall(r"\d{1,3}", s or "")
        return [int(x) for x in o] if len(o) == 4 else None

    g, s, m = _octs(gw), _octs(start), _octs(mask)
    if users and not users.isdigit():
        record_event("srv_plan_suspicious",
                     f"max users '{users}' is not a number",
                     device=dev, recovered=None)
    if not (g and s and m):
        return
    if max(g + s + m) > 255:
        record_event("srv_plan_suspicious",
                     f"octet out of range in gw {gw} / start {start} / "
                     f"mask {mask}", device=dev, recovered=None)
        return
    mi = (m[0] << 24) | (m[1] << 16) | (m[2] << 8) | m[3]
    gi = (g[0] << 24) | (g[1] << 16) | (g[2] << 8) | g[3]
    si = (s[0] << 24) | (s[1] << 16) | (s[2] << 8) | s[3]
    if (gi & mi) != (si & mi):
        record_event("srv_plan_suspicious",
                     f"start {start} is OUTSIDE {gw} / {mask} - the "
                     f"pool would hand out unroutable addresses",
                     device=dev, recovered=None)
        log(f"WARNING: {dev} pool plan inconsistent (start vs "
            f"gateway/mask) - filling anyway, check the plan")
    if gi == si:
        record_event("srv_plan_suspicious",
                     f"start IP {start} equals the gateway {gw}",
                     device=dev, recovered=None)


def _dns_record_saved(win, nm: str, addr: str,
                      below_fy: float) -> tuple:
    """Acceptance: the RECORD TABLE (below the Add button) lists the
    record. The form fields keep 'srv1' typed, so a panel-wide check
    ALWAYS passes - the user's run shipped an empty record table that
    way. Returns (ok, matched_line_or_'')."""
    _OCR_CACHE.clear()
    txt = (_ocr_region(win, min(0.95, below_fy + 0.03), 0.97) or "")
    want = _alnum(nm)
    for ln in txt.lower().splitlines():
        flat = " ".join(ln.split())
        if (want and want in _alnum(flat)
                and (_value_in_text(addr, flat)
                     or _prefix_in_text(addr, flat))):
            return True, flat
    return False, ""


def _srv_panel_has(win, needle: str) -> bool:
    """True if needle digits/text show anywhere in the service panel."""
    _OCR_CACHE.clear()
    txt = (_ocr_region(win, 0.08, 0.92) or "").lower()
    dig = _digits(needle)
    if dig and len(dig) >= 4:
        return dig in _digits(txt)
    return needle.lower() in txt


def _svc_flow_http(win, dev: str, params: dict) -> bool:
    if not _srv_select(win, dev, "http"):
        return False
    if not _srv_radio_on(win, dev):
        return False
    ok = _srv_panel_has(win, "http")
    https_ok = True
    if params.get("https") is True:
        https_ok = _srv_radio_on_named(win, dev, "HTTPS")
        if not https_ok:
            record_event(
                "srv_rule_unverified",
                "HTTP is on but the requested HTTPS control was not verified "
                "from its named live Services panel; service is marked "
                "failed",
                device=dev,
                recovered=False,
            )
    log(f"{dev}: HTTP service {'on' if ok else 'UNVERIFIED'}"
        f"; HTTPS {'on' if https_ok else 'UNVERIFIED'}")
    return ok and https_ok


def _svc_flow_dhcp_pool(win, dev: str, p: dict) -> bool:
    """Create a NAMED DHCP pool and prove it from the pool TABLE.

    User direction after the serverPool run: never dump the entered
    settings into the default pool - give them a NAME (derived from
    the start IP, e.g. pool192_168_10) and commit that. PT semantics:
    a NEW name commits with ADD; an EXISTING pool is fixed by selecting
    its row and SAVE. The flow is idempotent: if the named pool already
    exists with correct values, the run is a no-op (so a re-run never
    pops 'duplicate pool' modals). Plan values are sanity-checked
    before typing (srv_plan_suspicious).
    """
    if not _srv_select(win, dev, "dhcp"):
        return False
    _srv_radio_on(win, dev)
    _interruptible_sleep(0.4)
    p = dict(p)
    p["poolName"] = _derive_pool_name(p)
    pool = p["poolName"]
    _validate_pool_plan(p, dev)
    # idempotency gate: pool already correct -> nothing to do (this
    # also prevents Add-on-existing-name duplicate-pool error modals)
    already, _ = _dhcp_pool_saved(win, p)
    if already:
        log(f"{dev}: pool '{pool}' already in the table with the "
            f"requested values - skipping")
        RUN["srv_configured"] = RUN.get("srv_configured", 0) + 1
        return True
    # exists but WRONG -> select the row and edit it with SAVE;
    # not there at all -> fresh pool: name + fields + ADD
    words, _, _, _, h0 = _win_words(win)
    edit_mode = any(_alnum(pool) in wd and wd[2] > h0 * 0.44
                    for wd in words)
    btn = "save" if edit_mode else "add"
    bkey = f"dhcp:{btn}"
    if edit_mode:
        log(f"{dev}: pool '{pool}' exists with wrong values - "
            f"selecting it and editing (Save)")
        _srv_select_pool_row(win, p)
    # Tab-walk is only trusted from a VERIFIED row, so the FIRST field
    # never tabs from an unknown focused control: prev_ok starts False.
    # The pool NAME field is filled LAST with tab_from_ok=False: Tab
    # from Max Users lands on TFTP/WLC, not back at the top row.
    prev_ok, bad, ref = False, False, 0.0
    for token, val in (("gateway", p.get("gateway", "")),
                       ("dns", p.get("dnsServer", "")),
                       ("start", p.get("startIp", "")),
                       ("mask", p.get("mask", "")),
                       ("user", p.get("maxUsers", ""))):
        ok_f, spot = _srv_fill(win, dev, "dhcp", token, val,
                               tab_from_ok=prev_ok)
        prev_ok = ok_f
        bad = bad or not ok_f
        if spot and spot.get("fy"):
            ref = max(ref, spot["fy"])  # anchor the button below rows
    if not edit_mode:
        ok_f, spot = _srv_fill(win, dev, "dhcp", "pool", pool,
                               tab_from_ok=False)
        bad = bad or not ok_f
        if spot and spot.get("fy"):
            ref = max(ref, spot["fy"])
    spot_btn = _srv_button(win, dev, btn, below_fy=ref, svc="dhcp")
    saved, row = _dhcp_pool_saved(win, p)
    if not saved:
        # a modal may have eaten the click - dismiss + ONE re-click
        _dismiss_error_dialog(win, dev)
        if not spot_btn:
            spot_btn = _srv_button(win, dev, btn, below_fy=ref,
                                   svc="dhcp")
        elif spot_btn.get("learned"):
            _srv_evict_button(bkey, dev)
            spot_btn = _srv_button(win, dev, btn, below_fy=ref,
                                   svc="dhcp")
        _interruptible_sleep(0.8)
        saved, row = _dhcp_pool_saved(win, p)
    if saved:
        if spot_btn and not spot_btn.get("learned"):
            _srv_learn_button(bkey, spot_btn["fx"], spot_btn["fy"], dev)
    else:
        shot_name = f"{dev}_dhcp_fail.png"
        _fail_shot(win, shot_name)
        record_event("srv_save_failed",
                     f"pool '{pool}' never appeared with the values - "
                     f"last row OCR: {(row or 'nothing readable')[:90]}"
                     f" (wanted start {p.get('startIp', '')}, users "
                     f"{p.get('maxUsers', '')})",
                     device=dev, recovered=False,
                     extra={"shot": f"shots/{_safe_stem(
                         f'{dev}_dhcp_fail')}.png"})
    ok = (not bad) and saved
    log(f"{dev}: DHCP pool '{pool}' {p.get('startIp', '')} "
        f"({'saved' if saved else 'NOT SAVED in pool table'}"
        f"{', some fields unverified' if bad else ''})")
    return ok


def _svc_flow_dhcp(win, dev: str, p: dict) -> bool:
    """Configure one or more DHCP pools without losing earlier pools.

    Packet Tracer's Services tab requires Add/Save per pool.  The plan may
    therefore carry ``pools`` instead of one flattened form; each pool is
    committed and verified in the table before the next one starts.
    """
    pools = p.get("pools") if isinstance(p, dict) else None
    if not pools:
        return _svc_flow_dhcp_pool(win, dev, p)
    ok_all = True
    for pool in pools[:8]:
        if stopped():
            return False
        ok = _svc_flow_dhcp_pool(win, dev, dict(pool))
        ok_all = ok_all and ok
    return ok_all


def _svc_flow_dns(win, dev: str, p: dict) -> bool:
    """Add DNS A-records and prove each from the RECORD TABLE.

    The user's run shipped an EMPTY record table while every form field
    looked typed: the address fill Tab-walked into the 'Type' dropdown
    and the panel-wide verify passed on the form text. Both fixed: the
    address fill no longer trusts Tab (rowclick targets the box), and
    acceptance = the record line in the table (name + address).
    """
    if not _srv_select(win, dev, "dns"):
        return False
    _srv_radio_on(win, dev)
    recs = p.get("records", []) or []
    ok_all = True
    for rec in recs[:4]:  # bounded: at most 4 records per run
        nm, addr = rec.get("name", ""), rec.get("address", "")
        prev = False  # first field never tabs from unknown focus
        name_ok, _ = _srv_fill(win, dev, "dns", "name", nm,
                                tab_from_ok=prev)
        # KNOWN TRAP: Tab from Name lands on the Type dropdown, not the
        # Address box - the address fill goes straight to a rowclick.
        address_ok, spot = _srv_fill(win, dev, "dns", "address", addr,
                                     tab_from_ok=False)
        # Never press Add with an empty or unverified address. Packet
        # Tracer opens an "Invalid IP address entered" modal in that case,
        # and the record is lost. Stop this record, journal the precise
        # reason, and let the final validator report DNS failure.
        if not name_ok or not address_ok:
            record_event(
                "srv_record_blocked",
                f"record '{nm}' not added because name/address read-back "
                f"failed (name={'ok' if name_ok else 'failed'}, "
                f"address={'ok' if address_ok else 'failed'})",
                device=dev,
                recovered=False,
            )
            log(f"{dev}: DNS record {nm} blocked - refusing Add because "
                "a required field was not verified")
            ok_all = False
            continue
        anchor = spot["fy"] if spot and spot.get("fy") else 0.0
        spot_btn = _srv_button(win, dev, "add", below_fy=anchor,
                               svc="dns")
        below = spot_btn.get("fy") if spot_btn else None
        saved, row = _dns_record_saved(win, nm, addr,
                                       below if below else anchor + 0.05)
        if not saved:
            # The Add click missed (the exact failure that shipped an empty
            # record table).  Mirror the DHCP recovery: dismiss a modal,
            # EVICT the learned Add spot so it is re-located from the live
            # panel instead of re-clicking the same wrong pixel, then ONE
            # re-click + table re-read.  No loops.
            _dismiss_error_dialog(win, dev)
            if spot_btn and spot_btn.get("learned"):
                _srv_evict_button("dns:add", dev)
            if not spot_btn:
                spot_btn = _srv_button(win, dev, "add", below_fy=anchor,
                                       svc="dns")
            elif spot_btn.get("learned"):
                spot_btn = _srv_button(win, dev, "add", below_fy=anchor,
                                       svc="dns")
            below = spot_btn.get("fy") if spot_btn else None
            _interruptible_sleep(0.6)
            saved, row = _dns_record_saved(win, nm, addr,
                                           below if below
                                           else anchor + 0.05)
        if saved:
            # Promote the verified Add spot so the next run clicks the
            # remembered pixel instead of trusting flaky button OCR.
            if spot_btn and not spot_btn.get("learned"):
                _srv_learn_button("dns:add", spot_btn["fx"],
                                  spot_btn["fy"], dev)
        if not saved:
            _fail_shot(win, f"{dev}_dns_fail.png")
            record_event("srv_record_missing",
                         f"record '{nm}' -> {addr} never appeared in "
                         f"the table: {(row or 'nothing readable')[:80]}",
                         device=dev, recovered=False)
        log(f"{dev}: DNS record {nm} -> {addr} "
            f"({'in table' if saved else 'MISSING from table'}, "
            f"{'fields ok' if name_ok and address_ok else 'fields unverified'})")
        ok_all = ok_all and name_ok and address_ok and saved
    _srv_button(win, dev, "save", svc="dns")  # best effort
    return ok_all


def _svc_flow_aaa(win, dev: str, p: dict) -> bool:
    if not _srv_select(win, dev, "aaa"):
        return False
    _srv_radio_on(win, dev)
    ok_all = True
    users = (p.get("users", []) or [])[:4]
    if not users:
        log(f"{dev}: AAA service is on but no user was supplied - "
            "refusing to claim AAA login is configured")
        record_event("aaa_user_missing", "AAA service needs at least one "
                     "explicit username/password", device=dev,
                     recovered=False)
        return False
    for user in users:
        uname, pwd = user.get("username", ""), user.get("password", "")
        prev = False  # first field never tabs from unknown focus
        uok, _ = _srv_fill(win, dev, "aaa", "username", uname,
                           tab_from_ok=prev)
        prev = uok
        upwd, spot = _srv_fill(win, dev, "aaa", "password", pwd,
                               tab_from_ok=prev)
        uok = uok and upwd
        _srv_button(win, dev, "add", svc="aaa",
                    below_fy=spot["fy"] if spot and spot.get("fy")
                    else 0.0)
        uok = uok and _srv_panel_has(win, uname)
        if not uok:
            # The other silent exit from this flow: the fields read back but
            # the user row never appeared, so no event explained the failed
            # AAA service in the 2026-09-16 runs.
            record_event("aaa_user_unverified",
                         f"AAA user '{uname}' was not proven in the "
                         "account table",
                         device=dev, recovered=False,
                         extra={"username": uname})
        log(f"{dev}: AAA user {uname} "
            f"({'ok' if uok else 'UNVERIFIED'})")
        ok_all = ok_all and uok
    _srv_button(win, dev, "save", svc="aaa")  # best effort
    return ok_all


def _srv_fill_if_present(win, dev: str, svc: str, token: str,
                         val: str) -> tuple:
    """Fill an optional service field without treating a missing field as
    a click target. Packet Tracer service panels differ slightly by role."""
    if not (val or "").strip():
        return True, None
    if not _srv_find_field_live(win, token):
        return True, None
    return _srv_fill(win, dev, svc, token, val, tab_from_ok=False)


def _svc_flow_credentials(win, dev: str, svc: str, p: dict) -> bool:
    """Configure Packet Tracer EMAIL/FTP accounts when rules were supplied.

    These panels share the same user/password/Add pattern, but some PT
    versions omit the domain or Save control. Missing optional controls are
    tolerated; a requested account is only accepted after its username is
    visible in the panel/table.
    """
    if not _srv_select(win, dev, svc):
        return False
    if not _srv_radio_on(win, dev):
        return False
    domain_ok, _ = _srv_fill_if_present(
        win, dev, svc, "domain", str(p.get("domain", "")),
    )
    users = (p.get("users", []) or [])[:4]
    if not users:
        RUN["srv_rules_unverified"] = RUN.get("srv_rules_unverified", 0) + 1
        record_event(
            "srv_rules_unverified",
            f"{svc.upper()} enabled but no account rule was supplied; "
            "only service state was verified",
            device=dev,
            recovered=True,
        )
        return domain_ok
    ok_all = domain_ok
    for user in users:
        uname = str(user.get("username", "")).strip()
        pwd = str(user.get("password", "")).strip()
        if not uname or not pwd:
            ok_all = False
            record_event(
                "srv_account_blocked",
                f"{svc.upper()} account was missing username or password; "
                "Add was not pressed",
                device=dev,
                recovered=False,
            )
            continue
        if _srv_panel_has(win, uname):
            log(f"{dev}: {svc.upper()} user {uname} already visible - skip")
            continue
        uok, _ = _srv_fill(win, dev, svc, "username", uname)
        pok, spot = _srv_fill(win, dev, svc, "password", pwd,
                              tab_from_ok=uok)
        row_ok = uok and pok
        if row_ok:
            _srv_button(
                win, dev, "add", svc=svc,
                below_fy=spot.get("fy", 0.0) if spot else 0.0,
            )
            _interruptible_sleep(0.5)
            row_ok = _srv_panel_has(win, uname)
        if not row_ok:
            record_event(
                "srv_account_missing",
                f"{svc.upper()} account {uname} did not appear after Add",
                device=dev,
                recovered=False,
            )
        ok_all = ok_all and row_ok
        log(f"{dev}: {svc.upper()} user {uname} "
            f"({'saved' if row_ok else 'NOT SAVED'})")
    _srv_button(win, dev, "save", svc=svc)
    return ok_all


def _svc_flow_generic(win, dev: str, svc: str, params: dict | None = None) -> bool:
    if not _srv_select(win, dev, svc):
        return False
    on_ok = _srv_radio_on(win, dev)
    if not on_ok:
        return False
    params = params or {}
    detail_keys = set(params) - {"on", "verification"}
    if detail_keys:
        RUN["srv_rules_unverified"] = RUN.get("srv_rules_unverified", 0) + 1
        record_event(
            "srv_rule_unsupported",
            f"{svc.upper()} rule fields were supplied but this Packet Tracer "
            "panel has no safe bounded writer yet; service was not claimed "
            "fully configured",
            device=dev,
            recovered=False,
        )
        log(f"{dev}: {svc.upper()} enabled but requested rule fields were "
            "not applied - marking service failed")
        return False
    if not detail_keys:
        RUN["srv_rules_unverified"] = RUN.get("srv_rules_unverified", 0) + 1
        record_event(
            "srv_rules_unverified",
            f"{svc.upper()} enabled; Packet Tracer rule fields were not "
            "specified for this service",
            device=dev,
            recovered=True,
        )
        log(f"{dev}: {svc.upper()} enabled (state verified; rules not supplied)")
    return True


_STATE_ONLY_SERVICES = {"ntp", "tftp", "syslog", "dhcpv6", "iot", "prp"}


def _service_verification_mode(svc: str, params: dict, ok: bool) -> str:
    """Classify the evidence produced by one build service flow."""
    if not ok:
        return "failed"
    svc = str(svc).lower()
    keys = set(params or {}) - {"on", "verification"}
    if svc in _STATE_ONLY_SERVICES:
        return "rules_unverified" if keys else "state_only"
    if svc == "http":
        return "rules_verified" if keys else "state_only"
    return "rules_verified" if keys else "state_only"


def _config_server_services(rect, dev: str, slot: int, svccfg: dict,
                            project: str) -> bool:
    """Configure a server's Services tab: DHCP/DNS/HTTP/AAA/... .

    Bounded per service (select -> on -> fill -> Add -> verify); a
    failing service is journalled and the next one still runs. Never
    loops keystrokes.
    """
    services = (svccfg or {}).get("services", svccfg or {})
    if not services:
        return True
    win = _open_device_window(rect, dev, slot, project)
    if win is None:
        return False
    try:
        # A previous invalid Add attempt can leave Packet Tracer's modal
        # error dialog on top of the Services panel. Clear that stale modal
        # before reading or clicking service fields; otherwise every field
        # read is weak evidence and the next run can appear stuck.
        _dismiss_error_dialog(win, dev)
        if not _srv_open_services(win, dev):
            for svc in services:
                RUN.setdefault("service_results", []).append({
                    "device": dev, "service": str(svc).lower(),
                    "status": "failed", "verification_mode": "failed",
                    "evidence": "Services tab unavailable",
                })
                RUN["srv_failed"] = RUN.get("srv_failed", 0) + 1
            return False
        _interruptible_sleep(0.8)
        flows = {"http": _svc_flow_http, "dhcp": _svc_flow_dhcp,
                 "dns": _svc_flow_dns, "aaa": _svc_flow_aaa,
                 "email": _svc_flow_credentials,
                 "ftp": _svc_flow_credentials}
        all_ok = True
        for svc, params in services.items():
            if stopped():
                break
            fn = flows.get(str(svc).lower(), _svc_flow_generic)
            events_before = _EventCounter.total
            try:
                if fn == _svc_flow_generic:
                    ok = fn(win, dev, str(svc).lower(), params or {})
                else:
                    if fn == _svc_flow_credentials:
                        ok = fn(win, dev, str(svc).lower(), params or {})
                    else:
                        ok = fn(win, dev, params or {})
            except Exception as e:
                log(f"{dev}: {svc} flow failed: {e}")
                ok = False
            all_ok = all_ok and ok
            verification_mode = _service_verification_mode(
                str(svc).lower(), params or {}, ok,
            )
            _OCR_CACHE.clear()
            service_text = (_ocr_region(win, 0.08, 0.95) or "")[-500:]
            RUN.setdefault("service_results", []).append({
                "device": dev,
                "service": str(svc).lower(),
                "status": "verified" if ok else "failed",
                "verification_mode": verification_mode,
                "rules_verified": verification_mode == "rules_verified",
                "evidence": service_text,
            })
            if verification_mode == "rules_verified":
                RUN["srv_rules_verified"] = \
                    RUN.get("srv_rules_verified", 0) + 1
            if not ok and _EventCounter.total == events_before:
                # Every failing service must say why.  Several flows leave via
                # an early exit that records nothing (service row not found,
                # radio not set, table row missing): SRV1's dns, ftp, ntp and
                # tftp failures in the 2026-09-16 runs left no explanatory
                # event at all.  This is the backstop for every flow, present
                # and future.
                record_event("srv_flow_failed",
                             f"{svc} ended unverified without recording a "
                             "reason",
                             device=dev, recovered=False,
                             extra={"service": str(svc).lower(),
                                    "panel": (service_text or "")[-200:]})
            record_event("srv_service", f"{svc} {'on' if ok else 'FAILED'}",
                         device=dev, recovered=ok,
                         extra={"verification_mode": verification_mode})
            if ok:
                RUN["srv_configured"] = RUN.get("srv_configured", 0) + 1
            else:
                RUN["srv_failed"] = RUN.get("srv_failed", 0) + 1
        return all_ok
    except Exception as e:
        log(f"{dev}: Services config failed: {e}")
        record_event("srv_failed", str(e)[:120], device=dev,
                     recovered=False)
        return False
    finally:
        _close_device_window(win, dev)


def _security_check_evidence(check: dict, observed: str, before: str,
                             mode: str, typed: bool) -> tuple[bool, dict]:
    """Evaluate one security command using fresh, mode-checked evidence."""
    low = (observed or "").lower()
    compact = re.sub(r"[^a-z0-9]+", "", low)
    compact_tail = compact[-1400:]
    before_compact = re.sub(r"[^a-z0-9]+", "", (before or "").lower())

    def marker_increased(marker: str) -> bool:
        """Require the marker to be newly rendered after this probe."""
        token = re.sub(r"[^a-z0-9]+", "", str(marker or "").lower())
        return bool(token) and compact.count(token) > before_compact.count(token)

    expected = str(check.get("expected", "")).lower().strip()
    wanted = re.sub(r"[^a-z0-9]+", "", expected)
    markers = check.get("requiredMarkers", check.get("required_markers", []))
    if not isinstance(markers, list):
        markers = []
    markers = [str(marker).lower() for marker in markers if str(marker).strip()]
    compact_markers = [re.sub(r"[^a-z0-9]+", "", marker)
                       for marker in markers]
    errors = ("invalid input" in low or "incomplete command" in low or
              "ambiguous command" in low or "translating \"" in low or
              _term_state(observed) in {"setup", "return", "autoinstall"})
    # The command echo/output must change after this command.  This prevents
    # a previous command still visible in scrollback from satisfying a
    # security check, while allowing identical repeated show output.
    fresh = bool(observed.strip()) and (not before.strip() or
                                        compact != before_compact)
    ok = bool(typed and mode == "privileged" and fresh and not errors)
    reason = []
    if not typed:
        reason.append("command not typed")
    if mode != "privileged":
        reason.append(f"prompt mode={mode or 'unknown'}")
    if not fresh:
        reason.append("output did not change after command")
    if errors:
        reason.append("CLI error/setup text present")
    kind = str(check.get("kind", "")).lower()
    if ok and kind == "port_security":
        ok = ("portsecurity" in compact_tail and "enabled" in compact_tail and
              ("maximummacaddresses" in compact_tail or
               "maximumaddresses" in compact_tail))
        ok = ok and marker_increased("enabled") and (
            marker_increased("maximum mac addresses") or
            marker_increased("maximum addresses")
        )
        if not ok:
            reason.append("fresh enabled port-security interface evidence missing")
    elif ok and kind == "dhcp_snooping":
        heading = "configuredonfollowingvlans"
        lines = low.splitlines()
        heading_pos = max(
            (i for i, line in enumerate(lines)
             if "configured" in line and "vlan" in line),
            default=-1,
        )
        vlan_line = " ".join(
            lines[heading_pos:heading_pos + 3]
            if heading_pos >= 0 else lines[-3:]
        )
        vlan_compact = re.sub(r"[^a-z0-9]+", "", vlan_line)
        ok = ("dhcpsnoopingisenabled" in compact or
              ("dhcpsnooping" in compact and "enabled" in compact))
        ok = ok and heading in compact and "none" not in vlan_line
        ok = ok and bool(re.search(r"\bvlan?\s*1\b|\b1\b", vlan_line))
        ok = ok and marker_increased("dhcp snooping is enabled")
        if not ok:
            reason.append("fresh enabled snooping with a configured VLAN was missing")
    elif ok and kind == "aaa":
        ok = all(token in compact_tail for token in (
            "aaanewmodel", "tacacs", "loginauthentication",
            "transportinputtelnet",
        ))
        ok = ok and marker_increased("aaa new-model")
        if not ok:
            reason.append("fresh AAA/TACACS+/Telnet running-config evidence incomplete")
    elif ok and kind == "acl":
        ok = all(token in compact_tail for token in (
            "branchtohq", "permittcp", "denyip",
        ))
        ok = ok and marker_increased("permit tcp") and marker_increased("deny ip")
        if not ok:
            reason.append("fresh ACL name and both allow/deny rules missing")
    elif ok and kind == "ike":
        ok = "qmidle" in compact_tail
        ok = ok and marker_increased("qm_idle")
        if not ok:
            reason.append("fresh IKE state is not QM_IDLE")
    elif ok and kind == "ipsec":
        packet_match = re.search(
            r"pkts\s*encaps[^0-9]{0,20}([1-9][0-9]*)", low[-1600:])
        before_packet = re.search(
            r"pkts\s*encaps[^0-9]{0,20}([0-9]+)",
            (before or "").lower()[-1600:])
        current_count = int(packet_match.group(1)) if packet_match else 0
        previous_count = int(before_packet.group(1)) if before_packet else 0
        ok = bool(packet_match) and (
            marker_increased("pkts encaps") or current_count > previous_count
        )
        if not ok:
            reason.append("fresh IPSec encapsulation counter is absent, zero, or unchanged")
    elif ok and markers:
        ok = all(marker in compact_tail for marker in compact_markers)
        if not ok:
            reason.append("required evidence marker missing")
    elif ok and wanted:
        ok = wanted in compact_tail
        if not ok:
            reason.append("expected evidence marker missing")
    evidence = {
        "fresh_output": fresh,
        "typed": bool(typed),
        "mode": mode,
        "required_markers": markers,
        "reason": "; ".join(reason)[:240],
    }
    return bool(ok), evidence


def _verify_security_checks(rect, checks: list, slot_of: dict,
                            project: str) -> bool:
    """Run security probes and require fresh privileged live evidence.

    A command echo, an old scrollback row, a generic ``trust`` token, or a
    typed-but-invalid command can no longer satisfy a security check.
    """
    grouped = {}
    for check in checks or []:
        dev = str(check.get("device", ""))
        if dev:
            grouped.setdefault(dev, []).append(check)
    results = []
    all_ok = True
    for dev, device_checks in grouped.items():
        if stopped():
            all_ok = False
            break
        if dev not in slot_of:
            for check in device_checks:
                results.append({**check, "ok": False,
                                "observed": "device slot unavailable",
                                "evidence": {"reason": "slot unavailable"}})
            all_ok = False
            continue
        win = _open_device_window(rect, dev, slot_of[dev], project)
        if win is None or not _focus_cli_tab(win, dev):
            for check in device_checks:
                results.append({**check, "ok": False,
                                "observed": "CLI window unavailable",
                                "evidence": {"reason": "CLI unavailable"}})
            all_ok = False
            if win is not None:
                _close_device_window(win, dev)
            continue
        try:
            if not _settle_boot_dialogs(win, dev) or \
                    not _ensure_privileged_cli(win, dev, 25):
                for check in device_checks:
                    results.append({**check, "ok": False,
                                    "observed": "privileged CLI unavailable",
                                    "evidence": {"reason": "boot or mode "
                                                  "not verified"}})
                all_ok = False
                continue
            # Generate traffic before IKE/IPSec show commands so the tunnel
            # has a chance to negotiate. Traffic itself is logged separately;
            # the counters/state below remain the acceptance evidence.
            traffic_targets = sorted({
                str(check.get("trafficTarget", "")).strip()
                for check in device_checks
                if str(check.get("trafficTarget", "")).strip()
            })
            for target in traffic_targets:
                if not _ensure_privileged_cli(win, dev, 25):
                    all_ok = False
                    break
                typed = _type_line(f"ping {target}", 25,
                                   win=win, dev=dev)
                _interruptible_sleep(4.0)
                _OCR_CACHE.clear()
                traffic_text = _term_texts(win) if typed else ""
                traffic_ok = bool(typed and "reply" in traffic_text.lower())
                record_event("ipsec_traffic_trigger",
                             f"generated traffic toward {target} before "
                             f"crypto probes ({'reply seen' if traffic_ok else 'no reply seen'})",
                             device=dev, recovered=traffic_ok)
            for check in device_checks:
                if stopped():
                    all_ok = False
                    break
                cmd = str(check.get("command", "")).strip()
                before = _term_texts(win) or ""
                if not _ensure_privileged_cli(win, dev, 25):
                    typed, observed, mode = False, "", "unknown"
                else:
                    typed = _type_line(cmd, 25, win=win, dev=dev)
                    _interruptible_sleep(2.0)
                    _OCR_CACHE.clear()
                    observed = _term_texts(win) if typed else ""
                    try:
                        state, state_text = _confirmed_state(win, dev)
                        mode = _cli_prompt_mode(state_text) if state == "cli" \
                            else "unknown"
                    except Exception:
                        mode = "unknown"
                ok, evidence = _security_check_evidence(
                    check, observed, before, mode, typed,
                )
                results.append({**check, "ok": ok,
                                "observed": (observed or "")[-800:],
                                "evidence": evidence})
                all_ok = all_ok and ok
                # Keep the operative fields readable: a single stringified
                # evidence dict is cut at 120 characters per extra value, so
                # the journal lost the `reason` for every failed security
                # check in the 2026-09-16 runs.  Each key now has its own
                # budget (the dict stays for detail).
                record_event("security_check",
                             f"{check.get('label', cmd)} "
                             f"{'passed' if ok else 'FAILED'}",
                             device=dev, recovered=ok,
                             extra={"mode": evidence.get("mode", ""),
                                    "typed": evidence.get("typed", ""),
                                    "fresh_output":
                                        evidence.get("fresh_output", ""),
                                    "reason": evidence.get("reason", ""),
                                    "evidence": evidence})
                log(f"SECURITY TEST {dev}: {check.get('label', cmd)} "
                    f"{'PASS' if ok else 'FAIL'}")
        finally:
            _close_device_window(win, dev)
    RUN["security_checks"] = results
    RUN["security_failed"] = sum(1 for r in results if not r.get("ok"))
    return all_ok and bool(results) and len(results) == len(checks or [])


# PACKET TRACER FILE LIFECYCLE -----------------------------------------
# Packet Tracer is the authority for the opaque .pkt format.  We therefore
# never rewrite the binary directly.  The sidecar manages backups, opens the
# file in Packet Tracer, saves new files through Packet Tracer's UI, and keeps
# a readable companion manifest for plans generated by NetBuilder.
PKT_STATE = {
    "last": None,
    "running": False,
    "operation": None,
    "error": "",
}
PKT_BACKUP_DIR = os.path.join(os.path.dirname(__file__), "pkt_backups")


def _pkt_path(raw: str, must_exist: bool = True) -> str:
    """Resolve a user-selected .pkt path without changing the file."""
    value = os.path.abspath(os.path.expanduser(str(raw or "").strip()))
    if not value.lower().endswith(".pkt"):
        raise ValueError("Only Packet Tracer .pkt files are supported here.")
    if must_exist and not os.path.isfile(value):
        raise FileNotFoundError(f"Packet Tracer file not found: {value}")
    return value


def _pkt_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _pkt_info(path: str) -> dict:
    stat = os.stat(path)
    return {
        "path": path,
        "name": os.path.basename(path),
        "bytes": stat.st_size,
        "modified": time.strftime("%Y-%m-%d %H:%M:%S",
                                   time.localtime(stat.st_mtime)),
        "sha256": _pkt_sha256(path),
        "format": "pkt",
        "binaryAuthority": "Packet Tracer",
    }


def _pkt_manifest_path(path: str) -> str:
    return path + ".netbuilder.json"


def _pkt_backup(path: str) -> str:
    os.makedirs(PKT_BACKUP_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    stem = _safe_stem(os.path.splitext(os.path.basename(path))[0])
    target = os.path.join(PKT_BACKUP_DIR, f"{stem}-{stamp}.pkt")
    # Avoid a same-second collision without overwriting an older backup.
    suffix = 1
    candidate = target
    while os.path.exists(candidate):
        candidate = os.path.join(PKT_BACKUP_DIR,
                                 f"{stem}-{stamp}-{suffix}.pkt")
        suffix += 1
    shutil.copy2(path, candidate)
    return candidate


def _pkt_manifest(path: str) -> dict | None:
    companion = _pkt_manifest_path(path)
    if not os.path.isfile(companion):
        return None
    try:
        with open(companion, encoding="utf-8") as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else None
    except Exception as exc:
        log(f"PKT companion manifest unreadable: {exc}")
        return None


def _pkt_write_manifest(path: str, manifest: dict) -> str:
    companion = _pkt_manifest_path(path)
    payload = dict(manifest or {})
    payload["schema"] = 1
    payload["pkt"] = _pkt_info(path)
    payload["generated"] = time.strftime("%Y-%m-%d %H:%M:%S")
    temp = companion + ".tmp"
    with open(temp, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2)
    os.replace(temp, companion)
    return companion


def _click_any_window_control(names: list[str], timeout_s: float = 3.0) -> bool:
    """Click a visible native dialog button by name, not by coordinates."""
    if not HAS_RPA:
        return False
    deadline = time.time() + timeout_s
    wanted = [str(name).lower() for name in names]
    while time.time() < deadline:
        if stopped():
            return False
        try:
            for window in Desktop(backend="uia").windows():
                try:
                    title = (window.element_info.name or "").lower()
                    if "packet tracer" in title:
                        continue
                except Exception:
                    pass
                for control in window.descendants():
                    try:
                        name = (control.element_info.name or "").strip()
                        if name and any(w == name.lower() for w in wanted):
                            _click_control(control, "native dialog", name)
                            return True
                    except Exception:
                        continue
        except Exception:
            pass
        _interruptible_sleep(0.25)
    return False


def _save_dialog_visible(timeout_s: float = 3.0) -> bool:
    """Prove a native Save As dialog is present before typing a path."""
    if not HAS_RPA:
        return False
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if stopped():
            return False
        try:
            for window in Desktop(backend="uia").windows():
                title = (window.element_info.name or "").lower()
                if "packet tracer" in title:
                    continue
                if "save" in title or "export" in title:
                    return True
                names = []
                for control in window.descendants():
                    try:
                        name = (control.element_info.name or "").strip().lower()
                        if name:
                            names.append(name)
                    except Exception:
                        continue
                if any("file name" in name for name in names):
                    return True
        except Exception:
            pass
        _interruptible_sleep(0.25)
    return False


def _pkt_save_as(path: str) -> dict:
    """Save the currently open PT topology through the native Save As UI."""
    if not HAS_RPA:
        raise RuntimeError(f"RPA deps missing: {RPA_IMPORT_ERROR}")
    if os.path.exists(path):
        raise FileExistsError(
            f"Refusing to overwrite an existing file: {path}. "
            "Choose a new output filename.")
    w = focus_pt()
    if stopped():
        raise RuntimeError("stop requested before Packet Tracer Save As")
    # Ctrl+Shift+S is Packet Tracer's Save As shortcut.  The common Windows
    # dialog opens with the filename field focused, so typing the full path
    # avoids coordinate-specific automation.
    if not _safe_hotkey("ctrl", "shift", "s"):
        raise RuntimeError("stop requested while opening Save As")
    if not _save_dialog_visible(timeout_s=3.0):
        raise RuntimeError(
            "Packet Tracer Save As dialog was not detected; no output path "
            "was typed and the source topology was left unchanged.")
    if not _interruptible_sleep(0.3):
        raise RuntimeError("stop requested while opening Save As")
    if not _safe_hotkey("ctrl", "a"):
        raise RuntimeError("stop requested while selecting the filename")
    if not _safe_write(path, interval=0.005, chunk_size=96):
        raise RuntimeError("stop requested while entering the output path")
    if not _safe_press("enter"):
        raise RuntimeError("stop requested while saving the Packet Tracer file")
    _interruptible_sleep(1.5)
    # If PT presents an overwrite/confirmation dialog, only accept the
    # explicit save confirmation.  The destination itself was pre-checked.
    _click_any_window_control(["Yes", "Save"], timeout_s=1.5)
    _interruptible_sleep(1.0)
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise RuntimeError(
            "Packet Tracer did not create the requested .pkt file. "
            "The source topology was left unchanged.")
    log(f"PKT Save As created {path}")
    return _pkt_info(path)


def _pkt_open(path: str, make_backup: bool = True) -> dict:
    """Open a .pkt using the operating system association, then verify PT."""
    if not HAS_RPA:
        raise RuntimeError(f"RPA deps missing: {RPA_IMPORT_ERROR}")
    backup = _pkt_backup(path) if make_backup else ""
    if not hasattr(os, "startfile"):
        raise RuntimeError("Opening .pkt files requires Windows Packet Tracer.")
    os.startfile(path)  # type: ignore[attr-defined]
    deadline = time.time() + 20.0
    window_found = False
    last_error = ""
    while time.time() < deadline:
        if stopped():
            raise RuntimeError("stop requested while opening the .pkt file")
        try:
            focus_pt()
            window_found = True
            break
        except Exception as exc:
            last_error = str(exc)
            _interruptible_sleep(0.5)
    if not window_found:
        raise RuntimeError(
            "Packet Tracer did not become available after opening the .pkt "
            f"file: {last_error[:160]}")
    info = _pkt_info(path)
    info.update({
        "backup": backup,
        "windowFound": True,
        "loadedFileProof": "Packet Tracer window detected; run live audit "
                           "to prove the topology contents.",
        "manifest": _pkt_manifest(path),
    })
    PKT_STATE["last"] = info
    shot(f"pkt_open_{_safe_stem(os.path.basename(path))}.png")
    log(f"PKT opened {path}; backup={backup or 'not requested'}")
    return info


def pkt_read(path: str, project: str = "default") -> dict:
    """Return safe metadata and any companion intent/live inventory."""
    info = _pkt_info(path)
    companion = _pkt_manifest(path)
    live = TOPOLOGY.get("report") if TOPOLOGY.get("project") == project else None
    info.update({
        "manifest": companion,
        "liveInventory": live,
        "readMode": "metadata + companion manifest; Packet Tracer live UI "
                     "is required for authoritative topology contents",
    })
    PKT_STATE["last"] = info
    return info


# PACKET TRACER ARTIFACT CHAIN ------------------------------------------
# A topology that only lives on the canvas is not a deliverable.  This saves
# the finished network through Packet Tracer's own Save As, writes a companion
# manifest beside it (plan + run result, never configuration or credential
# text), and can reopen the file to prove it loads.  Packet Tracer stays the
# only writer: the .pkt format is proprietary, so reopening is the only honest
# proof that a file is valid.
LAST_PLAN: dict = {}
PKT_OUT_DIR = os.path.join(os.path.dirname(__file__), "pkt_output")


def _pkt_out_dir(override: str = "") -> str:
    """Resolve the artifact directory: explicit > NETBUILDER_PKT_DIR > default."""
    path = (override or os.environ.get("NETBUILDER_PKT_DIR") or PKT_OUT_DIR)
    path = os.path.abspath(path)
    os.makedirs(path, exist_ok=True)
    return path


def _pkt_plan_vs_run(plan: dict, project: str) -> dict:
    """What the plan asked for versus what the run recorded.

    Structural data only (names, counts, statuses) so the report and the
    companion manifest are safe to share: no configuration text, no
    credentials, no addresses.
    """
    planned = []
    planned_links = 0
    for step in ((plan or {}).get("steps") or []):
        if not isinstance(step, dict):
            continue
        if step.get("action") == "create_nodes":
            planned.extend(step.get("nodes") or [])
        elif step.get("action") == "create_links":
            planned_links += len(step.get("links") or [])
    placed = set((DEV_MEM.get(project, {}) or {}).keys())
    named = [str(node.get("name")) for node in planned
             if isinstance(node, dict) and node.get("name")]
    link_results = RUN.get("link_results", {}) or {}
    failed = [key for key, value in link_results.items()
              if isinstance(value, dict)
              and value.get("status") != "verified"]
    return {
        "plannedDevices": len(named),
        "plannedLinks": planned_links,
        "devicesOnCanvas": len(placed),
        "devicesMissing": [name for name in named if name not in placed][:20],
        "deviceOutcomes": dict(RUN.get("node_outcomes", {}) or {}),
        "linksRecorded": len(link_results),
        "linksFailed": len(failed),
        "configsVerified": RUN.get("configs_verified", 0),
        "pingsOk": RUN.get("pings_ok", 0),
        "pingsFailed": RUN.get("pings_failed", 0),
        "cliBlocks": RUN.get("cli_context_blocks", 0),
        "errorsUnrecovered": RUN.get("errors_unrecovered", 0),
        "runOk": bool(RUN.get("ok")),
    }


def pkt_save_verified(project: str = "", out_dir: str = "",
                      force: bool = False, reopen: bool = False) -> dict:
    """Save the live topology as a .pkt, then report what it should contain.

    Chain: Save As -> companion manifest -> optional reopen to prove the file
    loads.  Types no configuration and never changes the topology.
    """
    if not HAS_RPA:
        raise RuntimeError(f"RPA deps missing: {RPA_IMPORT_ERROR}")
    project = (project or JOB.project or "default").strip() or "default"
    directory = _pkt_out_dir(out_dir)
    stem = _safe_stem(project)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = os.path.join(directory, f"{stem}-{stamp}.pkt")
    suffix = 1
    while os.path.exists(path) and not force:
        path = os.path.join(directory, f"{stem}-{stamp}-{suffix}.pkt")
        suffix += 1
    if os.path.exists(path):
        # _pkt_save_as refuses to overwrite an existing file; a forced save
        # keeps the old one as a backup rather than losing it.
        backup = _pkt_backup(path)
        try:
            os.remove(path)
        except OSError as exc:
            raise RuntimeError(f"could not replace {path}: {exc}")
        log(f"PKT replacing existing artifact; backup kept at {backup}")
    info = _pkt_save_as(path)
    comparison = _pkt_plan_vs_run(LAST_PLAN, project)
    manifest = _pkt_write_manifest(path, {
        "project": project,
        "sidecarVersion": VERSION,
        "purpose": "companion record: what this file was built from and "
                   "what the run verified (no configuration or credential "
                   "text)",
        "comparison": comparison,
    })
    result = {**info, "manifest": manifest, "comparison": comparison,
              "reopened": False}
    if reopen:
        proof = _pkt_open(path, make_backup=False)
        result["reopened"] = True
        result["reopenEvidence"] = {
            "windowFound": proof.get("windowFound"),
            "loadedFileProof": proof.get("loadedFileProof"),
        }
    PKT_STATE["report"] = result
    log(f"PKT artifact {path} ({info.get('bytes', 0)} bytes); "
        f"devices={comparison['devicesOnCanvas']}/"
        f"{comparison['plannedDevices']} "
        f"links_failed={comparison['linksFailed']} "
        f"cli_blocks={comparison['cliBlocks']}")
    return result


def _artifact_enabled() -> bool:
    """Auto-save is on by default and can be turned off with an env var.

    The step is bounded (no reopen, no 20s open wait) but it still drives
    Packet Tracer's Save As at the end of every green run, so there is an
    escape hatch that does not require a code change.
    """
    raw = str(os.environ.get("NETBUILDER_ARTIFACT", "")).strip().lower()
    return raw not in {"0", "no", "off", "false"}


def _save_run_artifact() -> None:
    """Save a green run's topology as a .pkt; never fail the build for it.

    Called once at the end of a run.  The canvas is already built by then, so
    a save problem is recorded as its own event and reported to the user
    instead of turning a good build into a failed one.  A run that did not
    validate OK is deliberately not saved - a file that silently captures a
    broken topology is worse than no file.

    Bounded and measured: the step is skipped outright when the RPA stack or
    the user disabled it, and its own wall time is reported separately so it
    can never be mistaken for build cost in the run log.
    """
    if not HAS_RPA:
        return
    if not _artifact_enabled():
        log("PKT artifact skipped: disabled by NETBUILDER_ARTIFACT")
        return
    try:
        if not RUN.get("ok"):
            log("PKT artifact skipped: the run did not validate OK")
            return
        started = time.perf_counter()
        artifact = pkt_save_verified(JOB.project or "default")
        elapsed = time.perf_counter() - started
        RUN["pkt"] = {
            "path": artifact.get("path", ""),
            "bytes": artifact.get("bytes", 0),
            "manifest": artifact.get("manifest", ""),
            "comparison": artifact.get("comparison", {}),
            "saveMs": round(elapsed * 1000, 1),
        }
        log(f"PKT artifact saved: {artifact.get('path', '')} "
            f"({elapsed:.1f}s, outside the build cost above)")
    except Exception as exc:
        RUN["pkt"] = {"error": str(exc)[:200]}
        record_event("pkt_save_failed", str(exc)[:200], recovered=False)
        log(f"PKT artifact failed: {str(exc)[:160]}")


def _pkt_start_operation(operation: str, fn, *args, **kwargs):
    """Run one file operation in the background and retain its evidence."""
    PKT_STATE["operation"] = operation
    PKT_STATE["error"] = ""

    def worker():
        try:
            result = fn(*args, **kwargs)
            PKT_STATE["last"] = {
                **(result if isinstance(result, dict) else {}),
                "operation": operation,
                "ok": True,
            }
            record_event("pkt_operation", f"{operation} completed",
                         recovered=True,
                         extra={"path": PKT_STATE["last"].get("path", "")})
        except Exception as exc:
            PKT_STATE["error"] = str(exc)
            PKT_STATE["last"] = {
                "operation": operation,
                "ok": False,
                "error": str(exc),
            }
            record_event("pkt_operation", f"{operation} failed: {exc}",
                         recovered=False)
        finally:
            PKT_STATE["operation"] = None
            end_activity("pkt")

    threading.Thread(target=worker, daemon=True).start()


# NETWORK AUDIT ---------------------------------------------------------
# Analyzes an ALREADY-BUILT network (no plan needed): reads each device's
# interface table (+ OSPF on routers) via the CLI/OCR engine, reads PC
# IP panels, scans the canvas for red indicators - then reports findings
# with concrete, user-selectable fixes (fix_cli / fix_pc).
AUDIT = {"running": False, "report": None}
TOPOLOGY = {"project": "", "report": None}


def inventory_plan(rect, project: str, steps: list) -> dict:
    """Read the live canvas state for every planned device before acting.

    This is intentionally a preflight inventory, not a guess based only on
    device_memory.json. The screen is sampled at the remembered/planned slot
    and OCR evidence is retained in the report so later recovery decisions
    can explain why a device was reused, placed, or blocked.
    """
    nodes = []
    for st in steps:
        if st.get("action") == "create_nodes":
            nodes.extend(st.get("nodes", []) or [])
    layout = _layout_spot(nodes) if nodes else {}
    planned_names = set()
    report_nodes = []
    counts = {"match": 0, "empty": 0, "occupied_unknown": 0,
              "unknown": 0}
    for i, node in enumerate(nodes):
        name = str(node.get("name") or f"dev{i}")
        planned_names.add(name)
        mem = recall_device(project, name)
        if mem:
            fx, fy = float(mem["fx"]), float(mem["fy"])
            source = "remembered"
        else:
            fx, fy = layout.get(i, (CAL["grid_x0"], CAL["grid_y"]))
            source = "planned"
        dtype = str(node.get("type") or "").lower()
        model = str(node.get("model") or "")
        try:
            state, ocr = _slot_visual_state(rect, fx, fy, name,
                                            dtype, model)
        except Exception as e:
            state, ocr = "unknown", str(e)
        counts[state] = counts.get(state, 0) + 1
        report_nodes.append({
            "name": name, "type": dtype, "model": model,
            "fx": round(fx, 4), "fy": round(fy, 4),
            "source": source, "state": state,
            "ocr": (ocr or "")[:160],
        })
    unexpected = sorted(n for n in (DEV_MEM.get(project, {}) or {})
                        if n not in planned_names)
    report = {
        "project": project,
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "nodes": report_nodes,
        "counts": counts,
        "unexpected_remembered": unexpected,
        "screen_authority": True,
    }
    TOPOLOGY["project"] = project
    TOPOLOGY["report"] = report
    RUN["inventory"] = report
    record_event("inventory_done",
                 f"{len(report_nodes)} planned device(s): "
                 f"match={counts.get('match', 0)} "
                 f"empty={counts.get('empty', 0)} "
                 f"uncertain={counts.get('occupied_unknown', 0) + counts.get('unknown', 0)}",
                 recovered=True,
                 extra={"unexpected": unexpected[:6]})
    log("INVENTORY: " + json.dumps({
        "match": counts.get("match", 0),
        "empty": counts.get("empty", 0),
        "uncertain": counts.get("occupied_unknown", 0)
        + counts.get("unknown", 0),
        "unexpected_remembered": unexpected[:6],
    }))
    return report


def _short_iface(full: str) -> str:
    s = (full or "").strip().lower()
    for pre, short in (("gigabitethernet", "g"), ("fastethernet", "f"),
                       ("serial", "s"), ("ethernet", "e")):
        if s.startswith(pre):
            return short + s[len(pre):]
    return s


def _parse_ip_brief(text: str) -> list:
    """Parse `show ip interface brief` OCR text into interface rows."""
    rows = []
    for raw in (text or "").splitlines():
        line = " ".join(raw.split()).lower()
        if not line or line.startswith(("interface ", "ip-address", "show",
                                        "--more--")):
            continue
        m = re.match(
            r"^([a-z]+[0-9][\d/:.\-]*)\s+(unassigned|\d{1,3}(?:\.\d{1,3}){3})"
            r"\s+yes\s+\S+\s+(administratively down|down|up)\s+(down|up)",
            line)
        if m:
            rows.append({"name": m.group(1), "ip": m.group(2),
                         "status": m.group(3), "protocol": m.group(4)})
    return rows


def _parse_ospf_networks(text: str) -> list:
    """Pull advertised networks out of `show ip protocols` OCR text."""
    nets = []
    in_sec = False
    for raw in (text or "").splitlines():
        line = " ".join(raw.split()).lower()
        if "routing for networks" in line:
            in_sec = True
            continue
        if in_sec and (not line or "routing information sources" in line
                       or "distance" in line):
            break
        if in_sec:
            nets += re.findall(r"\d{1,3}(?:\.\d{1,3}){3}", line)
    # drop wildcard masks that share the line with each network
    return [n for n in nets
            if not n.startswith("0.") and not n.startswith("255.")]


def _evidence_lines(text: str, limit: int = 18) -> list:
    """Keep useful read-only CLI evidence without copying the whole screen."""
    lines = []
    for raw in (text or "").splitlines():
        line = " ".join(raw.split())
        low = line.lower()
        if (not line or low.startswith(("show ", "--more--"))
                or re.search(r"[>#]\s*show\s+", low)):
            continue
        if line.startswith(("%", "^")):
            continue
        if line not in lines:
            lines.append(line[:180])
    return lines[-limit:]


def _audit_cli_device(rect, dev: str, slot: int, project: str,
                      dtype: str):
    """Open a router/switch, read its live state, return findings."""
    out = {"name": dev, "type": dtype, "interfaces": [], "ospf": [],
           "routes": [], "neighbors": [], "vlans": [], "probes": [],
           "has_ospf": False, "readable": False, "findings": []}
    win = _open_device_window(rect, dev, slot, project)
    if win is None:
        out["findings"].append({"id": f"{dev}:unreadable", "severity": "info",
                                "text": "device window could not be opened",
                                "fix_cli": []})
        return out

    def run_show(cmd, wait):
        _type_line(cmd, 25, win=win, dev=dev)
        _interruptible_sleep(wait)
        _OCR_CACHE.clear()
        return _term_texts(win)

    try:
        if not _focus_cli_tab(win, dev):
            out["findings"].append({"id": f"{dev}:unreadable",
                                    "severity": "info",
                                    "text": "CLI tab could not be focused",
                                    "fix_cli": []})
            return out
        try:
            if not _focus_cli_input(win, dev, "audit probe"):
                out["findings"].append({
                    "id": f"{dev}:unreadable",
                    "severity": "info",
                    "text": "Packet Tracer was not foreground during CLI "
                            "probe",
                    "fix_cli": [],
                })
                return out
            _safe_press("enter")
            _interruptible_sleep(1.0)
        except Exception:
            pass
        if not _settle_boot_dialogs(win, dev):
            out["findings"].append({"id": f"{dev}:setup", "severity": "high",
                                    "text": "stuck in the setup dialog - "
                                    "answer no and re-run audit",
                                    "fix_cli": []})
            return out
        brief = run_show("show ip interface brief", 2.5)
        out["interfaces"] = _parse_ip_brief(brief)
        out["readable"] = bool(out["interfaces"])
        if dtype == "router":
            prot = run_show("show ip protocols", 2.5)
            out["ospf"] = _parse_ospf_networks(prot)
            out["has_ospf"] = bool(out["ospf"]) or "ospf" in prot.lower()
            route_text = run_show("show ip route", 2.5)
            out["routes"] = _evidence_lines(route_text)
            out["probes"].append({
                "command": "show ip route",
                "readable": bool(out["routes"]),
                "evidence": out["routes"],
            })
        else:
            vlan_text = run_show("show vlan brief", 2.5)
            out["vlans"] = _evidence_lines(vlan_text)
            out["probes"].append({
                "command": "show vlan brief",
                "readable": bool(out["vlans"]),
                "evidence": out["vlans"],
            })
        neighbor_text = run_show("show cdp neighbors", 2.5)
        out["neighbors"] = _evidence_lines(neighbor_text)
        out["probes"].append({
            "command": "show cdp neighbors",
            "readable": bool(out["neighbors"]),
            "evidence": out["neighbors"],
        })
        # FINDINGS
        for it in out["interfaces"]:
            if it["status"] == "administratively down":
                short = _short_iface(it["name"])
                out["findings"].append({
                    "id": f"{dev}:admin_down:{short}", "severity": "high",
                    "text": f"{short} is administratively down "
                            f"(port shut - link stays red)",
                    "fix_cli": [f"interface {short}", "no shutdown"]})
        if dtype == "router" and not out["has_ospf"]:
            ips = [i["ip"] for i in out["interfaces"]
                   if i["ip"] != "unassigned" and "." in i["ip"]]
            if ips:
                nets = []
                for ip in ips:
                    o = ip.split(".")
                    nets.append(f"network {o[0]}.{o[1]}.{o[2]}.0 "
                                f"0.0.0.255 area 0")
                out["findings"].append({
                    "id": f"{dev}:no_ospf", "severity": "medium",
                    "text": "OSPF not configured although interfaces "
                            "have IPs (no routing between LANs)",
                    "fix_cli": ["router ospf 1"] + nets})
        un = [_short_iface(i["name"]) for i in out["interfaces"]
              if i["ip"] == "unassigned"
              and i["status"] != "administratively down"]
        if un:
            out["findings"].append({
                "id": f"{dev}:no_ip", "severity": "medium",
                "text": f"no IP assigned on: {', '.join(un)}",
                "fix_cli": []})
        if not out["readable"]:
            out["findings"].append({"id": f"{dev}:unreadable",
                                    "severity": "info",
                                    "text": "interface table unreadable "
                                    "(OCR) - try again or read manually",
                                    "fix_cli": []})
        return out
    finally:
        _close_device_window(win, dev)


def _audit_pc(rect, dev: str, slot: int, project: str):
    """Open a PC's Desktop > IP Configuration and read its IP state."""
    res = {"name": dev, "type": "pc",
           "ipcfg": {"ip": "", "mask": "", "gw": ""}, "findings": []}
    win = _open_device_window(rect, dev, slot, project)
    if win is None:
        res["findings"].append({"id": f"{dev}:unreadable",
                                "severity": "info",
                                "text": "device window could not be opened",
                                "fix_pc": False})
        return res
    try:
        if _pc_open_desktop_app(win, dev, "ip_config",
                                ["IP Configuration"], ["configuration"],
                                ["ip configuration", "subnet mask"]):
            _interruptible_sleep(0.5)
            _OCR_CACHE.clear()
            txt = _ocr_region(win, 0.10, 0.42, invert=False) or ""
            ips = re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", txt)
            nonzero = [i for i in ips if i != "0.0.0.0"]
            if nonzero:
                res["ipcfg"]["ip"] = nonzero[0]
                masks = [i for i in ips if i.startswith("255.")]
                if masks:
                    res["ipcfg"]["mask"] = masks[0]
                for line in txt.lower().splitlines():
                    if "gateway" in line:
                        gateway = re.findall(
                            r"\b\d{1,3}(?:\.\d{1,3}){3}\b", line)
                        if gateway and gateway[0] != "0.0.0.0":
                            res["ipcfg"]["gw"] = gateway[0]
                            break
            else:
                res["findings"].append({
                    "id": f"{dev}:no_ip", "severity": "high",
                    "text": "PC has no IPv4 configured (cannot ping or "
                            "be pinged)",
                    "fix_pc": True})
        else:
            res["findings"].append({"id": f"{dev}:unreadable",
                                    "severity": "info",
                                    "text": "Desktop > IP Configuration "
                                    "could not be opened",
                                    "fix_pc": False})
        return res
    finally:
        _close_device_window(win, dev)


def _read_service_radio_state(win) -> str:
    """Read a Services-tab radio state without clicking it.

    Packet Tracer exposes the On/Off labels inconsistently through UIA. Try
    the read-only toggle interfaces when available and return unknown rather
    than guessing from the fact that both labels are visible.
    """
    try:
        for control in win.descendants():
            try:
                label = (control.element_info.name or "").strip().lower()
            except Exception:
                continue
            if label not in ("on", "off"):
                continue
            try:
                getter = getattr(control, "get_toggle_state", None)
                if callable(getter):
                    state = getter()
                    if str(state).lower() in ("1", "on", "true"):
                        return "on"
                    if str(state).lower() in ("0", "off", "false"):
                        return "off"
            except Exception:
                pass
            try:
                state = control.iface_toggle.CurrentToggleState
                if int(state) == 1:
                    return "on"
                if int(state) == 0:
                    return "off"
            except Exception:
                pass
    except Exception:
        pass
    return "unknown"


def _service_saved_evidence(service: str, text: str) -> bool:
    """Return true only when the panel contains likely saved data."""
    low = (text or "").lower()
    if service == "dhcp":
        return bool(re.search(r"pool\s*name|serverpool", low)) and bool(
            re.search(r"\d{1,3}(?:\.\d{1,3}){3}", low)
        )
    if service == "dns":
        return "resource records" in low or (
            "name" in low and bool(re.search(r"\d{1,3}(?:\.\d{1,3}){3}", low))
        )
    if service in {"email", "ftp", "aaa"}:
        return bool(re.search(r"user\s*(?:name)?|username|account", low)) and (
            "add" in low or "delete" in low or "remove" in low
        )
    return False


def _service_rule_evidence(service: str, text: str) -> dict:
    """Describe what read-only audit evidence can prove for this service."""
    if service in {"dhcp", "dns", "email", "ftp", "aaa"}:
        verified = _service_saved_evidence(service, text)
        return {
            "verified": verified,
            "mode": "saved_table_or_record" if verified else "state_only",
            "reason": "saved fields/table evidence visible" if verified
            else "service panel visible but no saved rule evidence detected",
        }
    return {
        "verified": False,
        "mode": "state_only",
        "reason": "this service has no generic saved-rule probe yet",
    }


def _audit_server(rect, dev: str, slot: int, project: str):
    """Read a Server-PT IP configuration and service panels.

    This deliberately performs navigation only. It never enables a service,
    edits a field, or presses Add/Save; service findings remain informational
    until a user explicitly approves a supported fix.
    """
    out = {
        "name": dev,
        "type": "server",
        "ipcfg": {"ip": "", "mask": "", "gw": ""},
        "services": [],
        "findings": [],
    }
    win = _open_device_window(rect, dev, slot, project)
    if win is None:
        out["findings"].append({
            "id": f"{dev}:unreadable",
            "severity": "info",
            "text": "server window could not be opened",
            "fix_pc": False,
        })
        return out
    try:
        if _pc_open_desktop_app(
            win,
            dev,
            "ip_config",
            ["IP Configuration"],
            ["configuration"],
            ["ip configuration", "subnet mask"],
        ):
            _interruptible_sleep(0.5)
            _OCR_CACHE.clear()
            ip_text = _ocr_region(win, 0.10, 0.42, invert=False) or ""
            ips = re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", ip_text)
            nonzero = [ip for ip in ips if ip != "0.0.0.0"]
            if nonzero:
                out["ipcfg"]["ip"] = nonzero[0]
                masks = [ip for ip in ips if ip.startswith("255.")]
                if masks:
                    out["ipcfg"]["mask"] = masks[0]
                for line in ip_text.lower().splitlines():
                    if "gateway" in line:
                        gateways = re.findall(
                            r"\b\d{1,3}(?:\.\d{1,3}){3}\b", line)
                        if gateways and gateways[0] != "0.0.0.0":
                            out["ipcfg"]["gw"] = gateways[0]
                            break
            else:
                out["findings"].append({
                    "id": f"{dev}:no_ip",
                    "severity": "high",
                    "text": "server has no IPv4 configured",
                    "fix_pc": True,
                })
            _close_open_panel(win)
        else:
            out["findings"].append({
                "id": f"{dev}:ip_unreadable",
                "severity": "info",
                "text": "server IP Configuration could not be opened",
                "fix_pc": False,
            })

        if not _srv_open_services(win, dev):
            out["findings"].append({
                "id": f"{dev}:services_unreadable",
                "severity": "info",
                "text": "Services tab could not be read",
                "fix_cli": [],
            })
            return out

        words, _, _, width, _ = _win_words(win)
        available = []
        for service, token in _SVC_TITLES.items():
            if any(token in word and x < width * 0.35
                   for word, x, _, _, _ in words):
                available.append(service)
        for service in available:
            if stopped():
                break
            if not _srv_select(win, dev, service):
                continue
            _OCR_CACHE.clear()
            panel = _ocr_region(win, 0.08, 0.92) or ""
            state = _read_service_radio_state(win)
            lines = [" ".join(line.split()) for line in panel.splitlines()
                     if line.strip()]
            evidence = lines[-8:]
            rule_evidence = _service_rule_evidence(service, panel)
            item = {
                "name": service,
                "state": state,
                "panel_visible": True,
                "saved_data": rule_evidence["verified"],
                "rules_verified": rule_evidence["verified"],
                "verification_mode": rule_evidence["mode"],
                "verification_reason": rule_evidence["reason"],
                "evidence": evidence,
            }
            out["services"].append(item)
            if state == "off":
                out["findings"].append({
                    "id": f"{dev}:service_off:{service}",
                    "severity": "medium",
                    "text": f"{service.upper()} service is reported Off",
                    "fix_cli": [],
                })
            elif state == "on" and not rule_evidence["verified"]:
                out["findings"].append({
                    "id": f"{dev}:service_rules_unverified:{service}",
                    "severity": "info",
                    "text": f"{service.upper()} is on, but its saved rule/table "
                            "was not proven by read-only inspection",
                    "fix_cli": [],
                })
            elif service in ("dhcp", "dns") and not item["saved_data"]:
                out["findings"].append({
                    "id": f"{dev}:service_empty:{service}",
                    "severity": "info",
                    "text": f"{service.upper()} panel opened but no saved table entry was visible",
                    "fix_cli": [],
                })
        if not out["services"]:
            out["findings"].append({
                "id": f"{dev}:services_empty",
                "severity": "info",
                "text": "Services list was visible but no service panels were readable",
                "fix_cli": [],
            })
        return out
    finally:
        _close_device_window(win, dev)


def _scan_red_dots(rect) -> list:
    """Cluster red pixels on the canvas = down-link indicators."""
    try:
        l, t, r, b = rect
        os.makedirs(SHOTS, exist_ok=True)
        p = os.path.join(SHOTS, "audit_canvas.png")
        pyautogui.screenshot(region=(l, t, r - l, b - t)).save(p)
        from PIL import Image
        im = Image.open(p).convert("RGB")
        W, H = im.size
        px = im.load()
        pts = []
        for y in range(int(H * 0.12), int(H * 0.80), 4):
            for x in range(int(W * 0.05), int(W * 0.95), 4):
                pr, pg, pb = px[x, y]
                if pr > 170 and pg < 80 and pb < 80:
                    pts.append((x, y))
        clusters = []
        for x, y in pts:
            for c in clusters:
                if abs(c[0] - x) < 25 and abs(c[1] - y) < 25:
                    c[0] = (c[0] + x) // 2
                    c[1] = (c[1] + y) // 2
                    c[2] += 1
                    break
            else:
                clusters.append([x, y, 1])
        return [c for c in clusters if c[2] >= 3]
    except Exception as e:
        log(f"red scan failed: {e}")
        return []


def _canvas_ocr_words(rect) -> list:
    """Read device labels from an arbitrary loaded .pkt canvas.

    Builds already know their device coordinates, but a .pkt created by
    somebody else does not.  Packet Tracer has no supported topology API, so
    this is deliberately an evidence-based discovery pass: OCR the canvas
    labels, classify only conservative device-name patterns, then use the
    discovered coordinates for the normal read-only device audit.
    """
    if not HAS_RPA or not TESSERACT_CMD:
        return []
    try:
        l, t, r, b = rect
        W, H = r - l, b - t
        # Exclude the menu/header and the device palette/PDU strip.
        fx0, fy0, fx1, fy1 = 0.03, 0.12, 0.97, 0.82
        x0, y0 = l + int(W * fx0), t + int(H * fy0)
        ww, hh = max(1, int(W * (fx1 - fx0))), max(1, int(H * (fy1 - fy0)))
        from PIL import Image, ImageOps
        image = pyautogui.screenshot(region=(x0, y0, ww, hh)).convert("L")
        image = ImageOps.autocontrast(image.resize((ww * 2, hh * 2)))
        os.makedirs(SHOTS, exist_ok=True)
        path = os.path.join(SHOTS, "pkt_canvas_labels.png")
        image.save(path)
        out = _run_hidden(
            [TESSERACT_CMD, path, "stdout", "--psm", "11", "tsv"],
            capture_output=True, text=True, timeout=15)
        words = []
        for line in (out.stdout or "").splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) < 12 or not parts[11].strip():
                continue
            try:
                confidence = float(parts[10])
                if confidence < 20:
                    continue
                raw = parts[11].strip()
                # Tesseract reports coordinates in the 2x OCR image.
                cx = x0 + (int(parts[6]) + int(parts[8]) / 2) / 2
                cy = y0 + (int(parts[7]) + int(parts[9]) / 2) / 2
                words.append({
                    "text": raw,
                    "fx": round((cx - l) / W, 4),
                    "fy": round((cy - t) / H, 4),
                    "confidence": round(confidence, 1),
                })
            except (TypeError, ValueError, IndexError):
                continue
        return words
    except Exception as exc:
        log(f"PKT canvas discovery OCR failed: {exc}")
        return []


def _canvas_device_token(raw: str) -> tuple[str, str] | None:
    """Map a conservative OCR label to (stable name, device type)."""
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "", str(raw or ""))
    if not cleaned or len(cleaned) > 32:
        return None
    low = cleaned.lower()
    # Common Packet Tracer labels plus the names used by the app's planner.
    if (re.fullmatch(r"(?:r|router|hqrouter|brr router|branchrouter)[-_]?\d*", low)
            or "router" in low or low.startswith("isr")):
        dtype = "router"
    elif (re.fullmatch(r"(?:sw|switch|hqswitch|brswitch)[-_]?\d*", low)
          or "switch" in low or low.startswith("2960")):
        dtype = "switch"
    elif (re.fullmatch(r"(?:pc|computer|laptop)[-_]?\d*", low)
          or low.startswith("pc")):
        dtype = "pc"
    elif (re.fullmatch(r"(?:srv|server)[-_]?\d*", low)
          or "server" in low):
        dtype = "server"
    else:
        return None
    name = re.sub(r"[- ]+", "_", cleaned).upper()
    return name, dtype


def discover_canvas_devices(rect, project: str) -> dict:
    """Discover an external .pkt's labelled devices and remember their spots."""
    candidates = []
    seen = set()
    for word in _canvas_ocr_words(rect):
        token = _canvas_device_token(word.get("text", ""))
        if not token:
            continue
        name, dtype = token
        if name in seen:
            continue
        seen.add(name)
        # Labels are rendered below their icon in Packet Tracer.  Keep the
        # correction bounded so we never click outside the canvas.
        fx = float(word.get("fx", 0.5))
        fy = max(0.18, float(word.get("fy", 0.4)) - 0.045)
        candidates.append({
            "name": name,
            "type": dtype,
            "fx": round(min(0.95, max(0.05, fx)), 4),
            "fy": round(min(0.78, max(0.18, fy)), 4),
            "ocr": word.get("text", ""),
            "confidence": word.get("confidence", 0),
        })
    candidates.sort(key=lambda item: (item["fy"], item["fx"], item["name"]))
    if not candidates:
        return {"devices": [], "reason": "no conservative device labels were found"}
    # A duplicate label is still useful, but it must not overwrite the first
    # device's memory entry.
    counts = {}
    for item in candidates:
        base = item["name"]
        counts[base] = counts.get(base, 0) + 1
        if counts[base] > 1:
            item["name"] = f"{base}_{counts[base]}"
        remember_device(project, item["name"], item["fx"], item["fy"],
                        item["type"], verified=False)
    record_event("pkt_discovery",
                 f"discovered {len(candidates)} labelled device(s) from the .pkt canvas",
                 recovered=True,
                 extra={"project": project,
                        "devices": [item["name"] for item in candidates]})
    return {"devices": candidates, "reason": "OCR-labelled canvas discovery"}


def _audit_summary(devices: list, red_indicators: list,
                   discovery: dict | None = None) -> dict:
    """Build stable, UI-friendly totals from audit evidence."""
    by_type = {}
    severity = {"high": 0, "medium": 0, "info": 0}
    interfaces = {"up": 0, "down": 0, "administratively_down": 0}
    services = {"checked": 0, "on": 0, "off": 0, "unknown": 0,
                "saved_data": 0, "rules_verified": 0, "state_only": 0}
    findings = 0
    for device in devices:
        dtype = str(device.get("type") or "unknown")
        by_type[dtype] = by_type.get(dtype, 0) + 1
        for finding in device.get("findings", []) or []:
            findings += 1
            level = str(finding.get("severity") or "info")
            severity[level] = severity.get(level, 0) + 1
        for interface in device.get("interfaces", []) or []:
            status = str(interface.get("status") or "").lower()
            if status == "up":
                interfaces["up"] += 1
            elif status == "administratively down":
                interfaces["administratively_down"] += 1
            elif status == "down":
                interfaces["down"] += 1
        for service in device.get("services", []) or []:
            services["checked"] += 1
            state = str(service.get("state") or "unknown")
            if state == "on":
                services["on"] += 1
            elif state == "off":
                services["off"] += 1
            else:
                services["unknown"] += 1
            if service.get("saved_data") is True:
                services["saved_data"] += 1
            if service.get("rules_verified") is True:
                services["rules_verified"] += 1
            if service.get("verification_mode") == "state_only":
                services["state_only"] += 1
    return {
        "device_count": len(devices),
        "by_type": by_type,
        "finding_count": findings,
        "severity": severity,
        "interfaces": interfaces,
        "services": services,
        "red_indicators": len(red_indicators),
        "canvas_discovery_used": bool((discovery or {}).get("devices")),
    }


def audit_network(project: str):
    """Full audit pass; result lands in AUDIT['report'] + /audit_report."""
    try:
        AUDIT["running"] = True
        AUDIT["report"] = None
        if stopped():
            log("AUDIT stopped before Packet Tracer focus")
            return
        w = focus_pt()
        rect = rect_of(w)
        devs = DEV_MEM.get(project, {})
        discovery = None
        if not devs:
            discovery = discover_canvas_devices(rect, project)
            devs = DEV_MEM.get(project, {})
        if not devs:
            AUDIT["report"] = {
                "project": project, "devices": [], "red_dots": 0,
                "reachability": {"enabled": False, "attempted": 0,
                                  "passed": 0, "failed": 0, "skipped": [],
                                  "results": []},
                "discovery": discovery or {},
                "note": "No labelled devices could be discovered on the loaded .pkt canvas. "
                "Rename devices to labels such as R1, SW1, PC1, or SRV1 and run analysis again."}
            return
        names = sorted(devs)
        devices = []
        for name in names:
            if stopped():
                break
            dtype = str(devs[name].get("type", ""))
            slot = names.index(name)
            log(f"AUDIT {name} ({dtype})...")
            # one bad device must NOT kill the whole audit (user run:
            # an early exception emptied the whole report)
            try:
                if dtype in ("router", "switch"):
                    d = _audit_cli_device(rect, name, slot, project, dtype)
                elif dtype == "server":
                    d = _audit_server(rect, name, slot, project)
                else:
                    d = _audit_pc(rect, name, slot, project)
                if d:
                    devices.append(d)
            except Exception as e:
                log(f"AUDIT {name} failed: {e}")
                devices.append({
                    "name": name, "type": dtype, "findings": [
                        {"id": f"{name}:audit_error", "severity": "info",
                         "text": f"audit error: {str(e)[:120]}",
                         "fix_cli": []}]})
        # Do not start another screen scan after the user has stopped the
        # audit.  Esc is a hard stop for both build and Analyze activity.
        if stopped():
            log("AUDIT stopped before the red-indicator scan")
            return
        try:
            reds = _scan_red_dots(rect)
        except Exception as e:
            log(f"red scan failed: {e}")
            reds = []
        if stopped():
            log("AUDIT stopped before reachability tests")
            return
        try:
            reachability = _audit_reachability(rect, devices, names, project)
        except Exception as e:
            log(f"reachability audit failed: {e}")
            reachability = {
                "enabled": True,
                "attempted": 0,
                "passed": 0,
                "failed": 0,
                "skipped": [],
                "results": [],
                "error": str(e)[:160],
            }
        red_indicators = [
            {"x": c[0], "y": c[1], "pixels": c[2]} for c in reds
        ]
        AUDIT["report"] = {"project": project, "devices": devices,
                           "red_dots": len(reds),
                           "red_indicators": red_indicators,
                           "summary": _audit_summary(devices, red_indicators,
                                                     discovery),
                           "reachability": reachability,
                           "scope": [
                               "canvas label discovery when positions were not remembered",
                               "router and switch CLI readback",
                               "PC and server IPv4 readback",
                               "server Services-tab readback",
                               "endpoint gateway and peer ping tests",
                               "read-only route/CDP/VLAN CLI probes",
                               "canvas red-link indicator scan",
                           ],
                           "discovery": discovery or {},
                           "generated": time.strftime("%Y-%m-%d %H:%M:%S")}
        record_event("audit_done",
                     f"{len(devices)} device(s), {len(reds)} red "
                     f"indicator(s)", recovered=True)
        log(f"AUDIT finished: {len(devices)} device(s), {len(reds)} red "
            f"indicator(s) - check the app for suggested fixes")
    except Exception as e:
        log(f"AUDIT ERROR: {e}")
        AUDIT["report"] = {"project": project, "devices": [],
                           "error": str(e)}
    finally:
        end_activity("audit")


def validate_run(plan: dict, project: str, slot_of: dict,
                 link_specs: dict) -> dict:
    """Independent end-to-end verdict from action results and live checks."""
    checks = []

    def add(name: str, ok: bool, expected: str, observed: str):
        checks.append({"name": name, "ok": bool(ok),
                       "expected": expected[:240],
                       "observed": observed[:240]})

    planned = [n.get("name") for st in plan.get("steps", [])
               if st.get("action") == "create_nodes"
               for n in st.get("nodes", []) if n.get("name")]
    if planned:
        outcomes = RUN.get("node_outcomes", {})
        add("devices", all(outcomes.get(n) in ("reused", "placed")
                            for n in planned),
            f"{len(planned)} planned devices verified",
            json.dumps({n: outcomes.get(n, "missing") for n in planned}))
    else:
        add("devices", True, "existing device slots available",
            f"{len(slot_of)} remembered slot(s)")

    links = [lnk for st in plan.get("steps", [])
             if st.get("action") == "create_links"
             for lnk in st.get("links", [])]
    link_results = RUN.get("link_results", {})
    link_statuses = [link_results.get(str(i), {}).get("status", "missing")
                     for i in range(len(links))]
    links_ok = (not links) or (
        bool(link_results) and
        all(link_results.get(str(i), {}).get("status") == "verified"
            and link_results.get(str(i), {}).get("visual_evidence") is True
            for i in range(len(links)))
    )
    add("links", links_ok,
        f"{len(links)} planned links verified",
        json.dumps({"status": link_statuses,
                    "visual": [link_results.get(str(i), {}).get(
                        "visual_evidence", False)
                                for i in range(len(links))]}))

    cli_names = [dev for st in plan.get("steps", [])
                 if st.get("action") == "paste_cli"
                 for dev in (st.get("configs", {}) or {})]
    cli_results = {k.split(":", 1)[1]: v
                   for k, v in RUN.get("action_results", {}).items()
                   if k.startswith("paste_cli:")}
    add("cli", all(cli_results.get(d, {}).get("status") == "verified"
                    for d in cli_names),
        f"{len(cli_names)} router/switch configs verified",
        json.dumps({d: cli_results.get(d, {}).get("status", "missing")
                    for d in cli_names}))

    pc_names = [dev for st in plan.get("steps", [])
                if st.get("action") == "config_pcs"
                for dev in (st.get("pcs", {}) or {})]
    pc_results = {k.split(":", 1)[1]: v
                  for k, v in RUN.get("action_results", {}).items()
                  if k.startswith("config_pc:")}
    add("pc_config", (not pc_names) or (
        len(pc_results) == len(pc_names) and
        RUN.get("pcs_configured", 0) == len(pc_names) and
        all(pc_results.get(d, {}).get("status") == "verified"
            for d in pc_names)),
        f"{len(pc_names)} PC IP configurations verified",
        json.dumps({d: pc_results.get(d, {}).get("status", "missing")
                    for d in pc_names}))

    server_names = [dev for st in plan.get("steps", [])
                    if st.get("action") == "config_servers"
                    for dev in (st.get("servers", {}) or {})]
    server_results = {k.split(":", 1)[1]: v
                      for k, v in RUN.get("action_results", {}).items()
                      if k.startswith("config_server:")}
    expected_services = []
    for st in plan.get("steps", []):
        if st.get("action") != "config_servers":
            continue
        for dev, config in (st.get("servers", {}) or {}).items():
            service_map = (config or {}).get("services", config or {})
            expected_services.extend(
                (dev, str(service).lower()) for service in service_map
            )
    server_config_ok = (not server_names) or (
        len(server_results) == len(server_names) and
        RUN.get("srv_configured", 0) == len(expected_services) and
        RUN.get("srv_failed", 0) == 0 and
        all(server_results.get(d, {}).get("status") == "verified"
            for d in server_names))
    add("server_config", server_config_ok,
        f"{len(server_names)} server service groups verified",
        json.dumps({d: server_results.get(d, {}).get("status", "missing")
                    for d in server_names}))

    add("links_live", (not links) or (
        RUN.get("red_link_check_ran") is True and
        RUN.get("links_red", 0) == 0 and links_ok and
        RUN.get("links_failed", 0) == 0),
        "no red link indicators and every cable has line evidence",
        f"red={RUN.get('links_red', 0)} failed={RUN.get('links_failed', 0)} "
        f"red_scan={RUN.get('red_link_check_ran', False)}")
    ping_results = RUN.get("ping_results", []) or []
    ping_expected = RUN.get("pings_expected", 0)
    pings_ok = (not pc_names) or (
        ping_expected > 0 and len(ping_results) == ping_expected and
        RUN.get("pings_failed", 0) == 0 and
        all(result.get("ok") is True for result in ping_results))
    add("pings", pings_ok,
        "every configured endpoint has real reply evidence",
        f"expected={ping_expected} results={len(ping_results)} "
        f"passed={RUN.get('pings_ok', 0)} failed={RUN.get('pings_failed', 0)}")
    remaps = RUN.get("interface_remaps", {}) or {}
    add("interface_capabilities", RUN.get("interfaces_blocked", 0) == 0,
        "all requested interfaces exist or are remapped to proven spare ports",
        f"blocked={RUN.get('interfaces_blocked', 0)} remaps={remaps}")
    # A proven spare port can keep a lab electrically usable, but it is not
    # the topology the user requested.  Keep that recovery visible and make
    # the exact-plan verdict fail until the required module/interface exists.
    add("interface_fidelity",
        RUN.get("interfaces_blocked", 0) == 0 and not remaps,
        "every requested cable uses its exact named interface",
        f"blocked={RUN.get('interfaces_blocked', 0)} remaps={remaps}")
    add(
        "cli_context",
        RUN.get("cli_context_blocks", 0) == 0,
        "every CLI command had a proven prompt context",
        f"blocked={RUN.get('cli_context_blocks', 0)} repairs="
        f"{RUN.get('cli_mode_repairs', 0)}",
    )
    service_results = RUN.get("service_results", []) or []
    service_keys = {(str(row.get("device")), str(row.get("service")).lower())
                    for row in service_results}
    service_status_ok = (
        len(service_results) == len(expected_services) and
        all((dev, svc) in service_keys for dev, svc in expected_services) and
        all(row.get("status") == "verified" for row in service_results)
    ) if expected_services else True
    add("services", service_status_ok and RUN.get("srv_failed", 0) == 0,
        "every planned server service has verified live evidence",
        f"expected={len(expected_services)} results={len(service_results)} "
        f"failed={RUN.get('srv_failed', 0)}")
    requested_rules = []
    for st in plan.get("steps", []):
        if st.get("action") != "config_servers":
            continue
        for dev, config in (st.get("servers", {}) or {}).items():
            service_map = (config or {}).get("services", config or {})
            for svc, params in service_map.items():
                if set((params or {})) - {"on", "verification"}:
                    requested_rules.append((dev, str(svc).lower()))
    rules_ok = all(any(row.get("device") == dev and
                       str(row.get("service")).lower() == svc and
                       row.get("rules_verified") is True
                       for row in service_results)
                   for dev, svc in requested_rules)
    add("service_rules", rules_ok,
        "every requested detailed service rule has table/record evidence",
        f"requested={len(requested_rules)} verified="
        f"{sum(1 for row in service_results if row.get('rules_verified'))}")
    security_steps = [st for st in plan.get("steps", [])
                      if st.get("action") == "verify_security"]
    planned_security = [
        check
        for st in security_steps
        for check in (st.get("checks", []) or [])
    ]
    if security_steps:
        observed_security = RUN.get("security_checks", []) or []
        add(
            "security",
            bool(planned_security)
            and len(observed_security) == len(planned_security)
            and RUN.get("security_failed", 0) == 0
            and all(c.get("ok") is True and
                     (c.get("evidence") or {}).get("fresh_output") is True
                     and (c.get("evidence") or {}).get("mode") == "privileged"
                     for c in observed_security),
            f"{len(planned_security)} security checks pass with live evidence",
            f"passed={sum(1 for c in observed_security if c.get('ok'))} "
            f"failed={sum(1 for c in observed_security if not c.get('ok'))}",
        )
    add("recovery", RUN.get("errors_unrecovered", 0) == 0,
        "no unrecovered CLI errors",
        f"recovered={RUN.get('errors_recovered', 0)} "
        f"unrecovered={RUN.get('errors_unrecovered', 0)}")
    add("execution_safety",
        RUN.get("fullscreen_verified") is True and
        RUN.get("focus_blocks", 0) == 0 and
        RUN.get("devices_skipped", 0) == 0
        and RUN.get("devices_reuse_blocked", 0) == 0,
        "Packet Tracer stayed maximized/foreground with no skipped devices",
        f"skipped={RUN.get('devices_skipped', 0)} "
        f"blocked={RUN.get('devices_reuse_blocked', 0)} "
        f"focus_blocks={RUN.get('focus_blocks', 0)} "
        f"maximized={RUN.get('fullscreen_verified', False)}")
    inventory = RUN.get("inventory") or {}
    add(
        "inventory",
        isinstance(inventory, dict)
        and inventory.get("screen_authority") is True
        and not bool(inventory.get("error")),
        "preflight inventory recorded from the Packet Tracer screen",
        "ok" if (isinstance(inventory, dict)
                 and inventory.get("screen_authority") is True
                 and not inventory.get("error")) else "missing or untrusted",
    )

    # Platform gaps are reported, never failed: Packet Tracer
    # cannot execute these even in a correct plan.
    unsupported = list(RUN.get("unsupported_features", []) or [])
    add("unsupported_features", True,
        "no Packet Tracer-unsupported commands requested",
        (f"{len(unsupported)} command(s) not supported by "
         f"Packet Tracer were elided and reported: "
         f"{'; '.join(unsupported[:4])}" if unsupported
         else "none requested"))
    ok = all(c["ok"] for c in checks)
    report = {
        "project": project,
        "ok": ok,
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "checks": checks,
    }
    RUN["validation"] = report
    phase_update("validation", "verified" if ok else "failed",
                 expected="all independent end-to-end checks pass",
                 observed="; ".join(f"{c['name']}={'ok' if c['ok'] else 'FAIL'}"
                                    for c in checks))
    record_event("validation_done",
                 "all checks passed" if ok else
                 "; ".join(c["name"] for c in checks if not c["ok"]),
                 recovered=ok)
    return report


def _failed_action_names() -> list:
    """Unverified work items from the last pass.

    Two sources are merged: per-device action results ("paste_cli:R1") and
    per-link results, which are keyed by plan index inside
    RUN["link_results"] ("create_links:3").
    """
    out = []
    for key, row in (RUN.get("action_results", {}) or {}).items():
        if not isinstance(row, dict) or row.get("status") == "verified":
            continue
        if ":" not in key:
            continue
        action, dev = key.split(":", 1)
        out.append((action, dev))
    for idx, row in (RUN.get("link_results", {}) or {}).items():
        if isinstance(row, dict) and row.get("status") != "verified":
            out.append(("create_links", str(idx)))
    return out


def _auto_repair_pass(rect, steps: list, slot_of: dict, type_of: dict,
                      project: str, link_specs: dict,
                      link_blocked_indices: set, passes_done: int) -> bool:
    """Re-run only the failed actions; return True if the plan can finish.

    This is the 'do not stop until the job is completed or the user stops
    it' layer.  Each pass re-attempts ONLY devices whose last action did not
    verify (the max_passes cap keeps a genuinely broken screen from looping
    forever), and every retry uses what the learning controller learned in
    earlier passes: remembered fallbacks are applied before typing, spots
    and panel geometry are already taught, and command memory skips lines
    that are known-benign.
    """
    pending = _failed_action_names()
    if not pending:
        return True
    remaining = MAX_REPAIR_PASSES - passes_done
    if remaining <= 0:
        record_event("repair_exhausted",
                     f"{len(pending)} action(s) still unverified after "
                     f"{MAX_REPAIR_PASSES} repair pass(es)",
                     recovered=False,
                     extra={"pending": ",".join(f"{a}:{d}" for a, d
                                               in pending[:6])})
        return False
    action_of = {}
    for st in steps:
        a = st.get("action", "")
        if a == "create_nodes":
            action_of["create_nodes"] = st
        elif a == "create_links":
            action_of["create_links"] = st
        elif a == "paste_cli":
            action_of["paste_cli"] = st
        elif a == "config_pcs":
            action_of["config_pcs"] = st
        elif a == "config_servers":
            action_of["config_servers"] = st
    dev_of = {dev: a for a, dev in pending}
    retype = {}
    cli_step = action_of.get("paste_cli")
    if cli_step:
        retype = {dev: cfg for dev, cfg in
                  (cli_step.get("configs", {}) or {}).items() if dev in dev_of}
    log(f"AUTO-REPAIR pass {passes_done + 1}/{MAX_REPAIR_PASSES}: "
        f"re-attempting {len(pending)} failed action(s) "
        f"({', '.join(f'{a} {d}' for a, d in pending[:8])})")
    RUN["repair_passes"] = RUN.get("repair_passes", 0) + 1
    phase_update("auto_repair", "running",
                 expected="each failed action re-attempted with learned "
                          "fallbacks",
                 observed=f"pending={len(pending)} pass={passes_done + 1}",
                 attempt=passes_done + 1)
    cli_cfgs = {}
    if cli_step:
        cli_cfgs = cli_step.get("configs", {}) or {}
    pcs_step = action_of.get("config_pcs") or {}
    servers_step = action_of.get("config_servers") or {}
    nodes_step = action_of.get("create_nodes")
    for action, dev in list(pending):
        if stopped():
            break
        if not wait_if_paused():
            break
        if action == "create_nodes" and nodes_step:
            names = [n.get("name") for n in nodes_step.get("nodes", [])
                     if n.get("name")]
            if dev in names:
                sub = dict(nodes_step)
                sub["nodes"] = [n for n in nodes_step.get("nodes", [])
                                if n.get("name") == dev]
                place_nodes(rect, sub["nodes"], project)
        elif action == "paste_cli" and dev in slot_of and retype.get(dev):
            cabled = []
            for (la, lb), (laIf, lbIf) in link_specs.items():
                if la == dev:
                    cabled.append(laIf)
                if lb == dev:
                    cabled.append(lbIf)
            dm = 25
            if cli_step:
                dm = int(cli_step.get("typing_delay_ms", 25) or 25)
            cli_ok = paste_to_device(rect, dev, slot_of[dev], retype[dev], dm,
                                     project, type_of.get(dev, ""),
                                     cabled=cabled)
            action_update("paste_cli", dev,
                          "verified" if cli_ok else "failed",
                          expected="CLI prompt live and config verified",
                          observed="verified on repair pass" if cli_ok
                          else "still failing after repair pass")
            if cli_ok:
                RUN["devices_done"] = RUN.get("devices_done", 0) + 1
                RUN["repair_recovered"] = RUN.get("repair_recovered", 0) + 1
        elif action == "config_pc" and dev in slot_of:
            ipcfg = (pcs_step.get("pcs", {}) or {}).get(dev) \
                if pcs_step else None
            if ipcfg:
                pc_ok = _config_pc_desktop(rect, dev, slot_of[dev], ipcfg,
                                           project)
                action_update("config_pc", dev,
                              "verified" if pc_ok else "failed",
                              expected="IP visible in PC panel",
                              observed="verified on repair pass" if pc_ok
                              else "still failing after repair pass")
                if pc_ok:
                    RUN["repair_recovered"] = \
                        RUN.get("repair_recovered", 0) + 1
        elif action == "config_server" and dev in slot_of:
            svccfg = (servers_step.get("servers", {}) or {}).get(dev) \
                if servers_step else None
            if svccfg:
                srv_ok = _config_server_services(rect, dev, slot_of[dev],
                                                 svccfg, project)
                action_update("config_server", dev,
                              "verified" if srv_ok else "failed",
                              expected="server services verified",
                              observed="verified on repair pass" if srv_ok
                              else "still failing after repair pass")
                if srv_ok:
                    RUN["repair_recovered"] = \
                        RUN.get("repair_recovered", 0) + 1
        elif action == "create_links":
            link_step = action_of.get("create_links") or {}
            planned = link_step.get("links", []) or []
            idx = int(dev) if str(dev).isdigit() else None
            if idx is None or idx >= len(planned):
                log(f"auto-repair: link index {dev} is not in the plan - "
                    "left as failed")
                continue
            if idx in link_blocked_indices:
                log(f"auto-repair: link {idx} was blocked by the interface "
                    "preflight - not retried")
                continue
            lnk = planned[idx]
            if lnk.get("a") not in slot_of or lnk.get("b") not in slot_of:
                log(f"auto-repair: link {idx} references an unknown slot - "
                    "left as failed")
                continue
            # original_indices re-keys the fresh result onto the SAME plan
            # index, so validate_run keeps matching planned vs recorded.
            place_links(rect, [lnk], slot_of, project, link_specs,
                        original_indices=[idx])
            if (RUN.get("link_results", {}).get(str(idx), {})
                    .get("status") == "verified"):
                RUN["repair_recovered"] = RUN.get("repair_recovered", 0) + 1
        else:
            log(f"auto-repair: no retry recipe for {action} {dev} - "
                "left as failed")
    still = _failed_action_names()
    phase_update("auto_repair",
                 "verified" if not still else "failed",
                 expected="each failed action re-attempted with learned "
                          "fallbacks",
                 observed=("all actions verified" if not still else
                           f"still failing: " +
                           ", ".join(f"{a}:{d}" for a, d in still[:6])),
                 attempt=passes_done + 1)
    if still:
        record_event("repair_pass_incomplete",
                     f"{len(still)} action(s) still unverified after pass "
                     f"{passes_done + 1}", recovered=False,
                     extra={"pending": ",".join(f"{a}:{d}" for a, d
                                               in still[:6])})
        return False
    record_event("repair_pass_complete",
                 f"all failed actions recovered on pass {passes_done + 1}",
                 recovered=True)
    return True


def run_plan(plan: dict):
    global LAST_PLAN
    LAST_PLAN = plan if isinstance(plan, dict) else {}
    try:
        with LOCK:
            JOB.running = True
            JOB.log.clear()
        _run_reset()
        if stopped():
            log("stop requested before Packet Tracer focus")
            return
        project = str(plan.get("project", "default"))
        phase_update("preflight", "running",
                     expected="Packet Tracer focused, visible, and safe to control")
        recalled = DEV_MEM.get(project, {})
        if recalled:
            log(f"remembered {len(recalled)} device(s) for '{project}': "
                + ", ".join(sorted(recalled)))
        else:
            log(f"no remembered devices for '{project}' yet - will memorize this run")
        stale = [n for n, e in (DEV_MEM.get(project, {}) or {}).items()
                 if isinstance(e, dict)
                 and e.get("layout") != LAYOUT_VERSION]
        if stale:
            log(f"ignoring {len(stale)} spot(s) saved under older layout "
                f"({', '.join(sorted(stale))}) - placing FRESH with "
                f"layout v{LAYOUT_VERSION} (use a BLANK canvas)")
        w = focus_pt()
        rect = rect_of(w)
        log(f"PT rect {rect}")
        log("REMINDER: keep Packet Tracer VISIBLE and in front for the "
            "whole run - clicks and screen reads hit whatever window is "
            "on top (a covering window breaks the PC/Desktop stages).")
        shot("before.png")
        prove_movement(rect)  # user MUST see this; diagnoses focus issues
        if stopped():
            phase_update("preflight", "failed",
                         expected="preflight completes", observed="stop requested")
            log("stopped after proof")
            return
        phase_update("preflight", "verified",
                     expected="Packet Tracer focused and visible",
                     observed=f"rect={rect}")
        steps = plan.get("steps", [])
        mode = str(plan.get("mode", "full"))
        # collect slots first so links/configs can reference them
        slot_of: dict = {}
        type_of: dict = {}
        link_specs: dict = {}
        for st in steps:
            if st.get("action") == "create_nodes":
                for i, n in enumerate(st.get("nodes", [])):
                    slot_of.setdefault(n.get("name"), len(slot_of))
                    type_of[n.get("name")] = (n.get("type") or "").lower()
            elif st.get("action") == "create_links":
                for lnk in st.get("links", []):
                    try:
                        link_specs[(lnk.get("a"), lnk.get("b"))] = (
                            lnk.get("aIf", "g0/0"), lnk.get("bIf", "g0/0"))
                    except Exception:
                        pass
        has_nodes = any(st.get("action") == "create_nodes" for st in steps)
        planned_node_names = [
            n.get("name")
            for st in steps
            if st.get("action") == "create_nodes"
            for n in st.get("nodes", [])
            if n.get("name")
        ]
        try:
            phase_update("inventory", "running",
                         expected="each planned slot classified from the live screen")
            inventory_plan(rect, project, steps)
            phase_update("inventory", "verified",
                         expected="inventory report recorded",
                         observed="live slot states stored")
        except Exception as e:
            RUN["inventory"] = {"project": project, "error": str(e)}
            record_event("inventory_failed", str(e), recovered=False)
            phase_update("inventory", "failed",
                         expected="inventory report recorded", observed=str(e))
            log(f"INVENTORY failed: {e} - execution will recheck each "
                "slot before acting")
        if not has_nodes and not slot_of:
            # fixes mode: apply chosen repairs to an EXISTING network -
            # slots come from remembered devices
            mem_devs = DEV_MEM.get(project, {})
            for i, name in enumerate(sorted(mem_devs)):
                slot_of.setdefault(name, i)
                type_of.setdefault(name,
                                   str(mem_devs[name].get("type", "")))
            if slot_of:
                log(f"fixes mode: {len(slot_of)} remembered device(s) "
                    f"available for repairs")
        if has_nodes:
            phase_update("placement", "running",
                         expected=f"{len(planned_node_names)} planned device(s) "
                                 "visible and verified")
            # Stage 1: devices, up to 3 attempts. A retry only touches
            # unresolved slots because verified placements are now reused.
            for attempt in (1, 2, 3):
                if attempt > 1:
                    RUN["placement_retries"] = \
                        RUN.get("placement_retries", 0) + 1
                for st in steps:
                    if stopped():
                        break
                    if st.get("action") == "create_nodes":
                        place_nodes(rect, st.get("nodes", []), project)
                if stopped():
                    log("stopped after devices")
                    return
                # VISUAL GATE: never cable an empty canvas (your screenshot case).
                shot("after_nodes.png")
                changed, score = canvas_changed(shot_path("before.png"),
                                                shot_path("after_nodes.png"))
                outcomes = RUN.get("node_outcomes", {})
                blocked = [name for name in planned_node_names
                           if outcomes.get(name) == "blocked"]
                if blocked:
                    phase_update("placement", "failed",
                                 expected="all planned devices verified",
                                 observed="blocked: " + ", ".join(blocked),
                                 attempt=attempt)
                    log("PLACEMENT BLOCKED for " + ", ".join(blocked) +
                        " - an occupied slot could not be identified safely; "
                        "no cables or commands will run")
                    RUN["ok"] = False
                    return
                ready = bool(planned_node_names) and all(
                    outcomes.get(name) in ("reused", "placed")
                    for name in planned_node_names)
                if ready:
                    phase_update("placement", "verified",
                                 expected=f"{len(planned_node_names)} planned device(s) verified",
                                 observed=json.dumps(outcomes), attempt=attempt)
                    if changed:
                        log(f"placement verified (canvas diff {score}). "
                            "Proceeding to cables/CLI.")
                    else:
                        log("all planned devices are already verified on the "
                            "canvas; no placement diff expected. Proceeding "
                            "to cables/CLI.")
                    break
                if changed and not planned_node_names:
                    log(f"placement verified (canvas diff {score}). "
                        f"Proceeding to cables/CLI.")
                    break
                record_event("placement_failed",
                             f"canvas diff {score} below threshold "
                             f"(attempt {attempt})", recovered=False)
                if attempt < 3:
                    phase_update("placement", "retrying",
                                 expected="all planned devices verified",
                                 observed=f"canvas diff {score}", attempt=attempt)
                    log(f"PLACEMENT FAILED (diff {score}) - auto-tuner "
                        f"scanned the model strip; retrying placement "
                        f"({3 - attempt} attempt(s) left).")
                else:
                    phase_update("placement", "failed",
                                 expected="all planned devices verified",
                                 observed=f"canvas diff {score} after 3 attempts",
                                 attempt=attempt)
                    log(f"PLACEMENT FAILED three times - NOT cabling an empty "
                        f"canvas. Fix: Detail -> Teach Model (hover the "
                        f"exact model thumbnail), then retry.")
                    shot("after.png")
                    RUN["ok"] = False
                    return
        else:
            phase_update("placement", "skipped",
                         expected="existing devices available",
                         observed=f"mode={mode}")
            log(f"cables-only/fixes mode ({mode}): devices assumed on "
                f"canvas, wiring {len(link_specs)} link(s) at remembered "
                f"spots.")
        # Stage 1.5: verify physical ports before cable clicks.  A default
        # PT 2911 may have no serial interface; a disposable fallback can
        # recover the WAN on a proven spare routed port, but the exact
        # interface verdict remains failed and records the remap explicitly.
        link_blocked_indices = set()
        all_planned_links = []
        for st in steps:
            if st.get("action") == "create_links":
                all_planned_links.extend(st.get("links", []) or [])
        if all_planned_links and not stopped():
            phase_update("interface_preflight", "running",
                         expected="all requested cable interfaces exist")
            link_blocked_indices = _preflight_link_capabilities(
                rect, all_planned_links, slot_of, project)
            _apply_interface_remaps_to_plan(steps)
            # The cable stage and CLI healing must use the post-preflight
            # interface names, not the stale map collected before probing.
            link_specs = {}
            for st2 in steps:
                if st2.get("action") != "create_links":
                    continue
                for lnk2 in st2.get("links", []) or []:
                    link_specs[(lnk2.get("a"), lnk2.get("b"))] = (
                        lnk2.get("aIf", "g0/0"),
                        lnk2.get("bIf", "g0/0"),
                    )
            phase_update(
                "interface_preflight",
                "verified" if not link_blocked_indices else "failed",
                expected="all requested cable interfaces exist or are safely remapped to proven spare ports",
                observed=("all available" if not link_blocked_indices and
                          not RUN.get("interface_remaps") else
                          f"remaps={RUN.get('interface_remaps', {})} "
                          f"blocked={sorted(link_blocked_indices)}"))

        # Stage 2: links + CLI only after verified devices.
        phase_seen = set()
        cli_prerequisite_failed = False
        downstream_blocked = False
        for st in steps:
            if stopped():
                break
            a = st.get("action")
            if a == "create_nodes":
                continue  # already done
            elif a == "create_links":
                if "links" not in phase_seen:
                    phase_update("links", "running",
                                 expected=f"{len(st.get('links', []))} link(s) wired and verified")
                    phase_seen.add("links")
                before_failed = RUN.get("links_failed", 0)
                planned_links = st.get("links", []) or []
                usable_links = [
                    link for i, link in enumerate(planned_links)
                    if i not in link_blocked_indices
                ]
                usable_indices = [
                    i for i in range(len(planned_links))
                    if i not in link_blocked_indices
                ]
                place_links(rect, usable_links, slot_of, project,
                            link_specs, original_indices=usable_indices)
                link_state = ("verified" if not any(
                    i in link_blocked_indices
                    for i in range(len(planned_links))) and
                    RUN.get("links_failed", 0) == before_failed
                              else "failed")
                phase_update("links", link_state,
                             expected=f"{len(st.get('links', []))} link(s) wired and verified",
                             observed=f"failed={RUN.get('links_failed', 0) - before_failed}")
            elif a == "paste_cli":
                phase_update("cli", "running",
                             expected="every router/switch config verified or a learned correction recorded")
                cfgs = st.get("configs", {})
                dm = st.get("typing_delay_ms", 25)
                reuse_configs = (mode == "full"
                                 and not bool(plan.get("force_reapply", False)))
                if reuse_configs:
                    log("verified command cache enabled for this FULL build; "
                        "Fixes mode always re-applies requested commands")
                for dev, cfg in cfgs.items():
                    if stopped():
                        break
                    if dev in slot_of:
                        action_update("paste_cli", dev, "running",
                                      expected="CLI prompt live and config verified")
                        if reuse_configs and cached_config_matches(
                                project, dev, cfg, type_of.get(dev, "")):
                            RUN["configs_reused"] = \
                                RUN.get("configs_reused", 0) + 1
                            RUN["devices_done"] = \
                                RUN.get("devices_done", 0) + 1
                            log(f"REUSED verified commands for {dev} - "
                                "skipping CLI typing (exact config match)")
                            record_event(
                                "config_reused",
                                "exact previously verified command set "
                                "matched; CLI typing skipped",
                                device=dev, recovered=True,
                                extra={"fingerprint":
                                       config_fingerprint(cfg)})
                            action_update("paste_cli", dev, "verified",
                                          expected="CLI config verified",
                                          observed="exact verified cache hit")
                            continue
                        # ports this device has cables on -> heal targets
                        cabled = []
                        for (la, lb), (laIf, lbIf) in link_specs.items():
                            if la == dev:
                                cabled.append(laIf)
                            if lb == dev:
                                cabled.append(lbIf)
                        cli_ok = paste_to_device(
                            rect, dev, slot_of[dev], cfg, dm, project,
                            type_of.get(dev, ""), cabled=cabled)
                        action_update("paste_cli", dev,
                                      "verified" if cli_ok else "failed",
                                      expected="CLI prompt live and config verified",
                                      observed="typed and verified" if cli_ok
                                      else "verification failed")
                    else:
                        action_update("paste_cli", dev, "failed",
                                      expected="device slot available",
                                      observed="no canvas slot")
                        log(f"skip CLI for {dev}: no canvas slot")
                cli_results = [
                    v for k, v in RUN.get("action_results", {}).items()
                    if k.startswith("paste_cli:")
                ]
                cli_phase_ok = (
                    not cfgs or
                    len(cli_results) == len(cfgs)
                    and len(cli_results) > 0
                    and all(v.get("status") == "verified"
                            for v in cli_results)
                )
                phase_update(
                    "cli",
                    "verified" if cli_phase_ok else "failed",
                    expected="every router/switch config verified or a learned correction recorded",
                    observed=f"results={len(cli_results)}")
                cli_prerequisite_failed = bool(cfgs) and not cli_phase_ok
                RUN["cli_prerequisite_failed"] = cli_prerequisite_failed
                if cli_prerequisite_failed:
                    record_event(
                        "cli_prerequisite_failed",
                        "router/switch CLI verification failed; PC, "
                        "server, security and reachability stages will "
                        "still run, and this result is reported "
                        "separately",
                        recovered=False,
                        extra={"results": len(cli_results),
                               "planned": len(cfgs)},
                    )
            elif a == "config_pcs":
                phase_update("pc_config", "running",
                             expected="every planned PC IP configuration verified")
                pcs = st.get("pcs", {})
                for dev, ipcfg in pcs.items():
                    if stopped():
                        break
                    if dev in slot_of:
                        action_update("config_pc", dev, "running",
                                      expected="IP visible in PC panel")
                        pc_ok = _config_pc_desktop(
                            rect, dev, slot_of[dev], ipcfg, project)
                        action_update("config_pc", dev,
                                      "verified" if pc_ok else "failed",
                                      expected="IP visible in PC panel",
                                      observed="IP verified" if pc_ok
                                      else "IP not verified")
                    else:
                        action_update("config_pc", dev, "failed",
                                      expected="PC slot available",
                                      observed="no canvas slot")
                        log(f"skip PC config for {dev}: no canvas slot")
                phase_update(
                    "pc_config",
                    "verified" if (
                        not pcs or
                        len([k for k in RUN.get("action_results", {})
                             if k.startswith("config_pc:")]) == len(pcs)
                        and all(v.get("status") == "verified"
                                for k, v in RUN.get("action_results", {}).items()
                                if k.startswith("config_pc:"))
                    ) else "failed",
                    expected="every planned PC IP configuration verified",
                    observed=f"configured={RUN.get('pcs_configured', 0)}")
            elif a == "config_servers":
                phase_update("server_config", "running",
                             expected="every planned server service verified")
                servers = st.get("servers", {})
                for dev, svccfg in servers.items():
                    if stopped():
                        break
                    if dev in slot_of:
                        action_update("config_server", dev, "running",
                                      expected="server services verified")
                        srv_ok = _config_server_services(
                            rect, dev, slot_of[dev], svccfg, project)
                        action_update("config_server", dev,
                                      "verified" if srv_ok else "failed",
                                      expected="server services verified",
                                      observed="services verified" if srv_ok
                                      else "one or more services failed")
                    else:
                        action_update("config_server", dev, "failed",
                                      expected="server slot available",
                                      observed="no canvas slot")
                        log(f"skip Services for {dev}: no canvas slot")
                phase_update(
                    "server_config",
                    "verified" if (
                        not servers or
                        len([k for k in RUN.get("action_results", {})
                             if k.startswith("config_server:")]) == len(servers)
                        and all(v.get("status") == "verified"
                                for k, v in RUN.get("action_results", {}).items()
                                if k.startswith("config_server:"))
                    ) else "failed",
                    expected="every planned server service verified",
                    observed=f"services={RUN.get('srv_configured', 0)}")
            elif a == "verify_security":
                phase_update(
                    "security_verification", "running",
                    expected="each requested security control produces live show-command evidence")
                checks = st.get("checks", []) or []
                security_ok = _verify_security_checks(
                    rect, checks, slot_of, project)
                phase_update(
                    "security_verification",
                    "verified" if security_ok else "failed",
                    expected=f"{len(checks)} security checks pass",
                    observed=f"passed={sum(1 for c in RUN.get('security_checks', []) if c.get('ok'))} "
                             f"failed={RUN.get('security_failed', 0)}")
            else:
                log(f"unknown step {a}, skipped")
                _interruptible_sleep(0.2)
        if stopped():
            phase_update("verification", "stopped",
                         expected="verification starts only while the run is active",
                         observed="stop requested")
            log("stop requested before verification; no further PT actions")
            return
        # AUTO-REPAIR: do not walk away from unverified work.  Failed
        # devices/links/configs are retried with everything learned so far
        # (remembered fallbacks, taught spots, quarantined bad commands)
        # until either everything verifies or the pass cap says the screen
        # is genuinely broken.  Only a user Stop ends the run early.
        repair_passes = 0
        while not stopped() and wait_if_paused():
            if _failed_action_names():
                if not _auto_repair_pass(rect, steps, slot_of, type_of,
                                         project, link_specs,
                                         link_blocked_indices, repair_passes):
                    repair_passes += 1
                    if repair_passes >= MAX_REPAIR_PASSES:
                        log("auto-repair cap reached - continuing to "
                            "verification with the remaining issues "
                            "reported")
                        break
                    continue
            break
        phase_update("verification", "running",
                     expected="reachability, link indicators, and all action results verified")
        # PING VERIFICATION: every configured endpoint proves its own
        # gateway and, where available, one endpoint on another LAN.  The
        # old implementation tested only the first PC, so a blank Server0
        # or broken branch path could still be reported as successful.
        try:
            pcs = {}
            for st in steps:
                if st.get("action") == "config_pcs":
                    pcs.update(st.get("pcs", {}))
            pc_names = [d for d in pcs if d in slot_of]
            ping_results = []
            _interruptible_sleep(1.0)
            for source in pc_names:
                ipcfg = pcs.get(source, {}) or {}
                source_ip = str(ipcfg.get("ip", "")).strip()
                gateway = str(ipcfg.get("gw", "")).strip()
                targets = []
                if gateway and gateway != "0.0.0.0":
                    targets.append(gateway)
                # Prefer a peer outside the source /24 so the test exercises
                # the routed/WAN path; fall back to a same-LAN peer when the
                # plan contains only one subnet.
                remote, local = [], []
                source_net = ".".join(source_ip.split(".")[:3])
                for peer, peer_cfg in pcs.items():
                    if peer == source:
                        continue
                    peer_ip = str((peer_cfg or {}).get("ip", "")).strip()
                    if not peer_ip or peer_ip == "0.0.0.0":
                        continue
                    if ".".join(peer_ip.split(".")[:3]) != source_net:
                        remote.append(peer_ip)
                    else:
                        local.append(peer_ip)
                targets += (remote or local)[:1]
                log(f"PING TEST: {source} -> {targets}")
                _pc_ping(rect, source, slot_of[source], targets, project,
                         results=ping_results, count_run=True)
            RUN["ping_results"] = ping_results
        except Exception as e:
            log(f"ping stage failed: {e}")
        shot("after.png")
        # LINK STATUS: red triangles after everything = port still down.
        try:
            links_all = []
            for st in steps:
                if st.get("action") == "create_links":
                    links_all.extend(st.get("links", []))
            if links_all:
                _interruptible_sleep(2.0)  # let link LEDs settle
                _red_link_check(rect, links_all, slot_of, project, link_specs)
                RUN["red_link_check_ran"] = True
        except Exception as e:
            log(f"link check failed: {e}")
        validation = validate_run(plan, project, slot_of, link_specs)
        RUN["ok"] = validation["ok"]
        record_event("run_finished",
                     "ok" if RUN["ok"] else
                     f"issues: skipped={RUN.get('devices_skipped', 0)} "
                     f"unrecovered={RUN.get('errors_unrecovered', 0)} "
                     f"red_links={RUN.get('links_red', 0)} "
                     f"pings_failed={RUN.get('pings_failed', 0)} "
                     f"srv_failed={RUN.get('srv_failed', 0)} "
                     f"validation={'ok' if RUN['ok'] else 'failed'}",
                     recovered=RUN["ok"])
        log(f"plan finished ({'OK' if RUN['ok'] else 'WITH ISSUES'}) - "
            f"CHECK shots/before.png vs after.png + PT canvas")
        # CLI BLOCKS: which evidence was missing, aggregated.  The journal
        # before this change had 592 unrecovered blocks and no way to tell
        # whether they were empty reads, ambiguous glyphs, or wrong modes.
        reasons = RUN.get("cli_block_reasons") or {}
        if reasons:
            top = sorted(reasons.items(), key=lambda kv: -kv[1])[:3]
            log("CLI BLOCKS: " + ", ".join(f"{k}={v}" for k, v in top))
        # ARTIFACT: a green run leaves a .pkt plus its companion manifest.
        _save_run_artifact()
        # Cost split for this run: reads/spawns/ms.  Printed as one log line
        # (visible in the app) and served on /run_summary.perf.
        RUN["perfSummary"] = perf_summary_line()
        log(RUN["perfSummary"])
    except Exception as e:  # never crash the server
        log(f"ERROR: {e}")
        RUN["ok"] = False
        record_event("run_crashed", str(e), recovered=False)
    finally:
        end_activity("build")


class H(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/health":
            self._json({"ok": True, "rpa": HAS_RPA,
                        "ocr": bool(TESSERACT_CMD), "version": VERSION,
                        "emergencyEsc": dict(HOTKEY_STATE),
                        "activity": activity_snapshot()})
        elif self.path == "/status":
            with LOCK:
                self._json({"running": JOB.running,
                            "activity": _active_activity_locked() or None,
                            "stopRequested": JOB.stop_requested,
                            "pause": pause_snapshot(),
                            "sessionId": LEARNING.session_id,
                            "learning": LEARNING.summary(),
                            "learningEvents": LEARNING.events(40),
                            "log": JOB.log[-80:]})
        elif self.path == "/cal_get":
            self._json({"ok": True, "cal": cal_flat()})
        elif self.path == "/shots":
            try:
                files = sorted(os.listdir(SHOTS)) if os.path.isdir(SHOTS) else []
            except Exception:
                files = []
            self._json({"ok": True, "shots": files[-20:]})
        elif self.path == "/inspect":
            try:
                items = inspect_pt()
                names = [c["name"] for c in items if c["name"].strip()][:80]
                log(f"inspect: {len(items)} controls, {len(names)} named")
                self._json({"ok": True, "names": names, "controls": items})
            except Exception as e:
                log(f"inspect ERROR: {e}")
                self._json({"ok": False, "error": str(e)}, 500)
        elif self.path == "/devices_get":
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query)
            project = (q.get("project", ["default"])[0])
            self._json({"ok": True, "project": project,
                        "devices": DEV_MEM.get(project, {})})
        elif self.path.startswith("/srv/probe"):
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query)
            try:
                report = srv_probe(
                    device=(q.get("device", [""])[0] or ""),
                    service=(q.get("service", [""])[0] or ""),
                    tokens=[t for t in
                            (q.get("tokens", [""])[0] or "").split(",")
                            if t.strip()])
            except Exception as e:
                report = {"ok": False, "error": str(e)}
            self._json(report)
        elif self.path == "/llm_status":
            self._json({"ok": True, **llm_status()})
        elif self.path == "/run_summary":
            with LOCK:
                self._json({"ok": True, "running": JOB.running,
                            "activity": _active_activity_locked() or None,
                            "summary": {**dict(RUN),
                                        "learning": LEARNING.summary(),
                                        "learningEvents": LEARNING.events(40)}})
        elif self.path == "/inventory":
            with LOCK:
                self._json({"ok": True, "project": TOPOLOGY.get("project", ""),
                            "report": TOPOLOGY.get("report")})
        elif self.path == "/stats":
            self._json({"ok": True, **journal_stats(),
                        "learning": STRATEGY_STORE.summary()})
        elif self.path == "/learning":
            rows = _experience_rows()
            self._json({"ok": True, "count": len(rows),
                        "experiences": rows,
                        "session": LEARNING.session_id,
                        "learning": LEARNING.summary(),
                        "events": LEARNING.events(100)})
        elif self.path == "/suggest":
            self._json({"ok": True, "suggestions": journal_suggestions()})
        elif self.path.startswith("/events"):
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query)
            try:
                lim = max(1, min(500, int(q.get("limit", ["60"])[0])))
            except Exception:
                lim = 60
            self._json({"ok": True, "events": _journal_rows()[-lim:]})
        elif self.path == "/audit_report":
            with LOCK:
                self._json({"ok": True, "running": AUDIT["running"],
                            "activity": _active_activity_locked() or None,
                            "report": AUDIT["report"]})
        elif self.path == "/pkt/status":
            with LOCK:
                self._json({"ok": True, **dict(PKT_STATE),
                            "activity": _active_activity_locked() or None})
        elif self.path == "/pkt/report":
            # Last saved artifact: path, companion manifest, and the
            # planned-vs-recorded comparison for it.
            self._json({"ok": True, "report": PKT_STATE.get("report")})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b"{}"
        if self.path == "/pkt/save_verified":
            # Save the live topology as a .pkt with its companion manifest,
            # optionally reopening it to prove the file loads.  The path is
            # generated (unique per second) unless the caller forces a
            # replacement of a specific one.
            try:
                req = json.loads(body.decode() or "{}")
            except Exception as exc:
                self._json({"ok": False, "error": f"bad json: {exc}"}, 400)
                return
            acquired, busy_activity = begin_activity("pkt")
            if not acquired:
                self._json({"ok": False,
                            "error": f"busy - {busy_activity} active",
                            "activity": activity_snapshot()}, 409)
                return
            _pkt_start_operation(
                "save_verified", pkt_save_verified,
                str(req.get("project") or JOB.project or "default"),
                str(req.get("outDir") or ""),
                bool(req.get("force")),
                bool(req.get("reopen")),
            )
            self._json({"ok": True, "operation": "save_verified",
                        "message": "Operation started; poll /pkt/status."})
            return
        if self.path in ("/pkt/read", "/pkt/open", "/pkt/save_as",
                         "/pkt/verify"):
            try:
                req = json.loads(body.decode() or "{}")
            except Exception as exc:
                self._json({"ok": False, "error": f"bad json: {exc}"}, 400)
                return
            raw_path = str(req.get("path", "")).strip()
            try:
                path = _pkt_path(raw_path,
                                 must_exist=self.path != "/pkt/save_as")
                if self.path == "/pkt/read":
                    project = str(req.get("project", "default"))
                    self._json({"ok": True,
                                "report": pkt_read(path, project)})
                    return
                operation = {
                    "/pkt/open": "open",
                    "/pkt/save_as": "save_as",
                    "/pkt/verify": "reopen_verify",
                }[self.path]
                acquired, busy = begin_activity("pkt")
                if not acquired:
                    self._json({"ok": False,
                                "error": f"busy - {busy} active",
                                "activity": activity_snapshot()}, 409)
                    return
                if self.path == "/pkt/open":
                    _pkt_start_operation(operation, _pkt_open, path, True)
                elif self.path == "/pkt/verify":
                    _pkt_start_operation(operation, _pkt_open, path, False)
                else:
                    if os.path.dirname(path) and not os.path.isdir(
                            os.path.dirname(path)):
                        end_activity("pkt")
                        self._json({"ok": False,
                                    "error": "output directory does not exist"},
                                   400)
                        return
                    manifest = req.get("manifest")

                    def save_with_manifest():
                        info = _pkt_save_as(path)
                        if isinstance(manifest, dict):
                            info["manifest"] = _pkt_write_manifest(path,
                                                                    manifest)
                        return info

                    _pkt_start_operation(operation, save_with_manifest)
                self._json({"ok": True, "operation": operation,
                            "message": "Operation started; poll /pkt/status."})
            except Exception as exc:
                self._json({"ok": False, "error": str(exc)}, 400)
            return
        if self.path == "/prove":
            acquired, busy = begin_activity("calibration")
            if not acquired:
                self._json({"ok": False, "error": f"busy - {busy} active"}, 409)
                return
            try:
                if stopped():
                    self._json({"ok": False, "error": "stop requested"}, 409)
                    return
                w = focus_pt()
                prove_movement(rect_of(w))
                self._json({"ok": True,
                            "msg": "mouse should have moved in a square over PT"})
            except Exception as e:
                log(f"prove ERROR: {e}")
                self._json({"ok": False, "error": str(e)}, 500)
            finally:
                end_activity("calibration")
            return
        if self.path == "/start":
            try:
                plan = json.loads(body.decode() or "{}")
            except Exception as e:
                self._json({"error": f"bad json: {e}"}, 400)
                return
            acquired, busy = begin_activity("build")
            if not acquired:
                self._json({"error": f"busy - {busy} active",
                            "activity": activity_snapshot()}, 409)
                return
            threading.Thread(target=run_plan, args=(plan,),
                             daemon=True).start()
            self._json({"ok": True})
        elif self.path == "/llm_config":
            try:
                req = json.loads(body.decode() or "{}")
            except Exception as exc:
                self._json({"ok": False, "error": f"bad json: {exc}"}, 400)
                return
            state = llm_configure(
                api_key=str(req.get("apiKey", "")),
                model=str(req.get("model", "")),
                enabled=bool(req.get("enabled", False)))
            log("LLM config updated: enabled=%s model=%s key=%s"
                % (state["enabled"], state["model"],
                   "<set>" if state["configured"] else "<none>"))
            self._json({"ok": True, **state})
        elif self.path == "/diagnostics/export":
            try:
                req = json.loads(body.decode() or "{}")
            except Exception as e:
                self._json({"ok": False, "error": f"bad json: {e}"}, 400)
                return
            try:
                result = diagnostics_export(
                    include_screenshots=bool(req.get("includeScreenshots")))
                self._json({"ok": True, **result})
            except Exception as e:
                log(f"diagnostics export ERROR: {e}")
                self._json({"ok": False, "error": str(e)}, 500)
        elif self.path == "/stop":
            request_stop("Stop button")
            self._json({"ok": True, "stopping": True,
                        "message": "Stop requested; the current action is being released."})
        elif self.path == "/pause":
            ok = request_pause("Pause button")
            self._json({"ok": ok,
                        "pause": pause_snapshot(),
                        "message": ("Pause requested; the worker will hold at "
                                    "the next safe boundary and keep all progress."
                                    if ok else "Nothing is running to pause.")})
        elif self.path == "/resume":
            request_resume("Resume")
            self._json({"ok": True,
                        "pause": pause_snapshot(),
                        "message": "Resume signalled; the run continues where it left off."})
        elif self.path == "/pause_toggle":
            new_state = toggle_pause("Pause toggle")
            self._json({"ok": True, "state": new_state,
                        "pause": pause_snapshot()})
        elif self.path == "/cal_set":
            acquired, busy = begin_activity("calibration")
            if not acquired:
                self._json({"ok": False, "error": f"busy - {busy} active"}, 409)
                return
            try:
                patch = json.loads(body.decode() or "{}")
            except Exception as e:
                self._json({"error": f"bad json: {e}"}, 400)
                end_activity("calibration")
                return
            try:
                applied = {}
                for k, v in patch.items():
                    if k not in CAL_DEFAULTS:
                        continue
                    try:
                        fv = float(v)
                        if not 0.0 <= fv <= 1.0:
                            continue
                    except Exception:
                        continue
                    if isinstance(CAL[k], tuple):
                        # single float sets both axes for pair keys? No - ignore.
                        continue
                    CAL[k] = fv
                    applied[k] = fv
                # pair keys come as "pal_router.x" style from the app
                for k, v in patch.items():
                    if "." in k:
                        base, axis = k.rsplit(".", 1)
                        if base in CAL and isinstance(CAL[base], tuple):
                            try:
                                fv = float(v)
                                if not 0.0 <= fv <= 1.0:
                                    continue
                                cur = list(CAL[base])
                                cur[0 if axis == "x" else 1] = fv
                                CAL[base] = tuple(cur)
                                applied[k] = fv
                            except Exception:
                                pass
                save_cal()
                log(f"cal updated {applied}")
                self._json({"ok": True, "applied": applied, "cal": cal_flat()})
            finally:
                end_activity("calibration")
        elif self.path == "/click_test":
            try:
                req = json.loads(body.decode() or "{}")
            except Exception as e:
                self._json({"error": f"bad json: {e}"}, 400)
                return
            acquired, busy = begin_activity("calibration")
            if not acquired:
                self._json({"ok": False, "error": f"busy - {busy} active"}, 409)
                return
            try:
                w = focus_pt()
                rect = rect_of(w)
                name = str(req.get("name", "grid0"))
                if name.startswith("grid"):
                    idx = int(name[4:] or 0)
                    fx = CAL["grid_x0"] + CAL["grid_step"] * idx
                    fy = CAL["grid_y"]
                elif name in CAL and isinstance(CAL[name], tuple):
                    fx, fy = CAL[name]
                else:
                    fx = float(req.get("fx", 0.5))
                    fy = float(req.get("fy", 0.5))
                click_frac(rect, fx, fy, f"test {name}")
                self._json({"ok": True, "fx": fx, "fy": fy})
            except Exception as e:
                log(f"click_test ERROR: {e}")
                self._json({"ok": False, "error": str(e)}, 500)
            finally:
                end_activity("calibration")
            return
        elif self.path == "/teach":
            try:
                req = json.loads(body.decode() or "{}")
            except Exception as e:
                self._json({"error": f"bad json: {e}"}, 400)
                return
            key = str(req.get("key", ""))
            if key not in CAL_DEFAULTS:
                self._json({"ok": False,
                            "error": f"unknown key {key}. valid: {sorted(CAL_DEFAULTS)}"},
                           400)
                return
            acquired, busy = begin_activity("calibration")
            if not acquired:
                self._json({"ok": False, "error": f"busy - {busy} active"}, 409)
                return
            # run in background so HTTP returns fast; app polls /status
            def _do():
                try:
                    res = teach_key(key)
                    log(f"TEACH saved {key} = {res}")
                except Exception as e:
                    log(f"TEACH ERROR {key}: {e}")
                finally:
                    end_activity("calibration")
            threading.Thread(target=_do, daemon=True).start()
            self._json({"ok": True,
                        "msg": f"Hover the {key} spot in PT NOW - capturing in 3s. Poll Logs."})
        elif self.path == "/devices_clear":
            try:
                req = json.loads(body.decode() or "{}")
            except Exception:
                req = {}
            project = str(req.get("project", "default"))
            DEV_MEM.pop(project, None)
            save_dev_mem()
            log(f"forgot remembered devices for '{project}'")
            self._json({"ok": True, "project": project})
        elif self.path == "/events_clear":
            try:
                cleared = []
                for path in (JOURNAL_FILE, EXPERIENCE_FILE):
                    if os.path.exists(path):
                        os.remove(path)
                        cleared.append(os.path.basename(path))
                self._json({"ok": True, "cleared": cleared})
            except Exception as e:
                self._json({"ok": False, "error": str(e)}, 500)
        elif self.path == "/audit":
            try:
                req = json.loads(body.decode() or "{}")
            except Exception as e:
                self._json({"error": f"bad json: {e}"}, 400)
                return
            project = str(req.get("project", "default"))
            acquired, busy = begin_activity("audit")
            if not acquired:
                self._json({"error": f"busy - {busy} active",
                            "activity": activity_snapshot()}, 409)
                return
            threading.Thread(target=audit_network, args=(project,),
                             daemon=True).start()
            self._json({"ok": True, "msg": f"auditing '{project}' - poll "
                        "/audit_report"})
        else:
            self._json({"error": "not found"}, 404)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"PT Autopilot sidecar {VERSION} on http://{HOST}:{PORT} "
          f"rpa={HAS_RPA}")
    print(f"CLI screen reader: OCR={'ON (' + TESSERACT_CMD + ')' if TESSERACT_CMD else 'OFF - tesseract.exe not found, UIA fallback only'}")
    print("EMERGENCY STOP: press Esc anywhere to halt the run.")
    print("PAUSE: press F9 anywhere to pause/resume; the app has a Pause "
          "button too. Progress is kept while paused.")
    print("Keep Packet Tracer open, maximized, focused during runs.")
    threading.Thread(target=_hotkey_loop, daemon=True).start()
    HTTPServer((HOST, PORT), H).serve_forever()
