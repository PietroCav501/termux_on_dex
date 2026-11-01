#!/usr/bin/env python3
"""I glifi a linee diventano sagome piene (GTK ricolora solo i riempimenti delle icone simboliche).

Si lancia a mano quando glifi.py cambia (serve Inkscape, ~0,3 s a glifo): scrive contorni.json,
che il generatore delle icone usa così com'è, senza bisogno di Inkscape sul telefono.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, QUI)
from glifi import GLIFI  # noqa: E402


def pulisci_stile(m):   # dello stile di Inkscape servono solo regola di riempimento e opacità
    tieni = [v for v in m.group(1).split(";") if v.split(":")[0] in ("fill-rule", "opacity") and v != "opacity:1"]
    return f' style="{";".join(tieni)}"' if tieni else ""


def main():
    nomi = sorted(GLIFI)
    with tempfile.TemporaryDirectory() as d:
        azioni = []
        for k, n in enumerate(nomi):
            src, dst = os.path.join(d, f"{k}.svg"), os.path.join(d, f"{k}-p.svg")
            with open(src, "w") as f:
                f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">{GLIFI[n]}</svg>')
            azioni.append(f"file-open:{src};select-all:all;object-stroke-to-path;select-all:all;object-to-path;"
                          f"export-filename:{dst};export-plain-svg;export-do;file-close")
        for i in range(0, len(azioni), 40):   # Inkscape in blocchi: una riga di azioni lunghissima lo rallenta
            subprocess.run(["inkscape", "--actions=" + ";".join(azioni[i:i + 40])], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out = {}
        for k, n in enumerate(nomi):
            t = open(os.path.join(d, f"{k}-p.svg")).read()
            corpo = re.sub(r"(?s)^.*?<svg[^>]*>", "", t)
            corpo = re.sub(r"(?s)</svg>\s*$", "", corpo)
            corpo = re.sub(r"(?s)<(defs|metadata|sodipodi:namedview)\b.*?(/>|</\1>)", "", corpo)
            corpo = re.sub(r'\s(id|inkscape:[a-z-]+|sodipodi:[a-z-]+)="[^"]*"', "", corpo)
            corpo = re.sub(r'\sstyle="([^"]*)"', pulisci_stile, corpo)
            corpo = re.sub(r"-?\d+\.\d{3,}", lambda m: f"{float(m.group(0)):.2f}".rstrip("0").rstrip("."), corpo)
            corpo = re.sub(r"\s+", " ", corpo).strip()
            if "stroke-width" in corpo and 'stroke:none' not in corpo and "stroke=\"none\"" not in corpo and "stroke:#" in corpo:
                print("ancora linee:", n, file=sys.stderr)
            out[n] = corpo
    with open(os.path.join(QUI, "contorni.json"), "w") as f:
        json.dump(out, f, indent=0, sort_keys=True)
    print(len(out), "glifi")


if __name__ == "__main__":
    main()
