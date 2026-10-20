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
}

# Kinds the planner can name but the executor cannot place yet. They are kept
# equal to `unsupportedDeviceKinds` in lib/services/nlu/lexicon.dart by
# test_device_palette.py. A kind leaves this set only when DEVICE_PALETTE has
# a real placement path for it; until then no substitute is placed.
UNSUPPORTED_DEVICE_KINDS = {
    "hub",
    "bridge",
    "repeater",
    "mcu",
    "sbc",
    "plc",
    "analog-phone",
    "voip-adapter",
    "cell-tower",
    "central-office",
    "controller",
    "sniffer",
    "historian",
    "cyber-observer",
    "power-distribution",
}


def ordered_models(requested: str, catalog: list) -> list:
    """Requested node model (from instruction) first, then catalog order."""
    req = (requested or "").strip()
    if req and req in catalog:
        return [req] + [m for m in catalog if m != req]
    if req:
        return [req] + catalog
    return catalog
