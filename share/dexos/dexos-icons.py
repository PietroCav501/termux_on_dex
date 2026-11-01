#!/usr/bin/env python3
"""Icone DeX OS: un set completo e nostro, "vetro liquido" (share/dexos/icone).

  dexos-icons.py build [--accent #0067c0] [--out ~/.local/share/icons]   → stampa il nome del tema

Tutto è disegnato qui, niente Fluent né Adwaita sotto (Inherits=hicolor, solo per le app che non
conosciamo): ogni nome in icone/nomi.txt, ogni tipo di file del sistema (globs2 di shared-mime-info)
e ogni app installata ha la sua icona.
  a colori   cartelle (nell'accento, simbolo bianco del luogo), file (foglio con sigla e simbolo del
             tipo), dispositivi e categorie (squircle col simbolo), app (squircle a tre tinte; le app
             di terzi dentro lo squircle con la loro icona), dialoghi ed emblemi (tondo colorato)
  simboli    pulsanti, menu, barra: glifi a sagome piene (icone/contorni.json), "-symbolic" per GTK e
             normali in grigio scuro; il tema scuro (DeX-OS-Icons-Dark-…) li ha chiari
Un nome per accento e versione (DeX-OS-Icons-0067c0-v5): GTK ricorda i temi per nome.
"""
import base64
import colorsys
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

QUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(QUI, "icone"))
import mappa as M  # noqa: E402
import vetro as V  # noqa: E402

DEFAULT_ACCENT = "#0067c0"
VERSION = 10   # nel nome del tema: cambiando il disegno si rifanno da sole (e GTK le rilegge)
PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
CASA = os.environ.get("TOD_TERMUX_HOME") or os.path.expanduser("~")
CONTORNI = json.load(open(os.path.join(QUI, "icone", "contorni.json")))
GRIGIO = {"chiaro": "#3a4150", "scuro": "#e4e7ee"}   # simboli non "-symbolic" (menu, barra, pulsanti)
VUOTO = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>'
AZIONI = re.compile(r"^(go|edit|view|list|document|media-(playback|seek|skip|record|eject|view|playlist)|window|zoom|format|mail|object|insert|process|tab|bookmark|"
                    r"address-book|appointment|contact|help|call|system-(search|run|lock|log|reboot|shutdown|suspend|hibernate))-")
EMBLEMI_VUOTI = {"emblem-symbolic-link", "emblem-unreadable", "emblem-noread", "emblem-readonly", "emblem-nowrite"}


# --- colori -------------------------------------------------------------------------------------
def hls(c):
    return colorsys.rgb_to_hls(*(int(c[i:i + 2], 16) / 255 for i in (1, 3, 5)))


def da_hls(h, l, s):
    return "#%02x%02x%02x" % tuple(round(max(0, min(1, x)) * 255) for x in colorsys.hls_to_rgb(h % 1, l, s))


def nell_accento(colori, accento):
    """le tinte delle cartelle (pensate per il blu predefinito) girate sulla tonalità dell'accento"""
    h0, _, s0 = hls(DEFAULT_ACCENT)
    h1, _, s1 = hls(accento)
    k = min(1.0, s1 / s0) if s0 else 1.0
    out = []
    for c in colori:
        h, l, s = hls(c)
        out.append(da_hls(h + h1 - h0, l, s * k))
    return out


# --- file SVG -----------------------------------------------------------------------------------
def svg64(ricetta):
    defs, corpo = ricetta
    return (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="64" '
            f'viewBox="0 0 64 64"><defs>{defs}</defs>{corpo}</svg>')


def simbolica(g):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">{CONTORNI[g]}</svg>'


def grigia(g, colore):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><g fill="{colore}">{CONTORNI[g]}</g></svg>'


def segno_di(nome, contesto):
    g = M.glifo(nome)
    if g is None:
        for pre in ("gtk-", "stock_", "gnome-", "xfce-", "xfce4-", "kde-", "org.xfce.", "preferences-"):
            if nome.startswith(pre):
                g = M.glifo(nome[len(pre):])
                if g:
                    break
    return g if g in CONTORNI else M.RIPIEGO.get(contesto, "rombo")


