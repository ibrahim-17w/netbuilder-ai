"""Pure native-verification contracts; no GUI, configuration or file writes."""
from __future__ import annotations

import copy
import datetime
import hashlib
import ipaddress
import ntpath
import os
import re
import uuid

import pt_verify

IDENTITY_KEYS = frozenset({
    "projectId", "planRevision", "buildRevision", "requirementsDigest",
    "target", "scope", "layoutIdentity", "outputIdentity",
})
CHECKER = "packet-tracer-native-v1"
HASH_BINDING = "native-session-v1"
MAX_ARTIFACT_BYTES = 32 * 1024 * 1024


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def new_run_id() -> str:
    return uuid.uuid4().hex


def validate_run_id(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value):
        raise ValueError("runId must be a nonempty identifier (letters, digits, '_' or '-').")
    return value


def validate_identity(value: object) -> dict:
    if not isinstance(value, dict) or set(value) != IDENTITY_KEYS:
        raise ValueError("actionIdentity must contain the complete BuildActionIdentity JSON.")
    for key, item in value.items():
        if (not isinstance(item, str) or not item.strip() or len(item) > 512
                or any(ord(char) < 32 for char in item)):
            raise ValueError(f"actionIdentity.{key} must be a nonempty string.")
    if value["target"] != "packet-tracer":
        raise ValueError("Native verification supports the local packet-tracer target only.")
    return copy.deepcopy(value)


def local_artifact_path(value: object) -> str:
    """Reject remote paths, device paths, relative paths and alternate streams."""
    if not isinstance(value, str) or not value.strip() or len(value) > 4096:
        raise ValueError("artifactPath must be an absolute local .pkt path.")
    raw = value.strip()
    slash = raw.replace("\\", "/")
    if (any(ord(char) < 32 for char in raw) or slash.startswith("//")
            or "://" in slash or ".." in slash.split("/")):
        raise ValueError("artifactPath must be local and must not contain traversal or device paths.")
    drive, rest = ntpath.splitdrive(raw)
    if ":" in rest or (drive and not re.fullmatch(r"[A-Za-z]:", drive)):
        raise ValueError("artifactPath must not contain an alternate stream or device path.")
    if not os.path.isabs(raw):
        raise ValueError("artifactPath must be absolute on the sidecar machine.")
    path = os.path.realpath(raw)
    if path.replace("\\", "/").startswith("//"):
        raise ValueError("artifactPath must resolve to a local file.")
    if not path.lower().endswith(".pkt") or not os.path.isfile(path):
        raise ValueError("artifactPath must name an existing local .pkt file.")
    if not 0 < os.path.getsize(path) <= MAX_ARTIFACT_BYTES:
        raise ValueError("artifactPath is empty or exceeds the native verification size limit.")
    # A Windows drive mapped to a network share is remote despite its C:-style path.
    if os.name == "nt":
        import ctypes
        root = ntpath.splitdrive(path)[0] + "\\"
        if ctypes.windll.kernel32.GetDriveTypeW(root) == 4:  # DRIVE_REMOTE
            raise ValueError("Native verification does not open mapped network drives.")
    return path


def artifact_snapshot(path: str) -> tuple[bytes, str]:
    with open(path, "rb") as stream:
        data = stream.read(MAX_ARTIFACT_BYTES + 1)
    if not data or len(data) > MAX_ARTIFACT_BYTES:
        raise ValueError("Artifact is empty or exceeds the native verification size limit.")
    return data, hashlib.sha256(data).hexdigest()


def validate_plan(plan: object) -> dict:
    if not isinstance(plan, dict) or not plan:
        raise ValueError("missing plan")
    if "target" in plan and plan["target"] != "packet-tracer":
        raise ValueError("Native verification supports the local packet-tracer target only.")
    for key in ("nodes", "links", "addressing", "steps", "tests", "customChecks"):
        if key in plan and (not isinstance(plan[key], list) or len(plan[key]) > 1000):
            raise ValueError(f"plan.{key} must be a bounded list.")
    names = set()
    for node in plan.get("nodes", []):
        if not isinstance(node, dict):
            raise ValueError("plan.nodes must contain objects.")
        name = node.get("name")
        if (not isinstance(name, str) or not name.strip() or len(name) > 128
                or any(ord(c) < 32 for c in name) or name in names):
            raise ValueError("plan.nodes names must be unique nonempty strings.")
        names.add(name)
        if "services" in node and not isinstance(node["services"], list):
            raise ValueError("node.services must be a list.")
        rules = node.get("serviceRules") or {}
        dns = rules.get("dns") if isinstance(rules, dict) else None
        for record in (dns.get("records") or []) if isinstance(dns, dict) else []:
            if isinstance(record, dict) and record.get("name"):
                if not safe_dns_name(record["name"]):
                    raise ValueError("DNS probe names must be plain DNS names, not commands.")
    for link in plan.get("links", []):
        if not isinstance(link, dict) or any(link.get(key) not in names for key in ("a", "b")):
            raise ValueError("plan.links must reference declared nodes.")
    for key in ("addressing", "steps", "customChecks"):
        if any(not isinstance(item, dict) for item in plan.get(key, [])):
            raise ValueError(f"plan.{key} must contain objects.")
    # Only these pure declarations derive probes. Never execute plan.steps.
    result = copy.deepcopy(plan)
    pt_verify.derive_tests(result)
    return result


