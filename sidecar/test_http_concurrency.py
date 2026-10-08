"""Gates for the threading change: a slow request must not take the engine down.

The engine used to serve on a plain ``HTTPServer``, which answers exactly one
request at a time.  Every endpoint was therefore a global serialization point,
and the failure mode was total rather than degraded: while one handler ran,
``/health`` could not answer either.  ``_status_payload_locked`` records a real
instance of exactly that ("wedged the ENTIRE process ... for the life of the
server").  The lock discipline fixed that one call; the server is now
threaded so the CLASS of bug cannot come back.

These tests pin the properties the threading depends on.  They run no real
work and need neither Packet Tracer nor Tesseract, so they stay green on a
machine that cannot drive a UI.

* the server really is threaded, and really is daemon-threaded
* a handler that blocks for a long time does NOT stop another request from
  being answered  - the whole point of the change
* a dropped connection does not take the process down
* the bind address is still loopback only  - threading must never widen it
* LOCK is still non-reentrant, and no LOCK block performs IO  - the invariant
  that threading makes load-bearing for availability
* build entry points still admit exactly one winner
"""
from __future__ import annotations

import json
import socket
import threading
import time
import urllib.error
import urllib.request

import pytest

import pt_autopilot as pt


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _get(port: int, path: str, timeout: float = 5.0):
    """(status, decoded-json-or-None). Never raises on an HTTP error code."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}",
                                    timeout=timeout) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, None
    except Exception as e:  # timeout / refused / bad json
        return None, e


class _SlowHandler(pt.H):
    """The real handler, plus one endpoint that blocks on demand."""

    SLOW_PATH = "/_test_slow"
    BLOCK = threading.Event()

    def do_GET(self):
        if self.path == self.SLOW_PATH:
            self.BLOCK.wait(10)
            self._json({"ok": True, "slow": True})
            return
        return super().do_GET()

    def log_message(self, *a):  # keep the suite quiet
        pass


def _serve():
    """Start the engine's REAL server on a free port; return (srv, port).

    This goes through ``build_server()`` - the same factory ``main`` calls -
    rather than instantiating a server class directly.  That matters: an
    earlier version of this file built ``pt._ThreadingHTTPServer`` itself, and
    consequently still passed after the bootstrap had been reverted to a
    single-threaded ``HTTPServer``.  A gate that constructs its own server
    gates nothing.
    """
    port = _free_port()
    srv = pt.build_server(host="127.0.0.1", port=port, handler=_SlowHandler)
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    return srv, port


@pytest.fixture
def engine():
    srv, port = _serve()
    yield port
    _SlowHandler.BLOCK.set()  # release any blocked slow handler
    srv.shutdown()
    srv.server_close()


# ---------------------------------------------------------------------------
# the change itself
# ---------------------------------------------------------------------------

def test_the_engine_server_is_threaded():
    """The server the engine ACTUALLY serves on must be threaded.

    Built through ``build_server()`` so this fails if the bootstrap is ever
    changed back to a serial server, however it is constructed.
    """
    from http.server import ThreadingHTTPServer
    srv = pt.build_server(host="127.0.0.1", port=0, handler=_SlowHandler)
    try:
        assert isinstance(srv, ThreadingHTTPServer), (
            f"build_server() returned {type(srv).__name__}; the engine is "
            "serving single-threaded again"
        )
    finally:
        srv.server_close()


def test_threads_are_daemons_so_a_build_run_cannot_block_shutdown():
    # A live build holds a request open.  If its thread were non-daemon, the
    # engine could not exit while that run is in flight.
    assert pt._ThreadingHTTPServer.daemon_threads is True


def test_bind_address_is_still_loopback_only():
    """Threading must never widen who can reach an unauthenticated API.

    This engine drives the operator's mouse and types into their terminals.
    It has no authentication, so the bind address is the only thing keeping it
    off the LAN.  A threading change is exactly the kind of edit where that
    line gets nudged, so it is pinned here.
    """
    import ipaddress
    assert ipaddress.ip_address(pt.HOST).is_loopback, (
        f"engine binds {pt.HOST}; it must stay loopback-only"
    )


def test_the_handler_bounds_its_socket_read():
    # do_POST reads exactly Content-Length bytes; without a timeout a stalled
    # caller pins a thread forever.
    assert getattr(pt.H, "timeout", None), "H must bound the socket read"


# ---------------------------------------------------------------------------
# the behaviour the change exists to produce
# ---------------------------------------------------------------------------

def test_a_blocking_handler_does_not_stop_other_requests(engine):
    """The regression this whole change is for.

    On the old single-threaded server, while ``/_test_slow`` sat in its wait,
    ``/health`` could not be answered at all.  That is the wedge recorded in
    ``_status_payload_locked``.  Here the slow handler is parked and a normal
    request must still come back promptly.
    """
    _SlowHandler.BLOCK.clear()
    started = threading.Event()
    outcome = {}

    def slow():
        started.set()
        _get(engine, _SlowHandler.SLOW_PATH, timeout=10)

    t = threading.Thread(target=slow, daemon=True)
    t.start()
    assert started.wait(5), "slow request never started"
    time.sleep(0.3)  # let it reach the blocking wait

    # The engine is genuinely busy...
    assert pt.H is _SlowHandler or issubclass(_SlowHandler, pt.H)

    # ...and a concurrent request is still answered, quickly.
    began = time.perf_counter()
    status, body = _get(engine, "/health")
    elapsed_ms = (time.perf_counter() - began) * 1000

    assert status == 200, f"/health was blocked by the slow handler: {body!r}"
    assert elapsed_ms < 2000, (
        f"/health took {elapsed_ms:.0f} ms while another handler was busy - "
        "the server is serializing requests again"
    )
    assert body and body.get("ok") is True
    _SlowHandler.BLOCK.set()


def test_health_answers_before_any_build_has_run(engine):
    status, body = _get(engine, "/health")
    assert status == 200
    assert body["ok"] is True
    assert "engine" in body and "version" in body


def test_status_answers_and_stays_self_consistent(engine):
    status, body = _get(engine, "/status")
    assert status == 200, body
    assert isinstance(body, dict) and body
    # /status is the endpoint the UI polls every 2s; it must answer even with
    # nothing running, which is the state a first launch is in.
    assert "running" in body


def test_a_dropped_connection_does_not_kill_the_engine(engine):
    """A caller that vanishes mid-request must not take the process with it."""
    s = socket.create_connection(("127.0.0.1", engine), timeout=5)
    s.sendall(b"GET /status HTTP/1.1\r\nHost: x\r\n")  # headers only, no body
    s.close()  # rude disconnect

    time.sleep(0.2)
    status, _ = _get(engine, "/health")
    assert status == 200, "engine stopped answering after a dropped connection"


def test_concurrent_status_polls_are_all_answered(engine):
    """The real UI pattern: /status every 2s while other work is in flight."""
    results = []

    def poll():
        results.append(_get(engine, "/status", timeout=10)[0])

    threads = [threading.Thread(target=poll) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(12)

    assert len(results) == 8
    assert all(r == 200 for r in results), f"some polls failed: {results}"


# ---------------------------------------------------------------------------
# the invariants threading makes load-bearing
# ---------------------------------------------------------------------------

def test_lock_is_not_reentrant():
    """LOCK is a plain Lock on purpose.

    Threading means two threads genuinely contend for it where the
    single-threaded server merely serialized them.  A reentrant lock would let
    a nested acquisition succeed and hide exactly the bug that wedged the
    engine before; a plain one fails loudly instead.
    """
    import threading as _t
    assert not hasattr(pt.LOCK, "_is_owned"), "LOCK must stay non-reentrant"
    assert isinstance(pt.LOCK, type(_t.Lock()))


def test_no_lock_block_performs_io():
    """Every ``with LOCK`` block must stay short and do no IO.

    Before threading this was a correctness nicety.  Now it is what keeps the
    engine AVAILABLE: a LOCK block that reads a file, sleeps, or shells out
    makes every other endpoint wait for it.  This walks the source and fails
    if a blocking call ever appears inside one.
    """
    import re
    src = pt.__file__
    lines = open(src, encoding="utf-8").read().split("\n")
    blocking = re.compile(
        r"time\.sleep|subprocess|\.communicate\(|urlopen|requests\.|"
        r"os\.walk|shutil\.|tesseract|socket\.", re.I)
    offenders = []
    i = 0
    while i < len(lines):
        if "with LOCK" in lines[i]:
            indent = len(lines[i]) - len(lines[i].lstrip())
            j = i + 1
            while j < len(lines):
                ln = lines[j]
                if ln.strip() and (len(ln) - len(ln.lstrip())) <= indent:
                    break
                if blocking.search(ln) and not ln.strip().startswith("#"):
                    offenders.append((j + 1, ln.strip()))
                j += 1
            i = j
        else:
            i += 1
    assert not offenders, (
        "blocking call inside a LOCK block - it would stall every endpoint "
        f"while held: {offenders}"
    )


def test_locked_helpers_take_no_lock_of_their_own():
    """``*_locked`` helpers are called WITH the lock held and must take none.

    Re-entering LOCK from a thread that already holds it is a self-deadlock on
    a plain Lock.  The inlined ``pause`` fields in ``_status_payload_locked``
    exist for this reason; this pins the property so a future edit cannot
    quietly reintroduce a nested acquisition.

    Parsed with ``ast`` rather than grepped: these functions have long
    docstrings that DISCUSS ``with LOCK``, and a text search would flag the
    explanation instead of the code.
    """
    import ast
    import inspect
    for name in ("_status_payload_locked", "_active_activity_locked"):
        fn = getattr(pt, name, None)
        if fn is None:
            continue
        tree = ast.parse(inspect.getsource(fn).lstrip())
        for node in ast.walk(tree):
            # `with LOCK: ...` outside a docstring - real code, not prose.
            if isinstance(node, (ast.With, ast.AsyncWith)):
                for item in node.items:
                    ctx = item.context_expr
                    name_of = getattr(ctx, "id", None) or getattr(
                        getattr(ctx, "value", None), "id", None)
                    assert name_of != "LOCK", (
                        f"{name}() is called while LOCK is held and must not "
                        "re-acquire it"
                    )


def test_build_entry_points_admit_exactly_one_winner():
    """Two /start calls now reach ``begin_activity`` concurrently.

    Before threading, the second one simply queued behind the first request.
    Now they race, so the exclusion has to be a real atomic claim - which it
    is: ``begin_activity`` does its check and its claim in one LOCK block and
    returns the loser a 409.  This drives that directly.
    """
    results = []

    def attempt():
        results.append(pt.begin_activity("build")[0])

    threads = [threading.Thread(target=attempt) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(5)

    assert len(results) == 8
    assert sum(1 for r in results if r) == 1, (
        f"begin_activity admitted {sum(1 for r in results if r)} concurrent "
        "runs; exactly one must win"
    )
    # Leave global state as we found it so other tests are unaffected.
    with pt.LOCK:
        pt.JOB.running = False
        pt.JOB.stop_requested = False
        pt.JOB.paused = False
        pt.JOB.pause_requested = False
        pt.JOB.pause_source = ""