# --- tipi di file -------------------------------------------------------------------------------
FAMIGLIE = [   # (espressione sul tipo MIME, chiaro, pieno, simbolo, sigla di ripiego)
    (r"^application/pdf|x-pdf|postscript|x-dvi|epub|x-mobipocket|djvu|x-xps|oxps", "#ff7a6b", "#f0312a", None, "PDF"),
    (r"^image/", "#5fe39a", "#10b860", None, "IMG"),
    (r"^audio/|x-mpegurl|playlist|x-cue", "#ff8ac0", "#e8338a", "musica", "AUDIO"),
    (r"^video/|x-matroska|x-flash-video|mp4|x-ogm", "#b59bff", "#7148f0", "play", "VIDEO"),
    (r"spreadsheet|excel|ms-excel|\.sheet|x-gnumeric|csv|tab-separated|x-kspread|calc", "#5fe39a", "#10a85a", "tabella", "XLS"),
    (r"presentation|powerpoint|ms-powerpoint|\.slide|impress|x-kpresenter", "#ffb067", "#f2681c", "schermo", "PPT"),
    (r"msword|wordprocessing|opendocument\.text|rtf|x-abiword|\.text|x-kword|wordperfect|x-mswrite|docbook|x-tex|latex|x-texinfo|troff",
     "#6aa8ff", "#1f6bf0", "dettagli", "DOC"),
    (r"zip|tar|gzip|bzip|xz|lzma|lzip|lz4|zstd|7z|rar|compress|archive|x-cpio|x-ar$|x-arj|x-lha|x-ace|x-cab|squashfs|stuffit|zoo|x-alz|x-lrzip|x-lzop",
     "#ffd36b", "#e89b0c", "archivio", "ZIP"),
    (r"debian|x-deb|x-rpm|redhat|x-apk|android\.package|vnd\.flatpak|x-snap|appimage|x-xpinstall|x-pkg|x-installer|java-archive|x-msi|x-ms-dos-executable|x-msdownload|x-ms-shortcut|x-ms-wim",
     "#8fc3ff", "#3d7ef0", "pacchetto", "PKG"),
    (r"font|x-tex-pk|x-tex-gf|x-afm|x-pcf|x-bdf|x-speedo|x-spss", "#b8c2d1", "#5b6b85", "carattere", "FONT"),
    (r"x-executable|x-sharedlib|x-object|x-core|x-elf|x-pie|x-mach|x-coredump|x-kernel|x-firmware|x-desktop|x-sharedlib",
     "#b8c2d1", "#58667e", "impostazioni", "BIN"),
    (r"iso9660|cd-image|x-raw-disk|disk-image|x-cdrdao|x-cue|x-qemu|vmdk|x-virtualbox|x-apple-diskimage|x-nrg|x-img",
     "#b8c2d1", "#58667e", "cd", "ISO"),
    (r"pkcs|x509|x-pem|pgp|gpg|x-ssh|keyring|x-java-keystore|x-x509|certificate|x-gnupg|signature|x-pkcs", "#b8c2d1", "#58667e", "chiave", "KEY"),
    (r"calendar|x-vcalendar|ics$", "#ff8a7a", "#f0312a", "calendario", "ICS"),
    (r"vcard|x-vcard|directory$", "#8fc3ff", "#3d7ef0", "rubrica", "VCF"),
    (r"message/|mbox|x-mbox|rfc822|x-mail|ms-outlook|x-mimearchive|x-ole-storage", "#8fc3ff", "#3d7ef0", "posta", "EML"),
    (r"x-shellscript|x-perl|x-python|x-ruby|javascript|ecmascript|json|xml|html|xhtml|css|x-php|x-java|x-csrc|x-chdr|x-c\+\+|x-csharp|x-go|x-rust|x-lua|x-tcl|x-makefile|x-cmake|x-sql|x-yaml|toml|x-scheme|x-lisp|x-haskell|x-kotlin|x-swift|x-dart|x-typescript|x-pascal|x-fortran|x-asm|x-patch|x-diff|x-gettext|x-po|x-subrip|x-ini|x-meson|x-ninja|x-ocaml|x-erlang|x-elixir|x-scala|x-groovy|x-matlab|x-r$|x-julia|x-nim|x-zig|x-vala|x-d$|x-objc|x-sh$|x-csh|x-zsh|x-fish|x-awk|x-m4|x-qml|x-sass|x-scss|x-less|x-coffee|x-markdown|markdown|x-rst|x-nix|x-dockerfile|x-script|wasm|x-bytecode|x-python-bytecode|x-class|x-dbus|x-ipynb|x-tex|x-bibtex|x-gradle|x-maven|x-cobol|x-ada|x-gherkin|x-verilog|x-vhdl|x-eiffel|x-twig|x-genie|x-blueprint|x-uri|x-iptables|x-ldif|x-texinfo|x-troff|x-mof|x-modelica|x-idl|x-dsrc|x-nemerle|x-ooc|x-opencl|x-protobuf|x-thrift|x-bsdl|x-glsl|x-hlsl|x-cuda|x-ocl|x-vb|x-vbscript|x-powershell|x-batch|x-prolog|x-forth|x-crystal|x-clojure|x-fsharp|x-vala",
     "#9fb6ff", "#4b5fe0", "codice", "CODE"),
    (r"^text/", "#c9d1dd", "#6b7789", "elenco", "TXT"),
    (r"x-trash|inode/", "#c9d1dd", "#6b7789", "cartella", ""),
    (r"model/|x-blender|x-3ds|x-stl|x-wavefront|x-gltf|x-fbx|x-collada|x-dwg|x-dxf|vnd\.dwg|x-freecad|x-sketchup|step|iges", "#ffb067", "#f2681c", "forme", "3D"),
    (r"x-sqlite|x-msaccess|database|x-dbf|x-sql", "#8fc3ff", "#3d7ef0", "server", "DB"),
    (r"x-bittorrent|x-torrent|x-metalink", "#9fb6ff", "#4b5fe0", "scarica", "TOR"),
    (r"x-gimp|x-krita|x-xcf|x-photoshop|x-adobe|illustrator|x-coreldraw|x-inkscape|x-sketch|x-figma|x-xara|x-openraster|x-ora",
     "#5fe39a", "#10b860", "pennello", "IMG"),
    (r"x-mswinurl|x-url|x-netscape-bookmark|internet-shortcut|x-mozilla-bookmarks|x-webarchive|x-mht", "#55e0f7", "#1f8bea", "globo", "URL"),
]
_FAMIGLIE = [(re.compile(e), c1, c2, g, s) for e, c1, c2, g, s in FAMIGLIE]
GENERICI = {   # i nomi "generici" della specifica
    "text-x-generic": "text/plain", "text-x-script": "text/x-script", "text-html": "text/html", "image-x-generic": "image/x",
    "audio-x-generic": "audio/x", "video-x-generic": "video/x", "package-x-generic": "application/x-tar",
    "font-x-generic": "font/x", "x-office-document": "application/msword", "x-office-spreadsheet": "application/vnd.ms-excel",
    "x-office-presentation": "application/vnd.ms-powerpoint", "x-office-calendar": "text/calendar",
    "x-office-address-book": "text/vcard", "x-office-drawing": "image/x", "application-x-executable": "application/x-executable",
    "text-x-generic-template": "text/plain", "x-office-document-template": "application/msword", "unknown": "",
    "application-x-addon": "application/x-xpinstall", "application-x-firmware": "application/x-firmware",
    "application-certificate": "application/pkcs", "x-package-repository": "application/x-tar",
    "inode-directory": "inode/directory", "text-x-preview": "text/plain", "application-x-desktop": "application/x-desktop",
}


