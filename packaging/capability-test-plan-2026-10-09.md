# Complex capability test script — a three-site enterprise lab (2026-10-09)

Every turn below was run through the real planner, advisor, layout engine and
design applier before this document was written, so what each one produces is
what the app actually does. The numbers in *Expect* are measured, not guessed.

Send ONE turn at a time and wait for the answer — the interesting behaviour is
in the follow-ups, not only in the opening brief.

> **Plan the whole thing in one sentence first, then break it.** The opening
> brief is deliberately over the top: multi-site, multi-tier, five services,
> VLANs, a VPN and three separate security features. It is the single best
> stress test of the parser in the app.

## 1 — The brief (parser: multi-clause, multi-site, multi-tier)

```
Build a three-site enterprise network. HQ needs 2 routers running HSRP, 1
firewall for the internet edge, 2 core multilayer switches, 2 access
switches, a WLC with 3 access points, 20 PCs, a DHCP server, a DNS server, a
TACACS+ AAA server and a web server. Each of two branch offices needs 1
router, 1 switch and 8 PCs. Use OSPF everywhere, put HQ users on VLAN 10,
branch users on VLAN 20 and management on VLAN 99, connect every site with an
IPsec VPN over a serial WAN link, and turn on port security plus DHCP
snooping on the access switch ports.
```

**Expect:** 40 devices, 38 links, VLANs `[10, 20, 99]`, routing `ospf`, and
`Understood` at high confidence.

**Watch for — this is the bug cluster to confirm.** The brief asks for 4
routers, 6 switches, 36 PCs and 4 servers. Measured, it plans **40 devices:
3 routers, 2 switches, 28 PCs, 1 server** (plus firewall, 3 APs, WLC, cloud).
Every one of those numbers is short:

| Asked | Planned | Why it matters |
|---|---|---|
| 4 routers (2 HQ + 1 per branch ×2) | **3** | the branch multiplier counts once, not per site |
| 6 switches (2 core + 2 access + 1 per branch ×2) | **2** | see below |
| 36 PCs (20 HQ + 8 per branch ×2) | **28** | 20 + 8, not 20 + 16 |
| 4 servers (DHCP, DNS, AAA, web) | **1** |

The through-line: **a quantity in a comma-separated list is only counted once
per noun, however many qualifications it carries.** Isolated, "2 core
multilayer switches and 2 access switches" → 1 switch, while the bare "2
switches and 2 access switches" → 2. Same for "a DHCP server, a DNS server, a
TACACS+ AAA server and a web server" → 1 server. If the Understood card reads
`1 switch` / `4 device(s), 1 link(s)` anywhere in this flow, that is the bug,
not a misreading of your words.

## 2 — Correction (must replace, not add)

```
Actually make it 30 PCs at HQ and add a second web server for the DMZ
```

**Expect:** 30 PCs at HQ, 2 web servers, everything else unchanged.

**Watch for:** a correction combined with an addition. Isolated on a
20-PC base, "actually make it 30 PCs" alone correctly gives **30**, but the
same sentence with "and add a second web server" on the end gives **50** — the
correction is applied on top of the existing 20 instead of replacing them.

## 3 — The "more than N" floor

```
I also need more than 6 laptops for the sales floor
Add more than six laptops
```

**Expect:** **7 laptops** — the floor plus one. Not 6, not a pile.

**Watch for:** the word-number form. "more than 6 laptops" gives 7 devices;
"add more than **six** laptops" gives 7 laptops but **9 devices** — two extra
devices appear that nobody asked for.

## 4 — What-if (must NOT change the lab)

```
Could we build it with EIGRP instead?
```

**Expect:** an answer comparing EIGRP with OSPF, followed by
**"Nothing in your lab changed"**. The plan still reads `ospf` afterwards —
the tentative gate. Say "build it" after this and the card must still be the
three-site OSPF lab.

## 5–7 — Design advice (recommendation first, then options)

```
What switch should I use for the HQ core?
What firewall do we need for an office with guests?
How many access points do I need for 40 users?
```

