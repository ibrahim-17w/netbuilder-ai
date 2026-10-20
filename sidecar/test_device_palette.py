"""Every device kind the planner can emit must be placeable and cableable.

`DeviceKind` lives in the Flutter app (lib/models/network_intent.dart) and the
executor lives here, so the two sides can drift silently: the planner adds a
kind, and the run either places the wrong palette device or gives up on the
cable.  These gates read the Dart catalog directly and pin the Python side to
it - palette path, model names, port vocabulary - so adding a device is one
entry in each language and the mismatch is a failing test rather than a
half-built topology.

Runs without Packet Tracer, Tesseract or the RPA stack.
"""
from __future__ import annotations

import os
import re
import sys

import pytest

from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pt_autopilot as pt  # noqa: E402

# The Dart `deviceKinds` table lived in `lib/models/network_intent.dart` until
# the NLU extraction moved it into the lexicon. The test reads whichever file
# declares it, so the cross-check survives the move instead of failing on a
# missing substring.
DART_CATALOG = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "lib", "services", "nlu", "lexicon.dart")


def _dart_kinds() -> list:
    """[(type, first model, port)] from the Dart `deviceKinds` table."""
    with open(DART_CATALOG, encoding="utf-8") as f:
        source = f.read()
    start = source.index("const List<DeviceKind> deviceKinds = [")
    block = source[start:source.index("\n];", start)]
    kinds = []
    for chunk in block.split("DeviceKind(")[1:]:
        type_m = re.search(r"type:\s*'([^']+)'", chunk)
        if not type_m:
            continue
        models_m = re.search(r"models:\s*\[([^\]]*)\]", chunk)
        models = re.findall(r"'([^']+)'", models_m.group(1)) if models_m else []
        port_m = re.search(r"port:\s*'([^']*)'", chunk)
        kinds.append((type_m.group(1),
                      models[0] if models else "",
                      port_m.group(1) if port_m else ""))
    return kinds


def _dart_unsupported_kinds() -> set:
    """The `unsupportedDeviceKinds` set from the Dart lexicon."""
    with open(DART_CATALOG, encoding="utf-8") as f:
        source = f.read()
    start = source.index("const Set<String> unsupportedDeviceKinds = {")
    block = source[start:source.index("};", start)]
    return set(re.findall(r"'([^']+)'", block))


def test_the_dart_catalog_is_readable():
    kinds = _dart_kinds()
    assert len(kinds) >= 15, kinds
    assert ("router", "4331", "f0") in kinds, kinds


def test_the_unsupported_lists_agree_in_both_directions():
    unsupported = _dart_unsupported_kinds()
    assert unsupported == pt.UNSUPPORTED_DEVICE_KINDS, (
        "lib/services/nlu/lexicon.dart and pt_autopilot.py disagree about "
        f"unsupported kinds: Dart-only {unsupported - pt.UNSUPPORTED_DEVICE_KINDS}, "
        f"Python-only {pt.UNSUPPORTED_DEVICE_KINDS - unsupported}")
    assert not (unsupported & set(pt.DEVICE_PALETTE)), (
        "a kind cannot be both unsupported and palette-backed: "
        f"{sorted(unsupported & set(pt.DEVICE_PALETTE))}")
    planned = {t for t, _m, _p in _dart_kinds()}
    assert unsupported <= planned, unsupported - planned


def test_every_planner_kind_has_an_executor_palette_path():
    unsupported = _dart_unsupported_kinds()
    missing = [t for t, _m, _p in _dart_kinds()
               if t not in pt.DEVICE_PALETTE and t not in unsupported]
    assert not missing, (
        f"the planner can emit {missing}, but the executor has neither a "
        "DEVICE_PALETTE entry nor an explicit unsupported-list entry")


def test_every_palette_kind_is_one_the_planner_can_emit():
    planned = {t for t, _m, _p in _dart_kinds()}
    extra = sorted(set(pt.DEVICE_PALETTE) - planned)
    assert not extra, f"palette entries nothing can ask for: {extra}"


def test_the_palette_offers_the_model_the_planner_picks():
    for kind, model, _port in _dart_kinds():
        spec = pt.DEVICE_PALETTE.get(kind)
        if not spec or not model:
            continue
        assert model in spec[2], (
            f"{kind}: the planner picks {model!r} but the palette looks for "
            f"{spec[2]}")


def test_every_declared_port_is_cableable():
    """A port the planner names must resolve to a name PT will show."""
    for kind, _model, port in _dart_kinds():
        if not port:
            continue
        if port in pt.PORT_NAME_VOCAB:
            continue
        wants = pt.iface_port_wants(port)
        assert wants and wants[0].lower().startswith(
            ("gigabitethernet", "fastethernet", "serial", "ethernet",
             "port")), (kind, port, wants)


def _reset_run_state():
    """The run counters place_nodes writes into."""
    pt.RUN["node_outcomes"] = {}
    pt.RUN["devices_placed"] = 0
    pt.RUN["devices_reused"] = 0
    pt.RUN["devices_reuse_blocked"] = 0