def mime_di(nome):   # dal nome dell'icona (application-pdf) al tipo (application/pdf)
    if nome in GENERICI:
        return GENERICI[nome]
    return nome.replace("-", "/", 1) if "-" in nome else nome


SIGLE = {"application/vnd.ms-excel": "XLS", "application/vnd.ms-powerpoint": "PPT", "application/msword": "DOC",
         "text/calendar": "ICS", "image/jpeg": "JPG", "text/plain": "TXT", "video/quicktime": "MOV",
         "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "DOCX",
         "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "XLSX",
         "application/vnd.openxmlformats-officedocument.presentationml.presentation": "PPTX",
         "application/vnd.oasis.opendocument.text": "ODT", "application/vnd.oasis.opendocument.spreadsheet": "ODS",
         "application/vnd.oasis.opendocument.presentation": "ODP", "application/x-shellscript": "SH",
         "text/markdown": "MD", "application/x-sharedlib": "SO", "application/x-executable": "BIN"}


def estensioni():
    """tipo MIME → estensione da mostrare come sigla, da globs2 di Termux e del container: prima quella
    che compare nel nome del tipo (mp4, py, deb), poi la più corta tra quelle di peso maggiore"""
    tutte = {}
    for g in (os.path.join(PREFIX, "share/mime/globs2"), "/usr/share/mime/globs2"):
        try:
            righe = open(g, encoding="utf-8").read().splitlines()
        except OSError:
            continue
        for r in righe:
            p = r.split(":")
            if len(p) < 3 or not re.fullmatch(r"\*\.[A-Za-z0-9+]{1,5}", p[2]):
                continue
            tutte.setdefault(p[1], {})[p[2][2:].lower()] = max(int(p[0]), tutte.get(p[1], {}).get(p[2][2:].lower(), 0))
    out = {}
    for mime, ext in tutte.items():
        if mime in SIGLE:
            out[mime] = SIGLE[mime].lower()
            continue
        sub = mime.split("/", 1)[-1].lower()
        nel_nome = sorted((e for e in ext if e in sub and len(e) >= 2), key=lambda e: (-len(e), e))
        out[mime] = nel_nome[0] if nel_nome else sorted(ext, key=lambda e: (-ext[e], len(e), e))[0]
    return out


def famiglia(mime):
    for e, c1, c2, g, s in _FAMIGLIE:
        if e.search(mime):
            return c1, c2, g, s
    return "#c9d1dd", "#8592a6", "documento", ""


def sigla_di(mime, ext, ripiego):
    if ext and len(ext) <= 4 and re.fullmatch(r"[A-Za-z0-9+]+", ext):
        return ext.upper()
    return ripiego


def foglio_tipo(mime, ext):
    c1, c2, g, s = famiglia(mime)
    sigla = sigla_di(mime, ext, s)
    if mime.startswith("inode/directory"):
        return None
    if g == "archivio":
        return V.archivio(sigla or "ZIP")
    if g is None and mime.startswith("image/"):
        return V.immagine(sigla or "IMG")
    if g is None:
        return V.foglio(c1, c2, V.segno("documento", c2, 21, 20, 20, 1.6) if not mime.endswith("pdf") else
                        '<rect x="19" y="20" width="16" height="3" rx="1.5" fill="TINTA"/>'
                        '<rect x="19" y="27" width="24" height="2" rx="1" fill="#c9d1db"/><rect x="19" y="32" width="20" height="2" rx="1" fill="#c9d1db"/>'
                        '<rect x="19" y="37" width="24" height="2" rx="1" fill="#c9d1db"/>', sigla or "PDF")
    return V.foglio(c1, c2, V.segno(g, c2, 21, 20, 20, 1.6), sigla)


def segno_tipo(mime):
    if mime.startswith("inode/"):
        return "cartella"
    c1, c2, g, s = famiglia(mime)
    if g is None:
        return "immagine" if mime.startswith("image/") else "documento"
    return g if g in CONTORNI else "documento"


