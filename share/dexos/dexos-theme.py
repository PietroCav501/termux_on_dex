#!/usr/bin/env python3
"""DeX OS: il tema delle finestre e dei controlli di Termux On DeX, nel colore scelto dall'utente.

  dexos-theme.py build [--accent #0067c0] [--scale 1.125] [--out ~/.local/share/themes]
      → stampa i 4 nomi: GTK chiaro, GTK scuro, cornice chiara, cornice scura

GTK ricorda i temi per nome: ogni accento ha il suo (DeX-OS-0067c0, DeX-OS-Dark-0067c0) e ogni
scala la sua cornice (DeX-OS-WM-1.125, DeX-OS-WM-Dark-1.125). Così il cambio di colore è immediato
e senza passaggi da un altro tema, e un colore già usato non si rifà. I vecchi si tolgono.

I temi GTK contengono:
  gtk-3.0, gtk-4.0  i controlli di Fluent (licenza GPL) ricolorati: il blu di Fluent e le sue
                    sfumature diventano l'accento scelto, anche nelle piccole immagini PNG
  xfwm4             la cornice delle finestre, disegnata qui da zero: stile Windows 11 (pulsanti
                    a destra, chiusura rossa) con la morbidezza di macOS (angoli in alto arrotondati,
                    pulsanti a pillola al passaggio del mouse). Si rigenera ai DPI dello schermo.
Solo Python e rsvg-convert: niente pacchetti in più. Si rifà in un paio di secondi.
"""
import colorsys
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
FLUENT = {"light": "Fluent-Light", "dark": "Fluent-Dark"}
NAMES = {"light": "DeX-OS", "dark": "DeX-OS-Dark"}
FLUENT_HUE = 214.0          # il blu di Fluent (#1A73E8, #3281EA, #1567d3...)
FLUENT_SL = (0.818, 0.506)  # saturazione e luminosità di #1A73E8
DEFAULT_ACCENT = "#0067c0"
VERSION = 11   # nel nome dei temi: cambiando il disegno si rifanno da soli


# --- colori ---------------------------------------------------------------------------------
def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def rgb_hex(r, g, b):
    return "#%02x%02x%02x" % (r, g, b)


class Recolor:
    """Porta le tinte vicine al blu di Fluent sull'accento, mantenendo le differenze di chiaro/scuro."""

    def __init__(self, accent):
        r, g, b = (c / 255 for c in hex_rgb(accent))
        h, l, s = colorsys.rgb_to_hls(r, g, b)
        self.h, self.l, self.s = h, l, s
        self.cache = {}

    def rgb(self, r, g, b):
        key = (r, g, b)
        if key in self.cache:
            return self.cache[key]
        h, l, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
        out = key
        if s > 0.3 and abs(h * 360 - FLUENT_HUE) <= 20 and 0.12 < l < 0.97:
            ns = max(0.0, min(1.0, s * (self.s / FLUENT_SL[0]) if FLUENT_SL[0] else self.s))
            nl = max(0.0, min(1.0, l + (self.l - FLUENT_SL[1]) * (1 - abs(l - 0.5) * 1.6)))
            out = tuple(int(round(c * 255)) for c in colorsys.hls_to_rgb(self.h, nl, ns))
        self.cache[key] = out
        return out

    def css(self, text):
        def hx(m):
            r, g, b = hex_rgb(m.group(0))
            nr = self.rgb(r, g, b)
            return m.group(0) if nr == (r, g, b) else rgb_hex(*nr)

        def rgba(m):
            r, g, b = int(m.group(2)), int(m.group(3)), int(m.group(4))
            nr = self.rgb(r, g, b)
            return f"{m.group(1)}({nr[0]}, {nr[1]}, {nr[2]}{m.group(5)}"
        text = re.sub(r"#[0-9a-fA-F]{6}\b", hx, text)
        return re.sub(r"\b(rgba?)\(\s*(\d+),\s*(\d+),\s*(\d+)(\s*[,)])", rgba, text)


