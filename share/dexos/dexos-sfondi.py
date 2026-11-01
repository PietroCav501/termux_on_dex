#!/usr/bin/env python3
"""DeX OS: gli sfondi di Termux On DeX, disegnati qui da zero nel colore d'accento.

  dexos-sfondi.py build [--accent #0067c0] [--size 3840x2160] [--out ~/.local/share/backgrounds/dexos]
      → uno sfondo per famiglia e variante: <famiglia>-<chiaro|scuro>.jpg (PNG se manca GdkPixbuf)
  dexos-sfondi.py anteprima [--accent #0067c0] FILE.png   → tutte le famiglie su un foglio

Quattro famiglie, ognuna chiara e scura:
  fiore       petali con volume (luce su un lato, bordo illuminato, ombra sui petali sotto) e un alone
  seta        nastri di colore che si incrociano, con il riflesso sul bordo e l'ombra sotto
  paesaggio   montagne con il lato in luce e un lago che le riflette; di notte aurora, luna e stelle
  vetro       forme di vetro smerigliato sopra macchie di colore, che dietro di loro si sfocano
Sotto ogni sfondo un fondo a più colori sfumati (non una sola sfumatura), sopra una grana leggera.
I colori vengono tutti dall'accento. Solo Python e rsvg-convert. La composizione regge anche
ritagliata al centro (telefono).
"""
import colorsys
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile

DEFAULT_ACCENT = "#0067c0"
FAMIGLIE = ("fiore", "seta", "paesaggio", "vetro")
W, H = 1920, 1080   # il disegno; si esporta alla dimensione voluta


def hls(h):
    h = h.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return colorsys.rgb_to_hls(r, g, b)


class Tavolozza:
    """i colori di uno sfondo, dall'accento: tonalità vicine, chiare o scure"""
    def __init__(self, accento):
        h, _l, s = hls(accento)
        self.h, self.s = h, max(s, 0.6)

    def t(self, gradi=0, l=0.5, s=None):
        r, g, b = colorsys.hls_to_rgb((self.h + gradi / 360) % 1.0, max(0, min(1, l)),
                                      max(0, min(1, self.s if s is None else s)))
        return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))


class Disegno:
    def __init__(self):
        self.defs, self.corpo, self.n = [], [], 0

    def id(self, p="x"):
        self.n += 1
        return f"{p}{self.n}"

    def lin(self, stops, x1=0, y1=0, x2=0, y2=1):
        i = self.id("l")
        s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
        self.defs.append(f'<linearGradient id="{i}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>')
        return f"url(#{i})"

    def rad(self, c, a=1.0):
        i = self.id("r")
        self.defs.append(f'<radialGradient id="{i}"><stop offset="0" stop-color="{c}" stop-opacity="{a}"/>'
                         f'<stop offset="0.55" stop-color="{c}" stop-opacity="{a * 0.45}"/>'
                         f'<stop offset="1" stop-color="{c}" stop-opacity="0"/></radialGradient>')
        return f"url(#{i})"

    def filtro(self, corpo):
        i = self.id("f")
        self.defs.append(f'<filter id="{i}" x="-40%" y="-40%" width="180%" height="180%">{corpo}</filter>')
        return f"url(#{i})"

    def svg(self):
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'
                f'<defs>{"".join(self.defs)}</defs>{"".join(self.corpo)}</svg>')