def safe_dns_name(value: object) -> bool:
    return (isinstance(value, str) and len(value) <= 253
            and bool(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", value)))


def safe_probe_ip(value: object) -> bool:
    try:
        return isinstance(value, str) and ipaddress.ip_address(value).version == 4
    except ValueError:
        return False


def validate_request(req: object) -> tuple[dict, dict]:
    if not isinstance(req, dict):
        raise ValueError("Verification request must be a JSON object.")
    if "plan" in req and not isinstance(req["plan"], dict):
        raise ValueError("plan must be a JSON object.")
    plan = validate_plan(req.get("plan", req))
    context = {"runId": new_run_id(), "artifactPath": "", "artifactHash": "",
               "actionIdentity": None, "bound": False}
    if "target" in req and req["target"] != "packet-tracer":
        raise ValueError("Native verification supports the local packet-tracer target only.")
    if "actionIdentity" in req:
        context["actionIdentity"] = validate_identity(req["actionIdentity"])
    if "artifactHash" in req:
        value = req["artifactHash"]
        if not isinstance(value, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", value):
            raise ValueError("artifactHash must be a SHA-256 hex digest.")
        context["artifactHash"] = value.lower()
    if "artifactPath" in req:
        context["artifactPath"] = local_artifact_path(req["artifactPath"])
        _, digest = artifact_snapshot(context["artifactPath"])
        if context["artifactHash"] and context["artifactHash"] != digest:
            raise ValueError("artifactHash does not match the requested file bytes.")
        context["artifactHash"] = digest
    elif "artifactHash" in req:
        raise ValueError("artifactHash requires artifactPath.")
    context["bound"] = bool(context["artifactPath"] and "artifactHash" in req
                            and context["actionIdentity"])
    return plan, context


def normalize_report(context: dict, raw: dict | None = None, *, state: str = "running",
                     error: str = "", hash_before: str = "", hash_after: str = "") -> dict:
    raw = raw or {}
    evidence = copy.deepcopy(raw.get("openEvidence") or {})
    evidence.setdefault("loadedFileMatches", False)
    evidence.setdefault("topologyMatches", False)
    stable = bool(context.get("bound") and hash_before == hash_after
                  == context.get("artifactHash") and hash_before)
    evidence.update({"artifactPath": context.get("artifactPath", ""),
                     "hashBefore": hash_before, "hashAfter": hash_after,
                     "digestMatches": stable})
    opened = bool(state == "completed" and stable
                  and evidence.get("loadedFileMatches") is True
                  and evidence.get("topologyMatches") is True
                  and raw.get("packetTracerVersion"))
    tests = []
    for item in raw.get("tests") or []:
        if not isinstance(item, dict):
            continue
        row = copy.deepcopy(item)
        # Legacy 'service' is ICMP reachability only, not a service assertion.
        if row.get("kind") == "service":
            row["kind"] = "peer"
        for key in ("src", "dst", "kind", "status", "evidence"):
            row.setdefault(key, "")
        if state == "cancelled" and row["status"] == "skipped" and row["kind"] not in ("custom", "manual"):
            row["status"] = "cancelled"
            row["evidence"] = row["evidence"] or "Verification cancelled before this probe completed."
        tests.append(row)
    totals = pt_verify.summarize(tests)
    counts = {key: totals[key] for key in ("passed", "failed", "skipped", "manual", "total")}
    counts["cancelled"] = sum(row["status"] == "cancelled" for row in tests)
    counts["timeout"] = sum(row["status"] == "timeout" for row in tests)
    return {
        "schema": 1, "checker": CHECKER,
        "hashBinding": HASH_BINDING if stable and state == "completed" else "",
        "runId": context["runId"], "state": state,
        "artifactHash": context.get("artifactHash", ""),
        "actionIdentity": copy.deepcopy(context.get("actionIdentity")),
        "packetTracerVersion": raw.get("packetTracerVersion") or "",
        "checkedAt": utc_now(), "opened": opened, "openEvidence": evidence,
        "tests": tests, "summary": counts,
        "error": error or str(raw.get("error") or ""),
        "errorKind": raw.get("errorKind") or ("cancelled" if state == "cancelled" else ""),
        "ok": bool(opened and totals["ok"] and state == "completed"
                   and not error and not raw.get("error")),
        **counts, "project": raw.get("project", ""),
    }