def test_the_palette_group_is_clicked_before_the_model():
    """place_nodes must go GROUP -> (TYPE) -> MODEL for a new kind too."""
    _reset_run_state()
    calls = []

    def by_names(names, what, **kwargs):
        calls.append(("names", tuple(names), what))
        # only the group names and the ASAs exist on this fake palette
        return names[0] in ("Security", "Firewalls", "Firewall", "5506")

    model_calls = []

    with patch.object(pt, "click_by_names", side_effect=by_names), \
         patch.object(pt, "click_frac",
                         side_effect=lambda *a, **k: calls.append(
                             ("frac", a[1], a[2]))), \
         patch.object(pt, "click_model",
                         side_effect=lambda rect, names, col, what:
                         model_calls.append((tuple(names), col)) or True), \
         patch.object(pt, "_slot_visual_state",
                         return_value=("empty", "")), \
         patch.object(pt, "_shot_region", return_value=""), \
         patch.object(pt, "canvas_changed", return_value=(True, 0.9)), \
         patch.object(pt, "_press_esc"), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "remember_device"), \
         patch.object(pt, "shot"), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        pt.place_nodes((0, 0, 1000, 700),
                       [{"name": "FW1", "type": "firewall", "model": "5506"}],
                       "test")

    assert model_calls, "the model step must happen for a firewall"
    asked, col = model_calls[0]
    assert asked[0] == "5506", asked
    assert col == 0, "ASA is the first entry in the Security list"
    group_names = [c[1] for c in calls if c[0] == "names"]
    assert group_names and group_names[0][0] == "Security", calls
    # Security opens straight onto its list, so no TYPE name click happens
    assert len(group_names) == 1, group_names


def test_an_unknown_type_never_places_silently_as_a_router():
    _reset_run_state()
    calls = []

    def by_names(names, what, **kwargs):
        calls.append(tuple(names))
        return names[0] in ("Network Devices", "Routers", "2911")

    with patch.object(pt, "click_by_names", side_effect=by_names), \
         patch.object(pt, "click_frac"), \
         patch.object(pt, "click_model",
                         side_effect=lambda rect, names, col, what: True), \
         patch.object(pt, "_slot_visual_state",
                         return_value=("empty", "")), \
         patch.object(pt, "_shot_region", return_value=""), \
         patch.object(pt, "canvas_changed", return_value=(True, 0.9)), \
         patch.object(pt, "_press_esc"), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "remember_device"), \
         patch.object(pt, "shot"), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        pt.place_nodes((0, 0, 1000, 700),
                       [{"name": "X1", "type": "hovercraft"}], "test")
    assert ("Network Devices", "Network Device") in calls, calls


def test_an_unsupported_planner_kind_is_skipped_not_substituted():
    """A hub must not become a router: no palette click happens at all."""
    _reset_run_state()
    calls = []

    with patch.object(pt, "click_by_names",
                      side_effect=lambda names, what, **kw:
                      calls.append(tuple(names)) or True), \
         patch.object(pt, "click_frac"), \
         patch.object(pt, "click_model"), \
         patch.object(pt, "_slot_visual_state",
                      return_value=("empty", "")), \
         patch.object(pt, "_shot_region", return_value=""), \
         patch.object(pt, "canvas_changed", return_value=(True, 0.9)), \
         patch.object(pt, "_press_esc"), \
         patch.object(pt, "_interruptible_sleep", return_value=True), \
         patch.object(pt, "remember_device"), \
         patch.object(pt, "shot"), \
         patch.object(pt, "record_event"), \
         patch.object(pt, "log"):
        pt.place_nodes((0, 0, 1000, 700),
                       [{"name": "H1", "type": "hub", "model": "Hub-PT"}],
                       "test")

    assert not calls, calls
    assert pt.RUN["node_outcomes"]["H1"] == "unsupported"


def test_generate_rejects_an_unsupported_kind_without_substituting():
    plan = {"steps": [{"action": "create_nodes", "nodes": [
        {"name": "H1", "type": "hub", "model": "Hub-PT"}]}]}
    with pytest.raises(pt.pkt_builder.BuildError) as caught:
        pt.pkt_generate(plan, project="unsupported", filename="unsupported")
    assert "hub" in str(caught.value)
    assert "Supported device types:" in str(caught.value)
    assert "No substitute" in str(caught.value)


if __name__ == "__main__":
    test_the_dart_catalog_is_readable()
    test_the_unsupported_lists_agree_in_both_directions()
    test_every_planner_kind_has_an_executor_palette_path()
    test_every_palette_kind_is_one_the_planner_can_emit()
    test_the_palette_offers_the_model_the_planner_picks()
    test_every_declared_port_is_cableable()
    test_the_palette_group_is_clicked_before_the_model()
    test_an_unknown_type_never_places_silently_as_a_router()
    test_an_unsupported_planner_kind_is_skipped_not_substituted()
    test_generate_rejects_an_unsupported_kind_without_substituting()
    print("ALL TESTS PASSED")
