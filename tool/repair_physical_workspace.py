"""Repair the Physical Workspace of an already-generated .pkt save.

The 48-device GUI-Services-48 build dropped Cloud-PT into the Logical
workspace because its saved variant carried no PHYSICAL_CPUR; Packet Tracer
then refused the file with "File contains corrupted Physical Workspace data."
The current builder grafts a donor at build time. This tool applies the same
repair to a file produced before that fix.

    python tool/repair_physical_workspace.py \
        --source build/gui-stress-20261118/exports/GUI-Services-48-native-open-failed.pkt \
        --output build/gui-stress-20261118/exports/GUI-Services-48-repaired.pkt
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

parser = argparse.ArgumentParser()
parser.add_argument("--library", default="sidecar/pkt_templates")
parser.add_argument("--source", required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()

sys.path.insert(0, str(ROOT / "sidecar"))

import pkt_builder  # noqa: E402
import pkt_codec  # noqa: E402

library = pkt_builder.load_library(str(ROOT / args.library))
source = Path(args.source)
repaired, warnings = pkt_builder.repair_physical_workspace(
    pkt_codec.decrypt_pkt(source.read_bytes()), library,
    project=source.stem)

output = Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(pkt_codec.encrypt_pkt(repaired))
print(f"wrote {output} ({output.stat().st_size} bytes)")
for warning in warnings:
    print("warning:", warning)
