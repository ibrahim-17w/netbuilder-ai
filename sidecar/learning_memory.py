"""Durable little memories that let one run's mistakes change the next run.

Before this module the engine recorded plenty and consumed almost none of it:
`failures.jsonl` fed a UI list, `experience_memory.jsonl` fed a UI list, and
the only thing that actually changed behaviour was a per-run set that was
cleared at `_run_reset`.  A mistake therefore repeated identically forever.

Four stores live here, all JSON-on-disk, atomic, bounded, and none of them
allowed to raise into a build:

* [LlmRejectionStore] - which (line, mode, error) triples the recovery model
  already failed to fix, so the same question is not asked every single run.
* [RunLedger] - where the previous run stopped and what it could not verify,
  so the next run can pre-empt a known blocker instead of rediscovering it.
* [CapabilityMap] - which feature families Packet Tracer has actually proven
  it cannot do on a model, so the planner stops regenerating them.
* [CorrectionStore] - what the USER said when the engine got something wrong.

The first three learn from what the engine observed.  The last one learns from
what the user said instead, and the two must not be trusted the same way: an
observation is a measurement, a correction is a hypothesis that still has to
survive a re-attempt on screen.  `CORRECTION_TAXONOMY` below is the mapping
from this app's event vocabulary to what a correction for it should aim at -
it is the only part of this module that knows Packet Tracer exists.

Stdlib only, and unit testable without Packet Tracer, Tesseract or the RPA
stack (same convention as the rest of `sidecar/`).
"""
from __future__ import annotations

import json
import os
import re
import threading
import time

SCHEMA = 1

# Bounds.  Every store is trimmed on write so a long-lived install cannot
# grow these files without limit.
LEDGER_RUNS_PER_PROJECT = 20
LEDGER_STILL_FAILED_MAX = 40
REJECTIONS_MAX = 400
CAPABILITY_MAX = 300

# A triple must be rejected this many times before the ask is skipped
# outright.  One rejection is a flake (a bad crop, a transient 429); two is
# a pattern worth not paying for again.
REJECTION_BLOCK_AFTER = 2

# A command head must fail unrecovered on the same model this many times
# before it is offered to the planner as a suspected platform gap.
CAPABILITY_SUSPECT_AFTER = 3

_LOCK = threading.RLock()


def _now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def normalize_signature(text: str, limit: int = 60) -> str:
    """Collapse an OCR/terminal error into a stable, comparable signature.

    Packet Tracer's error text echoes the offending token, so two sightings
    of the same mistake rarely match byte for byte.  Fold case, blank out
    numbers and punctuation runs, and keep the head of what is left.  Returns
    "" for input with no comparable content.
    """
    low = str(text or "").lower()
    low = re.sub(r"0x[0-9a-f]+", " ", low)
    low = re.sub(r"[0-9]+", "#", low)
    low = re.sub(r"[^a-z#% ]+", " ", low)
    low = re.sub(r"\s+", " ", low).strip()
    return low[:limit]