# --- cartelle, luoghi, dispositivi, categorie --------------------------------------------------
LASTRA = ("#a9b6cc", "#66758f", "#46526a")      # grigio ardesia dei dispositivi
COLORI_DISPOSITIVI = [   # (espressione, tinte)
    (r"wireless|wifi|network|modem|bluetooth|vpn|nfs|samba|server|workgroup|cloud|remote", ("#7fd6ff", "#2f8ef0", "#2f5ad6")),
    (r"phone|pda|smartphone|tablet|ipad|ipod|kdeconnect|multimedia-player", ("#5c6378", "#2a2f3d", "#161a24")),
    (r"audio|speaker|headphone|headset|hifi|microphone|sound", ("#ff9ac6", "#f03a7a", "#c8287a")),
    (r"camera|webcam|scanner|video|display|monitor|projector|tv", ("#5c6378", "#2a2f3d", "#161a24")),
    (r"battery|ac-adapter|ups|power", ("#8cf0a8", "#22b85a", "#14915a")),
    (r"input-gaming|joystick|gamepad", ("#c4a2ff", "#7b4fe0", "#5a35c0")),
]
COLORI_CATEGORIE = [
    (r"internet|network|web", ("#55e0f7", "#1f8bea", "#2f5ad6")),
    (r"multimedia|sound|video|audio|music", ("#ff9ac6", "#f03a7a", "#c8287a")),
    (r"graphics|appearance|theme|color|display", ("#ffd36b", "#ff8a2a", "#f0503a")),
    (r"office|business|education|documents", ("#8fc3ff", "#3d7ef0", "#2f4fd6")),
    (r"development|engineering|science|programming", ("#9fb6ff", "#4b5fe0", "#3a2fb8")),
    (r"games|entertainment|fun", ("#c4a2ff", "#7b4fe0", "#5a35c0")),
    (r"accessories|utilities|tools|other|misc", ("#ffcf70", "#f2a01c", "#e0701a")),
    (r"system|preferences|settings|hardware|personal|power", ("#b8c4d8", "#75849e", "#4f5d78")),
]


def tinte(nome, tabella, ripiego=LASTRA):
    for e, t in tabella:
        if re.search(e, nome):
            return t
    return ripiego


def luogo(nome, cartelle):
    c1, c2, c3 = cartelle
    if re.search(r"trash-full|trashcan_full", nome):
        return V.cestino(True)
    if re.search(r"trash|trashcan", nome):
        return V.cestino()
    if re.search(r"^start-here|distributor-logo|^dexos", nome):
        return logo(cartelle)
    if re.search(r"^(network|server|gnome-dev-network|gtk-network|knetattach|repository|nfs|samba|neat)", nome) and "folder" not in nome:
        t = tinte(nome, COLORI_DISPOSITIVI)
        return V.oggetto(segno_di(nome, "places"), *t)
    simbolo = None
    resto = re.sub(r"^(folder|user|gnome-fs|stock_folder|default-folder|inode)[-_]?", "", nome)
    if resto and resto not in ("directory", "open", "drag-accept", "visiting", "copy", "move", "new", "add"):
        g = segno_di(resto if M.glifo(resto) else nome, "places")
        if g not in ("cartella", "apri", "cartella-nuova"):
            simbolo = V.segno(g, "#ffffff", 22, 29, 20, 1.7, .95)
    elif resto in ("new", "add"):
        simbolo = V.segno("aggiungi", "#ffffff", 22, 29, 20, 1.9, .95)
    return V.cartella(c1, c2, simbolo, c3)


def dispositivo(nome, cartelle):
    """dischi e schede come oggetti veri (nel colore di sistema), il resto squircle col simbolo"""
    if re.search(r"media-flash|sd-mmc|sdcard|sd-card|memory-stick|^media-flash", nome):
        return V.scheda_sd(*cartelle)
    if re.search(r"removable-media-usb|drive-removable|media-removable|usb|thumbdrive|pendrive|gnome-dev-removable", nome) and "harddisk" not in nome:
        return V.chiavetta(*cartelle)
    if re.search(r"drive-harddisk|harddisk|drive-multidisk|^drive$|disk|ssd|nvme", nome):
        return V.disco_esterno(*cartelle)
    if re.search(r"optical|cdrom|dvd|bluray|^media-cd|disc", nome):
        return V.disco_ottico()
    return V.oggetto(segno_di(nome, "devices"), *tinte(nome, COLORI_DISPOSITIVI))


def logo(cartelle):   # DeX OS: quattro tessere di vetro nell'accento
    c1, c2, c3 = cartelle
    fondo, fd = V.lg([(0, c1, 1), (0.6, c2, 1), (1, c3, 1)], 0, 0, 0.8, 1)
    filo, ld = V.lg([(0, "#ffffff", 0.9), (1, "#ffffff", 0.25)])
    tessere = "".join(f'<rect x="{x}" y="{y}" width="24" height="24" rx="7" fill="{fondo}"/>'
                      f'<rect x="{x + .5}" y="{y + .5}" width="23" height="23" rx="6.5" fill="none" stroke="{filo}" stroke-width=".8"/>'
                      for x, y in ((6, 6), (34, 6), (6, 34), (34, 34)))
    return fd + ld, tessere


# --- app ----------------------------------------------------------------------------------------
def foto():
    return V.oggetto("immagine", "#ffd36b", "#ff8a2a", "#f0503a")


def note():
    d, c = V.pieno('<rect x="16" y="12" width="32" height="40" rx="6"/>')
    righe = f'<path d="M22 24h20M22 31h20M22 38h13" stroke="{V.tono("#e89b0c")}" stroke-width="2.6" stroke-linecap="round"/>'
    return V.app("#ffe58a", "#ffc21f", [(d, c + righe)], "#f29a0c")


