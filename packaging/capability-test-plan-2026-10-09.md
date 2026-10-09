# Capability test plan - a deliberately complicated network (2026-10-09)

A single brief plus a scripted turn sequence, sized to exercise the planner,
the offline assistant, the advisor, the layout reader and the `.pkt`
compiler - while staying under the 50-device refusal ceiling
(`validator_service.dart:734`).

**Device budget: 38 + the internet cloud.** Nothing here is expected to be
refused.

## The network being described

```
                    (cloud: internet)
                           |
                         FW1            firewall, internet edge
                           |
              +------------+------------+
              |                         |
             R1                        R2        HSRP pair, VLAN 99 mgmt
              |                         |
            CORE1 ------------------- CORE2     multilayer, distribution
              |                         |
             SW1                       SW2      access switch x2
              |  \                       |
       15x PC      AP1 AP2 AP3             |    WLC1
                  \___WLC1____/            |
                                          |
        DHCP1 (dhcp+dns)   AAA1 (tacacs+)   WEB1 (http)

BR1:  BR_R1 ==serial WAN, OSPF, IPsec VPN== R2
        |
      BR_SW1 --- 6x BR_PC
```

HQ = 30 devices, BR1 = 8, total 38.

## Prompt sequence

Paste ONE prompt per turn and wait for each answer before sending the next.
The app is conversational by design, so the interesting behaviour is in the
follow-ups, not only in the first brief.

### 1. The brief - multi-clause, multi-site, mixed vocabulary

```
Build a two-site enterprise network. HQ needs 2 routers running HSRP, 1
firewall for the internet edge, 2 core multilayer switches, 2 access
switches, a WLC with 3 access points, 15 PCs, a DHCP server, a DNS server, a
TACACS+ AAA server and a web server. The branch needs 1 router, 1 switch and
6 PCs. Use OSPF everywhere, put the HQ user PCs on VLAN 10 and the branch PCs
on VLAN 20, keep management on VLAN 99, connect the two sites with an IPsec
VPN over a serial WAN link, and turn on port security plus DHCP snooping on
the access switch ports.
```

Exercises: two sites counted separately, quantities across clauses,
"TACACS+ AAA" and "WLC" vocabulary, VLANs, OSPF, serial WAN, IPsec,
port security, DHCP snooping, and the HSRP/AAA/server services.

Check: the Understood card reports ~38 devices and 2 sites; the router count
is 3 (2 HQ + 1 branch) not 2+1 mistyped; VLAN 10/20/99 appear; routing reads
OSPF.

### 2. Correction that must stick

```
Actually make it 25 PCs at HQ, and add a second web server for the DMZ.
```

Check: 25 PCs (not 15), the web server count is 2, and the correction
survives the NEXT turn (say "build it" later and the card must still read 25).

### 3. The "more than N" floor

```
I also need more than 6 laptops for the sales floor.
```

Check: it adds **7** (the floor plus one), not 6 and not a pile.

### 4. A what-if that must NOT touch the lab

```
Could we build it with EIGRP instead?
```

Check: an answer discussing EIGRP vs OSPF, plus **"Nothing in your lab
changed"** - the tentative gate. The plan still says OSPF afterwards.

### 5. Design advice

```
What switch should I use for the HQ core?
```

Check: a recommendation first, 2-4 options with "choose this when" and a
trade-off, a "Based on:" line, and no invented prices. The advice card's
**Plan this** button should be available.

### 6. Environment profile

```
This is for a company with 300 users, and I'm a beginner.
```

Check: a later advice answer uses those facts without being asked again
(Memory > Environment tab shows them; forget it with one tap).

### 7. Two intents in one turn

```
Add a switch to the HQ core, and what cable should I use between the two
buildings?
```

Check: the plan takes the new switch AND the answer addresses the cabling
question. This is the mixed device-count + WH-word path.

### 8. Layout requests, one each

```
Draw it as a spine and leaf.
```
```
Put the servers on one side and the routers on the other.
```
```
Make it compact.
```

Check: three genuinely different drawings in the gallery - not three sizes
of the same tree. The servers/routers request should read as two zones.

### 9. The build, and opening the file

```
Build the .pkt
```

Check: a build card with a preflight, then a file path in the answer. **Tap
the path** - with Packet Tracer installed it opens there, otherwise the
built-in viewer draws the network at the same coordinates.

### 10. Verification and troubleshooting

```
Are there any problems with this network?
```
```
VLAN 20 has no internet - where do I start?
```

Check: findings are named with a concrete first step (a command, not a
lecture), and the troubleshooting ladder is numbered.

## What a PASS looks like

| # | Capability | Pass signal |
|---|---|---|
| 1 | Multi-site multi-clause parse | ~38 devices, 2 sites, VLANs 10/20/99, OSPF |
| 2 | Corrections stick | 25 PCs, 2 web servers, survives the next turn |
| 3 | "more than N" floor | 7 laptops |
| 4 | Tentative language | answered, lab unchanged, "Nothing in your lab changed" |
| 5 | Advice | recommendation first, options + trade-offs, provenance, no prices |
| 6 | Environment profile | later answers reuse 300 users / beginner unasked |
| 7 | Two intents in one turn | switch added AND cabling answered |
| 8 | Layout | three different drawings, two zones for servers/routers |
| 9 | Build + open | card with preflight; tapping the path opens PT or the viewer |
| 10 | Verify + troubleshoot | findings with a concrete first step; numbered ladder |

## Failure that is NOT a bug

- A plan above 50 devices is refused with that reason - that is the safety
  gate working (`validator_service.dart:734`), not a parse failure.
- Without an API key every answer comes from the offline brain; the app says
  so rather than pretending otherwise.

## Rollback

Nothing is changed by running this sequence except the conversation's own
memory. Memory > forget removes anything learned on request.
