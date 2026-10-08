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


# A finding's own words carry this network's names: "R1:g0/0 is shut down".
# Learning from that verbatim would make every later network look different
# from the first one, so the device, interface, address and model words are
# replaced by placeholders and only the SHAPE of the finding survives.
_NAMEY = re.compile(
    r"\b\d{1,3}(?:\.\d{1,3}){3}(?:/\d+)?"
    r"|\b[A-Za-z][A-Za-z\-]*\d[\w/\.\-]*"
    r"|\b\d+(\.\d+)*/\d+\b")


def finding_class(finding) -> str:
    """A stable name for the KIND of finding, stripped of this network.

    Two saves of the same lab that both report "the interface is shut down"
    produce the same class, so a repair verified on one is recognised on the
    other. Anything unrecognisable keeps its own text - a class is never
    guessed into shape.
    """
    if not isinstance(finding, dict):
        return ""
    text = str(finding.get("title") or finding.get("text")
               or finding.get("detail") or "").strip()
    if not text:
        return ""
    shape = _NAMEY.sub("*", text)
    shape = re.sub(r"\s+", " ", shape).strip().lower()
    severity = str(finding.get("severity") or "").strip().lower()
    return f"{severity}|{shape}" if severity else shape


def _commands_of(fix) -> list:
    if not isinstance(fix, dict):
        return []
    out = []
    for line in (fix.get("fix_cli") or fix.get("commands") or []):
        text = str(line).strip()
        if text:
            out.append(text[:160])
    return out[:12]


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
            repairs = [row for r in projects.values()
                       for row in (r.get("repairs") or {}).values()]
            return {
                "schema": SCHEMA,
                "generations": total,
                "projects": len(projects),
                "substitutions": sorted({
                    k for r in projects.values()
                    for k in r.get("substitutions", {})}),
                "remaps": sorted({
                    k for r in projects.values() for k in r.get("remaps", {})}),
                "verifiedRepairs": len(repairs),
                "detail": projects,
                "path": self.path,
            }

    def record_repair(self, project: str, verdict: dict, audit_before=None,
                      fixes=None) -> dict:
        """Remember a REPAIR THAT WAS PROVEN TO WORK, and nothing else.

        The only evidence accepted is [verify_repair]'s own ``verified``
        verdict, which means a re-audit of the repaired save no longer reports
        the finding. Anything weaker - applied, approved, proposed, or a fix
        whose finding survived the re-audit - is deliberately not learned from,
        because a store that remembers failed repairs as if they were lessons
        will, on its next confident reuse, repeat them.

        What is kept is deliberately plain: the finding's CLASS (this
        network's device and interface names removed), the commands that
        cleared it, and how many times that class has been cleared here. That
        is what lets the next audit of the same lab say "this exact class was
        fixed successfully on this project before" without anyone having to
        remember it.
        """
        key = (project or "default").strip() or "default"
        if not isinstance(verdict, dict) or verdict.get("verified") is not True:
            return {"recorded": 0, "reason": "repair was not verified",
                    "verdict": (verdict or {}).get("verdict")}
        wanted = {str(f.get("id") or f.get("findingId") or "")
                  for f in (fixes or []) if isinstance(f, dict)}
        wanted.discard("")
        wanted.discard("None")
        before = {}
        if isinstance(audit_before, dict):
            for device in audit_before.get("devices") or []:
                for finding in (device.get("findings") or []):
                    if isinstance(finding, dict) and finding.get("id"):
                        before[str(finding["id"])] = {
                            "device": device.get("name"),
                            "severity": finding.get("severity"),
                            "title": finding.get("title")
                            or finding.get("text") or finding.get("detail"),
                        }
        entries = []
        for row in verdict.get("resolved") or []:
            fid = str(row.get("id") or "")
            if wanted and fid not in wanted:
                continue
            entries.append(dict(row, **before.get(fid, {})))
        if not entries:
            return {"recorded": 0, "reason": "no resolved finding named",
                    "verdict": verdict.get("verdict")}
        commands: list[str] = []
        for fix in fixes or []:
            if isinstance(fix, dict):
                commands.extend(_commands_of(fix))
        if not commands:
            return {"recorded": 0, "reason": "the fix named no commands",
                    "verdict": verdict.get("verdict")}
        with self._lock:
            row = self._data["projects"].setdefault(key, {
                "generations": 0, "substitutions": {}, "remaps": {},
                "warnings": {}, "firstSeen": _now(), "last": {}, "repairs": {}})
            bucket = row.setdefault("repairs", {})
            learned = []
            for entry in entries:
                klass = finding_class(entry)
                if not klass:
                    continue
                item = bucket.setdefault(klass, {
                    "severity": entry.get("severity") or "",
                    "example": str(entry.get("title") or "")[:160],
                    "commands": [], "count": 0, "devices": [], "last": ""})
                item["count"] = int(item.get("count", 0)) + 1
                item["last"] = _now()
                for command in commands:
                    if command not in item["commands"]:
                        item["commands"].append(command)
                item["commands"] = item["commands"][:12]
                device = str(entry.get("device") or "")
                if device and device not in item["devices"]:
                    item["devices"] = (item["devices"] + [device])[:8]
                learned.append(klass)
            if not learned:
                return {"recorded": 0,
                        "reason": "the finding named no class to learn",
                        "verdict": verdict.get("verdict")}
            # Keep the store about this project, not about every finding this
            # project has ever had: the newest classes are the useful ones.
            if len(bucket) > 40:
                for stale in sorted(bucket, key=lambda k: bucket[k].get("last")
                                    or "")[:-40]:
                    bucket.pop(stale, None)
            self._save_locked()
        return {"recorded": len(learned), "classes": sorted(set(learned)),
                "commands": commands[:12],
                "note": "%d repair(s) verified on this project"
                        % len(set(learned))}

    def verified_repairs(self, project: str) -> dict:
        """The verified repair classes for [project], keyed by class."""
        key = (project or "default").strip() or "default"
        with self._lock:
            row = self._data.get("projects", {}).get(key) or {}
            return dict(row.get("repairs") or {})


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


def record_repair(project: str, verdict: dict, audit_before=None,
                  fixes=None) -> dict:
    """Learn a repair the re-audit PROVED worked. Never a hopeful one."""
    return _store().record_repair(project, verdict, audit_before, fixes)


def verified_repairs(project: str) -> dict:
    """The finding classes already proven fixed on [project]."""
    return _store().verified_repairs(project)


def summary() -> dict:
    return _store().summary()