APP = [   # (espressione sul nome dell'icona, ricetta) — le app di sistema, disegnate qui
    (r"^(org\.xfce\.thunar|thunar|system-file-manager|file-manager|org\.xfce\.filemanager|nautilus|org\.gnome\.Nautilus|dolphin|pcmanfm|nemo)$", lambda: V.esplora_file()),
    (r"terminal|konsole|xterm|org\.gnome\.Terminal|utilities-terminal|org\.gnome\.Vte", lambda: V.terminale()),
    (r"mousepad|text-editor|gedit|kate|kwrite|org\.gnome\.TextEditor|accessories-text-editor|leafpad|featherpad|xfce4-notes", note),
    (r"ristretto|image-viewer|eog|org\.gnome\.eog|shotwell|gthumb|org\.gnome\.Loupe|gwenview|viewnior|feh", foto),
    (r"screenshooter|screenshot|flameshot|spectacle|gnome-screenshot", lambda: V.oggetto("fotocamera", "#c4a2ff", "#7b4fe0", "#5a35c0")),
    (r"taskmanager|system-monitor|gnome-system-monitor|htop|ksysguard|plasma-systemmonitor", lambda: V.oggetto("chip", "#5c6378", "#2a2f3d", "#161a24")),
    (r"FileRoller|file-roller|ark|xarchiver|engrampa|archive-manager|org\.gnome\.ArchiveManager", lambda: V.oggetto("archivio", "#ffd36b", "#f2a01c", "#e0701a")),
    (r"pavucontrol|volume-control|pulseaudio", lambda: V.oggetto("volume-alto", "#ff9ac6", "#f03a7a", "#c8287a")),
    (r"software-update|update-manager|tod-updates|system-software-update", lambda: V.oggetto("aggiorna", "#7fd6ff", "#2f8ef0", "#2f5ad6")),
    (r"software-install|package-install|system-software-install|tod-installer|gdebi|synaptic|org\.gnome\.Software|plasmadiscover", lambda: V.oggetto("pacchetto", "#7fd6ff", "#2f8ef0", "#2f5ad6")),
    (r"clipman|clipboard|klipper|diodon|copyq", lambda: V.oggetto("incolla", "#b8c4d8", "#75849e", "#4f5d78")),
    (r"xfsm-logout|system-shutdown|system-log-out|application-exit|tod-spegni|gnome-logout", lambda: V.oggetto("accensione", "#ff8a7a", "#f0312a", "#c81e4a")),
    (r"org\.xfce\.about|help-about|xfce4-about", lambda: V.oggetto("informazioni", "#8fc3ff", "#3d7ef0", "#2f4fd6")),
    (r"webbrowser|web-browser|internet-web-browser|org\.xfce\.webbrowser", lambda: V.browser()),
    (r"mailreader|mail-client|internet-mail|evolution|thunderbird|geary|kmail", lambda: V.posta()),
    (r"DiskUtility|gnome-disks|disk-utility|tod-dischi|partitionmanager|gparted|baobab", lambda: V.oggetto("disco", "#b8c4d8", "#75849e", "#4f5d78")),
    (r"kwalletmanager|seahorse|keyring|passwords|keepass", lambda: V.oggetto("chiave", "#ffd36b", "#f2a01c", "#e0701a")),
    (r"calendar|orage|korganizer|gnome-calendar", lambda: V.calendario()),
    (r"calculator|galculator|qalculate|kcalc|gnome-calculator", lambda: V.oggetto("beuta", "#5c6378", "#2a2f3d", "#161a24")),
    (r"org\.xfce\.settings\.appearance|preferences-desktop-theme|appearance", lambda: V.oggetto("tavolozza", "#ffd36b", "#ff8a2a", "#f0503a")),
    (r"org\.xfce\.settings\.display|preferences-desktop-display|display-settings", lambda: V.oggetto("schermo", "#7fd6ff", "#2f8ef0", "#2f5ad6")),
    (r"org\.xfce\.settings\.keyboard|preferences-desktop-keyboard|keyboard", lambda: V.oggetto("tastiera", "#b8c4d8", "#75849e", "#4f5d78")),
    (r"org\.xfce\.settings\.mouse|preferences-desktop-peripherals|mouse", lambda: V.oggetto("mouse", "#b8c4d8", "#75849e", "#4f5d78")),
    (r"org\.xfce\.settings\.accessibility|accessibility", lambda: V.oggetto("utente", "#7fd6ff", "#2f8ef0", "#2f5ad6")),
    (r"default-applications|preferred-applications|mime-settings", lambda: V.oggetto("app", "#8fc3ff", "#3d7ef0", "#2f4fd6")),
    (r"org\.xfce\.settings\.editor|dconf-editor|settings-editor", lambda: V.oggetto("elenco", "#b8c4d8", "#75849e", "#4f5d78")),
    (r"org\.xfce\.notification|notifyd|preferences-desktop-notification", lambda: V.oggetto("notifica", "#ff8a7a", "#f0312a", "#c81e4a")),
    (r"org\.xfce\.powermanager|power-manager|battery", lambda: V.oggetto("batteria-70", "#8cf0a8", "#22b85a", "#14915a")),
    (r"org\.xfce\.session|session-properties", lambda: V.oggetto("accensione", "#b8c4d8", "#75849e", "#4f5d78")),
    (r"org\.xfce\.workspaces|workspace", lambda: V.oggetto("griglia", "#8fc3ff", "#3d7ef0", "#2f4fd6")),
    (r"org\.xfce\.xfdesktop|backdrop|wallpaper|preferences-desktop-wallpaper", lambda: V.oggetto("immagine", "#7fd6ff", "#2f8ef0", "#2f5ad6")),
    (r"org\.xfce\.xfwm4|window-manager|preferences-system-windows", lambda: V.oggetto("finestra", "#b8c4d8", "#75849e", "#4f5d78")),
    (r"org\.xfce\.panel|xfce4-panel", lambda: V.oggetto("menu", "#b8c4d8", "#75849e", "#4f5d78")),
    (r"^(preferences-system|preferences-desktop|org\.xfce\.settings\.manager|xfce4-settings|systemsettings|tod-settings|tod-control|org\.gnome\.Settings|gnome-control-center|kdesystemsettings|xfce-settings-manager)$", lambda: V.impostazioni()),
    (r"^(tod-start|start-here|dexos|distributor-logo)$", None),   # il logo, nell'accento
    (r"^(application-x-executable|application-default-icon|exec|applications-other|app)$", lambda: V.oggetto("app", "#b8c4d8", "#75849e", "#4f5d78")),
]
APP_NOTE = ["org.xfce.thunar", "system-file-manager", "org.xfce.terminal", "utilities-terminal", "org.xfce.mousepad",
            "accessories-text-editor", "org.xfce.ristretto", "org.xfce.screenshooter", "org.xfce.taskmanager",
            "org.gnome.FileRoller", "org.pulseaudio.pavucontrol", "system-software-update", "system-software-install",
            "xfce4-clipman-plugin", "xfsm-logout", "system-shutdown", "org.xfce.about", "org.xfce.webbrowser",
            "web-browser", "org.xfce.mailreader", "org.gnome.DiskUtility", "kwalletmanager", "preferences-system",
            "org.xfce.settings.manager", "xfce4-settings", "org.xfce.settings.appearance", "org.xfce.settings.display",
            "org.xfce.settings.keyboard", "org.xfce.settings.mouse", "org.xfce.settings.accessibility",
            "org.xfce.settings.default-applications", "org.xfce.settings.editor", "org.xfce.notification",
            "org.xfce.powermanager", "org.xfce.session", "org.xfce.workspaces", "org.xfce.xfdesktop", "org.xfce.xfwm4",
            "org.xfce.xfwm4-tweaks", "org.xfce.panel", "tod-start", "start-here", "application-x-executable",
            "org.xfce.terminalemulator", "org.xfce.filemanager", "thunar", "xarchiver", "org.gnome.Terminal",
            "accessories-calculator", "org.xfce.orage", "preferences-desktop-theme", "preferences-desktop"]