def _atomic_write(path: str, data) -> bool:
    """Write JSON through a temp file + os.replace. Never raises.

    A half-written memory file is worse than a stale one: every reader here
    treats an unparseable file as empty, so a torn write would silently
    discard everything learned so far.
    """
    try:
        directory = os.path.dirname(os.path.abspath(path))
        os.makedirs(directory, exist_ok=True)
        temp = f"{path}.tmp"
        with open(temp, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
        os.replace(temp, path)
        return True
    except Exception:
        return False


def _load(path: str, fallback: dict) -> dict:
    """Read a store, degrading to `fallback` on anything unexpected."""
    try:
        with open(path, encoding="utf-8") as stream:
            data = json.load(stream)
    except FileNotFoundError:
        return json.loads(json.dumps(fallback))
    except Exception:
        return json.loads(json.dumps(fallback))
    if not isinstance(data, dict):
        return json.loads(json.dumps(fallback))
    return data


class _JsonStore:
    """Shared shape: one file, one top-level dict, atomic writes."""

    def __init__(self, path: str, empty: dict):
        self.path = path
        self._empty = empty
        self._data = _load(path, empty)
        for key, value in empty.items():
            if not isinstance(self._data.get(key), type(value)):
                self._data[key] = json.loads(json.dumps(value))

    def _save_locked(self) -> bool:
        return _atomic_write(self.path, self._data)


class LlmRejectionStore(_JsonStore):
    """(line, mode, error) triples the recovery model already failed on.

    `llm_reset_run()` deliberately clears the per-run *budget*; this store is
    the part that must survive it.  Without it every run asks the same
    question about the same line, receives the same unusable answer, counts
    another `llm_fix_rejected`, and forgets - which is exactly the "stuck at
    the same point" complaint this exists to fix.
    """

    def __init__(self, path: str):
        super().__init__(path, {"schema": SCHEMA, "rejections": {}})

    @staticmethod
    def key(command_key: str, mode: str, error: str) -> str:
        """Identity of one ask: the line, the mode, and what went wrong."""
        return "|".join((
            str(command_key or "")[:80],
            str(mode or "unknown").strip().lower()[:20] or "unknown",
            normalize_signature(error) or "unreadable",
        ))

    def row(self, command_key: str, mode: str, error: str) -> dict:
        found = self._data["rejections"].get(self.key(command_key, mode, error))
        return dict(found) if isinstance(found, dict) else {}

    def blocked(self, command_key: str, mode: str, error: str) -> bool:
        """True once this exact ask has been rejected enough times to skip."""
        row = self.row(command_key, mode, error)
        return int(row.get("rejections", 0)) >= REJECTION_BLOCK_AFTER

    def record(self, command_key: str, mode: str, error: str,
               reason: str = "", device: str = "") -> dict:
        key = self.key(command_key, mode, error)
        with _LOCK:
            row = self._data["rejections"].setdefault(key, {
                "commandKey": str(command_key or "")[:80],
                "mode": str(mode or "unknown")[:20],
                "signature": normalize_signature(error),
                "first": _now(),
            })
            row["rejections"] = int(row.get("rejections", 0)) + 1
            row["last"] = _now()
            row["lastReason"] = str(reason or "")[:200]
            if device:
                row["lastDevice"] = str(device)[:60]
            self._trim_locked()
            self._save_locked()
            return dict(row)

    def clear(self, command_key: str, mode: str, error: str) -> bool:
        """A verified fix retires the block for that exact triple."""
        key = self.key(command_key, mode, error)
        with _LOCK:
            removed = self._data["rejections"].pop(key, None)
            if removed is not None:
                self._save_locked()
            return removed is not None

    def _trim_locked(self):
        rows = self._data["rejections"]
        excess = len(rows) - REJECTIONS_MAX
        if excess <= 0:
            return
        ordered = sorted(rows.items(),
                         key=lambda kv: str(kv[1].get("last", "")))
        for key, _ in ordered[:excess]:
            rows.pop(key, None)

    def summary(self) -> dict:
        rows = list(self._data["rejections"].values())
        return {
            "count": len(rows),
            "blocked": sum(1 for r in rows
                           if int(r.get("rejections", 0)) >= REJECTION_BLOCK_AFTER),
            "rejections": rows[-50:],
        }


def _still_failed_signatures(entry: dict) -> list:
    """Stable identities for one run's unverified (action, device) pairs."""
    out = []
    for item in (entry.get("stillFailed") or [])[:LEDGER_STILL_FAILED_MAX]:
        if not isinstance(item, dict):
            continue
        out.append("|".join((
            str(item.get("action", ""))[:60],
            str(item.get("device", ""))[:60],
            normalize_signature(item.get("reason"), 40) or "unrecorded",
        )))
    return out


class RunLedger(_JsonStore):
    """Where the previous run stopped, and what it could not verify.

    `_run_reset()` wipes phases, action results, link results and node
    outcomes on every run, so run N+1 had no idea run N had died at the same
    step.  The ledger is the record that survives that reset.
    """

    def __init__(self, path: str):
        super().__init__(path, {"schema": SCHEMA, "projects": {}})

    def record(self, project: str, *, ok: bool, final_phase: str = "",
               still_failed: list | None = None, repair_passes: int = 0,
               cli_block_reasons: dict | None = None,
               counters: dict | None = None,
               unsupported: list | None = None) -> dict:
        project = str(project or "default")
        entry = {
            "ts": _now(),
            "ok": bool(ok),
            "finalPhase": str(final_phase or "")[:60],
            "repairPasses": int(repair_passes or 0),
            "stillFailed": [
                {
                    "action": str((item or {}).get("action", ""))[:60],
                    "device": str((item or {}).get("device", ""))[:60],
                    "reason": str((item or {}).get("reason", ""))[:160],
                }
                for item in (still_failed or [])[:LEDGER_STILL_FAILED_MAX]
                if isinstance(item, dict)
            ],
            "cliBlockReasons": {str(k)[:60]: int(v or 0)
                                for k, v in (cli_block_reasons or {}).items()},
            "counters": {str(k)[:40]: v
                         for k, v in (counters or {}).items()},
            "unsupported": [str(u)[:160] for u in (unsupported or [])[:20]],
        }
        with _LOCK:
            runs = self._data["projects"].setdefault(project, [])
            runs.append(entry)
            del runs[:-LEDGER_RUNS_PER_PROJECT]
            self._save_locked()
        return entry

    def runs(self, project: str) -> list:
        return [dict(r) for r
                in (self._data["projects"].get(str(project or "default")) or [])]

    def previous(self, project: str) -> dict:
        runs = self._data["projects"].get(str(project or "default")) or []
        return dict(runs[-1]) if runs else {}

    def repeat_offenders(self, project: str, minimum: int = 2) -> list:
        """Pairs that failed the *same way* in each of the last runs.

        `minimum` defaults to 2 consecutive entries - a single failure is a
        bad day, not a pattern, and must not trigger pre-emption.
        """
        runs = self._data["projects"].get(str(project or "default")) or []
        if len(runs) < max(1, minimum):
            return []
        tail = runs[-max(1, minimum):]
        shared = set(_still_failed_signatures(tail[0]))
        for entry in tail[1:]:
            shared &= set(_still_failed_signatures(entry))
        out = []
        for sig in shared:
            action, device, reason = (sig.split("|", 2) + ["", "", ""])[:3]
            out.append({
                "action": action,
                "device": device,
                "reason": reason,
                "runs": sum(1 for r in runs
                            if sig in _still_failed_signatures(r)),
            })
        out.sort(key=lambda item: (-item["runs"], item["action"]))
        return out

    def summary(self) -> dict:
        return {
            "projects": {name: len(rows or [])
                         for name, rows in self._data["projects"].items()},
        }


class CapabilityMap(_JsonStore):
    """Feature families Packet Tracer has proven it cannot do per model.

    Rows are `proven` (the live CLI rejected the family and the existing
    static classifier agreed) or `suspect` (the head of a command that kept
    failing unrecovered on one model).  Only `proven` rows are treated as
    fact; `suspect` rows exist so the planner stops proposing them and the
    user is told, never so the engine silently drops user intent.
    """

    def __init__(self, path: str):
        super().__init__(path, {"schema": SCHEMA, "unsupported": {}})

    @staticmethod
    def head(line: str, words: int = 2) -> str:
        """Leading keyword family of a command, e.g. 'crypto isakmp'."""
        parts = str(line or "").strip().lower().split()
        return " ".join(parts[:max(1, words)])[:60]

    @staticmethod
    def key(family: str, model: str = "") -> str:
        return json.dumps({
            "family": str(family or "").strip().lower()[:60] or "unknown",
            "model": str(model or "any").strip().lower()[:40] or "any",
        }, sort_keys=True, separators=(",", ":"))

    def row(self, family: str, model: str = "") -> dict:
        found = self._data["unsupported"].get(self.key(family, model))
        if not isinstance(found, dict):
            found = self._data["unsupported"].get(self.key(family, "any"))
        return dict(found) if isinstance(found, dict) else {}

    def reason(self, family: str, model: str = "") -> str:
        """Reason this family is unsupported, or "" when it is not known."""
        return str(self.row(family, model).get("reason", ""))

    def proven_families(self, model: str = "") -> list:
        """Families the live CLI proved unsupported - planner facts."""
        out = []
        for row in self._data["unsupported"].values():
            if not row.get("proven"):
                continue
            if model and str(row.get("model", "")) not in (
                    str(model).strip().lower(), "any"):
                continue
            out.append({"family": row.get("family", ""),
                        "model": row.get("model", "any"),
                        "reason": row.get("reason", "")})
        out.sort(key=lambda item: item["family"])
        return out

    def mark(self, family: str, model: str = "", reason: str = "",
             proven: bool = False) -> dict:
        family = str(family or "").strip().lower()[:60]
        if not family:
            return {}
        key = self.key(family, model)
        with _LOCK:
            row = self._data["unsupported"].setdefault(key, {
                "family": family,
                "model": str(model or "any").strip().lower()[:40] or "any",
                "count": 0,
                "first": _now(),
            })
            row["count"] = int(row.get("count", 0)) + 1
            row["last"] = _now()
            if reason:
                row["reason"] = str(reason)[:200]
            # A family never demotes: once the live CLI proved it, a later
            # failure with a different label must not turn it back into a
            # mere suspicion.
            row["proven"] = bool(row.get("proven")) or bool(proven)
            self._trim_locked()
            self._save_locked()
            return dict(row)

    def remove(self, family: str, model: str = "") -> bool:
        """Drop one row, for when a user un-teaches a capability claim."""
        key = self.key(family, model)
        with _LOCK:
            removed = self._data["unsupported"].pop(key, None) is not None
            if removed:
                self._save_locked()
            return removed

    def _trim_locked(self):
        rows = self._data["unsupported"]
        excess = len(rows) - CAPABILITY_MAX
        if excess <= 0:
            return
        # Keep proven rows; drop the least-observed suspicions first.
        ordered = sorted(
            rows.items(),
            key=lambda kv: (bool(kv[1].get("proven")),
                            int(kv[1].get("count", 0))),
        )
        for key, _ in ordered[:excess]:
            rows.pop(key, None)

    def summary(self) -> dict:
        rows = list(self._data["unsupported"].values())
        return {
            "count": len(rows),
            "proven": sum(1 for r in rows if r.get("proven")),
            "unsupported": rows[-50:],
        }


# CORRECTIONS: the teaching loop ---------------------------------------
# Everything above learns from what the ENGINE observed.  This learns from
# what the USER said instead, and the two must not be trusted alike.
#
# The rule that keeps a correction from poisoning the config stores - the way
# the blind-dy "fields" entry did, when the mask row drifted PAST the gateway
# row and IP/mask values were typed into Gateway/DNS for a whole run - is that
# a correction is NEVER written straight into PC_LEARNED, SRV_MEM or the
# strategy store.  It is applied through a scoped, ephemeral override, the step
# is re-attempted, and only a screen-verified outcome is promoted.  A
# correction that fails to verify stays as `rejected` and is shown back to the
# user: silently discarding someone's own instruction is worse than the
# failure it was meant to fix.
CORRECTIONS_MAX = 300
# Correcting the same element more than this many times is thrash, not
# learning.  The newest correction still wins (the user is the authority), but
# the row is flagged so the UI can warn and show the history instead of letting
# a third guess silently overwrite the second.
CORRECTION_THRASH_AFTER = 2
# A promoted correction that misses this many times is REPORTED, never silently
# quarantined.  The engine's own guesses may be quietly dropped; the user's
# must not be.
CORRECTION_REPORT_AFTER = 2
# Where a verified correction was actually written, flattened so a revert can
# find exactly one entry.  These are the only stores a promotion may target,
# which is what keeps the loop from inventing a sixth memory nobody reads.
# A placement promotion lives in DEV_MEM (per project+device); the rest are
# keyed by the teach run's `store:key` pair.
PROMOTION_STORES = ("PC_LEARNED", "SRV_MEM:f", "SRV_MEM:b", "CAPABILITY",
                    "DEV_MEM")

TARGET_KINDS = ("placement", "label", "point", "cli", "order", "skip",
                "rule", "preference")
# Where a taught thing is allowed to apply.  Nothing is ever promoted at a
# wider scope than the user picked, and the default comes from the taxonomy.
SCOPES = ("device", "dtype", "model", "project", "global")
STATUSES = ("proposed", "verified", "rejected", "reverted")

# CORRECTION_TAXONOMY: event kind -> what a correction for it should aim at.
#
# Every kind here was taken from this install's own `failures.jsonl` instead of
# being invented, so the table covers what actually happens.  Per entry:
#   target  - the kind of thing being taught (see TARGET_KINDS)
#   store   - which memory a verified result is promoted into
#   scope   - the default scope, and the reason for that default:
#             * a PLACEMENT is per device - a canvas slot only means anything
#               on the canvas it was laid out on;
#             * every panel, tile, field and button coordinate is per device
#               TYPE, because the 2026-09-16 run proved a spot learned on a
#               Server-PT desktop opened the wrong panel on a PC-PT one;
#             * a COMMAND belongs to a model - that is what the CLI accepts.
#   verify  - the screen evidence that must agree before promotion
#   hint    - the sentence the correction sheet shows the user
#   gate    - True when this is a fail-closed proof gate rather than a mistake,
#             so the sheet must say a correction does NOT loosen it
CORRECTION_TAXONOMY: dict = {}

# --- the click missed something on the canvas -------------------------
CORRECTION_TAXONOMY.update({
    "window_not_found": {
        "target": "placement", "store": "placement", "scope": "device",
        "verify": "device_window_opened",
        "hint": "Point at the device on the canvas so the double-click lands "
                "on it.",
    },
    "placement_unverified": {
        "target": "placement", "store": "placement", "scope": "device",
        "verify": "device_window_opened",
        "hint": "Point at where the device actually sits, so the next run "
                "re-tries that spot first.",
    },
})

# --- the wrong panel, tab or tile opened -------------------------------
CORRECTION_TAXONOMY.update({
    "pc_wrong_panel": {
        "target": "label", "store": "pc_tile", "scope": "dtype",
        "verify": "panel_title",
        "hint": "Name the Desktop tile that should open, using its label "
                "(e.g. Command Prompt).",
    },
    "pc_tile_missing": {
        "target": "label", "store": "pc_tile", "scope": "dtype",
        "verify": "panel_title",
        "hint": "Name the Desktop tile that should open, using its label.",
    },
    "pc_desktop_tab": {
        "target": "label", "store": "pc_tab", "scope": "dtype",
        "verify": "panel_title",
        "hint": "Name the tab that should open (e.g. Desktop).",
    },
    "srv_tab_missing": {
        "target": "label", "store": "srv_tab", "scope": "dtype",
        "verify": "panel_title",
        "hint": "Name the service tab that should open (e.g. DHCP).",
    },
})

# --- a field row was missed, or filled into the wrong box --------------
CORRECTION_TAXONOMY.update({
    "srv_field_missing": {
        "target": "label", "store": "srv_field", "scope": "dtype",
        "verify": "field_readback",
        "hint": "Name the row LABEL that anchors the value box (e.g. "
                "Gateway). The box is vertically centred on its label, so the "
                "label is what makes the click repeatable.",
    },
    "srv_fill_mismatch": {
        "target": "label", "store": "srv_field", "scope": "dtype",
        "verify": "field_readback",
        "hint": "Name the row LABEL that anchors the value box (e.g. "
                "Gateway), or point at the box that was typed into wrongly.",
    },
    "pc_config_failed": {
        "target": "label", "store": "pc_field", "scope": "dtype",
        "verify": "field_readback",
        "hint": "Point at the IP Configuration value box that was missed.",
    },
})

# --- a button was missed, or a record never landed ---------------------
CORRECTION_TAXONOMY.update({
    "srv_record_blocked": {
        "target": "label", "store": "srv_button", "scope": "dtype",
        "verify": "record_row",
        "hint": "Name the button that should have been clicked (e.g. Add).",
    },
    "srv_record_missing": {
        "target": "label", "store": "srv_button", "scope": "dtype",
        "verify": "record_row",
        "hint": "Name the button that should have been clicked (e.g. Add).",
    },
    "srv_save_failed": {
        "target": "label", "store": "srv_button", "scope": "dtype",
        "verify": "record_row",
        "hint": "Name the button or tab that saves this panel, so the write "
                "stops being eaten.",
    },
})

# --- the port popup, or the cabling endpoint --------------------------
CORRECTION_TAXONOMY.update({
    "port_popup_missing": {
        "target": "label", "store": "port_popup", "scope": "global",
        "verify": "port_selected",
        "hint": "Name the port row that should be picked in the popup (e.g. "
                "GigabitEthernet0/1). A silently wrong port is how R1-R2 got "
                "cabled on g0/0 instead of the requested g0/1.",
    },
    "link_attempt_failed": {
        "target": "point", "store": "link_endpoint", "scope": "device",
        "verify": "port_selected",
        "hint": "Point at the port on the device that should have been "
                "cabled.",
    },
})

# --- the command itself was wrong -------------------------------------
CORRECTION_TAXONOMY.update({
    "cli_line_error": {
        "target": "cli", "store": "cli_fallback", "scope": "model",
        "verify": "cli_no_new_error",
        "hint": "Give the command that works instead of the one that was "
                "rejected. It goes through the same verification as any learned "
                "line, so it has to clear the terminal to stick.",
    },
    "cli_unresolvable": {
        "target": "order", "store": "order", "scope": "model",
        "verify": "cli_no_new_error",
        "hint": "Name the prerequisite that has to happen first, so the plan "
                "stops reaching this line too early.",
    },
    "cli_prerequisite_failed": {
        "target": "order", "store": "order", "scope": "model",
        "verify": "cli_no_new_error",
        "hint": "Name the step that has to succeed before this one.",
    },
    "cli_context_blocked": {
        "target": "cli", "store": "cli_context", "scope": "model",
        "verify": "cli_no_new_error", "gate": True,
        "hint": "The CLI prompt could not be proven, so the engine refused to "
                "type. A working enable/transition sequence can be taught, but "
                "this is the fail-closed proof gate - correcting it does NOT "
                "loosen it.",
    },
})

# --- the teaching loop itself -----------------------------------------
# Phases of the loop are events too, so the journal shows WHY a memory
# changed - the user said it (taught), the screen agreed (verified), or the
# screen disagreed (rejected).  All are records of outcomes, not steps, so
# none of them offers a correction form.
CORRECTION_TAXONOMY.update({
    "correction_verified": {
        "teachable": False,
        "reason": "The teach run re-attempted the step and the screen "
                  "verified it, so the correction was promoted into memory. "
                  "It is an outcome, not a step.",
    },
    "correction_rejected": {
        "teachable": False,
        "reason": "The teach run could not verify this correction, so "
                  "nothing was written to memory. It stays in the "
                  "corrections list so it can be adjusted and re-taught - "
                  "an outcome, not a step.",
    },
    "correction_stale": {
        "teachable": False,
        "reason": "A correction the user already taught has stopped "
                  "verifying. It is reported, never silently removed - "
                  "re-teach it or un-teach it from the corrections list.",
    },
    "correction_protected": {
        "teachable": False,
        "reason": "The engine left a user-taught entry alone instead of "
                  "overwriting it with its own guess. An outcome, not a step.",
    },
    "correction_reverted": {
        "teachable": False,
        "reason": "The user un-taught this correction and its promoted "
                  "entry was removed. An outcome, not a step.",
    },
})

# --- proven platform gaps ---------------------------------------------
CORRECTION_TAXONOMY.update({
    "unsupported_by_packet_tracer": {
        "target": "skip", "store": "capability", "scope": "model",
        "verify": "capability_declared",
        "hint": "Confirm this really is impossible on this model, so the "
                "planner stops regenerating it. The step is still named in the "
                "run report - a skip is never silent.",
    },
    "serial_module_hint": {
        "target": "skip", "store": "capability", "scope": "model",
        "verify": "capability_declared",
        "hint": "Confirm which serial module this model accepts, or that none "
                "is available.",
    },
    "link_blocked": {
        "target": "skip", "store": "capability", "scope": "model",
        "verify": "capability_declared",
        "hint": "Name the port/medium combination Packet Tracer refuses on "
                "this model, or the port that should be used instead.",
    },
    "interface_unavailable": {
        "target": "skip", "store": "capability", "scope": "model",
        "verify": "capability_declared",
        "hint": "Name the interface this model genuinely does not have, so it "
                "stops being planned for.",
    },
    "interface_capability_unknown": {
        "target": "skip", "store": "capability", "scope": "model",
        "verify": "capability_declared",
        "hint": "Settle whether this model has the interface or not.",
    },
    "admin_down_heal_blocked": {
        "target": "skip", "store": "capability", "scope": "model",
        "verify": "capability_declared",
        "hint": "Confirm the interface cannot be brought up on this model, or "
                "name the command that does it.",
    },
})

# --- environment, not a mistake ---------------------------------------
# Offering a correction form for these would be dishonest: there is no click
# spot or command that fixes them, so the sheet shows the reason instead.
CORRECTION_TAXONOMY.update({
    "pt_focus_blocked": {
        "teachable": False, "gate": True,
        "reason": "Packet Tracer was not in front, so the click or keystroke "
                  "was refused on purpose. That is a window problem, not "
                  "something a click or command correction can fix - keep "
                  "Packet Tracer uncovered and focused.",
    },
    "setup_unresolvable": {
        "teachable": False, "gate": True,
        "reason": "The boot setup dialog would not accept 'no'. It needs the "
                  "console awake and Packet Tracer focused; there is no click "
                  "spot to correct.",
    },
})

# Events that record something which already worked, or plain bookkeeping.
# A correction here would be noise, and a user who took it would be teaching
# the engine about a step that was never a problem.
CORRECTION_INFORMATIONAL = {
    "phase_state", "run_finished", "run_started", "inventory_done",
    "audit_done", "validation_done", "cli_plan_compiled",
    "cli_transition_skipped", "setup_dialog", "cli_mode_repaired",
    "learned_command_fix", "cli_mode_transition_verified",
    "cli_mode_recovered", "boot_return_verified", "config_reused",
    "interface_remapped", "interface_remaps_applied", "admin_down",
    "dns_hang_aborted", "pc_error_dialog", "pc_rows_learned",
    "pc_tile_learned", "pc_tile_stale", "srv_field_learned",
    "srv_button_learned", "srv_button_stale", "srv_rules_verified",
}

# Events that only report an outcome.  The cause is a separate event that IS
# teachable, so the useful answer is "correct the step this came from".
CORRECTION_AGGREGATE = {
    "ping_test", "security_check", "link_red", "link_failed",
    "srv_rules_unverified", "srv_service", "boot_return_blocked",
    "boot_return_pending", "phase_blocked", "save_blocked",
    "ipsec_traffic_trigger",
}

CORRECTION_TAXONOMY_REASON = {
    "informational": "This records a step that worked, or run bookkeeping. "
                     "There is nothing here to correct.",
    "aggregate": "This is an outcome, not a step. Correct the step it came "
                 "from instead.",
    "unknown": "No correction is defined for this event kind yet.",
}


def correction_plan(failure_kind: str) -> dict:
    """What a correction for this event kind should aim at.

    Always returns a dict.  `teachable` False carries a `reason` that the UI
    shows INSTEAD of a correction form, which is how the sheet avoids offering
    to "fix" a step that was never broken.
    """
    kind = str(failure_kind or "").strip()
    spec = CORRECTION_TAXONOMY.get(kind)
    if isinstance(spec, dict):
        out = dict(spec)
        out["kind"] = kind
        out.setdefault("teachable", True)
        return out
    if kind in CORRECTION_AGGREGATE:
        return {"kind": kind, "teachable": False,
                "reason": CORRECTION_TAXONOMY_REASON["aggregate"]}
    if kind in CORRECTION_INFORMATIONAL:
        return {"kind": kind, "teachable": False,
                "reason": CORRECTION_TAXONOMY_REASON["informational"]}
    return {"kind": kind, "teachable": False,
            "reason": CORRECTION_TAXONOMY_REASON["unknown"]}


def taxonomy_snapshot() -> dict:
    """Every known event kind mapped to its correction plan.

    The app reads this once to decide whether an event gets a "Correct..."
    action at all, and which fields to render when it does.
    """
    kinds = (set(CORRECTION_TAXONOMY) | CORRECTION_INFORMATIONAL
             | CORRECTION_AGGREGATE)
    return {kind: correction_plan(kind) for kind in sorted(kinds)}


def promotion_ref(store: str, key: str, scope: str = "",
                  anchor: str = "") -> str:
    """Handle for one promoted entry, so a revert can find exactly it again.

    Deliberately a flat pipe-joined string rather than a nested object: it is
    stored inside the correction row, echoed by the API, and has to survive a
    round trip through the app without needing a schema.
    """
    return "|".join((str(store or "")[:24], str(scope or "")[:12],
                     str(anchor or "")[:60], str(key or "")[:80]))


def parse_promotion(ref: str) -> dict:
    """Split a promotion reference back into its parts, or {} if malformed."""
    parts = str(ref or "").split("|", 3)
    if len(parts) < 4 or not parts[0]:
        return {}
    return {"store": parts[0], "scope": parts[1],
            "anchor": parts[2], "key": parts[3]}


def _norm_target(target, default_scope: str = "") -> dict:
    """Keep only the fields a correction may carry, coerced and bounded.

    `fx`/`fy` are window FRACTIONS, so anything outside 0..1 is DROPPED rather
    than clamped: a fraction of 1.4 is not a slightly wrong point, it is a
    point in a different coordinate system, and storing it would aim a click
    off the window entirely.
    """
    src = dict(target or {})
    out = {}
    kind = str(src.get("kind", "")).strip().lower()
    out["kind"] = kind if kind in TARGET_KINDS else "label"
    scope = (str(src.get("scope", "")).strip().lower()
             or str(default_scope or "").strip().lower())
    out["scope"] = scope if scope in SCOPES else "dtype"
    for text_key, limit in (("label", 80), ("panel", 60), ("cli", 400),
                            ("text", 300), ("store", 40), ("note", 300)):
        value = str(src.get(text_key, "") or "").strip()
        if value:
            out[text_key] = value[:limit]
    for num_key in ("fx", "fy", "clickAbove"):
        try:
            value = float(src.get(num_key))
        except (TypeError, ValueError):
            continue
        if 0.0 <= value <= 1.0:
            out[num_key] = round(value, 4)
    return out

class CorrectionStore(_JsonStore):
    """Corrections the user made, and whether they ever verified.

    Lifecycle: `proposed` -> `verified` (promoted into a real memory) or
    `rejected` (tried, did not verify, kept so the user can adjust it), and
    `reverted` if the user un-taught it later.  A promoted row also carries
    hit/miss counters, which is what makes "the thing you taught stopped
    working" answerable instead of invisible.
    """

    def __init__(self, path: str):
        super().__init__(path, {"schema": SCHEMA, "nextId": 1,
                               "corrections": {}})

    @staticmethod
    def identity(target: dict, device: str = "", dtype: str = "") -> str:
        """Stable identity of the thing being corrected, for thrash counting.

        Scoped the same way the promotion will be, so two corrections that
        will land in different stores can never look like the same edit.  Note
        that where the scope is `model` this uses the device TYPE: the finer
        per-model key is applied by the target store at promotion time, and
        this identity only has to be good enough to spot a repeat edit.
        """
        src = dict(target or {})
        kind = str(src.get("kind", "label"))[:20]
        scope = str(src.get("scope", "dtype"))[:12]
        anchor = str(src.get("label") or src.get("cli") or src.get("text")
                     or "").strip().lower()[:60]
        if not anchor and src.get("fx") is not None:
            anchor = f"@{src.get('fx')},{src.get('fy')}"
        where = {"device": device, "dtype": dtype, "model": dtype}.get(
            scope, "")
        return "|".join((kind, scope, str(where or "").strip().lower()[:60],
                         anchor))

    def propose(self, *, failure_kind: str = "", project: str = "",
                device: str = "", dtype: str = "", model: str = "",
                action: str = "", layout: int = 0, target=None,
                evidence=None) -> dict:
        """Record a correction as a hypothesis.  Never promotes by itself.

        `thrash` counts prior corrections for the same identity that are still
        proposed or verified, so the UI can warn before a third guess silently
        replaces the second.
        """
        plan = correction_plan(failure_kind)
        norm = _norm_target(target, str(plan.get("scope", "") or ""))
        with _LOCK:
            try:
                next_id = max(1, int(self._data.get("nextId", 1)))
            except (TypeError, ValueError):
                next_id = 1
            cid = f"c{next_id}"
            self._data["nextId"] = next_id + 1
            identity = self.identity(norm, device, dtype)
            prior = [row for row in self._data["corrections"].values()
                     if isinstance(row, dict)
                     and row.get("identity") == identity
                     and row.get("status") in ("proposed", "verified")]
            row = {
                "id": cid,
                "ts": _now(),
                "status": "proposed",
                "failureKind": str(failure_kind or "")[:60],
                "project": str(project or "")[:60],
                "device": str(device or "")[:60],
                "dtype": str(dtype or "")[:40],
                "model": str(model or "")[:40],
                "action": str(action or "")[:60],
                "layout": int(layout or 0),
                "target": norm,
                "identity": identity,
                "thrash": len(prior),
                "gate": bool(plan.get("gate")),
                "verify": str(plan.get("verify", "") or "")[:40],
                "evidence": {str(k)[:30]: str(v)[:200]
                             for k, v in list((evidence or {}).items())[:8]},
                "promotedTo": "",
                "hits": 0,
                "misses": 0,
            }
            self._data["corrections"][cid] = row
            self._trim_locked()
            self._save_locked()
            return dict(row)

    def get(self, cid: str) -> dict:
        row = self._data["corrections"].get(str(cid or ""))
        return dict(row) if isinstance(row, dict) else {}

    def _set_status(self, cid: str, status: str, **extra) -> dict:
        cid = str(cid or "")
        with _LOCK:
            row = self._data["corrections"].get(cid)
            if not isinstance(row, dict) or status not in STATUSES:
                return {}
            row["status"] = status
            row[f"{status}At"] = _now()
            row.update(extra)
            self._save_locked()
            return dict(row)

    def mark_verified(self, cid: str, promoted_to: str = "") -> dict:
        """Promotion only ever happens through here, and only after a run.

        `promoted_to` is the [promotion_ref] of the entry that was actually
        written, which is what `revert` needs in order to take it back out
        again.
        """
        return self._set_status(cid, "verified",
                                promotedTo=str(promoted_to or "")[:120])

    def mark_rejected(self, cid: str, reason: str = "") -> dict:
        """Tried and it did not verify.  Kept, not dropped."""
        return self._set_status(cid, "rejected",
                                rejectReason=str(reason or "")[:200])

    def revert(self, cid: str) -> dict:
        """Un-teach.  Returns the row so the caller can undo the promotion."""
        return self._set_status(cid, "reverted")

    def record_hit(self, cid: str) -> dict:
        """The promoted correction was used and the step verified."""
        with _LOCK:
            row = self._data["corrections"].get(str(cid or ""))
            if not isinstance(row, dict):
                return {}
            row["hits"] = int(row.get("hits", 0)) + 1
            row["lastHit"] = _now()
            self._save_locked()
            return dict(row)

    def record_miss(self, cid: str, reason: str = "") -> dict:
        """A promoted correction failed again.

        Past CORRECTION_REPORT_AFTER misses the row is flagged `stale` so the
        app can say "the thing you taught stopped working".  It is
        deliberately NOT deleted: the engine's own guesses may be quietly
        quarantined, but silently discarding a user's instruction is worse
        than the failure it was meant to fix.
        """
        with _LOCK:
            row = self._data["corrections"].get(str(cid or ""))
            if not isinstance(row, dict):
                return {}
            row["misses"] = int(row.get("misses", 0)) + 1
            row["lastMiss"] = _now()
            if reason:
                row["lastMissReason"] = str(reason)[:200]
            row["stale"] = int(row["misses"]) >= CORRECTION_REPORT_AFTER
            self._save_locked()
            return dict(row)

    def listing(self, status: str = "", project: str = "",
                limit: int = 50) -> list:
        rows = []
        for row in self._data["corrections"].values():
            if not isinstance(row, dict):
                continue
            if status and row.get("status") != status:
                continue
            if project and row.get("project") != project:
                continue
            rows.append(dict(row))
        rows.sort(key=self._order_key, reverse=True)
        return rows[:max(1, int(limit or 50))]

    @staticmethod
    def _order_key(row: dict) -> tuple:
        """Newest first, and deterministic when two rows share a second.

        `ts` only has one-second resolution, so without the creation-sequence
        tiebreak a listing could come back oldest-first within a second - which
        the API surfaces directly.
        """
        try:
            sequence = int(str(row.get("id", "c0")).lstrip("c") or 0)
        except ValueError:
            sequence = 0
        return (str(row.get("ts", "")), sequence)

    def pending(self) -> list:
        """Corrections still waiting for a teach run to prove them."""
        return self.listing(status="proposed", limit=CORRECTIONS_MAX)

    def stale_rows(self) -> list:
        """User-taught entries that have stopped verifying - must be shown."""
        return [dict(row) for row in self._data["corrections"].values()
                if isinstance(row, dict) and row.get("stale")
                and row.get("status") == "verified"]

    def thrash_rows(self) -> list:
        """Elements corrected repeatedly - a sign the wrong thing is blamed."""
        return [dict(row) for row in self._data["corrections"].values()
                if isinstance(row, dict)
                and int(row.get("thrash", 0)) >= CORRECTION_THRASH_AFTER]

    def _trim_locked(self):
        """Enforce CORRECTIONS_MAX, sacrificing the least useful rows first.

        Order of sacrifice, most expendable first:
          1. reverted and rejected - the audit trail, already acted on;
          2. proposed - a hypothesis nothing has ever proved;
          3. no successful application yet;
          4. whatever is left, oldest first.

        An earlier version only ever dropped reverted/rejected rows, and then
        only unused *verified* ones, so a run of proposed corrections grew the
        file without limit - CORRECTIONS_MAX was not a cap at all.  A working
        correction is therefore still the LAST thing to go, but it does go: an
        unbounded store is its own failure.
        """
        rows = self._data["corrections"]

        def sequence(item):
            """Oldest first, by creation order rather than by timestamp.

            Timestamps have one-second resolution, so rows written inside the
            same second would otherwise be ordered arbitrarily and the cap
            could evict a newer correction instead of an older one.
            """
            try:
                return int(str(item[1].get("id", "c0")).lstrip("c") or 0)
            except (AttributeError, ValueError):
                return 0

        tiers = (
            lambda row: row.get("status") in ("reverted", "rejected"),
            lambda row: row.get("status") == "proposed",
            lambda row: int(row.get("hits", 0)) == 0,
            lambda row: True,
        )
        for matches in tiers:
            excess = len(rows) - CORRECTIONS_MAX
            if excess <= 0:
                return
            candidates = sorted(
                ((key, row) for key, row in rows.items()
                 if isinstance(row, dict) and matches(row)),
                key=sequence)
            for key, _ in candidates[:excess]:
                rows.pop(key, None)

    def summary(self) -> dict:
        rows = [row for row in self._data["corrections"].values()
                if isinstance(row, dict)]
        return {
            "count": len(rows),
            "proposed": sum(1 for r in rows if r.get("status") == "proposed"),
            "verified": sum(1 for r in rows if r.get("status") == "verified"),
            "rejected": sum(1 for r in rows if r.get("status") == "rejected"),
            "reverted": sum(1 for r in rows if r.get("status") == "reverted"),
            # Counted the same way as stale_rows(): a reverted or rejected
            # correction is not "in use", so it cannot have "stopped working".
            "stale": sum(1 for r in rows if r.get("stale")
                         and r.get("status") == "verified"),
            "thrash": sum(1 for r in rows
                          if int(r.get("thrash", 0))
                          >= CORRECTION_THRASH_AFTER),
            "hits": sum(int(r.get("hits", 0)) for r in rows),
            "corrections": self.listing(limit=50),
        }
