#!/usr/bin/env python3
"""DeX OS: il puntatore del mouse di Termux On DeX, disegnato qui da zero, nel colore d'accento.

  dexos-cursors.py build [--accent #0067c0] [--out ~/.local/share/icons]   → stampa i 2 nomi
  dexos-cursors.py anteprima [--accent #0067c0] FILE.png                   → tutte le forme su un foglio

Due varianti: "DeX-OS-Cursors-<acc>" (corpo scuro, bordo bianco: si vede su ogni sfondo, come
macOS) e "DeX-OS-Cursors-Light-<acc>" (corpo bianco, bordo scuro, come Windows). L'accento sta
nei dettagli: il collegamento (la goccia piena d'accento), l'attesa, i distintivi di copia e aiuto.

Forme in un quadrato da 32 unità (punto attivo in quelle unità), disegnate a più dimensioni con
rsvg-convert; il file Xcursor lo scrive questo programma (niente xcursorgen). Bordo esterno senza
linee interne: si disegnano prima tutte le forme col tratto spesso del bordo, poi le stesse piene.
"""
import importlib.util
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile

QUI = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location("dexos_theme", os.path.join(QUI, "dexos-theme.py"))
_t = importlib.util.module_from_spec(_s)
_s.loader.exec_module(_t)
png_read = _t.png_read

VERSION = 2
DEFAULT_ACCENT = "#0067c0"
SIZES = (24, 32, 36, 48, 64, 72, 96)   # Xcursor sceglie la più vicina a CursorThemeSize
FRAMES, DELAY = 20, 40                 # attesa: un giro in 0,8 s
RED = "#e5484d"
VARIANTS = {   # nome → (corpo, bordo)
    "DeX-OS-Cursors": ("#1c1c21", "#ffffff"),
    "DeX-OS-Cursors-Light": ("#ffffff", "#1c1c21"),
}

FILTRO = ('<filter id="o" x="-30%" y="-30%" width="160%" height="160%">'
          '<feDropShadow dx="0" dy="0.8" stdDeviation="0.9" flood-color="#000" flood-opacity="0.35"/></filter>')


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><defs>{FILTRO}</defs>'
            f'<g filter="url(#o)">{body}</g></svg>')


def contorno(forme, corpo, bordo, w=1.7):
    """FORME: elementi SVG senza colore. Bordo esterno continuo, interno pieno."""
    sotto = "".join(f.replace("/>", f' fill="{bordo}" stroke="{bordo}" stroke-width="{2 * w}" '
                              'stroke-linejoin="round" stroke-linecap="round"/>') for f in forme)
    sopra = "".join(f.replace("/>", f' fill="{corpo}"/>') for f in forme)
    return sotto + sopra


# --- le forme (unità 0..32): stile "Goccia" ---------------------------------------------------
# la punta è una goccia senza coda, piegata verso l'alto a sinistra; il collegamento è la stessa goccia
# nel colore d'accento; il resto (attesa, afferra, sposta...) sono cerchi e capsule della stessa famiglia
GOCCIA = "M5 4 L21.5 12.6 Q23.4 13.6 21.4 14.6 L14.6 17.4 Q13.6 17.8 13.2 18.8 L10.4 25.4 Q9.6 27.2 8.8 25.2 Z"


def goccia(corpo, bordo, accento=None):
    if accento:   # collegamento: piena d'accento, con il punto bianco
        return (f'<path d="{GOCCIA}" fill="{accento}" stroke="{bordo}" stroke-width="1.8" stroke-linejoin="round"/>'
                '<circle cx="12.4" cy="14" r="2.2" fill="#ffffff"/>')
    return f'<path d="{GOCCIA}" fill="{corpo}" stroke="{bordo}" stroke-width="1.8" stroke-linejoin="round"/>'


def contorno(forme, corpo, bordo, w=1.7):
    """FORME: elementi SVG senza colore. Bordo esterno continuo, interno pieno."""
    sotto = "".join(f.replace("/>", f' fill="{bordo}" stroke="{bordo}" stroke-width="{2 * w}" '
                              'stroke-linejoin="round" stroke-linecap="round"/>') for f in forme)
    sopra = "".join(f.replace("/>", f' fill="{corpo}"/>') for f in forme)
    return sotto + sopra


