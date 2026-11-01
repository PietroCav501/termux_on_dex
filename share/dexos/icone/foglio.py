#!/usr/bin/env python3
"""Foglio di prova dei glifi DeX OS: ognuno a 16, 24 e 48 px, su chiaro e su scuro, con il nome.

  foglio.py FILE.png [colonne]
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glifi import GLIFI  # noqa: E402


def foglio(path, colonne=8):
    cella_w, cella_h = 150, 96
    nomi = list(GLIFI)
    righe = (len(nomi) + colonne - 1) // colonne
    w, h = colonne * cella_w, righe * cella_h
    out = [f'<rect width="{w}" height="{h}" fill="#f3f3f5"/>']
    for i, n in enumerate(nomi):
        x, y = (i % colonne) * cella_w, (i // colonne) * cella_h
        scuro = (i // colonne + i % colonne) % 2
        fondo, colore = ("#26262b", "#f2f2f5") if scuro else ("#fbfbfd", "#1c1c21")
        out.append(f'<rect x="{x + 2}" y="{y + 2}" width="{cella_w - 4}" height="{cella_h - 4}" rx="10" fill="{fondo}"/>')
        corpo = GLIFI[n].replace('stroke="#000"', f'stroke="{colore}"').replace('fill="#000"', f'fill="{colore}"')
        for k, (s, ox) in enumerate(((16, 12), (24, 36), (48, 70))):
            out.append(f'<g transform="translate({x + ox} {y + 10 + (48 - s) / 2}) scale({s / 16})">{corpo}</g>')
        out.append(f'<text x="{x + cella_w / 2}" y="{y + cella_h - 12}" text-anchor="middle" font-family="Inter, sans-serif" '
                   f'font-size="11" fill="{colore}" opacity=".75">{n}</text>')
    s = f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">{"".join(out)}</svg>'
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(s)
    try:
        subprocess.run(["rsvg-convert", "-o", path, f.name], check=True)
    finally:
        os.unlink(f.name)


if __name__ == "__main__":
    foglio(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 8)
