"""The engine's model calls, routed through an in-process Respan Gateway.

WHY THIS EXISTS
When Packet Tracer rejects a command the engine asks a model for a repair.
Until now [pt_autopilot._llm_request] built that call itself: one ``urllib``
POST to Gemini's ``generateContent``, or to an OpenAI-compatible
``/chat/completions``, chosen by an ``if`` in the caller.  The open-source
[Respan Gateway](https://github.com/respanai/respan-gateway) now sits in front
of it: one gateway in this process, one OpenAI chat shape on the wire, and the
vendor picked by the config instead of by a branch spread through the engine.
That is what makes a second provider (or a swapped base URL) a config change
rather than another code path, and it is where usage, retries and routes would
grow later.  No Respan account, hosted credits or tracing export are involved:
the gateway runs here, spending the provider key the app already pushes.

The gateway is optional at runtime.  Without the wheel - an older install, a
stripped bundle - [available] is False and the engine keeps its own direct
request, so nothing that worked before stops working.

Secrets: the app pushes the provider key once per run (POST /llm_config); it is
handed to the gateway's config and never written to disk, logged, or put in a
URL.  [fingerprint] hashes it so the cache key says which settings a gateway was
built from without keeping the credential readable beside it.
"""
from __future__ import annotations

import hashlib
import threading
from urllib.parse import urlparse

try:
    import respan_gateway as rg
    HAS_GATEWAY = True
    IMPORT_ERROR = ""
except Exception as exc:  # noqa: BLE001 - the engine serves without the wheel
    rg = None
    HAS_GATEWAY = False
    IMPORT_ERROR = str(exc)

# The provider name inside the gateway config.  Only one is ever configured:
# whatever the app selected for this run.
PROVIDER = "netbuilder"
OPENAI_DEFAULT_BASE = "https://api.openai.com/v1"

_LOCK = threading.Lock()
_CACHED: dict = {"fingerprint": None, "gateway": None}


class GatewayUnavailable(RuntimeError):
    """This process cannot route through the gateway; callers use the direct request."""


def available() -> bool:
    """True when the gateway package imported and can carry a request."""
    return HAS_GATEWAY


def config_for(provider: str = "gemini", model: str = "",
               base_url: str = "", api_key: str = "") -> dict:
    """The gateway config for the provider the app selected.

    ``openai`` is any OpenAI-compatible endpoint - a local llama.cpp server, a
    hosted free tier, OpenAI itself - and keeps the base URL the user set.
    ``gemini`` is the built-in vendor, which knows its own URLs.  The model the
    engine asks for is routed explicitly to this one provider, so routing never
    depends on a provider's model list being reachable.

    Raises [GatewayUnavailable] when the settings cannot be expressed at all.
    """
    provider = "openai" if str(provider or "").strip() == "openai" else "gemini"
    model = str(model or "").strip()
    if not model:
        raise GatewayUnavailable("no model selected")
    if provider == "openai":
        base = str(base_url or "").strip().rstrip("/")
        parsed = urlparse(base)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise GatewayUnavailable("Invalid model provider address")
        entry: dict = {"formats": ["openai-chat"], "base_url": base}
        if str(api_key or "").strip():
            entry["key"] = str(api_key).strip()
    else:
        if not str(api_key or "").strip():
            raise GatewayUnavailable("no provider key")
        entry = {"vendor": "gemini", "key": str(api_key).strip()}
    return {
        # In-process: no UI, no admin API, no per-request stderr lines.
        "ui": False,
        "log": "off",
        "providers": {PROVIDER: entry},
        "routes": {model: {"to": f"{PROVIDER}/{model}"}},
    }


def fingerprint(provider: str = "gemini", model: str = "",
                base_url: str = "", api_key: str = "") -> tuple:
    """What a cached gateway was built from, with the key hashed, not readable."""
    digest = hashlib.sha256(str(api_key or "").encode("utf-8")).hexdigest()[:16]
    return (str(provider or ""), str(model or ""), str(base_url or ""), digest)


def _gateway(provider: str, model: str, base_url: str, api_key: str):
    """One gateway per settings revision, rebuilt when the app pushes new ones."""
    key = fingerprint(provider, model, base_url, api_key)
    with _LOCK:
        if _CACHED["gateway"] is not None and _CACHED["fingerprint"] == key:
            return _CACHED["gateway"]
        stale = _CACHED["gateway"]
        _CACHED["gateway"] = None
        _CACHED["fingerprint"] = None
        if stale is not None:
            _close(stale)
        if not HAS_GATEWAY:
            raise GatewayUnavailable(f"respan-gateway is not installed ({IMPORT_ERROR[:80]})")
        try:
            gateway = rg.Gateway(config=config_for(provider, model, base_url, api_key))
        except GatewayUnavailable:
            raise
        except Exception as exc:  # noqa: BLE001 - ConfigError and friends
            raise GatewayUnavailable(f"gateway config refused: {str(exc)[:120]}")
        _CACHED["gateway"] = gateway
        _CACHED["fingerprint"] = key
        return gateway


def complete(prompt: str, *, provider: str = "gemini", model: str = "",
             base_url: str = "", api_key: str = "",
             timeout: float = 20.0) -> str:
    """Send one prompt through the gateway and return the reply text.

    The caller has already redacted [prompt].  An empty string means the model
    answered nothing usable - the same answer the direct request gave.

    Raises [GatewayUnavailable] when the gateway itself could not be built or
    carried the request (the caller may fall back), and ``RuntimeError`` when
    the provider answered with an HTTP error.
    """
    gateway = _gateway(provider, model, base_url, api_key)
    try:
        response = gateway.request(
            "POST", "/v1/chat/completions",
            json={"model": str(model).strip(),
                  "messages": [{"role": "user", "content": str(prompt or "")}],
                  "stream": False},
            timeout=timeout)
    except Exception as exc:  # noqa: BLE001 - httpx timeout / transport failure
        raise GatewayUnavailable(f"gateway request failed: {str(exc)[:120]}")
    if response.status_code >= 400:
        raise RuntimeError(f"model provider HTTP {response.status_code}")
    try:
        data = response.json()
    except Exception:  # noqa: BLE001 - a body that is not JSON is no answer
        return ""
    choices = data.get("choices") or []
    message = (choices[0] if choices else {}).get("message") or {}
    return str(message.get("content") or "").strip()


def reset() -> None:
    """Forget the cached gateway (privacy mode clears the key it was built with)."""
    with _LOCK:
        gateway, _CACHED["gateway"] = _CACHED["gateway"], None
        _CACHED["fingerprint"] = None
    if gateway is not None:
        _close(gateway)


def _close(gateway) -> None:
    try:
        gateway.close()
    except Exception:  # noqa: BLE001 - closing must never raise at the caller
        pass