def distintivo(cx, cy, accento, bordo, interno):
    """un cerchietto nel colore d'accento con un simbolo bianco (copia, collegamento, aiuto...)"""
    return (f'<circle cx="{cx}" cy="{cy}" r="5" fill="{bordo}"/>'
            f'<circle cx="{cx}" cy="{cy}" r="4.1" fill="{accento}"/>'
            f'<g transform="translate({cx} {cy})" fill="none" stroke="#fff" stroke-width="1.4" '
            f'stroke-linecap="round" stroke-linejoin="round">{interno}</g>')


SIMBOLI = {
    "piu": '<path d="M0 -2.2 V2.2 M-2.2 0 H2.2"/>',
    "link": '<path d="M-2 1.8 L2 -2 M-0.6 -2 H2 V0.6"/>',
    "aiuto": '<path d="M-1.3 -1 Q-1.3 -2.4 0 -2.4 Q1.4 -2.4 1.4 -1.1 Q1.4 -0.2 0.3 0.3 Q0 0.5 0 1.1"/>'
             '<circle cx="0" cy="2.4" r="0.25" fill="#fff"/>',
    "menu": '<path d="M-2 -1.5 H2 M-2 0 H2 M-2 1.5 H2"/>',
    "no": '<circle r="2.2"/><path d="M-1.5 1.5 L1.5 -1.5"/>',
}


def arco(cx, cy, r, angolo, accento, w):
    a0 = math.radians(angolo)
    a1 = a0 + math.radians(250)
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{accento}" stroke-opacity="0.25" stroke-width="{w}"/>'
            f'<path d="M{cx + r * math.cos(a0):.2f} {cy + r * math.sin(a0):.2f} A{r} {r} 0 1 1 '
            f'{cx + r * math.cos(a1):.2f} {cy + r * math.sin(a1):.2f}" fill="none" stroke="{accento}" '
            f'stroke-width="{w}" stroke-linecap="round"/>')


def attesa(cx, cy, r, angolo, accento, corpo, bordo):
    """disco del corpo con l'arco d'accento che gira (ANGOLO in gradi)"""
    return (f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{corpo}" stroke="{bordo}" stroke-width="1.6"/>'
            + arco(cx, cy, r * 0.64, angolo, accento, r * 0.26))


def doppia(angolo, corpo, bordo, barra=False):
    """freccia doppia (ridimensionamenti) con le punte morbide, verticale ruotata di ANGOLO"""
    f = ['<path d="M16 3 L22 10 H18 V22 H22 L16 29 L10 22 H14 V10 H10 Z"/>']
    if barra:
        f = ['<path d="M16 2.6 L21.4 8.6 H18 V13.2 H14 V8.6 H10.6 Z"/>',
             '<path d="M16 29.4 L21.4 23.4 H18 V18.8 H14 V23.4 H10.6 Z"/>',
             '<rect x="7" y="14.6" width="18" height="2.8" rx="1.4"/>']
    return f'<g transform="rotate({angolo} 16 16)">{contorno(f, corpo, bordo, 0.9)}</g>'


def sposta(accento, corpo, bordo):
    punte = "".join(f'<g transform="rotate({a} 16 16)"><path d="M16 2.4 L20.2 7.4 H11.8 Z"/></g>' for a in (0, 90, 180, 270))
    g = (f'<g fill="{corpo}" stroke="{bordo}" stroke-width="1.4" stroke-linejoin="round">{punte}</g>'
         f'<circle cx="16" cy="16" r="6.6" fill="{corpo}" stroke="{bordo}" stroke-width="1.6"/>'
         f'<circle cx="16" cy="16" r="2.4" fill="{accento}"/>')
    return g


