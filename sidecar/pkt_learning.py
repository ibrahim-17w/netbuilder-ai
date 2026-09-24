"""Offline .pkt generation learning.

Every offline generation is a repeatable experiment with no GUI: the builder
resolves each requested model and interface against the machine-local template
library and reports what it *actually* did (a 2911 becoming a 2811 because the
2911 template has no serial port, a `g0/0` landing on `FastEthernet0/0`). This
store turns those per-run warnings into durable knowledge, so the app can say
what this machine will do BEFORE a build - and repeated generations can prove
the machine's behaviour is learned and stable.

Pure file work: no Packet Tracer, no screen, no network.  The store lives
beside the other sidecar memories and can be redirected with
NETBUILDER_PKT_LEARNING (tests use that).
"""
from __future__ import annotations

import json
import os
import re
import tempfile
import threading
import time

SCHEMA = 1

_SUB_RE = re.compile(r"^(.+?):\s+used\s+(\S+)\s+instead of\s+(\S+)")
_REMAP_RE = re.compile(r"^(.+?):\s+(\S+)\s+->\s+(\S+)\s+\(slot remap\)")


def _now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def default_path() -> str:
    override = os.environ.get("NETBUILDER_PKT_LEARNING", "").strip()
    if override:
        return os.path.abspath(os.path.expanduser(override))
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "pkt_learning.json")


def parse_warnings(warnings):
    """Classify the builder's warnings WITHOUT guessing.

    Returns (substitutions, remaps, other). An unrecognised line stays in
    ``other`` verbatim; only the two shapes the builder actually emits are
    interpreted.
    """
    subs, remaps, other = {}, {}, []
    for raw in warnings or []:
        text = str(raw).strip()
        if not text:
            continue
        m = _SUB_RE.match(text)
        if m:
            device, used, requested = m.group(1), m.group(2), m.group(3)
            key = "%s->%s" % (requested, used)
            row = subs.setdefault(
                key, {"requested": requested, "used": used, "count": 0,
                      "devices": []})
            row["count"] += 1
            if device not in row["devices"]:
                row["devices"].append(device)
            continue
        m = _REMAP_RE.match(text)
        if m:
            device, requested, actual = m.group(1), m.group(2), m.group(3)
            key = "%s->%s" % (requested, actual)
            row = remaps.setdefault(
                key, {"requested": requested, "actual": actual, "count": 0,
                      "devices": []})
            row["count"] += 1
            if device not in row["devices"]:
                row["devices"].append(device)
            continue
        other.append(text)
    return subs, remaps, other


class PktLearningStore:
    """Persistent, per-project record of what offline generation does here."""

    def __init__(self, path: str = ""):
        self.path = path or default_path()
        self._lock = threading.RLock()
        self._data = self._load()

    def _load(self) -> dict:
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
            if isinstance(data, dict) and isinstance(data.get("projects"), dict):
                return data
        except Exception:  # noqa: BLE001 - a missing/corrupt store starts empty
            pass
        return {"schema": SCHEMA, "projects": {}}

    def _save_locked(self) -> None:
        directory = os.path.dirname(self.path) or "."
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".pktlearn",
                                   suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(self._data, handle, indent=2, sort_keys=True)
            os.replace(tmp, self.path)
        finally:
            if os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except OSError:
                    pass

    def record(self, project: str, result: dict) -> dict:
        subs, remaps, other = parse_warnings(result.get("warnings"))
        key = (project or "default").strip() or "default"
        with self._lock:
            row = self._data["projects"].setdefault(key, {
                "generations": 0, "substitutions": {}, "remaps": {},
                "warnings": {}, "firstSeen": _now(), "last": {}})
            row["generations"] = int(row.get("generations", 0)) + 1
            new_items = []

            for sub_key, sub_row in subs.items():
                bucket = row["substitutions"].setdefault(sub_key, {
                    "requested": sub_row["requested"],
                    "used": sub_row["used"], "count": 0, "devices": []})
                bucket["count"] += sub_row["count"]
                for device in sub_row["devices"]:
                    if device not in bucket["devices"]:
                        bucket["devices"].append(device)
                if bucket["count"] == sub_row["count"]:
                    new_items.append(
                        "model %s is only available as %s on this machine"
                        % (sub_row["requested"], sub_row["used"]))
            for remap_key, remap_row in remaps.items():
                bucket = row["remaps"].setdefault(remap_key, {
                    "requested": remap_row["requested"],
                    "actual": remap_row["actual"], "count": 0, "devices": []})
                bucket["count"] += remap_row["count"]
                for device in remap_row["devices"]:
                    if device not in bucket["devices"]:
                        bucket["devices"].append(device)
                if bucket["count"] == remap_row["count"]:
                    new_items.append(
                        "interface %s lands on %s"
                        % (remap_row["requested"], remap_row["actual"]))
            for text in other:
                row["warnings"][text] = int(row["warnings"].get(text, 0)) + 1

            row["last"] = {
                "at": _now(),
                "name": result.get("name"),
                "devices": result.get("deviceCount"),
                "links": result.get("linkCount"),
                "bytes": result.get("bytes"),
                "sha256": result.get("sha256"),
            }
            self._save_locked()

            generations = row["generations"]
            known = {
                "substitutions": [
                    "%s -> %s (%dx)" % (v["requested"], v["used"], v["count"])
                    for v in row["substitutions"].values()],
                "remaps": [
                    "%s -> %s (%dx)" % (v["requested"], v["actual"], v["count"])
                    for v in row["remaps"].values()],
            }
            recurring = sorted(
                ((t, c) for t, c in row["warnings"].items() if c >= 2),
                key=lambda kv: (-kv[1], kv[0]))

        if generations == 1:
            note = "first offline generation for this project"
        elif new_items:
            note = ("offline generation #%d: %d new machine behaviour(s) "
                    "learned" % (generations, len(new_items)))
        else:
            note = ("offline generation #%d for this project - this machine's "
                    "behaviour is known and stable" % generations)
        return {
            "project": key,
            "generations": generations,
            "repeat": generations > 1,
            "new": new_items,
            "known": known,
            "recurringWarnings": ["%s (%dx)" % (t, c) for t, c in recurring],
            "note": note,
        }

    def summary(self) -> dict:
        with self._lock:
            projects = self._data.get("projects", {})
            total = sum(int(r.get("generations", 0))
                        for r in projects.values())
            return {
                "schema": SCHEMA,
                "generations": total,
                "projects": len(projects),
                "substitutions": sorted({
                    k for r in projects.values()
                    for k in r.get("substitutions", {})}),
                "remaps": sorted({
                    k for r in projects.values() for k in r.get("remaps", {})}),
                "detail": projects,
                "path": self.path,
            }


_STORE = None
_STORE_LOCK = threading.Lock()


def _store() -> PktLearningStore:
    global _STORE
    with _STORE_LOCK:
        if _STORE is None:
            _STORE = PktLearningStore()
        return _STORE


def reset(path: str = "") -> None:
    """Point the module store at a fresh file (test hook)."""
    global _STORE
    with _STORE_LOCK:
        _STORE = PktLearningStore(path)


def record_generation(project: str, result: dict) -> dict:
    return _store().record(project, result)


def summary() -> dict:
    return _store().summary()
