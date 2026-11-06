"""Generate the NetBuilder AI application icon.

Draws a rounded-square tile with a navy gradient and a network-topology
motif (nodes joined by links), supersampled for crisp small sizes, then
writes:

  windows/runner/resources/app_icon.ico  (256/64/48/32/24/16, 32bpp)
  assets/app_icon.png                    (512, used by the About panel)
  dist/app_icon_preview.png              (1024, for review only)

Run from the repo root:  python tool/make_app_icon.py
"""

from __future__ import annotations

import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent

# Supersample factor: everything is drawn at this multiple and downscaled
# with LANCZOS, so 16 px keeps antialiased edges.
S = 4
SIZE = 1024 * S

# Palette
GRAD_TOP = (32, 52, 94)  # indigo navy
GRAD_BOTTOM = (12, 20, 38)  # near-black navy
LINK = (86, 196, 240)  # cyan
LINK_DIM = (64, 130, 180)
NODE_WHITE = (238, 246, 255)
NODE_CYAN = (96, 205, 245)
NODE_GREEN = (86, 214, 166)
GLOW = (70, 160, 230)

# Rounded-square corner radius, Windows 11 app-tile proportion (~22%).
RADIUS = 230 * S
MARGIN = 64 * S


def rounded_tile() -> Image.Image:
    """The gradient tile with rounded corners on transparency."""
    tile = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    grad = Image.new("RGBA", (SIZE, SIZE))
    px = grad.load()
    for y in range(SIZE):
        # Vertical gradient with a slight diagonal lean.
        t = (y / SIZE) * 0.85 + ((SIZE - y) / SIZE) * 0.0
        r = int(GRAD_TOP[0] + (GRAD_BOTTOM[0] - GRAD_TOP[0]) * t)
        g = int(GRAD_TOP[1] + (GRAD_BOTTOM[1] - GRAD_TOP[1]) * t)
        b = int(GRAD_TOP[2] + (GRAD_BOTTOM[2] - GRAD_TOP[2]) * t)
        for x in range(0, SIZE, S):
            for dx in range(S):
                px[x + dx, y] = (r, g, b, 255)
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, SIZE - 1, SIZE - 1), radius=RADIUS, fill=255
    )
    tile.paste(grad, (0, 0), mask)
    return tile


def build_topology(scale: int = SIZE) -> tuple[Image.Image, Image.Image]:
    """Return (links layer, nodes layer) at the given working size."""
    # Node positions in 1024-space, scaled to the working size.
    pts = {
        "tl": (322, 318),
        "tr": (706, 252),
        "c": (512, 522),
        "bl": (296, 714),
        "br": (736, 668),
    }
    radii = {"tl": 64, "tr": 46, "c": 84, "bl": 50, "br": 60}
    edges = [
        ("tl", "tr"),
        ("tl", "c"),
        ("tr", "c"),
        ("c", "bl"),
        ("c", "br"),
        ("bl", "br"),
        ("tl", "bl"),
        ("tr", "br"),
    ]
    k = scale / 1024
    p = {name: (x * k, y * k) for name, (x, y) in pts.items()}
    r = {name: rad * k for name, rad in radii.items()}

    links = Image.new("RGBA", (scale, scale), (0, 0, 0, 0))
    d = ImageDraw.Draw(links)
    width = max(1, round(17 * k))
    for a, b in edges:
        d.line((p[a], p[b]), fill=LINK_DIM + (235,), width=width)
    # Bright core on each link for a lit-wire look.
    thin = max(1, round(width * 0.45))
    for a, b in edges:
        d.line((p[a], p[b]), fill=LINK + (255,), width=thin)
    return links, (p, r)


def draw_nodes(layer: Image.Image, geom: tuple[dict, dict]) -> None:
    p, r = geom
    d = ImageDraw.Draw(layer)
    colors = {
        "tl": NODE_WHITE,
        "tr": NODE_WHITE,
        "c": NODE_CYAN,
        "bl": NODE_WHITE,
        "br": NODE_GREEN,
    }
    for name, (x, y) in p.items():
        rad = r[name]
        # Halo
        halo = rad * 1.55
        d.ellipse(
            (x - halo, y - halo, x + halo, y + halo),
            fill=colors[name] + (36,),
        )
        # Body
        d.ellipse(
            (x - rad, y - rad, x + rad, y + rad),
            fill=colors[name] + (255,),
        )
        # Glossy highlight offset towards the top-left light source.
        shine = rad * 0.34
        d.ellipse(
            (x - rad * 0.5 - shine, y - rad * 0.5 - shine,
             x - rad * 0.5 + shine, y - rad * 0.5 + shine),
            fill=(255, 255, 255, 75),
        )


def main() -> None:
    tile = rounded_tile()

    # Glow pass: blur the topology and screen it under the crisp layer.
    links, geom = build_topology()
    glow = links.filter(ImageFilter.GaussianBlur(28 * (S / 4)))
    tile.alpha_composite(glow)
    tile.alpha_composite(links)
    nodes = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_nodes(nodes, geom)
    node_glow = nodes.filter(ImageFilter.GaussianBlur(20 * (S / 4)))
    tile.alpha_composite(node_glow)
    tile.alpha_composite(nodes)

    final = tile.resize((1024, 1024), Image.LANCZOS)

    # 16 px legibility pass: thicken what survives the downscale by
    # deriving the small sizes from a slightly bolder drawing.
    small_src_size = 1024
    links_s, geom_s = build_topology(small_src_size * S)
    tile_s = rounded_tile()
    tile_s.alpha_composite(links_s)
    nodes_s = Image.new("RGBA", (small_src_size * S, small_src_size * S), (0, 0, 0, 0))
    draw_nodes(nodes_s, geom_s)
    tile_s.alpha_composite(nodes_s)
    small_master = tile_s.resize((256, 256), Image.LANCZOS)

    out_ico = ROOT / "windows/runner/resources/app_icon.ico"
    out_ico.parent.mkdir(parents=True, exist_ok=True)

    # Pillow composes the .ico from the provided images; every size comes
    # from the same master so the set stays consistent.
    sizes = [(256, 256), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)]
    rendered = {s: small_master.resize(s, Image.LANCZOS) for s in sizes}
    rendered[(256, 256)].save(
        out_ico,
        format="ICO",
        sizes=sizes,
        append_images=[rendered[s] for s in sizes[1:]],
    )

    out_png = ROOT / "assets/app_icon.png"
    out_png.parent.mkdir(parents=True, exist_ok=True)
    final.resize((512, 512), Image.LANCZOS).save(out_png)

    preview = ROOT / "dist/app_icon_preview.png"
    preview.parent.mkdir(parents=True, exist_ok=True)
    final.save(preview)

    # Verify the .ico directory.
    data = out_ico.read_bytes()
    count = struct.unpack("<H", data[4:6])[0]
    entries = []
    for i in range(count):
        w, h, _, _, _, bpp, size, _ = struct.unpack(
            "<BBBBHHII", data[6 + i * 16 : 22 + i * 16]
        )
        entries.append(f"{w or 256}x{h or 256} bpp={bpp} bytes={size}")
    print(f"wrote {out_ico} with {count} images:")
    for e in entries:
        print("  " + e)
    print(f"wrote {out_png}")
    print(f"wrote {preview}")


if __name__ == "__main__":
    main()
