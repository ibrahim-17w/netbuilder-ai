# Layer-2, VLAN and routing features in the offline planner — 2026-09-24

Everything below is the **offline** path (no API key, no model, no Packet
Tracer): `NetworkIntent.parseSimple` → `CiscoAdapter.render` /
`PacketTracerAdapter` → `pkt_builder`. The point of the batch is that a
course brief asking for VLANs, a routing protocol, SSH, HSRP,
spanning-tree or an EtherChannel is now planned and configured without the
LLM ever being consulted.

## Routing protocols were static-routes-only

* **EIGRP** — one process (`router eigrp 10`), `no auto-summary`, and one
  `network <base> <wildcard>` per connected subnet the router owns. The
  protocol replaces the static routes instead of stacking on them.
* **BGP** — `router bgp 65001` with `bgp log-neighbor-changes`, one
  `neighbor <peer-ip> remote-as 65001` per transit peer (iBGP between the
  plan's own routers, read from the plan's addressing), and each LAN
  advertised with `network <base> mask <mask>`. The transit subnet is
  deliberately *not* advertised.

## Router-on-a-stick (VLANs and inter-VLAN routing)

* VLAN numbers are extracted **before** addressing now, because the slot
  list has to exist before the LAN pass runs. `vlan 10`, `vlans 10, 20, 30`,
  `vlan 10 and 20` all parse.
* "VLANs + a router + a switch" now means router-on-a-stick unless the brief
  says "flat network". Each VLAN gets its own subnet in documentation space
  — **VLAN 20 lives in `192.168.20.0/24`** — the router's physical uplink
  stays unaddressed (it is a trunk) and one `InterfaceAddr` row per VLAN
  (`<uplink>.<vlan>`, e.g. `g0/1.10`) is written. Endpoints are spread
  round-robin over the VLANs so every VLAN is populated and testable.
* The adapter renders those rows as the IOS block: `interface g0/1.10` /
  `encapsulation dot1Q 10` / `ip address` / `no shutdown`, then `no
  shutdown` on the parent trunk. The switch side gets `switchport mode
  trunk`, `switchport trunk allowed vlan 10,20`, a native VLAN, and access
  ports per VLAN.
* Packets on the switch uplink or trunk are the *plan's own rows*, so the
  sub-interfaces, the PCs' gateways and the DHCP pools can never disagree.
* **One DHCP pool per VLAN** on the server: pool name `VLAN<N>`, gateway =
  the matching sub-interface address, first lease `x.x.x.50` (low addresses
  stay free for statically addressed gear), `/24` mask, 100 users.

Sidecar (`pkt_builder.py`) had to learn the same shape: a dot1Q
sub-interface must not claim a port of its own (only its parent is
hardware), `g0/0.10` on a 2811 remaps to `FastEthernet0/0.10` with the VLAN
suffix intact using the *same* parent resolution as the links, and the
sub-interface address is never mirrored onto the physical port element (the
parent is a trunk; mirroring it would break the other VLANs).

## Secure access and gateway redundancy

* **SSH** — `ip domain-name`, `crypto key generate rsa` (1024), a local
  `admin` account, then `line vty 0 4` with `transport input ssh` and
  `login local`. Asked for on switches too. SSH wording on a brief that also
  mentions telnet/VTY turns telnet **off** rather than stacking both.
* **`enable secret`** — read from the original text so the secret's case
  survives (`enable secret Cl4ss2026`).
* **HSRP** — `standby 1 ip <virtual>` plus `priority`/`preempt` on the
  router's LAN interfaces only (transit links excluded). The virtual IP is
  read from the brief when stated ("HSRP 192.168.1.254"), otherwise `.254`
  of the LAN subnet. VRRP/GLBP wording is accepted and routed to HSRP
  because that is what Packet Tracer's images implement.
* **Spanning-tree** — `spanning-tree mode rapid-pvst` with the first switch
  pinned `root primary` for the plan's VLANs.
* **EtherChannel** — LACP (`active`/`passive`) by default, PAgP
  (`desirable`/`auto`) when the brief says so, both sides naming
  `channel-group 1`.

### EtherChannel needed a cable to exist (fixed on this pass)

The first pass rendered the `channel-group` lines but the deterministic
layout gives each switch its **own** router uplink (`SW1→R1`, `SW2→R2`), so
"an etherchannel between the switches" had no interfaces facing each other
and the switches came out with no channel-group at all — `test/offline_
planner_test.dart` caught it. The planner now notices the missing cable: if
a bundle is asked for and the first two switches are not linked, they are
cabled on their last ports (`f0/23`, `f0/24`) as a **two-member bundle**, so
`Po1` is a real EtherChannel rather than a single-link stub. Briefs that
cable the switches themselves are left exactly as written. The assumption
text now names the two switches and asks for matching member ports.

## Validator

* Interface names accept dot1Q sub-interfaces (`g0/1.10`) instead of
  flagging the router-on-a-stick rows as typos.
* Services `cme` and `radiuseap` are known, so a plan that carries them
  validates.
* New structural checks: EtherChannel with fewer than two switches is an
  **error**; inter-VLAN routing with no VLANs is a warning and with no
  router an **error**; HSRP with no router holding a LAN interface is a
  warning. A shared `_isTransitEndpoint` helper keeps the planner's and the
  validator's definition of a transit link identical.

## Adapter service coverage

`radiuseap` passes the AAA server's EAP method list through to the Services
tab (WPA-Enterprise), and `cme` the telephony parameters.
Known loose end: the **offline** parser has no wording that produces
`radiusEap` yet — only the LLM path can request it.

## Verification

* `test/offline_planner_test.dart` — 27 cases, all green, including the new
  EIGRP, BGP, SSH/HSRP/STP/EtherChannel and VLAN tests.
* `sidecar/test_pkt_generator.py` — 81 passed (4 new: sub-interfaces never
  claim a port, remap keeps the VLAN suffix, sub-interface address is not
  mirrored onto the parent, router/trunk/HSRP lines survive into the saved
  config).
* Full suites: `flutter test` **396 passed**; `flutter analyze` clean;
  `pytest sidecar` 432 passed with one pre-existing, environment-dependent
  failure (`test_ocr_perf.py::test_golden_ocr_text_matches_recorded_baseline`
  — Tesseract output vs. a recorded baseline; untouched by this batch).