def afferra(chiusa, accento, corpo, bordo):
    g = f'<circle cx="16" cy="16" r="9" fill="{corpo}" stroke="{bordo}" stroke-width="1.8"/>'
    if chiusa:
        return g + f'<circle cx="16" cy="16" r="4" fill="{accento}"/>'
    return g + f'<circle cx="16" cy="16" r="3.4" fill="none" stroke="{accento}" stroke-width="2"/>'


def testo(accento, corpo, bordo, verticale=False):
    g = (f'<rect x="14" y="5" width="4" height="22" rx="2" fill="{corpo}" stroke="{bordo}" stroke-width="1.6"/>'
         f'<rect x="15.2" y="9" width="1.6" height="14" rx=".8" fill="{accento}"/>')
    return f'<g transform="rotate(90 16 16)">{g}</g>' if verticale else g


def mirino(accento, corpo, bordo):
    f = ['<rect x="15" y="3" width="2" height="8" rx="1"/>', '<rect x="15" y="21" width="2" height="8" rx="1"/>',
         '<rect x="3" y="15" width="8" height="2" rx="1"/>', '<rect x="21" y="15" width="8" height="2" rx="1"/>']
    return (contorno(f, corpo, bordo, 1.0) +
            f'<circle cx="16" cy="16" r="3.4" fill="none" stroke="{bordo}" stroke-width="3.2"/>'
            f'<circle cx="16" cy="16" r="3.4" fill="none" stroke="{accento}" stroke-width="1.6"/>')


def cella(accento, corpo, bordo):
    f = ['<path d="M13.6 5 Q13.6 4 14.6 4 H17.4 Q18.4 4 18.4 5 V13.6 H27 Q28 13.6 28 14.6 V17.4 Q28 18.4 27 18.4 '
         'H18.4 V27 Q18.4 28 17.4 28 H14.6 Q13.6 28 13.6 27 V18.4 H5 Q4 18.4 4 17.4 V14.6 Q4 13.6 5 13.6 H13.6 Z"/>']
    return contorno(f, corpo, bordo, 1.1) + f'<circle cx="16" cy="16" r="1.6" fill="{accento}"/>'


def lente(segno, accento, corpo, bordo):
    f = ['<circle cx="13" cy="13" r="8.6"/>',
         '<path d="M18.6 20.6 L21 18.2 L28.4 25.6 Q29 26.6 28 27.6 L27.6 28 Q26.6 29 25.6 28.4 Z"/>']
    s = '<path d="M9 13 H17 M13 9 V17"/>' if segno == "piu" else '<path d="M9 13 H17"/>'
    return contorno(f, corpo, bordo, 1.3) + f'<g fill="none" stroke="{accento}" stroke-width="2.4" stroke-linecap="round">{s}</g>'


def matita(accento, corpo, bordo):
    f = ['<path d="M4 28 L5.6 21.6 L21.4 5.8 Q23 4.2 24.6 5.8 L26.2 7.4 Q27.8 9 26.2 10.6 L10.4 26.4 Z"/>']
    return (contorno(f, corpo, bordo, 1.2) +
            f'<path d="M19.6 7.6 L24.4 12.4 L26.2 10.6 Q27.8 9 26.2 7.4 L24.6 5.8 Q23 4.2 21.4 5.8 Z" fill="{accento}"/>')


def vietato(bordo):
    return (f'<circle cx="16" cy="16" r="10.4" fill="none" stroke="{bordo}" stroke-width="6"/>'
            f'<circle cx="16" cy="16" r="10.4" fill="none" stroke="{RED}" stroke-width="3.2"/>'
            f'<path d="M9 23 L23 9" stroke="{bordo}" stroke-width="6" stroke-linecap="round"/>'
            f'<path d="M9 23 L23 9" stroke="{RED}" stroke-width="3.2" stroke-linecap="round"/>')