def fondo(d, t, scuro, macchie):
    """fondo a più colori: un colore pieno e macchie morbide (gradienti radiali, niente filtri)"""
    d.corpo.append(f'<rect width="{W}" height="{H}" fill="{t.t(0, 0.07 if scuro else 0.95, 0.45)}"/>')
    for (x, y, rx, ry, g, l, a) in macchie:
        d.corpo.append(f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="{d.rad(t.t(g, l, 0.85), a)}"/>')


def grana(d, scuro):
    f = d.filtro('<feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="3" stitchTiles="stitch"/>'
                 '<feColorMatrix type="saturate" values="0"/>'
                 f'<feComponentTransfer><feFuncA type="table" tableValues="0 {0.07 if scuro else 0.05}"/></feComponentTransfer>')
    d.corpo.append(f'<rect width="{W}" height="{H}" filter="{f}"/>')


# --- fiore ----------------------------------------------------------------------------------
def fiore(t, scuro):
    d = Disegno()
    fondo(d, t, scuro, [(300, 200, 700, 500, 30, 0.35 if scuro else 0.86, 0.55),
                        (1650, 900, 800, 520, -30, 0.30 if scuro else 0.84, 0.6),
                        (1150, 560, 700, 600, 0, 0.45 if scuro else 0.80, 0.55)])
    cx, cy = 1120, 840
    d.corpo.append(f'<ellipse cx="{cx}" cy="{cy - 120}" rx="620" ry="520" fill="{d.rad(t.t(0, 0.6 if scuro else 0.72, 0.9), 0.7)}"/>')
    ombra = d.filtro(f'<feDropShadow dx="0" dy="10" stdDeviation="18" flood-color="{t.t(0, 0.12, 0.8)}" '
                     f'flood-opacity="{0.55 if scuro else 0.28}"/>')
    petali = 9
    ordine = sorted(range(petali), key=lambda i: -abs(i - (petali - 1) / 2))   # dall'esterno al centro
    for i in ordine:
        a = 192 + i * (156 / (petali - 1))
        g = -40 + i * 80 / (petali - 1)
        lung = 660 - abs(i - (petali - 1) / 2) * 34
        larg = 168
        base, meta, punta = (t.t(g, 0.22 if scuro else 0.40, 0.95), t.t(g + 10, 0.42 if scuro else 0.58, 0.9),
                             t.t(g + 24, 0.70 if scuro else 0.86, 0.85))
        fill = d.lin([(0, base, 1), (0.55, meta, 0.97), (1, punta, 0.92)], 0, 0, 1, 0)
        luce = d.lin([(0, "#ffffff", 0.0), (0.45, "#ffffff", 0.0), (0.8, "#ffffff", 0.42 if scuro else 0.55),
                      (1, "#ffffff", 0.0)], 0, 1, 0, 0)
        bordo = d.lin([(0, "#ffffff", 0.0), (1, "#ffffff", 0.75)], 0, 0, 1, 0)
        p = (f"M0 0 C {lung * 0.32:.0f} {-larg:.0f} {lung * 0.82:.0f} {-larg * 0.78:.0f} {lung:.0f} 0 "
             f"C {lung * 0.82:.0f} {larg * 0.62:.0f} {lung * 0.32:.0f} {larg * 0.9:.0f} 0 0 Z")
        d.corpo.append(f'<g transform="translate({cx} {cy}) rotate({a:.1f})" filter="{ombra}">'
                       f'<path d="{p}" fill="{fill}"/><path d="{p}" fill="{luce}"/>'
                       f'<path d="{p}" fill="none" stroke="{bordo}" stroke-width="2"/></g>')
    d.corpo.append(f'<ellipse cx="{cx}" cy="{cy}" rx="90" ry="60" fill="{d.rad("#ffffff", 0.55 if scuro else 0.7)}"/>')
    grana(d, scuro)
    return d.svg()


# --- seta -----------------------------------------------------------------------------------
def nastro(y0, spessore, amp, fase, pend):
    n = 48
    top, bot = [], []
    for k in range(n + 1):
        x = -100 + (W + 200) * k / n
        u = k / n
        y = y0 + pend * (x - W / 2) + amp * math.sin(fase + u * math.pi * 1.6)
        s = spessore * (0.55 + 0.45 * math.sin(fase * 0.7 + u * math.pi))
        top.append((x, y))
        bot.append((x, y + s))
    d = f"M {top[0][0]:.1f} {top[0][1]:.1f} " + " ".join(f"L {x:.1f} {y:.1f}" for x, y in top[1:])
    d += " " + " ".join(f"L {x:.1f} {y:.1f}" for x, y in reversed(bot)) + " Z"
    bordo = f"M {top[0][0]:.1f} {top[0][1]:.1f} " + " ".join(f"L {x:.1f} {y:.1f}" for x, y in top[1:])
    return d, bordo


def seta(t, scuro):
    d = Disegno()
    fondo(d, t, scuro, [(200, 900, 800, 500, -30, 0.28 if scuro else 0.86, 0.6),
                        (1700, 150, 800, 500, 35, 0.32 if scuro else 0.88, 0.6),
                        (960, 540, 900, 600, 0, 0.18 if scuro else 0.92, 0.5)])
    ombra = d.filtro(f'<feDropShadow dx="0" dy="14" stdDeviation="22" flood-color="{t.t(0, 0.1, 0.8)}" '
                     f'flood-opacity="{0.6 if scuro else 0.25}"/>')
    nastri = [(300, 260, 120, 0.4, 0.28, -35), (480, 220, 140, 2.2, 0.20, -10), (640, 240, 110, 4.0, 0.12, 15),
              (780, 200, 90, 5.4, 0.05, 35)]
    for (y, sp, amp, fase, pend, g) in nastri:
        corpo, bordo = nastro(y, sp, amp, fase, pend)
        if scuro:
            fill = d.lin([(0, t.t(g - 20, 0.22, 0.9), 1), (0.5, t.t(g, 0.46, 0.95), 1), (1, t.t(g + 20, 0.28, 0.9), 1)], 0, 0, 1, 0)
        else:
            fill = d.lin([(0, t.t(g - 20, 0.62, 0.9), 1), (0.5, t.t(g, 0.50, 0.95), 1), (1, t.t(g + 20, 0.70, 0.9), 1)], 0, 0, 1, 0)
        luce = d.lin([(0, "#ffffff", 0.38 if scuro else 0.5), (0.35, "#ffffff", 0.0), (1, "#000000", 0.18 if scuro else 0.08)])
        d.corpo.append(f'<g filter="{ombra}"><path d="{corpo}" fill="{fill}"/></g><path d="{corpo}" fill="{luce}"/>'
                       f'<path d="{bordo}" fill="none" stroke="#ffffff" stroke-opacity="{0.55 if scuro else 0.8}" stroke-width="2.2"/>')
    grana(d, scuro)
    return d.svg()


# --- paesaggio ------------------------------------------------------------------------------
def montagne(rnd, base, alt, n):
    """[(x, y)] dei punti di una catena: cime alternate a valli"""
    pts, x = [(-60, base)], -60
    passo = (W + 120) / n
    for k in range(n):
        x1 = x + passo * rnd.uniform(0.35, 0.65)
        pts.append((x1, base - alt * rnd.uniform(0.55, 1.0)))
        x += passo
        pts.append((x, base - alt * rnd.uniform(0.05, 0.3)))
    return pts


def paesaggio(t, scuro):
    rnd = random.Random(11)
    d = Disegno()
    orizzonte = 760
    if scuro:
        cielo = d.lin([(0, t.t(15, 0.05, 0.6), 1), (0.6, t.t(-10, 0.14, 0.6), 1), (1, t.t(-30, 0.24, 0.55), 1)])
    else:
        cielo = d.lin([(0, t.t(-5, 0.62, 0.7), 1), (0.55, t.t(15, 0.84, 0.65), 1), (0.8, "#ffe7cf", 1), (1, "#ffd9b8", 1)])
    d.corpo.append(f'<rect width="{W}" height="{H}" fill="{cielo}"/>')
    scena = []
    if scuro:
        for _ in range(220):
            x, y, r = rnd.uniform(0, W), rnd.uniform(0, orizzonte * 0.75), rnd.uniform(0.5, 1.9)
            d.corpo.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{r:.1f}" fill="#fff" opacity="{rnd.uniform(0.25, 0.95):.2f}"/>')
        aurora = d.filtro('<feGaussianBlur stdDeviation="28"/>')
        for k, (g, a) in enumerate(((60, 0.55), (20, 0.4))):
            yy = 210 + k * 70
            pts = " ".join(f"L {x} {yy + 60 * math.sin(x / 260 + k):.0f}" for x in range(0, W + 1, 60))
            d.corpo.append(f'<path d="M 0 {yy} {pts}" fill="none" stroke="{t.t(g, 0.6, 0.9)}" stroke-opacity="{a}" '
                           f'stroke-width="70" filter="{aurora}"/>')
        d.corpo.append(f'<circle cx="1440" cy="230" r="230" fill="{d.rad("#ffffff", 0.18)}"/>')
        falce = d.id("m")   # la falce: la luna meno un cerchio spostato (si vede il cielo, non un disco scuro)
        d.defs.append(f'<mask id="{falce}"><circle cx="1440" cy="230" r="58" fill="#fff"/>'
                      f'<circle cx="1466" cy="214" r="52" fill="#000"/></mask>')
        d.corpo.append(f'<circle cx="1440" cy="230" r="58" fill="#f4f1e8" mask="url(#{falce})"/>')
    else:
        d.corpo.append(f'<circle cx="1380" cy="420" r="420" fill="{d.rad("#fff3dd", 0.95)}"/>')
        d.corpo.append(f'<circle cx="1380" cy="420" r="86" fill="#fffaf2"/>')
    strati = [(orizzonte - 40, 330, 5), (orizzonte - 10, 230, 7), (orizzonte + 5, 150, 9)]
    for i, (base, alt, n) in enumerate(strati):
        pts = montagne(rnd, base, alt, n)
        if scuro:
            ombra_c, luce_c = t.t(-15 + i * 8, 0.20 - i * 0.04, 0.4), t.t(-15 + i * 8, 0.30 - i * 0.05, 0.45)
        else:
            ombra_c, luce_c = t.t(-15 + i * 10, 0.58 - i * 0.12, 0.42), t.t(-15 + i * 10, 0.74 - i * 0.12, 0.38)
        poli = "M " + " L ".join(f"{x:.0f} {y:.0f}" for x, y in pts) + f" L {W + 60} {orizzonte + 40} L -60 {orizzonte + 40} Z"
        g = [f'<path d="{poli}" fill="{ombra_c}"/>']
        for k in range(1, len(pts) - 1, 2):   # il versante in luce (a sinistra di ogni cima, sole a destra... qui da sinistra)
            (xv, yv), (xc, yc), (xn, yn) = pts[k - 1], pts[k], pts[k + 1]
            g.append(f'<path d="M {xc:.0f} {yc:.0f} L {xn:.0f} {yn:.0f} L {xc + (xn - xc) * 0.25:.0f} {orizzonte + 40} '
                     f'L {xc - 10:.0f} {orizzonte + 40} Z" fill="{luce_c}" opacity="0.9"/>')
        foschia = d.lin([(0, "#ffffff", 0.0), (1, "#ffffff", 0.10 if scuro else 0.32)])
        g.append(f'<rect x="-60" y="{base - alt}" width="{W + 120}" height="{alt + 80}" fill="{foschia}"/>')
        scena.append("".join(g))
    d.corpo.extend(scena)
    # il lago: la scena capovolta, sfocata e più scura, con riflessi orizzontali
    acqua = d.lin([(0, t.t(-10, 0.30 if not scuro else 0.12, 0.6), 1), (1, t.t(-20, 0.18 if not scuro else 0.05, 0.6), 1)])
    d.corpo.append(f'<rect y="{orizzonte + 20}" width="{W}" height="{H - orizzonte}" fill="{acqua}"/>')
    sfoca = d.filtro('<feGaussianBlur stdDeviation="3 6"/>')
    d.corpo.append(f'<g transform="translate(0 {2 * (orizzonte + 20)}) scale(1 -1)" opacity="0.45" filter="{sfoca}">'
                   f'{"".join(scena)}</g>')
    for k in range(26):
        y = orizzonte + 30 + k * 12 + rnd.uniform(0, 6)
        x = rnd.uniform(0, W * 0.9)
        d.corpo.append(f'<rect x="{x:.0f}" y="{y:.0f}" width="{rnd.uniform(60, 260):.0f}" height="1.6" fill="#fff" '
                       f'opacity="{rnd.uniform(0.08, 0.28):.2f}"/>')
    grana(d, scuro)
    return d.svg()


# --- vetro ----------------------------------------------------------------------------------
def vetro(t, scuro):
    d = Disegno()
    macchie = [(520, 300, 520, 420, -35, 0.42 if scuro else 0.62, 0.95), (1500, 760, 600, 460, 30, 0.40 if scuro else 0.60, 0.95),
               (1200, 220, 420, 320, 0, 0.48 if scuro else 0.55, 0.9), (420, 900, 460, 300, 55, 0.36 if scuro else 0.70, 0.8)]
    fondo(d, t, scuro, macchie)
    dietro = "".join(f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="{d.rad(t.t(g, l, 0.85), a)}"/>'
                     for (x, y, rx, ry, g, l, a) in macchie)
    sfoca = d.filtro('<feGaussianBlur stdDeviation="40"/>')
    ombra = d.filtro(f'<feDropShadow dx="0" dy="18" stdDeviation="26" flood-color="#000" flood-opacity="{0.45 if scuro else 0.16}"/>')
    forme = [f'<circle cx="1260" cy="470" r="250"/>',
             f'<rect x="560" y="340" width="420" height="420" rx="96" transform="rotate(-12 770 550)"/>',
             f'<rect x="1080" y="760" width="560" height="150" rx="75" transform="rotate(-6 1360 835)"/>']
    for k, f in enumerate(forme):
        cid = d.id("c")
        d.defs.append(f'<clipPath id="{cid}">{f}</clipPath>')
        riflesso = d.lin([(0, "#ffffff", 0.55 if scuro else 0.75), (0.5, "#ffffff", 0.12 if scuro else 0.25),
                          (1, "#ffffff", 0.04 if scuro else 0.1)], 0, 0, 1, 1)
        bordo = d.lin([(0, "#ffffff", 0.9), (1, "#ffffff", 0.15)], 0, 0, 1, 1)
        d.corpo.append(f'<g filter="{ombra}">{f.replace("/>", f" fill=\"{t.t(0, 0.2 if scuro else 0.9, 0.3)}\" fill-opacity=\"0.25\"/>")}</g>'
                       f'<g clip-path="url(#{cid})"><g filter="{sfoca}">{dietro}</g></g>'
                       f'{f.replace("/>", f" fill=\"{riflesso}\"/>")}'
                       f'{f.replace("/>", f" fill=\"none\" stroke=\"{bordo}\" stroke-width=\"2\"/>")}')
    grana(d, scuro)
    return d.svg()


DISEGNI = {"fiore": fiore, "seta": seta, "paesaggio": paesaggio, "vetro": vetro}


def disegna(testo, out, w, h):
    tmp = tempfile.mkdtemp()
    try:
        p = os.path.join(tmp, "s.svg")
        with open(p, "w") as f:
            f.write(testo)
        subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h), "-o", out, p], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        shutil.rmtree(tmp)


