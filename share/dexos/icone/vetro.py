"""DeX OS: icone di oggi, "vetro liquido". Lastre di vetro traslucido sovrapposte, un filo di luce sul
bordo, colori vivaci e morbidi che si mescolano dove le lastre si incrociano. Niente rilievi, niente
carta o metallo, quasi niente ombre (spunti: Liquid Glass di Apple, Fluent 2, One UI 8/9).

Quadrato 64×64. Funzioni: (defs, corpo).
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

N = 0


def _id(p):
    global N
    N += 1
    return f"{p}{N}"


def schiarisci(c, t):
    r, g, b = (int(c[i:i + 2], 16) for i in (1, 3, 5))
    return "#%02x%02x%02x" % tuple(round(x + (255 - x) * t) for x in (r, g, b))


INTENSITA = 1.0   # 1 = colori pieni; meno = più sobri (saturazione e luminosità ridotte)


def tono(c):
    import colorsys
    if not (isinstance(c, str) and c.startswith("#") and len(c) == 7) or INTENSITA >= 1:
        return c
    r, g, b = (int(c[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    if s < 0.15:
        return c   # bianchi e grigi restano
    s *= INTENSITA
    l = l * (0.92 + 0.08 * INTENSITA) if l > 0.5 else l
    r, g, b = colorsys.hls_to_rgb(h, l, s)
    return "#%02x%02x%02x" % (round(r * 255), round(g * 255), round(b * 255))


def lg(stops, x1=0, y1=0, x2=0, y2=1):
    stops = [(o, tono(c), a) for o, c, a in stops]
    i = _id("g")
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f"url(#{i})", f'<linearGradient id="{i}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{s}</linearGradient>'


def morbida():
    i = _id("f")
    return f"url(#{i})", (f'<filter id="{i}" x="-30%" y="-30%" width="160%" height="170%">'
                          '<feDropShadow dx="0" dy="1.8" stdDeviation="2" flood-color="#0b1220" flood-opacity=".24"/></filter>')


def squircle(cx=32, cy=32, r=28, n=5.0, punti=96):
    pts = []
    for k in range(punti):
        t = 2 * math.pi * k / punti
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{cx + r * math.copysign(abs(c) ** (2 / n), c):.2f} {cy + r * math.copysign(abs(s) ** (2 / n), s):.2f}")
    return "M" + " L".join(pts) + "Z"


SQ = squircle()


def lastra(forma, tinta="#ffffff", a=0.55):
    """vetro: riempimento traslucido più chiaro in alto, e il filo di luce sul bordo (forte in alto)"""
    fondo, fd = lg([(0, tinta, min(1, a + 0.2)), (1, tinta, a)])
    filo, ld = lg([(0, "#ffffff", 0.95), (0.5, "#ffffff", 0.25), (1, "#ffffff", 0.6)])
    return fd + ld, (forma.replace("/>", f' fill="{fondo}"/>') +
                     forma.replace("/>", f' fill="none" stroke="{filo}" stroke-width=".9"/>'))


def app(c1, c2, strati, c3=None):
    """fondo a squircle con la sfumatura a tre tinte (cambia davvero colore), alone del suo colore sotto,
    un riflesso in alto a sinistra; sopra i simboli"""
    c3 = c3 or c2
    fondo, fd = lg([(0, c1, 1), (0.55, c2, 1), (1, c3, 1)], 0, 0, 0.75, 1)
    i = _id("f")
    # alone del suo colore; per le lastre chiare (app di terzi, Esplora file) un'ombra grigia, che le stacca dal fondo
    ombra = tono(c3) if sum(int(c3[k:k + 2], 16) for k in (1, 3, 5)) < 600 else "#0b1220"
    alone_f = (f'<filter id="{i}" x="-30%" y="-30%" width="160%" height="170%">'
               f'<feDropShadow dx="0" dy="2.2" stdDeviation="2.8" flood-color="{ombra}" flood-opacity=".3"/></filter>')
    riflesso, rd = lg([(0, "#ffffff", 0.30), (1, "#ffffff", 0)])
    defs, corpo = [fd, alone_f, rd], [f'<g filter="url(#{i})"><path d="{SQ}" fill="{fondo}" stroke="#0b1220" stroke-opacity=".12" stroke-width=".7"/></g>',
                                      f'<path d="M10 22C12 9 22 6.5 34 6.5c-9 2-16 6-19.5 16.5z" fill="{riflesso}"/>']
    for d, c in strati:
        defs.append(d)
        corpo.append(c)
    return "".join(defs), "".join(corpo)


def pieno(forma, a=0.97):
    """un simbolo bianco pieno e netto, con un filo più chiaro in alto"""
    fondo, fd = lg([(0, "#ffffff", 1), (1, "#eef3ff", a)])
    return fd, forma.replace("/>", f' fill="{fondo}"/>')


def cartella(c1="#45c8f5", c2="#2f6be8", simbolo=None, c3="#4a4fd6"):
    """retro profondo, davanti vivo e brillante (tre tinte), filo di luce sul bordo; alone del suo colore"""
    dietro, dd = lg([(0, c2, 1), (1, c3, 1)], 0, 0, 0.6, 1)
    davanti, vd = lg([(0, c1, 1), (0.6, c2, 1), (1, c3, 0.95)], 0, 0, 0.5, 1)
    filo, ld = lg([(0, "#ffffff", 0.95), (0.4, "#ffffff", 0.2), (1, "#ffffff", 0.35)])
    i = _id("f")
    alone = (f'<filter id="{i}" x="-30%" y="-30%" width="160%" height="170%">'
             f'<feDropShadow dx="0" dy="2.2" stdDeviation="2.6" flood-color="{tono(c3)}" flood-opacity=".24"/></filter>')
    corpo = [f'<g filter="url(#{i})"><path d="M8 17a5 5 0 0 1 5-5h9.5a5 5 0 0 1 3.6 1.5l1.8 1.9a5 5 0 0 0 3.6 1.6H51a5 5 0 0 1 5 5V49a5 5 0 0 1-5 5H13a5 5 0 0 1-5-5z" '
             f'fill="{dietro}"/>',
             f'<rect x="8" y="24" width="48" height="30" rx="5" fill="{davanti}"/></g>',
             f'<rect x="8.4" y="24.4" width="47.2" height="29.2" rx="4.6" fill="none" stroke="{filo}" stroke-width=".8"/>']
    if simbolo:
        corpo.append(simbolo)
    return dd + vd + ld + alone, "".join(corpo)


def documenti_simbolo():
    return ('<rect x="26" y="31" width="12" height="16" rx="2.5" fill="#ffffff"/>'
            '<path d="M29 37h6M29 40.5h6M29 44h4" stroke="#2b62ff" stroke-width="1.3" stroke-linecap="round"/>')


def foglio(colore1, colore2, contenuto, sigla):
    """una lastra chiara a foglio (angolo arrotondato in alto a destra appena accennato), sopra vetro colorato"""
    carta, cd = lg([(0, "#ffffff", 1), (1, "#f2f5f9", 1)])
    o, od = morbida()
    forma = "M18 5h17l13 13v36a5 5 0 0 1-5 5H18a5 5 0 0 1-5-5V10a5 5 0 0 1 5-5z"
    tinta, td = lg([(0, colore1, 1), (1, colore2, 1)], 0, 0, 1, 1)
    corpo = (f'<g filter="{o}"><path d="{forma}" fill="{carta}"/></g>'
             f'<path d="{forma}" fill="none" stroke="#0b1220" stroke-opacity=".16" stroke-width=".7"/>'
             f'<path d="M35 5v8a5 5 0 0 0 5 5h8" fill="{tinta}" fill-opacity=".45"/>'
             + contenuto.replace("TINTA", tinta) +
             f'<text x="30.5" y="53" text-anchor="middle" font-family="Inter, sans-serif" font-weight="700" font-size="6.5" '
             f'fill="{colore2}" letter-spacing=".5">{sigla}</text>')
    return cd + od + td, corpo


def pdf():
    righe = ('<rect x="19" y="20" width="16" height="3" rx="1.5" fill="TINTA"/>'
             '<rect x="19" y="27" width="24" height="2" rx="1" fill="#c9d1db"/><rect x="19" y="32" width="20" height="2" rx="1" fill="#c9d1db"/>'
             '<rect x="19" y="37" width="24" height="2" rx="1" fill="#c9d1db"/>')
    return foglio("#ff7a6b", "#f0312a", righe, "PDF")


def immagine(sigla="JPG"):
    vista = ('<rect x="18" y="18" width="26" height="24" rx="5" fill="TINTA" fill-opacity=".35"/>'
             '<circle cx="37" cy="25" r="3" fill="#ffd25e"/>'
             '<path d="M18 37l7-7 6 6 4-4 9 8v.5a5 5 0 0 1-5 4.5H23a5 5 0 0 1-5-5z" fill="TINTA"/>')
    return foglio("#5fe39a", "#10b860", vista, sigla)


def impostazioni():
    pts = []
    for k in range(8):
        a0 = k * math.pi / 4
        for da, rr in ((-0.30, 12.4), (-0.17, 17), (0.17, 17), (0.30, 12.4)):
            pts.append(f"{32 + rr * math.cos(a0 + da):.2f} {32 + rr * math.sin(a0 + da):.2f}")
    ingr = "M" + " L".join(pts) + "Z"
    d, c = pieno(f'<path d="{ingr}" stroke="#ffffff" stroke-width="1.6" stroke-linejoin="round"/>')
    foro = f'<circle cx="32" cy="32" r="5.2" fill="{tono("#5f5ae0")}"/>'
    return app("#86c6ff", "#5f74ec", [(d, c + foro)], "#6a4fdc")


def esplora_file():
    d, c = cartella("#ffe36b", "#ffb21f", c3="#ff7a1a")
    return app("#eef5ff", "#cfe0fb", [(d, f'<g transform="translate(11 12) scale(.66)">{c}</g>')], "#a9c2ee")


def terminale():
    finestra = '<rect x="13" y="16" width="38" height="32" rx="7"/>'
    d, c = lastra(finestra, "#ffffff", 0.16)
    prompt = ('<path d="M20.5 26.5l6 5.5-6 5.5" fill="none" stroke="#7cf0a6" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>'
              '<path d="M30 38h11" stroke="#ffffff" stroke-opacity=".9" stroke-width="2.8" stroke-linecap="round"/>')
    return app("#5a5fc8", "#2a2a72", [(d, c + prompt)], "#15163a")


def posta():
    busta = '<rect x="12" y="19" width="40" height="27" rx="7"/>'
    d1, c1 = pieno(busta)
    lembo = f'<path d="M14.5 22L32 35l17.5-13" fill="none" stroke="{tono("#2f6be8")}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>'
    return app("#55d2f7", "#2f6be8", [(d1, c1 + lembo)], "#4a4fd6")


from glifi import GLIFI  # noqa: E402


def segno(nome, colore="#ffffff", x=16, y=16, lato=32, spessore=1.5, opacita=1):
    """un simbolo dei glifi (griglia 16) nel colore, alla posizione e grandezza volute"""
    g = GLIFI[nome].replace("#000", tono(colore)).replace('stroke-width="1.5"', f'stroke-width="{spessore}"')
    return f'<g transform="translate({x} {y}) scale({lato / 16})" opacity="{opacita}">{g}</g>'


def luogo(nome):
    """le cartelle dei luoghi: la stessa cartella, il simbolo bianco sul davanti"""
    return cartella(simbolo=segno(nome, "#ffffff", 22, 29, 20, 1.7, .95))


TIPI = {   # sigla: (chiaro, pieno, simbolo)
    "PDF": ("#ff7a6b", "#f0312a", None), "JPG": ("#5fe39a", "#10b860", None),
    "DOC": ("#6aa8ff", "#1f6bf0", "dettagli"), "XLS": ("#5fe39a", "#10a85a", "griglia"),
    "PPT": ("#ffb067", "#f2681c", "schermo"), "TXT": ("#b8c2d1", "#6b7789", "elenco"),
    "ZIP": ("#ffd36b", "#e89b0c", "chiavetta"), "MP3": ("#ff8ac0", "#e8338a", "musica"),
    "MP4": ("#b59bff", "#7148f0", "play"), "PY": ("#7ec4ff", "#3a6fe0", "terminale"),
    "": ("#c9d1dd", "#8592a6", "documento"),
}


def archivio(sigla="ZIP"):
    """un foglio con la cerniera: denti alterni giù dal centro e il cursore"""
    denti = "".join(f'<rect x="{25 if k % 2 else 29}" y="{6 + k * 3.2:.1f}" width="4" height="2.2" rx=".6" fill="TINTA"/>' for k in range(8))
    cursore = ('<rect x="23.5" y="32" width="11" height="9" rx="2.5" fill="TINTA"/>'
               '<rect x="26.5" y="35" width="5" height="3" rx="1.2" fill="#ffffff" fill-opacity=".9"/>')
    return foglio("#ffd36b", "#e89b0c", denti + cursore, sigla)


def tipo(sigla):
    c1, c2, simbolo = TIPI[sigla]
    if sigla == "PDF":
        return pdf()
    if sigla == "JPG":
        return immagine()
    return foglio(c1, c2, segno(simbolo, c2, 21, 20, 20, 1.6), sigla)


def oggetto(nome, c1="#a9b6cc", c2="#66758f", c3="#46526a"):
    """dispositivi e app senza disegno proprio: squircle col simbolo bianco"""
    return app(c1, c2, [("", segno(nome, "#ffffff", 15, 15, 34, 1.6))], c3)


def calendario():
    carta = '<rect x="13" y="13" width="38" height="38" rx="9"/>'
    d, c = pieno(carta)
    testa = f'<path d="M13 22a9 9 0 0 1 9-9h20a9 9 0 0 1 9 9v2H13z" fill="{tono("#f0312a")}"/>'
    giorno = ('<text x="32" y="45.5" text-anchor="middle" font-family="Inter, sans-serif" font-weight="600" '
              'font-size="18" fill="#1d2433">22</text>')
    return app("#ff8a7a", "#f0312a", [(d, c + testa + giorno)], "#c81e4a")


def browser():
    anello = '<circle cx="32" cy="32" r="16"/>'
    d, c = pieno(anello)
    ago = (f'<path d="M38.5 25.5L34.6 34.6 25.5 38.5 29.4 29.4z" fill="{tono("#2f6be8")}"/>'
           f'<path d="M38.5 25.5L29.4 29.4 34.6 34.6z" fill="{tono("#ff5a4a")}"/>')
    return app("#55e0f7", "#1f8bea", [(d, c + ago)], "#2f5ad6")


def cestino(pieno=False):
    """un cestino di vetro chiaro: corpo a tronco di cono con le costole, bordo in alto; pieno: fogli che spuntano"""
    corpo, cd = lg([(0, "#eef2f8", 0.97), (1, "#b9c4d6", 0.95)])
    bordo, bd = lg([(0, "#ffffff", 1), (1, "#dfe5ee", 1)])
    filo, fd = lg([(0, "#ffffff", 0.95), (1, "#ffffff", 0.3)])
    o, od = morbida()
    fogli = ""
    if pieno:
        fogli = ('<path d="M20 17l9-6 6 7z" fill="#ffffff" stroke="#c4ccd8" stroke-width=".6"/>'
                 '<path d="M30 16l10-7 5 9z" fill="#eef3fb" stroke="#c4ccd8" stroke-width=".6"/>'
                 f'<path d="M24 18l7-9 8 9z" fill="{tono("#7fb2ff")}" fill-opacity=".85"/>')
    costole = "".join(f'<path d="M{x} 24.5L{x + (x - 32) * 0.12:.2f} 53" stroke="#8b97aa" stroke-opacity=".8" stroke-width="1.4" stroke-linecap="round"/>'
                      for x in (24, 32, 40))
    return (cd + bd + fd + od,
            fogli + f'<g filter="{o}"><path d="M14.5 19h35l-3.6 35.2a4 4 0 0 1-4 3.6H22.1a4 4 0 0 1-4-3.6z" fill="{corpo}" stroke="#7d899c" stroke-opacity=".7" stroke-width=".8"/></g>'
            f'<path d="M15 19.5h34" stroke="{filo}" stroke-width=".8"/>' + costole +
            f'<rect x="11.5" y="15" width="41" height="6" rx="3" fill="{bordo}" stroke="#7d899c" stroke-opacity=".8" stroke-width=".8"/>')


def distintivo(nome, c1, c2):
    """dialoghi ed emblemi: un tondo colorato con il simbolo bianco"""
    fondo, fd = lg([(0, c1, 1), (1, c2, 1)], 0, 0, 0.6, 1)
    i = _id("f")
    alone = (f'<filter id="{i}" x="-30%" y="-30%" width="160%" height="170%">'
             f'<feDropShadow dx="0" dy="1.6" stdDeviation="2" flood-color="{tono(c2)}" flood-opacity=".3"/></filter>')
    riflesso, rd = lg([(0, "#ffffff", 0.32), (1, "#ffffff", 0)])
    return (fd + alone + rd, f'<g filter="url(#{i})"><circle cx="32" cy="32" r="26" fill="{fondo}"/></g>'
            f'<path d="M11 27a22 22 0 0 1 32-17.5c-12-1-24 4-32 17.5z" fill="{riflesso}"/>'
            + segno(nome, "#ffffff", 14, 14, 36, 1.7))


# --- dispositivi: oggetti veri (non squircle), colori pieni, il colore di sistema dove sta bene ---
def ombra_oggetto():
    i = _id("f")
    return f"url(#{i})", (f'<filter id="{i}" x="-30%" y="-30%" width="160%" height="170%">'
                          '<feDropShadow dx="0" dy="2" stdDeviation="2.2" flood-color="#0b1220" flood-opacity=".22"/></filter>')


def chiavetta(c1="#45c8f5", c2="#2f6be8", c3="#4a4fd6"):
    """chiavetta USB in piedi: connettore di metallo con i due fori, corpo nel colore di sistema"""
    metallo, md = lg([(0, "#f4f6f9", 1), (0.5, "#d3d9e2", 1), (1, "#aeb7c4", 1)], 0, 0, 1, 0)
    corpo, cd = lg([(0, c1, 1), (0.55, c2, 1), (1, c3, 1)], 0, 0, 0.8, 1)
    luce, ld = lg([(0, "#ffffff", 0.35), (1, "#ffffff", 0)], 0, 0, 1, 0)
    o, od = ombra_oggetto()
    return (md + cd + ld + od,
            f'<g filter="{o}">'
            f'<rect x="22" y="5" width="20" height="17" rx="2.5" fill="{metallo}" stroke="#8d97a6" stroke-opacity=".6" stroke-width=".8"/>'
            f'<rect x="17" y="20" width="30" height="40" rx="8" fill="{corpo}"/></g>'
            '<rect x="26.5" y="10" width="4" height="4" rx=".8" fill="#6f7a8a"/><rect x="33.5" y="10" width="4" height="4" rx=".8" fill="#6f7a8a"/>'
            f'<rect x="18.5" y="21.5" width="10" height="37" rx="5" fill="{luce}"/>'
            '<rect x="23" y="27" width="18" height="4" rx="2" fill="#ffffff" fill-opacity=".85"/>'
            '<circle cx="32" cy="50" r="2.3" fill="#ffffff" fill-opacity=".9"/>')


def scheda_sd(c1="#45c8f5", c2="#2f6be8", c3="#4a4fd6"):
    """scheda SD: angolo tagliato, contatti dorati in alto, etichetta chiara con la striscia di colore"""
    corpo, cd = lg([(0, "#4a5262", 1), (1, "#2b303b", 1)], 0, 0, 0.6, 1)
    etichetta, ed = lg([(0, "#ffffff", 1), (1, "#e9edf3", 1)])
    oro, gd = lg([(0, "#ffe08a", 1), (1, "#e2a93a", 1)])
    striscia, sd = lg([(0, c1, 1), (1, c3, 1)], 0, 0, 1, 0)
    o, od = ombra_oggetto()
    contatti = "".join(f'<rect x="{19 + k * 5.2:.1f}" y="9" width="3" height="9" rx="1.2" fill="{oro}"/>' for k in range(6))
    return (cd + ed + gd + sd + od,
            f'<g filter="{o}"><path d="M14 9a5 5 0 0 1 5-5h22l11 11v40a5 5 0 0 1-5 5H19a5 5 0 0 1-5-5z" fill="{corpo}"/></g>'
            + contatti +
            f'<rect x="19" y="24" width="28" height="30" rx="3" fill="{etichetta}"/>'
            f'<rect x="19" y="24" width="28" height="6" rx="3" fill="{striscia}"/><rect x="19" y="27" width="28" height="3" fill="{striscia}"/>'
            '<text x="33" y="46.5" text-anchor="middle" font-family="Inter, sans-serif" font-weight="800" font-size="11" '
            'fill="#2b303b" letter-spacing=".5">SD</text>')


def disco_esterno(c1="#45c8f5", c2="#2f6be8", c3="#4a4fd6"):
    """disco esterno: scatola chiara arrotondata, fascia più scura sotto, spia nel colore di sistema"""
    corpo, cd = lg([(0, "#fbfcfd", 1), (1, "#d7dde6", 1)])
    fascia, fd = lg([(0, "#c6ced9", 1), (1, "#aab4c2", 1)])
    o, od = ombra_oggetto()
    return (cd + fd + od,
            f'<g filter="{o}"><rect x="7" y="17" width="50" height="32" rx="8" fill="{corpo}" stroke="#97a2b2" stroke-opacity=".55" stroke-width=".8"/></g>'
            f'<path d="M7 39h50v2a8 8 0 0 1-8 8H15a8 8 0 0 1-8-8z" fill="{fascia}"/>'
            '<path d="M12 19.5h40" stroke="#ffffff" stroke-width="1" stroke-linecap="round"/>'
            f'<circle cx="48" cy="44" r="2.2" fill="{tono(c2)}"/><circle cx="48" cy="44" r="3.6" fill="{tono(c1)}" fill-opacity=".3"/>'
            '<path d="M14 44h12" stroke="#ffffff" stroke-opacity=".7" stroke-width="1.6" stroke-linecap="round"/>')


def disco_ottico():
    """CD/DVD: argento con un riflesso di colori, foro trasparente"""
    i = _id("g")
    defs = (f'<radialGradient id="{i}" cx=".5" cy=".5" r=".5"><stop offset=".25" stop-color="#e9edf2"/>'
            '<stop offset=".55" stop-color="#cfd6e0"/><stop offset="1" stop-color="#f6f8fa"/></radialGradient>')
    arc, ad = lg([(0, "#8fd3ff", 0.55), (0.5, "#ffd08a", 0.45), (1, "#e9a2ff", 0.5)], 0, 0, 1, 1)
    o, od = ombra_oggetto()
    return (defs + ad + od,
            f'<g filter="{o}"><path d="M32 6a26 26 0 1 1 0 52 26 26 0 0 1 0-52zm0 21a5 5 0 1 0 0 10 5 5 0 0 0 0-10z" fill="url(#{i})" fill-rule="evenodd" stroke="#aab4c2" stroke-width=".7"/></g>'
            f'<path d="M14 21a21 21 0 0 1 14-11l2 8a13 13 0 0 0-8 7z" fill="{arc}"/>'
            '<circle cx="32" cy="32" r="8.5" fill="none" stroke="#b8c1cd" stroke-width="1.2"/>')


MANIFESTO = [("Cartella", lambda: cartella()), ("Documenti", lambda: cartella(simbolo=documenti_simbolo())),
             ("Preventivo.pdf", pdf), ("Vacanze.jpg", immagine), ("Impostazioni", impostazioni),
             ("Esplora file", esplora_file), ("Terminale", terminale), ("Posta", posta)]