def croce(corpo, bordo):
    f = ['<path d="M8.6 6.2 L16 13.6 L23.4 6.2 Q24.4 5.2 25.4 6.2 L25.8 6.6 Q26.8 7.6 25.8 8.6 L18.4 16 L25.8 23.4 '
         'Q26.8 24.4 25.8 25.4 L25.4 25.8 Q24.4 26.8 23.4 25.8 L16 18.4 L8.6 25.8 Q7.6 26.8 6.6 25.8 L6.2 25.4 '
         'Q5.2 24.4 6.2 23.4 L13.6 16 L6.2 8.6 Q5.2 7.6 6.2 6.6 L6.6 6.2 Q7.6 5.2 8.6 6.2 Z"/>']
    return contorno(f, corpo, bordo, 1.1)


# --- l'elenco: nome → (disegno(corpo, bordo, accento, fotogramma), punto attivo, animato) --------
def forme():
    F = {}
    P = (5, 4)   # la punta della goccia

    def con(simbolo, colore=None):
        return lambda c, b, a, k: goccia(c, b) + distintivo(22.5, 23, colore or a, b, SIMBOLI[simbolo])
    F["default"] = (lambda c, b, a, k: goccia(c, b), P, False)
    F["pointer"] = (lambda c, b, a, k: goccia(c, b, a), P, False)
    F["grab"] = (lambda c, b, a, k: afferra(False, a, c, b), (16, 16), False)
    F["grabbing"] = (lambda c, b, a, k: afferra(True, a, c, b), (16, 16), False)
    F["text"] = (lambda c, b, a, k: testo(a, c, b), (16, 16), False)
    F["vertical-text"] = (lambda c, b, a, k: testo(a, c, b, True), (16, 16), False)
    F["wait"] = (lambda c, b, a, k: attesa(16, 16, 10, k * 360 / FRAMES, a, c, b), (16, 16), True)
    F["progress"] = (lambda c, b, a, k: goccia(c, b) + attesa(23, 23.5, 5.2, k * 360 / FRAMES, a, c, b), P, True)
    F["help"] = (con("aiuto"), P, False)
    F["context-menu"] = (con("menu"), P, False)
    F["copy"] = (con("piu"), P, False)
    F["alias"] = (con("link"), P, False)
    F["no-drop"] = (con("no", RED), P, False)
    F["not-allowed"] = (lambda c, b, a, k: vietato(b), (16, 16), False)
    F["crosshair"] = (lambda c, b, a, k: mirino(a, c, b), (16, 16), False)
    F["cell"] = (lambda c, b, a, k: cella(a, c, b), (16, 16), False)
    F["move"] = (lambda c, b, a, k: sposta(a, c, b), (16, 16), False)
    F["ew-resize"] = (lambda c, b, a, k: doppia(90, c, b), (16, 16), False)
    F["ns-resize"] = (lambda c, b, a, k: doppia(0, c, b), (16, 16), False)
    F["nwse-resize"] = (lambda c, b, a, k: doppia(-45, c, b), (16, 16), False)
    F["nesw-resize"] = (lambda c, b, a, k: doppia(45, c, b), (16, 16), False)
    F["col-resize"] = (lambda c, b, a, k: doppia(90, c, b, True), (16, 16), False)
    F["row-resize"] = (lambda c, b, a, k: doppia(0, c, b, True), (16, 16), False)
    F["zoom-in"] = (lambda c, b, a, k: lente("piu", a, c, b), (13, 13), False)
    F["zoom-out"] = (lambda c, b, a, k: lente("meno", a, c, b), (13, 13), False)
    F["pencil"] = (lambda c, b, a, k: matita(a, c, b), (4, 28), False)
    F["X_cursor"] = (lambda c, b, a, k: croce(c, b), (16, 16), False)
    return F


