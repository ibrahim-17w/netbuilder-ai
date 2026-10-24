"""Packet Tracer device catalog and palette paths.

The executor used to carry this table next to its click code. Keeping it in a
leaf module lets the planner/tests import the same names without importing the
RPA stack, and gives the sidecar's catalog split one obvious home.

`DEVICE_PALETTE` maps a planner kind to the PT category group, the sub-list,
the acceptable model names in priority order, the strip column used by the CAL
fallback, and the taught category anchor for that group.
"""

from __future__ import annotations

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
HUB_MODELS = ["Hub-PT", "Hub"]
SNIFFER_MODELS = ["Sniffer", "Packet Sniffer"]
PLC_MODELS = ["PLC-PT", "PLC"]
HISTORIAN_MODELS = ["DataHistorianServer", "Data Historian Server"]
CYBER_OBSERVER_MODELS = ["CyberObserver", "Cyber Observer"]
CONTROLLER_MODELS = ["NetworkController", "Network Controller"]
POWER_DISTRIBUTION_MODELS = ["Power Distribution Device", "PDU-PT"]

# Palette path per device kind: the PT category group, the sub-list (empty
# when the category opens straight onto its model row, as Security does), the
# acceptable model names in priority order, the strip column used by the CAL
# fallback, and the taught category anchor for that group. One table instead
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
    # The kinds below were offline-only until a live palette path was taught
    # for each. Their groups follow the same shape the rest of the table
    # uses: End Devices opens onto a list of named rows; Network Devices ->
    # IoT Devices holds the industrial/control shapes; Security holds the
    # sniffer. A kind leaves OFFLINE_ONLY_DEVICE_KINDS only by moving here.
    "hub": (("Network Devices", "Network Device"),
            ("Hubs", "Hub"), HUB_MODELS, 0, "pal_router"),
    "sniffer": (("Security", "Security Devices"), (), SNIFFER_MODELS, 0,
                "pal_security"),
    "plc": (("Network Devices", "Network Device"),
            ("IoT Devices", "IoT", "PLC"), PLC_MODELS, 0, "pal_router"),
    "historian": (("Network Devices", "Network Device"),
                  ("IoT Devices", "IoT", "Historian"), HISTORIAN_MODELS, 2,
                  "pal_router"),
    "cyber-observer": (("Network Devices", "Network Device"),
                       ("IoT Devices", "IoT", "Cyber Observer"),
                       CYBER_OBSERVER_MODELS, 2, "pal_router"),
    "controller": (("Network Devices", "Network Device"),
                   ("IoT Devices", "IoT", "Controller"), CONTROLLER_MODELS, 2,
                   "pal_router"),
    "power-distribution": (("Network Devices", "Network Device"),
                           ("IoT Devices", "IoT", "Power"),
                           POWER_DISTRIBUTION_MODELS, 2, "pal_router"),
}

# Kinds the offline compiler can build from Packet Tracer's own templates but
# the live executor has no palette path for yet. They remain buildable offline;
# a live run skips them with an `offline_only` outcome instead of substituting
# another device. Kept equal to `offlineOnlyDeviceKinds` in
# lib/services/nlu/lexicon.dart by test_device_palette.py.
#
# Empty since the seven industrial/control kinds (hub, sniffer, plc,
# historian, cyber-observer, controller, power-distribution) were taught
# DEVICE_PALETTE entries above; the set stays as the landing place for the
# next offline-buildable kind that has no taught click-path yet.
OFFLINE_ONLY_DEVICE_KINDS = set()

# Kinds the planner can name but neither builder can place yet. They are kept
# equal to `unsupportedDeviceKinds` in lib/services/nlu/lexicon.dart by
# test_device_palette.py. A kind leaves this set only when DEVICE_PALETTE has
# a real placement path for it; until then no substitute is placed.
UNSUPPORTED_DEVICE_KINDS = {
    "bridge",
    "repeater",
    "mcu",
    "sbc",
    "analog-phone",
    "voip-adapter",
    "cell-tower",
    "central-office",
}


def ordered_models(requested: str, catalog: list) -> list:
    """Requested node model (from instruction) first, then catalog order."""
    req = (requested or "").strip()
    if req and req in catalog:
        return [req] + [m for m in catalog if m != req]
    if req:
        return [req] + catalog
    return catalog