# --- PNG senza librerie: le immagini dei controlli di Fluent (8 bit, RGB/RGBA) ---------------
def png_read(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, idat, w = 8, b"", None
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            w, h, depth, ctype, _c, _f, inter = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or inter:
                return None
        elif typ == b"IDAT":
            idat += body
        pos += 12 + n
    if w is None:
        return None
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, bpp, rows


def png_write(path, w, h, bpp, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    ctype = 6 if bpp == 4 else 2
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def recolor_png(src, dst, rc):
    img = png_read(src)
    if img is None:
        shutil.copyfile(src, dst)
        return
    w, h, bpp, rows = img
    changed = False
    for line in rows:
        for x in range(0, w * bpp, bpp):
            r, g, b = line[x], line[x + 1], line[x + 2]
            nr = rc.rgb(r, g, b)
            if nr != (r, g, b):
                line[x], line[x + 1], line[x + 2] = nr
                changed = True
    if changed:
        png_write(dst, w, h, bpp, rows)
    else:
        shutil.copyfile(src, dst)


def gtk_part(src_root, dst_root, rc):
    for top, _dirs, files in os.walk(src_root):
        rel = os.path.relpath(top, src_root)
        os.makedirs(os.path.join(dst_root, rel), exist_ok=True)
        for f in files:
            s, d = os.path.join(top, f), os.path.join(dst_root, rel, f)
            if f.endswith(".css"):
                open(d, "w").write(rc.css(open(s, errors="replace").read()))
            elif f.endswith(".png"):
                recolor_png(s, d, rc)
            elif f.endswith(".svg"):
                open(d, "w").write(rc.css(open(s, errors="replace").read()))
            else:
                shutil.copyfile(s, d)


# --- cornice delle finestre (xfwm4) -----------------------------------------------------------
PALETTE = {
    # barra dello stesso colore delle finestre GTK (Fluent: #f2f2f2 / #333333): un pezzo unico come macOS;
    # il contorno è appena accennato, la profondità la dà l'ombra del compositore
    "light": dict(bar="#f2f2f2", bar_in="#f7f7f7", line="#d4d4d4", line_in="#e0e0e0", text="#1b1b1b",
                  text_in="#8a8a8a", glyph="#1b1b1b", glyph_in="#a0a0a0", hover="#000000", hover_a=0.06,
                  press_a=0.11),
    "dark": dict(bar="#333333", bar_in="#2c2c2c", line="#4a4a4a", line_in="#3e3e3e", text="#f3f3f3",
                 text_in="#8f8f8f", glyph="#f3f3f3", glyph_in="#7a7a7a", hover="#ffffff", hover_a=0.08,
                 press_a=0.14),
}
CLOSE_RED = "#c42b1c"


def svg_png(svg, path, w, h):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg)
    try:
        subprocess.run(["rsvg-convert", "-w", str(w), "-h", str(h), "-o", path, f.name], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        os.unlink(f.name)


def xfwm(dst, mode, scale):
    p = PALETTE[mode]
    S = lambda n: max(1, int(round(n * scale)))   # noqa: E731
    H, R, B, BTN_W, BTN_H = S(34), S(10), max(1, S(1)), S(46), S(34)
    os.makedirs(dst, exist_ok=True)

    def rect(w, h, fill, line=None, sides=""):
        out = f'<rect width="{w}" height="{h}" fill="{fill}"/>'
        if line:
            if "t" in sides:
                out += f'<rect width="{w}" height="{B}" fill="{line}"/>'
            if "l" in sides:
                out += f'<rect width="{B}" height="{h}" fill="{line}"/>'
            if "r" in sides:
                out += f'<rect x="{w - B}" width="{B}" height="{h}" fill="{line}"/>'
            if "b" in sides:
                out += f'<rect y="{h - B}" width="{w}" height="{B}" fill="{line}"/>'
        return out

    def save(name, w, h, body):
        svg_png(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">{body}</svg>',
                os.path.join(dst, name + ".png"), w, h)

    for state, sfx in (("", "active"), ("_in", "inactive")):
        bar, line = p["bar" + state], p["line" + state]
        # barra del titolo: 5 pezzi (xfwm4), tinta unita con la riga in alto
        for i in range(1, 6):
            save(f"title-{i}-{sfx}", S(8), H, rect(S(8), H, bar, line, "t"))
        # angoli in alto arrotondati come macOS (la parte trasparente "taglia" la finestra)
        save(f"top-left-{sfx}", R, H,
             f'<path d="M{R},0 H{R} V{H} H0 V{R} A{R},{R} 0 0 1 {R},0 Z" fill="{bar}"/>'
             f'<path d="M{R},{B / 2} A{R - B / 2},{R - B / 2} 0 0 0 {B / 2},{R} V{H}" fill="none" stroke="{line}" stroke-width="{B}"/>')
        save(f"top-right-{sfx}", R, H,
             f'<path d="M0,0 A{R},{R} 0 0 1 {R},{R} V{H} H0 Z" fill="{bar}"/>'
             f'<path d="M0,{B / 2} A{R - B / 2},{R - B / 2} 0 0 1 {R - B / 2},{R} V{H}" fill="none" stroke="{line}" stroke-width="{B}"/>')
        # bordi: una riga sottile e basta, come Windows 11 e macOS. Per afferrarli non serve mirare:
        # share/tod-edges.py mette zone invisibili appena fuori dalla finestra attiva.
        # Gli angoli in basso restano larghi quanto quelli in alto: xfwm4 4.20 posiziona la striscia
        # superiore (frame_border_top) in base alla loro larghezza, e se fossero stretti coprirebbe
        # l'arrotondamento in alto (15 ottobre: con angoli da 1 px le finestre erano tornate squadrate)
        cw = R + S(10)
        # (e i pulsanti partono dopo l'angolo: con il bordo da 1 px l'icona dell'app lo copriva)
        save(f"left-{sfx}", B, S(8), rect(B, S(8), line))
        save(f"right-{sfx}", B, S(8), rect(B, S(8), line))
        save(f"bottom-{sfx}", S(8), B, rect(S(8), B, line))
        save(f"bottom-left-{sfx}", cw, B, rect(cw, B, line))
        save(f"bottom-right-{sfx}", cw, B, rect(cw, B, line))

    # pulsanti: riduci, ingrandisci/ripristina, chiudi (a destra) e il menu della finestra
    g = lambda c: f'stroke="{c}" stroke-width="{max(1, scale)}" fill="none" stroke-linecap="round"'  # noqa: E731
    cx, cy, k = BTN_W / 2, BTN_H / 2, S(5)
    glyphs = {
        "hide": lambda c: f'<line x1="{cx - k}" y1="{cy}" x2="{cx + k}" y2="{cy}" {g(c)}/>',
        "maximize": lambda c: f'<rect x="{cx - k}" y="{cy - k}" width="{2 * k}" height="{2 * k}" rx="{S(1.5)}" {g(c)}/>',
        "maximize-toggled": lambda c: (f'<rect x="{cx - k}" y="{cy - k + S(2)}" width="{2 * k - S(2)}" height="{2 * k - S(2)}" rx="{S(1.5)}" {g(c)}/>'
                                       f'<path d="M{cx - k + S(2)},{cy - k} H{cx + k - S(1)} a{S(1)},{S(1)} 0 0 1 {S(1)},{S(1)} V{cy + k - S(2)}" {g(c)}/>'),
        "close": lambda c: (f'<line x1="{cx - k}" y1="{cy - k}" x2="{cx + k}" y2="{cy + k}" {g(c)}/>'
                            f'<line x1="{cx + k}" y1="{cy - k}" x2="{cx - k}" y2="{cy + k}" {g(c)}/>'),
        "menu": lambda c: "",
    }
    for name, glyph in glyphs.items():
        w = BTN_W if name != "menu" else S(8)
        for state in ("active", "inactive", "prelight", "pressed"):
            bar = p["bar_in"] if state == "inactive" else p["bar"]
            body = rect(w, BTN_H, bar, p["line_in" if state == "inactive" else "line"], "t")
            color = p["glyph_in"] if state == "inactive" else p["glyph"]
            if name == "close" and state in ("prelight", "pressed"):   # rosso, ma a pastiglia come gli altri
                body += (f'<rect x="{S(4)}" y="{S(4)}" width="{w - S(8)}" height="{BTN_H - S(8)}" rx="{S(6)}" '
                         f'fill="{CLOSE_RED}" opacity="{1 if state == "prelight" else 0.85}"/>')
                color = "#ffffff"
            elif state in ("prelight", "pressed") and name != "menu":
                a = p["hover_a"] if state == "prelight" else p["press_a"]
                body += (f'<rect x="{S(4)}" y="{S(4)}" width="{w - S(8)}" height="{BTN_H - S(8)}" rx="{S(6)}" '
                         f'fill="{p["hover"]}" opacity="{a}"/>')
            save(f"{name}-{state}", w, BTN_H, body + glyph(color))
    with open(os.path.join(dst, "themerc"), "w") as f:
        f.write(f"""# DeX OS ({mode}) - generato da Termux On DeX (share/dexos/dexos-theme.py)
active_text_color={p['text']}
inactive_text_color={p['text_in']}
title_alignment=left
title_horizontal_offset={S(10)}
title_vertical_offset_active=0
title_vertical_offset_inactive=0
title_shadow_active=false
title_shadow_inactive=false
full_width_title=true
button_offset={R}
button_spacing=0
button_layout=O|HMC
show_app_icon=true
maximized_offset=0
""")


def names(accent, scale):
    tag, sc = accent.lstrip("#").lower(), ("%.3f" % scale).rstrip("0").rstrip(".")
    v = f"-v{VERSION}"
    return {"light": f"{NAMES['light']}-{tag}{v}", "dark": f"{NAMES['dark']}-{tag}{v}",
            "wm-light": f"DeX-OS-WM-{sc}{v}", "wm-dark": f"DeX-OS-WM-Dark-{sc}{v}"}


def notify(dst, mode, accent):
    """le notifiche (xfce4-notifyd, tema = questo tema GTK): una scheda come macOS e Windows 11"""
    bg, fg, bordo = (("#2b2b30", "#f2f2f5", "rgba(255,255,255,0.10)") if mode == "dark"
                     else ("#ffffff", "#1b1b1f", "rgba(0,0,0,0.10)"))
    os.makedirs(dst, exist_ok=True)
    with open(os.path.join(dst, "gtk.css"), "w") as f:
        f.write(f"""/* DeX OS: notifiche (Termux On DeX) */
#XfceNotifyWindow {{
    background-color: {bg};
    color: {fg};
    border: 1px solid {bordo};
    border-radius: 14px;
    padding: 14px 16px;
}}
#XfceNotifyWindow:hover {{ border-color: {accent}; }}
#XfceNotifyWindow label#summary {{ font-weight: 600; font-size: 1.04em; color: {fg}; }}
#XfceNotifyWindow label#body {{ color: alpha({fg}, 0.78); }}
#XfceNotifyWindow image {{ margin-right: 6px; }}
#XfceNotifyWindow button {{
    background-image: none;
    background-color: alpha({fg}, 0.06);
    border: 1px solid {bordo};
    border-radius: 8px;
    color: {fg};
    padding: 4px 12px;
    box-shadow: none;
}}
#XfceNotifyWindow button:hover {{ background-color: {accent}; color: #ffffff; border-color: {accent}; }}
#XfceNotifyWindow progressbar progress {{ background-color: {accent}; border-radius: 4px; }}
#XfceNotifyWindow progressbar trough {{ background-color: alpha({fg}, 0.10); border-radius: 4px; }}
""")


# scrivania, tra macOS e Windows 11: scritte scure sugli sfondi chiari del tema chiaro, bianche su quelli
# scuri (niente alone), al passaggio una pillola di vetro, selezionata una pillola nell'accento; l'icona
# selezionata non si scurisce
DESKTOP_CSS = """
XfdesktopIconView.view {
  color: TESTO;
  font-weight: 500;
  text-shadow: OMBRA;
  border-radius: 7px;
  -gtk-icon-effect: none;
}
XfdesktopIconView.view:hover {
  background-color: PASSAGGIO;
  color: TESTO;
}
XfdesktopIconView.view:selected, XfdesktopIconView.view:selected:focus, XfdesktopIconView.view:active {
  background-color: alpha(ACCENTO, 0.9);
  color: #ffffff;
  text-shadow: none;
  -gtk-icon-effect: none;
}
XfdesktopIconView.view .rubberband {
  border: 1px solid alpha(ACCENTO, 0.8);
  background-color: alpha(ACCENTO, 0.18);
  border-radius: 4px;
}
"""


# lo stile approvato da Pietro (i pannelli della barra, share/tod-pannelli.py) esteso a menu del tasto destro,
# popup, suggerimenti: fondi pieni (niente vetro), angoli ampi, voce sotto il puntatore nell'accento, come macOS
VETRO_CSS = {
    "light": dict(fondo="#f6f6f8", testo="#1d1d1f", tenue="#6e6e73", linea="rgba(0, 0, 0, 0.09)",
                  bordo="rgba(0, 0, 0, 0.10)", ombra="rgba(0, 0, 0, 0.20)", spento="rgba(0, 0, 0, 0.3)"),
    "dark": dict(fondo="#2a2a2e", testo="#f5f5f7", tenue="#a1a1a6", linea="rgba(255, 255, 255, 0.10)",
                 bordo="rgba(255, 255, 255, 0.12)", ombra="rgba(0, 0, 0, 0.45)", spento="rgba(255, 255, 255, 0.3)"),
}
VETRO = """
/* --- DeX OS: menu, popup, suggerimenti --- */
.csd.popup decoration, .popup decoration {
  border-radius: 12px;
  box-shadow: 0 10px 28px {ombra}, 0 0 0 1px {bordo};
}
menu, .menu, .context-menu {
  margin: 0; padding: 5px;
  background-color: {fondo};
  border: none; border-radius: 12px;
}
.csd menu, .csd .menu, .csd .context-menu { border-radius: 12px; border: none; }
menu menuitem, .menu menuitem, .context-menu menuitem,
.csd menu menuitem, .csd .menu menuitem, .csd .context-menu menuitem {
  margin: 0; padding: 5px 10px; min-height: 18px; border-radius: 7px;
  color: {testo}; font-family: Inter, sans-serif; font-size: 10pt;
}
menu menuitem:hover, .menu menuitem:hover, .context-menu menuitem:hover {
  background-color: {accento}; color: #ffffff;
}
menu menuitem:hover > label, menu menuitem:hover > accelerator, menu menuitem:hover > arrow,
menu menuitem:hover > box > label, menu menuitem:hover > box > accelerator,
menu menuitem:hover > check, menu menuitem:hover > radio { color: #ffffff; }
menu menuitem:disabled, .menu menuitem:disabled, .context-menu menuitem:disabled { color: {spento}; }
menu menuitem accelerator { color: {tenue}; }
menu separator, .menu separator, .context-menu separator {
  margin: 5px 10px; min-height: 1px; background-color: {linea};
}
menu menuitem check:checked, menu menuitem radio:checked { color: {accento}; }
popover, popover.background {
  background-color: {fondo}; border: 1px solid {bordo}; border-radius: 14px;
  box-shadow: 0 10px 28px {ombra};
}
popover modelbutton { border-radius: 7px; padding: 5px 10px; }
popover modelbutton:hover { background-color: {accento}; color: #ffffff; }
tooltip, tooltip.background, tooltip.background.csd {
  background-color: {fondo}; color: {testo}; border-radius: 8px; border: none;
}
tooltip.csd decoration { border-radius: 8px; box-shadow: 0 4px 14px {ombra}, 0 0 0 1px {bordo}; }
tooltip label { color: {testo}; font-family: Inter, sans-serif; font-size: 9pt; }
tooltip > box { padding: 5px 9px; }
/* caselle, scelte, interruttori e cursori: sempre nel colore di sistema */
check:checked, radio:checked, check:indeterminate, radio:indeterminate {
  background-color: {accento}; border-color: {accento}; color: #ffffff;
}
switch:checked { background-color: {accento}; border-color: {accento}; }
scale highlight, scale trough highlight, progressbar progress, levelbar block.filled { background-color: {accento}; }
"""


def vetro_css(mode, accent):
    v = dict(VETRO_CSS["dark" if mode == "dark" else "light"], accento=accent)
    out = VETRO
    for k, val in v.items():
        out = out.replace("{" + k + "}", val)
    return out


def build(accent, scale, out):
    rc = Recolor(accent)
    want = names(accent, scale)
    os.makedirs(out, exist_ok=True)
    for mode in ("light", "dark"):
        for key, part in ((mode, "gtk"), ("wm-" + mode, "wm")):
            dst = os.path.join(out, want[key])
            if os.path.isfile(os.path.join(dst, "index.theme")):
                continue   # già fatto: tornare a un colore usato è immediato
            tmp = dst + ".nuovo"
            shutil.rmtree(tmp, ignore_errors=True)
            os.makedirs(tmp)
            if part == "gtk":
                src = os.path.join(PREFIX, "share/themes", FLUENT[mode])
                for sub in ("gtk-3.0", "gtk-4.0"):
                    if os.path.isdir(os.path.join(src, sub)):
                        gtk_part(os.path.join(src, sub), os.path.join(tmp, sub), rc)
                with open(os.path.join(tmp, "gtk-3.0", "gtk.css"), "a") as f:
                    f.write(vetro_css(mode, accent))
                    f.write(DESKTOP_CSS.replace("ACCENTO", accent).replace("TESTO", "#ffffff" if mode == "dark" else "#1b1f2a")
                            .replace("OMBRA", "0 1px 2px rgba(0, 0, 0, 0.6)" if mode == "dark" else "0 1px 1px rgba(255, 255, 255, 0.55)")
                            .replace("PASSAGGIO", "rgba(255, 255, 255, 0.18)" if mode == "dark" else "rgba(255, 255, 255, 0.55)"))
                if os.path.isdir(os.path.join(src, "gtk-2.0")):
                    shutil.copytree(os.path.join(src, "gtk-2.0"), os.path.join(tmp, "gtk-2.0"))
                notify(os.path.join(tmp, "xfce-notify-4.0"), mode, accent)
            else:
                xfwm(os.path.join(tmp, "xfwm4"), mode, scale)
            with open(os.path.join(tmp, "index.theme"), "w") as f:
                f.write(f"[Desktop Entry]\nType=X-GNOME-Metatheme\nName=DeX OS {'scuro' if mode == 'dark' else 'chiaro'}\n"
                        f"Comment=Termux On DeX ({accent}, {scale})\nEncoding=UTF-8\n\n[X-GNOME-Metatheme]\n"
                        f"GtkTheme={want[mode]}\nMetacityTheme={want['wm-' + mode]}\nIconTheme=DeX-OS\n")
            shutil.rmtree(dst, ignore_errors=True)
            os.rename(tmp, dst)   # tutto o niente: mai un tema a metà
    # via le versioni vecchie (le app che le hanno in memoria non ne hanno più bisogno); se ne tiene
    # qualcuna recente, così tornare al colore di prima resta immediato
    keep = set(want.values())
    old = sorted((d for d in os.listdir(out) if d.startswith("DeX-OS") and d not in keep),
                 key=lambda d: os.path.getmtime(os.path.join(out, d)), reverse=True)
    for d in old[6:] + [d for d in old if d.endswith(".nuovo") or d in ("DeX-OS", "DeX-OS-Dark")]:
        shutil.rmtree(os.path.join(out, d), ignore_errors=True)
    return [want[k] for k in ("light", "dark", "wm-light", "wm-dark")]


def main():
    args = sys.argv[1:]
    if not args or args[0] != "build":
        print(__doc__)
        return 1
    opt = {"--accent": DEFAULT_ACCENT, "--scale": "1", "--out": os.path.expanduser("~/.local/share/themes")}
    for i, a in enumerate(args):
        if a in opt and i + 1 < len(args):
            opt[a] = args[i + 1]
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", opt["--accent"]):
        print("accento non valido:", opt["--accent"], file=sys.stderr)
        return 2
    print(" ".join(build(opt["--accent"], float(opt["--scale"]), opt["--out"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