# nomi dello standard (CSS, X11 e le impronte usate da Qt e GTK 2) → la forma
ALIAS = {
    "default": "left_ptr arrow top_left_arrow left_arrow right_ptr center_ptr",
    "pointer": "hand2 hand1 hand pointing_hand e29285e634086352946a0e7090d73106 9d800788f1b08800ae810202380a0822",
    "grab": "openhand hand_open 5aca4d189052212118709018842178c0 208530c400c041818281048008011002",
    "grabbing": "closedhand dnd-move dnd-none fleur_closed 4498f0e0c1937ffe01fd06f973665830 9081237383d90e509aa00f00170e968f fcf21c00b30f7e3f83fe0dfd12e71cff",
    "text": "xterm ibeam",
    "wait": "watch",
    "progress": "left_ptr_watch half-busy 3ecb610c1bf2410f44200f48c40d3599 08e8e1c95fe2fc01f976f1e063a24ccd 00000000000000020006000e7e9ffc3f",
    "help": "question_arrow whats_this dnd-ask left_ptr_help d9ce0ab605698f320427677b458ad60b 5c6cd98b3f3ebcb1f9c7f1c204630408",
    "copy": "dnd-copy 1081e37283d90000800003c07f3ef6bf 6407b0e94181790501fd1e167b474872 b66166c04f8c3109214a4fbd64a50fc8",
    "alias": "link dnd-link 640fb0e74195791501fd1ed57b41487f 3085a0e285430894940527032f8b26df a2a266d0498c3104214a47bd64ab0fc8",
    "no-drop": "dnd-no-drop",
    "not-allowed": "forbidden crossed_circle circle 03b6e0fcb3499374a867c041f52298f0",
    "crosshair": "cross tcross cross_reverse diamond_cross target",
    "cell": "plus",
    "move": "fleur all-scroll size_all",
    "ew-resize": "e-resize w-resize left_side right_side sb_h_double_arrow h_double_arrow size_hor 028006030e0e7ebffc7f7070c0600140",
    "ns-resize": "n-resize s-resize top_side bottom_side sb_v_double_arrow v_double_arrow size_ver double_arrow 00008160000006810000408080010102",
    "nwse-resize": "nw-resize se-resize top_left_corner bottom_right_corner bd_double_arrow size_fdiag c7088f0f3e6c8088236ef8e1e3e70000",
    "nesw-resize": "ne-resize sw-resize top_right_corner bottom_left_corner fd_double_arrow size_bdiag fcf1c3c7cd4491d801f1e1c78f100000",
    "col-resize": "split_h 14fef782d02440884392942c11205230",
    "row-resize": "split_v 2870a09082c103050810ffdffffe0204",
    "pencil": "draft",
    "X_cursor": "pirate",
}


