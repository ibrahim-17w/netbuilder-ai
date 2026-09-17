"""Deterministic, confidence-scored learning for Packet Tracer automation.

This module deliberately contains no UI automation.  It is the small,
testable policy layer that decides which already-known strategy may be tried,
records immediate failures/successes, and persists only safe verified
strategies.  Packet Tracer remains the source of truth for whether an action
worked.
"""
from __future__ import annotations

import hashlib
import json
import os
import threading
import time
import uuid
from copy import deepcopy


SCHEMA = 1
DECAY_DAYS = 14
SAFE_KINDS = {
    "cli_fallback",
    "ui_coordinate",
    "panel_strategy",
    "field_row",
    "server_button",
    "model_selector",
}


def _now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True)


def _short_hash(value) -> str:
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()[:24]


def _safe_json(value):
    """Keep screenshots/objects out of the strategy file."""
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, dict):
        return {str(k): _safe_json(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_safe_json(v) for v in value]
    return str(value)[:240]


class StrategyStore:
    """Thread-safe JSON store with atomic writes and confidence updates."""

    def __init__(self, path: str):
        self.path = path
        self._lock = threading.RLock()
        self._data = {"schema": SCHEMA, "strategies": {}}
        self._load()

    def _load(self):
        try:
            with open(self.path, encoding="utf-8") as stream:
                data = json.load(stream)
            if isinstance(data, dict) and isinstance(data.get("strategies"), dict):
                self._data = {
                    "schema": SCHEMA,
                    "strategies": data["strategies"],
                }
        except FileNotFoundError:
            return
        except Exception:
            # A corrupted memory file must never stop Packet Tracer work.
            self._data = {"schema": SCHEMA, "strategies": {}}

    @staticmethod
    def _confidence(row: dict) -> float:
        successes = max(0, int(row.get("successes", 0)))
        failures = max(0, int(row.get("failures", 0)))
        # Beta(1,1) prior: one verified success beats a never-tested option,
        # while repeated failures naturally push a strategy out of use.
        return round((successes + 1) / (successes + failures + 2), 4)

    def _decay(self, row: dict):
        stamp = row.get("last_seen_epoch")
        if not isinstance(stamp, (int, float)):
            return
        age_days = max(0.0, (time.time() - stamp) / 86400.0)
        if age_days < DECAY_DAYS:
            return
        periods = int(age_days // DECAY_DAYS)
        if periods <= 0:
            return
        row["confidence"] = round(
            max(0.05, float(row.get("confidence", 0.5)) * (0.95 ** periods)),
            4,
        )
        row["last_seen_epoch"] = time.time()

    def _write_locked(self):
        directory = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(directory, exist_ok=True)
        temp = self.path + ".tmp"
        with open(temp, "w", encoding="utf-8") as stream:
            json.dump(self._data, stream, indent=2, sort_keys=True)
        os.replace(temp, self.path)

    def _key(self, kind: str, scope: str, context: dict, candidate) -> str:
        return _short_hash({
            "kind": kind,
            "scope": scope,
            "context": _safe_json(context),
            "candidate": _safe_json(candidate),
        })

    def get(self, kind: str, scope: str, context: dict, candidate):
        key = self._key(kind, scope, context, candidate)
        with self._lock:
            row = self._data["strategies"].get(key)
            if not isinstance(row, dict):
                return None
            self._decay(row)
            return deepcopy(row)

    def record(self, kind: str, scope: str, context: dict, candidate,
               outcome: str, persist: bool = True, detail: str = "") -> dict:
        candidate = _safe_json(candidate)
        context = _safe_json(context)
        key = self._key(kind, scope, context, candidate)
        with self._lock:
            row = self._data["strategies"].setdefault(key, {
                "id": key,
                "kind": kind,
                "scope": scope,
                "context": context,
                "candidate": candidate,
                "attempts": 0,
                "successes": 0,
                "failures": 0,
                "confidence": 0.5,
                "quarantined": False,
                "created": _now(),
            })
            row["attempts"] = int(row.get("attempts", 0)) + 1
            if outcome == "success":
                row["successes"] = int(row.get("successes", 0)) + 1
                row["last_success"] = _now()
            elif outcome == "failure":
                row["failures"] = int(row.get("failures", 0)) + 1
                row["last_failure"] = _now()
            else:
                raise ValueError(f"unknown strategy outcome: {outcome}")
            row["last_seen"] = _now()
            row["last_seen_epoch"] = time.time()
            row["last_detail"] = (detail or "")[:240]
            row["confidence"] = self._confidence(row)
            if row["failures"] >= 2 and row["confidence"] < 0.35:
                row["quarantined"] = True
            if outcome == "success" and row["confidence"] >= 0.55:
                row["quarantined"] = False
            if persist and kind in SAFE_KINDS:
                self._write_locked()
            return deepcopy(row)

    def candidates(self, kind: str, scope: str, context: dict,
                   candidates: list, banned: set | None = None) -> list:
        banned = banned or set()
        scored = []
        for candidate in candidates:
            key = _canonical(_safe_json(candidate))
            if key in banned:
                continue
            row = self.get(kind, scope, context, candidate)
            if row and row.get("quarantined"):
                continue
            confidence = float((row or {}).get("confidence", 0.5))
            successes = int((row or {}).get("successes", 0))
            scored.append((confidence, successes, candidate))
        scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
        return [candidate for _, _, candidate in scored]

    def summary(self) -> dict:
        with self._lock:
            rows = list(self._data["strategies"].values())
            return {
                "schema": SCHEMA,
                "count": len(rows),
                "trusted": sum(
                    1 for row in rows
                    if not row.get("quarantined")
                    and int(row.get("successes", 0)) > 0
                ),
                "quarantined": sum(1 for row in rows
                                    if row.get("quarantined")),
                "strategies": deepcopy(rows[-100:]),
            }


class SessionLearningController:
    """Immediate working memory layered over the persistent store."""

    def __init__(self, store: StrategyStore, session_id: str | None = None):
        self.store = store
        self.session_id = session_id or uuid.uuid4().hex[:16]
        self._lock = threading.RLock()
        self._banned: dict[str, set[str]] = {}
        # Verified corrections are kept in a fast, run-scoped overlay. The
        # persistent store remains the long-term record, but callers should
        # not have to wait for a later run (or reload) before reusing a
        # correction that just passed live verification.
        self._immediate: dict[str, dict[str, dict]] = {}
        self._events: list[dict] = []

    @staticmethod
    def _candidate_key(candidate) -> str:
        return _canonical(_safe_json(candidate))

    def _bucket(self, kind: str, scope: str, context: dict) -> str:
        return _short_hash({
            "kind": kind,
            "scope": scope,
            "context": _safe_json(context),
        })

    def choose(self, kind: str, scope: str, context: dict,
               candidates: list) -> list:
        bucket = self._bucket(kind, scope, context)
        with self._lock:
            banned = set(self._banned.get(bucket, set()))
        return self.store.candidates(kind, scope, context, candidates, banned)

    def _event(self, outcome: str, kind: str, scope: str, context: dict,
               candidate, detail: str, persistent: bool) -> dict:
        row = {
            "session": self.session_id,
            "ts": _now(),
            "outcome": outcome,
            "kind": kind,
            "scope": scope,
            "context": _safe_json(context),
            "candidate": _safe_json(candidate),
            "detail": (detail or "")[:240],
            "persistent": bool(persistent),
        }
        with self._lock:
            self._events.append(row)
            self._events[:] = self._events[-500:]
        return row

    def failure(self, kind: str, scope: str, context: dict, candidate,
                detail: str = "", persistent: bool = True) -> dict:
        bucket = self._bucket(kind, scope, context)
        with self._lock:
            self._banned.setdefault(bucket, set()).add(
                self._candidate_key(candidate))
        effective_persist = bool(persistent and kind in SAFE_KINDS)
        self.store.record(kind, scope, context, candidate, "failure",
                          persist=effective_persist, detail=detail)
        return self._event("failure", kind, scope, context, candidate, detail,
                           effective_persist)

    def success(self, kind: str, scope: str, context: dict, candidate,
                detail: str = "", persistent: bool = True) -> dict:
        effective_persist = bool(persistent and kind in SAFE_KINDS)
        row = self.store.record(kind, scope, context, candidate, "success",
                                persist=effective_persist, detail=detail)
        bucket = self._bucket(kind, scope, context)
        with self._lock:
            self._banned.setdefault(bucket, set()).discard(
                self._candidate_key(candidate))
        event = self._event("success", kind, scope, context, candidate,
                            detail, effective_persist)
        event["confidence"] = row.get("confidence", 0.5)
        return event

    def remember_correction(self, kind: str, scope: str, context: dict,
                            source, candidate, detail: str = "") -> dict:
        """Make a verified correction available immediately this run.

        This is intentionally separate from [success]. A successful strategy
        may already exist in the persistent store, but the corrected candidate
        can be a new multi-step replacement that is not part of the caller's
        original candidate list. The overlay is cleared when a new controller
        is created, so it cannot silently outlive the current build session.
        """
        bucket = self._bucket(kind, scope, context)
        source_key = self._candidate_key(source)
        row = {
            "source": _safe_json(source),
            "candidate": _safe_json(candidate),
            "detail": (detail or "")[:240],
            "session": self.session_id,
            "ts": _now(),
        }
        with self._lock:
            self._immediate.setdefault(bucket, {})[source_key] = row
        return deepcopy(row)

    def immediate_correction(self, kind: str, scope: str, context: dict,
                             source):
        """Return the current-run correction for [source], if verified."""
        bucket = self._bucket(kind, scope, context)
        source_key = self._candidate_key(source)
        with self._lock:
            row = self._immediate.get(bucket, {}).get(source_key)
            if not isinstance(row, dict):
                return None
            candidate = row.get("candidate")
            if self._candidate_key(candidate) in self._banned.get(
                    bucket, set()):
                return None
            return deepcopy(candidate)

    def events(self, limit: int = 100) -> list[dict]:
        with self._lock:
            return deepcopy(self._events[-max(1, min(500, limit)):])

    def summary(self) -> dict:
        with self._lock:
            banned = sum(len(values) for values in self._banned.values())
            immediate = sum(len(values) for values in self._immediate.values())
            return {
                "session": self.session_id,
                "events": len(self._events),
                "bannedCandidates": banned,
                "immediateCorrections": immediate,
                "persistent": self.store.summary(),
            }