def ricetta_app(nome, cartelle):
    for e, r in APP:
        if re.search(e, nome):
            return logo(cartelle) if r is None else r()
    return None


def icona_originale(nome):
    """il file dell'icona di un'app di terzi (hicolor, pixmaps), il più grande"""
    radici = [os.path.join(CASA, ".local/share/icons/hicolor"), os.path.join(PREFIX, "share/icons/hicolor"),
              "/usr/share/icons/hicolor"]
    migliore, lato = None, -1
    for r in radici:
        for f in glob.glob(os.path.join(r, "*", "apps", nome + ".*")):
            d = os.path.basename(os.path.dirname(os.path.dirname(f)))
            n = 10000 if d == "scalable" else int(re.match(r"(\d+)", d).group(1)) if re.match(r"\d+", d) else 0
            if n > lato and f.endswith((".svg", ".png")):
                migliore, lato = f, n
    if migliore is None:
        for p in (os.path.join(PREFIX, "share/pixmaps"), "/usr/share/pixmaps"):
            for ext in (".svg", ".png"):
                if os.path.isfile(os.path.join(p, nome + ext)):
                    return os.path.join(p, nome + ext)
    return migliore


def png_256(f):
    if f.endswith(".png"):
        return open(f, "rb").read()
    try:
        return subprocess.run(["rsvg-convert", "-w", "256", "-h", "256", "--keep-aspect-ratio", f], capture_output=True,
                              check=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return None


def riempie(png):
    """vero se l'icona occupa già il quadrato (una tessera piena): allora si ritaglia a squircle"""
    try:
        import gi
        gi.require_version("GdkPixbuf", "2.0")
        from gi.repository import GdkPixbuf
        ld = GdkPixbuf.PixbufLoader()
        ld.write(png)
        ld.close()
        p = ld.get_pixbuf()
    except Exception:   # niente GdkPixbuf: la si mette sempre sulla lastra chiara
        return False
    if not p.get_has_alpha():
        return True
    w, h, rs, n, px = p.get_width(), p.get_height(), p.get_rowstride(), p.get_n_channels(), p.get_pixels()
    pieni = sum(1 for y in range(0, h, 4) for x in range(0, w, 4) if px[y * rs + x * n + 3] > 200)
    return pieni / (((h + 3) // 4) * ((w + 3) // 4)) > 0.82


def app_di_terzi(f):
    """l'icona originale dentro lo squircle: se è una tessera piena ritagliata, sennò su vetro chiaro"""
    png = png_256(f)
    if not png:
        return None
    dati = "data:image/png;base64," + base64.b64encode(png).decode()
    if riempie(png):
        i = V._id("c")
        o, od = V.morbida()
        return (f'<clipPath id="{i}"><path d="{V.SQ}"/></clipPath>' + od,
                f'<g filter="{o}"><g clip-path="url(#{i})"><image x="4" y="4" width="56" height="56" '
                f'preserveAspectRatio="xMidYMid slice" xlink:href="{dati}"/></g></g>')
    return V.app("#ffffff", "#f2f5fa", [("", f'<image x="13" y="13" width="38" height="38" xlink:href="{dati}"/>')], "#dfe6f0")


def app_installate():
    """i nomi d'icona delle app con una voce nel menu (Termux, container esportato, utente)"""
    nomi = set()
    for d in (os.path.join(PREFIX, "share/applications"), os.path.join(CASA, ".local/share/applications"), "/usr/share/applications"):
        for f in glob.glob(os.path.join(d, "*.desktop")):
            try:
                for r in open(f, encoding="utf-8", errors="replace"):
                    if r.startswith("Icon="):
                        n = r[5:].strip()
                        if n and "/" not in n and not n.startswith("@@") and not n.startswith("tod-android-"):
                            nomi.add(n)
                        break
            except OSError:
                pass
    return nomi


# --- costruzione --------------------------------------------------------------------------------
def leggi_nomi():
    out = []
    for r in open(os.path.join(QUI, "icone", "nomi.txt"), encoding="utf-8"):
        if r.strip() and not r.startswith("#"):
            c, n = r.rstrip("\n").split("\t")
            out.append((c, n))
    return out


def build(accent, out):
    name = f"DeX-OS-Icons-{accent.lstrip('#').lower()}-v{VERSION}"
    scuro = f"DeX-OS-Icons-Dark-{accent.lstrip('#').lower()}-v{VERSION}"
    root = os.path.join(out, name)
    app = sorted(app_installate() | set(APP_NOTE))
    # l'icona di ripiego di GTK anche in hicolor (vedi sotto): a ogni giro, anche senza rifare il tema
    mancante = svg64(V.oggetto("immagine", *LASTRA))
    h = os.path.join(out, "hicolor", "scalable", "status")
    os.makedirs(h, exist_ok=True)
    with open(os.path.join(h, "image-missing.svg"), "w") as f:
        f.write(mancante)
    # c'è l'indice delle icone esportate (desktop_refresh_caches): GTK si fida di quello e senza
    # rifarlo l'icona nuova non la vede
    if os.path.exists(os.path.join(out, "hicolor", "icon-theme.cache")) and shutil.which("gtk-update-icon-cache"):
        subprocess.run(["gtk-update-icon-cache", "-q", "-f", "-t", os.path.join(out, "hicolor")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # GIMP usa un suo tema (Legacy, che eredita "Color", inesistente in GIMP 3): le icone comuni (frecce,
    # più/meno, cartelle) le prendeva da Adwaita, tolto dalla pulizia. "Color" rimanda a DeX OS
    os.makedirs(os.path.join(out, "Color"), exist_ok=True)
    with open(os.path.join(out, "Color", "index.theme"), "w") as f:
        f.write(f"[Icon Theme]\nName=Color\nComment=Ripiego per GIMP: le icone DeX OS\nInherits={name},hicolor\n"
                "Hidden=true\nDirectories=\n")
    impronta = hashlib.sha1("\n".join(app).encode()).hexdigest()[:12]   # app nuove → si rifanno le loro
    try:
        if open(os.path.join(root, ".app")).read() == impronta and os.path.isfile(os.path.join(out, scuro, "index.theme")):
            return name
    except OSError:
        pass
    cartelle = nell_accento(("#45c8f5", "#2f6be8", "#4a4fd6"), accent)
    files, files_scuro = {}, {}
    fatti = set()

    def colori(ctx, n, ricetta):
        if ricetta is not None:
            files[f"scalable/{ctx}/{n}.svg"] = svg64(ricetta)
            fatti.add(n)

    def simbolo(ctx, n, g, mono=False):
        files[f"symbolic/{ctx}/{n}-symbolic.svg"] = simbolica(g)
        if mono and n not in fatti:   # pulsanti e menu chiedono anche il nome senza "-symbolic"
            files[f"scalable/{ctx}/{n}.svg"] = grigia(g, GRIGIO["chiaro"])
            files_scuro[f"scalable/{ctx}/{n}.svg"] = grigia(g, GRIGIO["scuro"])

    ext = estensioni()
    tipi = {mime.replace("/", "-", 1) for mime in ext}
    elenco = leggi_nomi() + [("mimetypes", t) for t in sorted(tipi)]
    visti = set()
    for ctx, n in elenco:
        if n in visti:
            continue
        visti.add(n)
        if ctx in ("places", "devices", "categories", "emblems") and AZIONI.match(n):
            ctx = "actions"   # go-home, edit-find…: pulsanti, non oggetti a colori
        if ctx == "places":
            colori(ctx, n, luogo(n, cartelle))
            simbolo(ctx, n, segno_di(n, ctx))
        elif ctx == "devices":
            colori(ctx, n, dispositivo(n, cartelle))
            simbolo(ctx, n, segno_di(n, ctx))
        elif ctx == "categories":
            g = segno_di(n, ctx)
            colori(ctx, n, V.oggetto(g, *tinte(n, COLORI_CATEGORIE, COLORI_CATEGORIE[-2][1])))
            simbolo(ctx, n, g)
        elif ctx == "mimetypes":
            mime = mime_di(n)
            r = luogo("folder", cartelle) if mime.startswith("inode/directory") else foglio_tipo(mime, ext.get(mime))
            colori(ctx, n, r)
            simbolo(ctx, n, segno_tipo(mime))
        elif ctx == "emblems":
            if n in EMBLEMI_VUOTI:
                files[f"scalable/{ctx}/{n}.svg"] = files[f"symbolic/{ctx}/{n}-symbolic.svg"] = VUOTO
                continue
            g = segno_di(n, ctx)
            t = (("#ff8a7a", "#e5332a") if re.search(r"error|unreadable|urgent|important", n) else
                 ("#ffd36b", "#f29a0c") if re.search(r"warning|favorite|new", n) else
                 ("#8cf0a8", "#1fae55") if re.search(r"ok|default|success|check", n) else ("#8fc3ff", "#2f6be8"))
            colori(ctx, n, V.distintivo(g, *t))
            simbolo(ctx, n, g)
        else:
            g = segno_di(n, ctx)
            if re.search(r"^(gtk-)?dialog-(error|warning|information|question|password)|^dialog-(info)$", n):
                t = {"error": ("#ff8a7a", "#e5332a"), "warning": ("#ffd36b", "#f29a0c"), "password": ("#b8c4d8", "#5b6b85")}
                k = next((k for k in t if k in n), None)
                colori(ctx, n, V.distintivo(g, *(t[k] if k else ("#8fc3ff", "#2f6be8"))))
            simbolo(ctx, n, g, mono=True)
    # app: le nostre disegnate, quelle di terzi nello squircle con la loro icona
    for n in app:
        r = ricetta_app(n, cartelle)
        if r is None:
            f = icona_originale(n)
            r = app_di_terzi(f) if f else None
        if r is not None:
            for k in [k for k in files if k.startswith("scalable/") and k.endswith(f"/{n}.svg")]:
                del files[k]   # un nome, un'icona sola: quella dell'app
                files_scuro.pop(k, None)
            colori("apps", n, r)
            files[f"symbolic/apps/{n}-symbolic.svg"] = simbolica(segno_di(n, "apps"))
    for alias in ("tod-start", "start-here", "dexos", "distributor-logo", "org.xfce.panel.applicationsmenu"):
        files[f"scalable/apps/{alias}.svg"] = svg64(logo(cartelle))

    # l'icona di ripiego di GTK: se manca in tutta la catena del tema, GTK 3 si ferma (abort). GIMP ha un
    # tema suo (Legacy → hicolor) che non vede DeX OS, e senza Adwaita (tolto dalla pulizia) non si apriva
    # più (26 ottobre): la stessa icona va anche in hicolor dell'utente, il ripiego di ogni tema
    files["scalable/status/image-missing.svg"] = mancante
    files["symbolic/status/image-missing-symbolic.svg"] = simbolica("immagine")
    scrivi(out, name, files, f"Inherits=hicolor", f"Icone di Termux On DeX (accento {accent})")
    scrivi(out, scuro, files_scuro, f"Inherits={name},hicolor", f"Icone di Termux On DeX, tema scuro (accento {accent})")
    with open(os.path.join(root, ".app"), "w") as f:
        f.write(impronta)
    # come per i temi: si tengono le ultime versioni, le altre si tolgono
    old = sorted((d for d in os.listdir(out) if d.startswith("DeX-OS-Icons-") and d not in (name, scuro)),
                 key=lambda d: os.path.getmtime(os.path.join(out, d)), reverse=True)
    for d in old[8:] + [d for d in old if d.endswith(".nuovo")]:
        shutil.rmtree(os.path.join(out, d), ignore_errors=True)
    return name


def scrivi(out, name, files, inherits, comment):
    """i file del tema; quelli uguali una volta sola (gli altri sono collegamenti)"""
    root = os.path.join(out, name)
    tmp = root + ".nuovo"
    shutil.rmtree(tmp, ignore_errors=True)
    primi = {}
    for rel in sorted(files):
        path = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        dati = files[rel]
        h = hashlib.sha1(dati.encode()).digest()
        if h in primi:
            os.symlink(os.path.relpath(primi[h], os.path.dirname(path)), path)
            continue
        primi[h] = path
        with open(path, "w") as f:
            f.write(dati)
    dirs = sorted({os.path.dirname(r) for r in files})
    with open(os.path.join(tmp, "index.theme"), "w") as f:
        f.write(f"[Icon Theme]\nName=DeX OS\nComment={comment}\n{inherits}\nExample=folder\n"
                f"Directories={','.join(dirs)}\n\n")
        for d in dirs:
            ctx = d.split("/")[1].capitalize()
            size = 16 if d.startswith("symbolic") or ctx in ("Actions", "Status", "Panel", "Emotes", "Animations") else 64
            f.write(f"[{d}]\nSize={size}\nMinSize=8\nMaxSize=512\nType=Scalable\nContext={ctx}\n\n")
    shutil.rmtree(root, ignore_errors=True)
    os.rename(tmp, root)


def main():
    args = sys.argv[1:]
    if not args or args[0] != "build":
        print(__doc__)
        return 1
    opt = {"--accent": DEFAULT_ACCENT, "--out": os.path.expanduser("~/.local/share/icons")}
    for i, a in enumerate(args):
        if a in opt and i + 1 < len(args):
            opt[a] = args[i + 1]
    if not re.fullmatch(r"#[0-9a-fA-F]{6}", opt["--accent"]):
        print("accento non valido:", opt["--accent"], file=sys.stderr)
        return 2
    print(build(opt["--accent"], opt["--out"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