# --- Xcursor --------------------------------------------------------------------------------
def disegna(svgtxt, n, tmp):
    p = os.path.join(tmp, "f.svg")
    o = os.path.join(tmp, "f.png")
    with open(p, "w") as f:
        f.write(svgtxt)
    subprocess.run(["rsvg-convert", "-w", str(n), "-h", str(n), "-o", o, p], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    w, h, bpp, rows = png_read(o)
    px = bytearray()
    for r in rows:
        for x in range(w):
            i = x * bpp
            R, G, B = r[i], r[i + 1], r[i + 2]
            A = r[i + 3] if bpp == 4 else 255
            # Xcursor: ARGB con i colori già moltiplicati per l'alfa, little endian (B G R A)
            px += bytes(((B * A + 127) // 255, (G * A + 127) // 255, (R * A + 127) // 255, A))
    return w, h, bytes(px)


def xcursor(path, immagini):
    """IMMAGINI: [(dimensione nominale, w, h, xhot, yhot, ritardo, pixel)]"""
    n = len(immagini)
    pos = 16 + 12 * n
    toc, corpi = b"", b""
    for (nom, w, h, xh, yh, d, px) in immagini:
        toc += struct.pack("<III", 0xFFFD0002, nom, pos)
        c = struct.pack("<IIIIIIIII", 36, 0xFFFD0002, nom, 1, w, h, xh, yh, d) + px
        corpi += c
        pos += len(c)
    with open(path, "wb") as f:
        f.write(b"Xcur" + struct.pack("<III", 16, 0x10000, n) + toc + corpi)


def tema(out, nome, corpo, bordo, accento, titolo):
    d = os.path.join(out, nome)
    cur = os.path.join(d, "cursors")
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(cur)
    tmp = tempfile.mkdtemp()
    try:
        for f, (fn, (hx, hy), anim) in forme().items():
            imm = []
            for n in SIZES:
                for k in range(FRAMES if anim else 1):
                    w, h, px = disegna(svg(fn(corpo, bordo, accento, k)), n, tmp)
                    imm.append((n, w, h, min(w - 1, round(hx * n / 32)), min(h - 1, round(hy * n / 32)),
                                DELAY if anim else 0, px))
            xcursor(os.path.join(cur, f), imm)
            for a in ALIAS.get(f, "").split():
                if not os.path.exists(os.path.join(cur, a)):
                    os.symlink(f, os.path.join(cur, a))
    finally:
        shutil.rmtree(tmp)
    with open(os.path.join(d, "index.theme"), "w") as f:
        f.write(f"[Icon Theme]\nName={titolo}\nComment=Puntatore di Termux On DeX\n")
    return d


def nomi(accento):
    a = accento.lstrip("#").lower()
    return [f"{v}-{a}-v{VERSION}" for v in VARIANTS]


def build(accento, out):
    os.makedirs(out, exist_ok=True)
    fatti = []
    for (v, (corpo, bordo)), nome in zip(VARIANTS.items(), nomi(accento)):
        if not os.path.isfile(os.path.join(out, nome, "index.theme")):
            tema(out, nome, corpo, bordo, accento, v.replace("-", " "))
        fatti.append(nome)
    # i disegni vecchi (altra versione) via; dei colori vecchi al massimo 6 per variante
    for v in VARIANTS:
        mie = [x for x in os.listdir(out) if x.startswith(v + "-") and x not in fatti and
               (v != "DeX-OS-Cursors" or not x.startswith("DeX-OS-Cursors-Light"))]
        for x in mie:
            if not x.endswith(f"-v{VERSION}"):
                shutil.rmtree(os.path.join(out, x), ignore_errors=True)
        vecchi = sorted((x for x in mie if x.endswith(f"-v{VERSION}")), key=lambda x: os.path.getmtime(os.path.join(out, x)))
        for x in vecchi[:-6] if len(vecchi) > 6 else []:
            shutil.rmtree(os.path.join(out, x), ignore_errors=True)
    print("\n".join(fatti))


def anteprima(accento, path):
    """un foglio con tutte le forme, nelle due varianti, su sfondo chiaro e scuro"""
    F = forme()
    celle = []
    for riga, (v, (corpo, bordo)) in enumerate(VARIANTS.items()):
        for sfondo_i, sfondo in enumerate(("#f3f3f5", "#2b2b30")):
            y = (riga * 2 + sfondo_i) * 80
            celle.append(f'<rect x="0" y="{y}" width="{len(F) * 64 + 16}" height="80" fill="{sfondo}"/>')
            for i, (nome, (fn, _h, anim)) in enumerate(F.items()):
                corpo_svg = fn(corpo, bordo, accento, 3 if anim else 0)
                celle.append(f'<g transform="translate({16 + i * 64} {y + 8}) scale(1.6)"><g filter="url(#o)">{corpo_svg}</g></g>')
    w, h = len(F) * 64 + 16, 4 * 80
    s = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
         f'<defs>{FILTRO}</defs>{"".join(celle)}</svg>')
    tmp = tempfile.mkdtemp()
    try:
        p = os.path.join(tmp, "a.svg")
        open(p, "w").write(s)
        subprocess.run(["rsvg-convert", "-o", path, p], check=True)
    finally:
        shutil.rmtree(tmp)


def main():
    args = sys.argv[1:]
    accento, out = DEFAULT_ACCENT, os.path.expanduser("~/.local/share/icons")
    if "--accent" in args:
        i = args.index("--accent"); accento = args[i + 1]; del args[i:i + 2]
    if "--out" in args:
        i = args.index("--out"); out = os.path.expanduser(args[i + 1]); del args[i:i + 2]
    if args[:1] == ["build"]:
        build(accento, out)
    elif args[:1] == ["anteprima"] and len(args) == 2:
        anteprima(accento, args[1])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