def jpeg(png, jpg):
    """PNG → JPEG (qualità 92) con GdkPixbuf: la grana in PNG pesa 6-8 MB a sfondo, in JPEG meno di 1.
    False se GdkPixbuf non c'è (resta il PNG)"""
    try:
        import gi
        gi.require_version("GdkPixbuf", "2.0")
        from gi.repository import GdkPixbuf
        GdkPixbuf.Pixbuf.new_from_file(png).savev(jpg, "jpeg", ["quality"], ["92"])
        return True
    except Exception:   # noqa: BLE001 (senza GdkPixbuf o senza il formato: va bene il PNG)
        return False


def build(accento, w, h, out):
    os.makedirs(out, exist_ok=True)
    fatti = []
    t = Tavolozza(accento)
    for fam in FAMIGLIE:
        for scuro in (False, True):
            base = os.path.join(out, f"{fam}-{'scuro' if scuro else 'chiaro'}")
            for vecchio in (base + ".png", base + ".jpg"):
                if os.path.exists(vecchio):
                    os.remove(vecchio)
            disegna(DISEGNI[fam](t, scuro), base + ".png", w, h)
            if jpeg(base + ".png", base + ".jpg"):
                os.remove(base + ".png")
                fatti.append(base + ".jpg")
            else:
                fatti.append(base + ".png")
    with open(os.path.join(out, ".accento"), "w") as f:
        f.write(accento)
    print("\n".join(fatti))