**Expect** for each: a highlighted recommendation, 2–4 options with a
"Choose it when" and a "Trade-off", a **Base on:** provenance line, and **no
invented prices**. The advice card's **Plan this** button sends a sentence that
carries the scale — ask "what firewall do we need for an office with guests?"
after having said 40 users and the chip should read "Plan a small office with
40 employees, …`.

## 8 — Two intents in one turn

```
Add a switch to the HQ core, and what cable should I use between the two
buildings?
```

**Expect:** the plan takes the new switch **and** the answer addresses the
cabling (the answer part works today — it returns the straight-through /
crossover / console cheat sheet). Watch the switch count: this is the second
place the §1 counting bug shows up.

## 9 — Layouts (six different drawings, one at a time)

```
Draw it as site trees
Put the servers on one side and the routers on the other
Make it compact
Give each kind of device its own column
Draw it as a two-tier campus
Put every device in one circle
```

**Expect:** six genuinely different silhouettes — a nested tree, two parked
zones, a tighter tree, one column per kind, aligned core/access tiers, and one
ring. All six place every device exactly once on the canvas, and the preview
and the built `.pkt` share the same geometry. "Put the servers on one side and
the routers on the other" should read as **two zones** (servers left, routers
right), not one.

## 10 — Named design vs shorthand-alias design

```
Rebuild it with the DMZ design
Small office design please
Use the flat lab
```

**Expect:** the first and third are **applied** — naming a design by its own
name is honoured, which is the promise the design review makes, and it is
applied even when the plan is smaller than the catalog's stated range. The
second is **refused**: "small office" is the `soho` design, built for 1–15
hosts, and this lab has 40. A refusal must *say so* rather than silently doing
nothing.

## 11 — Build and open the file

```
Build the .pkt
```

**Expect:** a preflight card (target, plan, open assumptions), then a file
path in the answer. **Tap the path** — with Packet Tracer installed it opens
there, otherwise the built-in viewer draws the network at the same
coordinates. The `Open assumptions` line should be honest about anything it
could not verify.

## 12 — Verify and troubleshoot

```
Are there any problems with this network?
VLAN 20 has no internet — where do I start?
A PC on VLAN 10 cannot get an address
```

**Expect:** named findings with severity, then numbered ladders with a real
first command — not a lecture.

## What a PASS looks like

What a PASS looks like

| # | Capability | Pass signal |
|---|---|---|
| 1 | Multi-site multi-clause parse | 40 devices, 3 sites, VLANs 10/20/99, OSPF — **and the counts the brief actually asked for** |
| 2 | Correction | 30 PCs (replaces), 2 web servers, rest intact |
| 3 | "more than N" floor | 7 devices for both digit and word forms |
| 4 | Tentative language | answered, lab unchanged, "Nothing in your lab changed" |
| 5–7 | Advice | recommendation first, options + trade-offs, provenance, no prices |
| 8 | Two intents in one turn | switch added **and** cabling answered |
| 9 | Layouts | six different drawings, every device placed once, two zones for servers/routers |
| 10 | Named vs shorthand design | DMZ and flat lab applied; "small office" refused **with a reason** |
| 11 | Build + open | preflight card; tapping the path opens PT or the viewer |
| 12 | Verify + troubleshoot | findings with severity; numbered ladders |

## Bugs already measured in this build — confirm or clear them

These are real findings from running the script through the planner, not
guesses. If any is already fixed by the time you read this, the test changes
to a PASS.

1. **Quantities are not summed across qualifications.** Measured on the §1
   brief: 4 routers asked → **3**; 6 switches → **2**; 36 PCs → **28**; 4
   servers → **1**. A per-site multiplier ("Each of two branch offices needs
   …") applies only to the first quantity in the list, and repeated
   differently-qualified nouns count once.
2. **A correction plus an addition re-plans instead of correcting.**
   "Actually make it 30 PCs … and add a second web server" → **50 PCs** on a
   20-PC base. The correction alone gives 30. (§2)
3. **A word-numbered floor adds extra devices.** "add more than six laptops" →
   7 laptops but **9 devices**. (§3)

## Not a bug

- A plan above 50 devices is refused with that reason: that is the safety gate
  at `validator_service.dart:734`, and it is doing its job. Keep this brief
  under it or split the lab.
- With no API key every answer comes from the offline brain, and the app says
  so rather than pretending otherwise.
- Memory > forget removes anything learned on request.