def anteprima(accento, path):
    tw, th, m = 640, 360, 16
    tmp = tempfile.mkdtemp()
    t = Tavolozza(accento)
    try:
        celle = []
        for r, fam in enumerate(FAMIGLIE):
            for k, scuro in enumerate((False, True)):
                p = os.path.join(tmp, f"{fam}{k}.png")
                disegna(DISEGNI[fam](t, scuro), p, tw, th)
                celle.append((p, m + k * (tw + m), m + r * (th + m)))
        W2, H2 = 2 * tw + 3 * m, 4 * th + 5 * m
        imm = "".join(f'<image href="file://{p}" x="{x}" y="{y}" width="{tw}" height="{th}"/>' for p, x, y in celle)
        s = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W2}" height="{H2}"><rect width="{W2}" height="{H2}" '
             f'fill="#e9e9ee"/>{imm}</svg>')
        p = os.path.join(tmp, "foglio.svg")
        open(p, "w").write(s)
        subprocess.run(["rsvg-convert", "-o", path, p], check=True)
    finally:
        shutil.rmtree(tmp)


def main():
    args = sys.argv[1:]
    accento, size, out = DEFAULT_ACCENT, "3840x2160", os.path.expanduser("~/.local/share/backgrounds/dexos")
    for opt in ("--accent", "--size", "--out"):
        if opt in args:
            i = args.index(opt)
            v = args[i + 1]
            del args[i:i + 2]
            if opt == "--accent":
                accento = v
            elif opt == "--size":
                size = v
            else:
                out = os.path.expanduser(v)
    if args[:1] == ["build"]:
        w, h = (int(x) for x in size.split("x"))
        build(accento, w, h, out)
    elif args[:1] == ["anteprima"] and len(args) == 2:
        anteprima(accento, args[1])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
