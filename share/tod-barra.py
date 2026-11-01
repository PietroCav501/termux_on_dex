#!/usr/bin/env python3
"""Barra delle applicazioni di DeX OS, al posto di quella di XFCE.

Al centro (o a sinistra) lo Start e le app: fissate e aperte, nell'ordine scelto (si trascinano tenendo
premuto), con un segno sotto: lungo nel colore di sistema per l'app in primo piano, corto per quelle
aperte o ridotte a icona; niente segno = chiusa. Passando sopra un'app aperta compare l'anteprima delle
sue finestre (nello stile e alla stessa distanza dalla barra dei pannelli di tod-pannelli.py). A destra
le icone di sistema (quelle delle app, rete, volume, batteria, notifiche, orologio).

  tod-barra.py [--replace]

Impostazioni in ~/.config/tod/barra.json (Impostazioni → Barra): app fissate, allineamento, grandezza,
anteprime.
"""
import ctypes
import ctypes.util
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import Gdk, GdkPixbuf, GdkX11, Gio, GLib, Gtk, Pango  # noqa: E402

try:   # GLib 2.86: le funzioni Unix di Gio stanno in GioUnix
    gi.require_version("GioUnix", "2.0")
    from gi.repository import GioUnix
    DesktopAppInfo = GioUnix.DesktopAppInfo
except (ValueError, ImportError):
    DesktopAppInfo = Gio.DesktopAppInfo

QUI = os.path.dirname(os.path.abspath(__file__))
PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
TMP = os.environ.get("TMPDIR", "/tmp")
CASA = os.environ.get("TOD_TERMUX_HOME", os.path.expanduser("~"))
CONF = os.path.join(CASA, ".config", "tod")
FILE = os.path.join(CONF, "barra.json")
PIDFILE = os.path.join(TMP, "tod-barra.pid")
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "")).startswith("it")

# la prima volta: queste, se installate (si cambiano dalle Impostazioni o trascinando)
PRIME = ["thunar.desktop", "chromium.desktop", "firefox.desktop", "xfce4-terminal.desktop", "libreoffice-writer.desktop"]
PREDEFINITE = {"fissate": ["thunar.desktop", "chromium.desktop", "xfce4-terminal.desktop"],
               "allineamento": "centro", "grandezza": "media", "anteprime": True}
GRANDEZZE = {"piccola": (40, 22), "media": (48, 26), "grande": (56, 32)}   # altezza della barra, icona (a 96 DPI)
MARGINE = 12   # come tod-pannelli.py: distanza dei pannelli (e delle anteprime) dalla barra


def T(it, en):
    return it if ITALIAN else en


def log(*a):
    print("tod-barra", time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


# --- impostazioni ------------------------------------------------------------------------------
def carica():
    try:
        c = json.load(open(FILE))
    except (OSError, ValueError):
        c = {}
        prime = []
        for ident in PRIME:
            try:
                if DesktopAppInfo.new(ident) is not None:
                    prime.append(ident)
            except TypeError:
                pass
        if prime:
            c["fissate"] = prime
    for k, v in PREDEFINITE.items():
        c.setdefault(k, v)
    return c


def salva(c):
    os.makedirs(CONF, exist_ok=True)
    tmp = FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(c, f, indent=1)
    os.replace(tmp, FILE)


def accento():
    a = "#0067c0"
    try:
        for r in open(os.path.join(CONF, "tod.conf")):
            if r.startswith("ACCENTO="):
                v = r.split("=", 1)[1].strip().strip('"')
                if re.fullmatch(r"#[0-9a-fA-F]{6}", v):
                    a = v
    except OSError:
        pass
    return a


def scuro():
    return "dark" in (Gtk.Settings.get_default().get_property("gtk-theme-name") or "").lower()


SCALA = 1.0


def px(n):
    return int(round(n * SCALA))


CSS = """
/* il filo in alto dentro lo sfondo: come bordo della finestra GTK non lo copriva lo sfondo e LINEA (nero
   all'8%) finiva sul nero di X, una striscia nera */
.tod-barra { background-color: FONDO; border: none; box-shadow: inset 0 1px LINEA; font-family: Inter, sans-serif; color: TESTO; }
.tod-barra .app { border-radius: 8px; padding: 0; margin: 4px 1px; }
.tod-barra .app:hover { background-color: PASSAGGIO; }
.tod-barra .app.attiva { background-color: ATTIVA; box-shadow: inset 0 0 0 1px LINEA; }
.tod-barra .app.trascina { opacity: 0.35; }
.tod-barra .segno { border-radius: 2px; min-height: 3px; background-color: SPENTO; }
.tod-barra .segno.attiva { background-color: ACCENTO; }
.tod-barra .vassoio { border-radius: 8px; padding: 0 6px; margin: 4px 0; }
.tod-barra .vassoio:hover { background-color: PASSAGGIO; }
.tod-barra .orologio { font-size: 9pt; }
.tod-barra .desktop { margin: 8px 0 8px 4px; border-left: 1px solid LINEA; }
.tod-barra .desktop:hover { background-color: PASSAGGIO; }
.tod-barra .numero {
  background-color: ACCENTO; color: #ffffff; border-radius: 7px; font-size: 7pt; font-weight: 700;
  min-width: 14px; min-height: 14px; padding: 0 3px;
}
.tod-anteprima { background-color: transparent; }
.tod-anteprima .root {
  background-color: PANNELLO; border: 1px solid LINEA; border-radius: 14px; padding: 8px;
  font-family: Inter, sans-serif; color: TESTO;
}
.tod-anteprima.flat .root { border-radius: 0; }
.tod-anteprima .finestra { border-radius: 10px; padding: 6px; }
.tod-anteprima .finestra:hover { background-color: PASSAGGIO; }
.tod-anteprima .finestra.attiva { background-color: alpha(ACCENTO, 0.14); }
.tod-anteprima .titolo { font-size: 9pt; font-weight: 500; }
.tod-anteprima .miniatura { border-radius: 6px; background-color: LINEA; }
.tod-anteprima .ridotta { font-size: 8pt; color: TENUE; }
.tod-anteprima button.chiudi {
  border: none; box-shadow: none; background: transparent; border-radius: 10px; padding: 2px; min-width: 0; min-height: 0;
}
.tod-anteprima button.chiudi:hover { background-color: #e81123; color: #ffffff; }
"""
COLORI = {
    False: dict(FONDO="#f3f4f8", LINEA="rgba(0, 0, 0, 0.08)", TESTO="#1d1d1f", TENUE="#6e6e73",
                PASSAGGIO="rgba(255, 255, 255, 0.75)", ATTIVA="#ffffff", SPENTO="#8a8a8e", PANNELLO="#f2f2f5"),
    True: dict(FONDO="#202022", LINEA="rgba(255, 255, 255, 0.08)", TESTO="#f5f5f7", TENUE="#a1a1a6",
               PASSAGGIO="rgba(255, 255, 255, 0.07)", ATTIVA="rgba(255, 255, 255, 0.12)", SPENTO="#8e8e93",
               PANNELLO="#242428"),
}


def css():
    c = dict(COLORI[scuro()], ACCENTO=accento())
    out = CSS
    for k in sorted(c, key=len, reverse=True):
        out = out.replace(k, c[k])
    return re.sub(r"(\d+(?:\.\d+)?)px", lambda m: "%dpx" % max(1, px(float(m.group(1)))), out).encode()


# --- X11: lo spazio della barra (struts), con ctypes come tod-edges.py ---------------------------
_x = None


def xlib():
    global _x
    if _x is None:
        _x = ctypes.CDLL(ctypes.util.find_library("X11") or os.path.join(PREFIX, "lib/libX11.so"))
        _x.XInternAtom.restype = ctypes.c_ulong
        _x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        _x.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int,
                                       ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        _x.XFlush.argtypes = [ctypes.c_void_p]
        _x.XOpenDisplay.restype = ctypes.c_void_p
        _x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    return _x


_dpy = None


def riserva_spazio(win, altezza, larghezza_schermo, alto_schermo):
    """_NET_WM_STRUT(_PARTIAL): le finestre ingrandite si fermano sopra la barra (una connessione X nostra:
    le proprietà stanno nel server, vale per tutti)"""
    global _dpy
    gw = win.get_window()
    if gw is None:
        return
    x = xlib()
    if _dpy is None:
        _dpy = x.XOpenDisplay(None)
        _gestisci_errori(x, _dpy)
    dpy = _dpy
    xid = GdkX11.X11Window.get_xid(gw)
    cardinal = x.XInternAtom(dpy, b"CARDINAL", 0)
    parziale = (ctypes.c_long * 12)(0, 0, 0, altezza, 0, 0, 0, 0, 0, 0, 0, larghezza_schermo - 1)
    semplice = (ctypes.c_long * 4)(0, 0, 0, altezza)
    x.XChangeProperty(dpy, xid, x.XInternAtom(dpy, b"_NET_WM_STRUT_PARTIAL", 0), cardinal, 32, 0, parziale, 12)
    x.XChangeProperty(dpy, xid, x.XInternAtom(dpy, b"_NET_WM_STRUT", 0), cardinal, 32, 0, semplice, 4)
    x.XFlush(dpy)


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]


class XEvent(ctypes.Union):
    _fields_ = [("xclient", XClientMessageEvent), ("pad", ctypes.c_long * 24)]


def messaggio_wm(xid, nome, *dati):
    """un messaggio EWMH alla radice (come xdotool): _NET_ACTIVE_WINDOW, _NET_CLOSE_WINDOW..."""
    global _dpy
    x = xlib()
    if _dpy is None:
        _dpy = x.XOpenDisplay(None)
        _gestisci_errori(x, _dpy)
    x.XDefaultRootWindow.restype = ctypes.c_ulong
    x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(XEvent)]
    ev = XEvent()
    ev.xclient.type = 33   # ClientMessage
    ev.xclient.send_event = 1
    ev.xclient.window = xid
    ev.xclient.message_type = x.XInternAtom(_dpy, nome.encode(), 0)
    ev.xclient.format = 32
    for i, d in enumerate(dati[:5]):
        ev.xclient.data[i] = d
    root = x.XDefaultRootWindow(_dpy)
    x.XSendEvent(_dpy, root, 0, (1 << 19) | (1 << 20), ctypes.byref(ev))   # SubstructureRedirect|Notify
    x.XFlush(_dpy)


# --- le finestre aperte, lette dal gestore delle finestre (EWMH) ------------------------------------
# Al posto di libwnck: con PyGObject andava in crash appena una finestra si chiudeva (anche senza
# segnali collegati). Qui solo proprietà X: _NET_CLIENT_LIST, _NET_ACTIVE_WINDOW, WM_CLASS, stato, icone.
def _x11():
    x = ctypes.CDLL(ctypes.util.find_library("X11") or os.path.join(PREFIX, "lib/libX11.so"))
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XInternAtom.restype = ctypes.c_ulong
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XDefaultRootWindow.restype = ctypes.c_ulong
    x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long,
                                     ctypes.c_int, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
                                     ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
                                     ctypes.POINTER(ctypes.c_void_p)]
    x.XFree.argtypes = [ctypes.c_void_p]
    x.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]
    x.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    x.XSetErrorHandler.restype = ctypes.c_void_p
    x.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
    x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    return x


# finestre sparite: sulle nostre connessioni l'errore si ignora; quelli di GTK vanno al suo gestore
# (le sue "trappole" contano gli errori: senza, GTK crede riuscita ogni chiamata fallita)
_NOSTRE = set()
_PRIMA = [None]
_CHIAVE = threading.Lock()
_TIPO_GESTORE = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)


def _errore_x(dpy, ev):
    if dpy in _NOSTRE or not _PRIMA[0]:
        return 0
    return _PRIMA[0](dpy, ev)


_GESTORE_ERRORI = _TIPO_GESTORE(_errore_x)


def _gestisci_errori(x, dpy):
    _NOSTRE.add(dpy)
    with _CHIAVE:   # una volta sola, anche dai thread (la seconda prenderebbe il nostro come "prima")
        if _PRIMA[0] is None:
            x.XSetErrorHandler.restype = ctypes.c_void_p
            x.XSetErrorHandler.argtypes = [ctypes.c_void_p]
            prima = x.XSetErrorHandler(_GESTORE_ERRORI)
            _PRIMA[0] = _TIPO_GESTORE(prima) if prima else False


class Proprieta:
    def __init__(self):
        self.x = _x11()
        self.dpy = self.x.XOpenDisplay(None)
        _gestisci_errori(self.x, self.dpy)
        self.root = self.x.XDefaultRootWindow(self.dpy)
        self._atomi = {}

    def atomo(self, nome):
        if nome not in self._atomi:
            self._atomi[nome] = self.x.XInternAtom(self.dpy, nome.encode(), 0)
        return self._atomi[nome]

    def leggi(self, win, nome, lunghezza=1 << 20):
        """(formato, dati): 32 → lista di interi, 8 → byte"""
        tipo, fmt, n, resto, dati = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        r = self.x.XGetWindowProperty(self.dpy, win, self.atomo(nome), 0, lunghezza, 0, 0, ctypes.byref(tipo),
                                      ctypes.byref(fmt), ctypes.byref(n), ctypes.byref(resto), ctypes.byref(dati))
        if r != 0 or not dati.value:
            return None, None
        try:
            if fmt.value == 32:   # con Xlib i dati a 32 bit arrivano come "long" (64 bit qui)
                return 32, list((ctypes.c_long * n.value).from_address(dati.value))
            if fmt.value == 8:
                return 8, ctypes.string_at(dati.value, n.value)
            return fmt.value, None
        finally:
            self.x.XFree(dati)

    def interi(self, win, nome):
        f, d = self.leggi(win, nome)
        return d if f == 32 else []

    def testo(self, win, nome):
        f, d = self.leggi(win, nome)
        return d if f == 8 else b""

    def dimensioni(self, win):
        attr = (ctypes.c_int * 64)()   # XWindowAttributes: x, y, width, height, ...
        if not self.x.XGetWindowAttributes(self.dpy, win, attr):
            return 0, 0
        return attr[2], attr[3]


class Finestra:
    """una finestra aperta, con i metodi che servono alla barra"""

    def __init__(self, prop, xid):
        self.p, self.xid = prop, xid

    def __eq__(self, altra):
        return isinstance(altra, Finestra) and altra.xid == self.xid

    def __hash__(self):
        return hash(self.xid)

    def get_xid(self):
        return self.xid

    def get_name(self):
        t = self.p.testo(self.xid, "_NET_WM_NAME") or self.p.testo(self.xid, "WM_NAME")
        return t.decode(errors="replace")

    def classe(self):
        parti = self.p.testo(self.xid, "WM_CLASS").split(b"\0")
        return [c.decode(errors="replace") for c in parti if c]

    def get_class_instance_name(self):
        c = self.classe()
        return c[0] if c else ""

    def get_class_group_name(self):
        c = self.classe()
        return c[1] if len(c) > 1 else (c[0] if c else "")

    def get_pid(self):
        d = self.p.interi(self.xid, "_NET_WM_PID")
        return d[0] if d else 0

    def stato(self):
        return set(self.p.interi(self.xid, "_NET_WM_STATE"))

    def is_minimized(self):
        return self.p.atomo("_NET_WM_STATE_HIDDEN") in self.stato()

    def da_mostrare(self):
        if self.p.atomo("_NET_WM_STATE_SKIP_TASKBAR") in self.stato():
            return False
        tipi = self.p.interi(self.xid, "_NET_WM_WINDOW_TYPE")
        ok = {self.p.atomo("_NET_WM_WINDOW_TYPE_NORMAL"), self.p.atomo("_NET_WM_WINDOW_TYPE_DIALOG")}
        return not tipi or tipi[0] in ok

    def get_client_window_geometry(self):
        w, h = self.p.dimensioni(self.xid)
        return 0, 0, w, h

    def get_icon(self, lato=48):
        """_NET_WM_ICON (ARGB a 32 bit: larghezza, altezza, pixel...) → la misura più vicina"""
        d = self.p.interi(self.xid, "_NET_WM_ICON")
        migliore, i = None, 0
        while i + 2 <= len(d):
            w, h = d[i], d[i + 1]
            if w <= 0 or h <= 0 or i + 2 + w * h > len(d):
                break
            if migliore is None or abs(w - lato) < abs(migliore[0] - lato):
                migliore = (w, h, i + 2)
            i += 2 + w * h
        if migliore is None:
            return None
        w, h, inizio = migliore
        rgba = bytearray(w * h * 4)
        for k in range(w * h):
            v = d[inizio + k] & 0xFFFFFFFF
            rgba[4 * k:4 * k + 4] = bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255, (v >> 24) & 255))
        pb = GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(bytes(rgba)), GdkPixbuf.Colorspace.RGB, True, 8, w, h, w * 4)
        return pb.scale_simple(lato, lato, GdkPixbuf.InterpType.BILINEAR) if w != lato else pb

    def get_mini_icon(self):
        return self.get_icon(16)


class Schermo:
    """l'elenco delle finestre e quella attiva; avvisa (nel thread di GTK) quando cambiano"""

    def __init__(self, cambiato):
        self.p = Proprieta()
        self.cache = {}
        self.cambiato = cambiato
        threading.Thread(target=self._ascolta, daemon=True).start()

    def get_windows(self):
        ids = self.p.interi(self.p.root, "_NET_CLIENT_LIST")
        self.cache = {i: self.cache.get(i) or Finestra(self.p, i) for i in ids}
        return [self.cache[i] for i in ids]

    def get_active_window(self):
        d = self.p.interi(self.p.root, "_NET_ACTIVE_WINDOW")
        if not d or not d[0]:
            return None
        return self.cache.get(d[0]) or Finestra(self.p, d[0])

    def _ascolta(self):
        """un'altra connessione X, solo per gli eventi: radice (elenco, attiva) e ogni finestra (stato, nome)"""
        x = _x11()
        dpy = x.XOpenDisplay(None)
        _gestisci_errori(x, dpy)
        root = x.XDefaultRootWindow(dpy)
        PROPRIETA = 1 << 22   # PropertyChangeMask
        x.XSelectInput(dpy, root, PROPRIETA)
        atomo = {n: x.XInternAtom(dpy, n.encode(), 0) for n in
                 ("_NET_CLIENT_LIST", "_NET_ACTIVE_WINDOW", "_NET_WM_STATE", "_NET_WM_ICON", "WM_CLASS")}
        interessa = set(atomo.values())
        seguite = set()
        ev = (ctypes.c_long * 24)()

        def segui():
            p = Proprieta.__new__(Proprieta)
            p.x, p.dpy, p.root, p._atomi = x, dpy, root, {}
            for w in p.interi(root, "_NET_CLIENT_LIST"):
                if w not in seguite:
                    x.XSelectInput(dpy, w, PROPRIETA)
                    seguite.add(w)

        segui()
        while True:
            x.XNextEvent(dpy, ev)
            tipo = ctypes.c_int.from_buffer(ev).value
            if tipo != 28:   # PropertyNotify: type, serial, send_event, display, window, atom
                continue
            finestra, at = ev[4], ev[5]
            if at in interessa:
                if finestra == root and at == atomo["_NET_CLIENT_LIST"]:
                    segui()
                GLib.idle_add(self.cambiato)


# --- app e finestre ----------------------------------------------------------------------------
class Catalogo:
    """dalle finestre (classe WM, eseguibile) alle voci del menu (.desktop)"""

    def __init__(self):
        self.ricarica()
        self._dopo = 0
        Gio.AppInfoMonitor.get().connect("changed", lambda *a: self._ricarica_dopo())

    def _ricarica_dopo(self):   # una raffica di cambi (app del telefono spente, un .deb): una volta sola
        if self._dopo:
            GLib.source_remove(self._dopo)
        self._dopo = GLib.timeout_add(1500, lambda: (setattr(self, "_dopo", 0), self.ricarica()) and False)

    def ricarica(self):
        self.per_chiave = {}
        for info in Gio.AppInfo.get_all():
            ident = info.get_id() or ""
            if not ident:
                continue
            chiavi = {ident[:-8].lower(), ident[:-8].split(".")[-1].lower()}
            try:
                wm = info.get_startup_wm_class()
            except AttributeError:
                wm = None
            if wm:
                chiavi.add(wm.lower())
            exe = (info.get_executable() or "").split("/")[-1].lower()
            if exe and exe not in ("env", "sh", "bash", "python3", "tod", "tod-run", "flatpak"):
                chiavi.add(exe)
            for k in chiavi:
                # le voci "vere" vincono sulle copie (impostazioni, nascoste)
                if k not in self.per_chiave or (info.should_show() and not self.per_chiave[k].should_show()):
                    self.per_chiave[k] = info

    def info(self, ident):
        try:
            return DesktopAppInfo.new(ident)
        except TypeError:
            return None

    def per_finestra(self, w):
        nomi = [w.get_class_instance_name(), w.get_class_group_name()]
        try:
            pid = w.get_pid()
            if pid:
                nomi.append(os.path.basename(open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")[0].decode(errors="replace")))
        except OSError:
            pass
        for n in nomi:
            if n and n.lower() in self.per_chiave:
                return self.per_chiave[n.lower()]
        return None


class Voce:
    """un'app nella barra: fissata e/o con finestre aperte"""

    def __init__(self, chiave, info=None):
        self.chiave, self.info, self.finestre = chiave, info, []

    @property
    def nome(self):
        if self.info is not None:
            return self.info.get_display_name() or self.info.get_name()
        return self.finestre[0].get_class_group_name() if self.finestre else self.chiave


# --- anteprima delle finestre ------------------------------------------------------------------
class Anteprima(Gtk.Window):
    def __init__(self, barra):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.set_accept_focus(False)
        self.barra = barra
        self.get_style_context().add_class("tod-anteprima")
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)
            self.set_app_paintable(True)
        else:
            self.get_style_context().add_class("flat")
        self.root = Gtk.Box(spacing=px(6))
        self.root.get_style_context().add_class("root")
        self.add(self.root)
        self.voce, self.dentro, self._chiudi = None, False, 0
        self.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.connect("enter-notify-event", lambda *a: self._entra())
        self.connect("leave-notify-event", lambda w, e: self._esce(e))

    def _entra(self):
        self.dentro = True
        self.annulla_chiusura()

    def _esce(self, e):
        if e.detail != Gdk.NotifyType.INFERIOR:
            self.dentro = False
            self.chiudi_tra(250)

    def annulla_chiusura(self):
        if self._chiudi:
            GLib.source_remove(self._chiudi)
            self._chiudi = 0

    def chiudi_tra(self, ms):
        self.annulla_chiusura()
        self._chiudi = GLib.timeout_add(ms, self._forse_chiudi)

    def _forse_chiudi(self):
        self._chiudi = 0
        if not self.dentro and not self.barra.sopra_voce(self.voce):
            self.hide()
            self.voce = None
        return False

    def mostra(self, voce, pulsante):
        self.voce = voce
        for c in self.root.get_children():
            self.root.remove(c)
        attiva = self.barra.schermo.get_active_window()
        for w in voce.finestre[:6]:
            self.root.pack_start(self.scheda(w, w == attiva), False, False, 0)
        self.root.show_all()
        self.resize(1, 1)
        _m, nat = self.get_preferred_size()
        # sopra l'app, il bordo basso alla stessa distanza dalla barra dei pannelli
        a = pulsante.get_allocation()
        ox, _oy = pulsante.get_window().get_origin()[1:]
        wa = self.barra.area()
        x = ox + a.x + a.width // 2 - nat.width // 2
        x = max(wa.x + px(MARGINE), min(x, wa.x + wa.width - nat.width - px(MARGINE)))
        self.move(x, wa.y + wa.height - nat.height - px(MARGINE))
        self.show()

    def scheda(self, w, attiva):
        ev = Gtk.EventBox()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(6))
        box.get_style_context().add_class("finestra")
        if attiva:
            box.get_style_context().add_class("attiva")
        testa = Gtk.Box(spacing=px(6))
        pix = w.get_mini_icon()
        if pix is not None:
            testa.pack_start(Gtk.Image.new_from_pixbuf(pix.scale_simple(px(16), px(16), GdkPixbuf.InterpType.BILINEAR)),
                             False, False, 0)
        tit = Gtk.Label(label=w.get_name() or "", xalign=0)
        tit.get_style_context().add_class("titolo")
        tit.set_ellipsize(Pango.EllipsizeMode.END)
        tit.set_max_width_chars(22)
        testa.pack_start(tit, True, True, 0)
        x = Gtk.Button()
        x.get_style_context().add_class("chiudi")
        img = Gtk.Image.new_from_icon_name("window-close-symbolic", Gtk.IconSize.MENU)
        img.set_pixel_size(px(12))
        x.add(img)
        x.connect("clicked", lambda *_: (messaggio_wm(w.get_xid(), "_NET_CLOSE_WINDOW", 0, 2), self.hide()))
        testa.pack_end(x, False, False, 0)
        box.pack_start(testa, False, False, 0)
        box.pack_start(self.miniatura(w), False, False, 0)
        ev.add(box)
        ev.connect("button-release-event", lambda *_: (self.barra.attiva(w), self.hide()) and False)
        return ev

    def miniatura(self, w):
        larg, alt = px(200), px(118)
        if not w.is_minimized():
            try:
                gw = GdkX11.X11Window.foreign_new_for_display(Gdk.Display.get_default(), w.get_xid())
                _x, _y, ww, wh = w.get_client_window_geometry()
                pb = Gdk.pixbuf_get_from_window(gw, 0, 0, ww, wh) if gw is not None and ww > 0 and wh > 0 else None
            except (TypeError, GLib.Error):
                pb = None
            if pb is not None:
                k = min(larg / pb.get_width(), alt / pb.get_height())
                img = Gtk.Image.new_from_pixbuf(pb.scale_simple(max(1, int(pb.get_width() * k)), max(1, int(pb.get_height() * k)),
                                                                GdkPixbuf.InterpType.BILINEAR))
                img.set_size_request(larg, alt)
                return img
        # ridotta a icona (o non leggibile): l'icona grande dell'app al posto del contenuto
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(4))
        box.get_style_context().add_class("miniatura")
        box.set_size_request(larg, alt)
        pix = w.get_icon()
        img = Gtk.Image.new_from_pixbuf(pix.scale_simple(px(48), px(48), GdkPixbuf.InterpType.BILINEAR)) if pix else Gtk.Image()
        img.set_vexpand(True)
        img.set_valign(Gtk.Align.END)
        box.pack_start(img, True, True, 0)
        if w.is_minimized():
            l = Gtk.Label(label=T("Ridotta a icona", "Minimized"))
            l.get_style_context().add_class("ridotta")
            l.set_vexpand(True)
            l.set_valign(Gtk.Align.START)
            box.pack_start(l, True, True, 0)
        return box


# --- area di notifica (XEmbed): le icone che le app mettono nel "vassoio" (es. le app Electron) ------------
class XAnyEv(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong)]


class XEv(ctypes.Union):
    _fields_ = [("type", ctypes.c_int), ("xany", XAnyEv), ("xclient", XClientMessageEvent), ("pad", ctypes.c_long * 24)]


class AreaNotifica(Gtk.Box):
    """gestore del vassoio di sistema (_NET_SYSTEM_TRAY_S0): una connessione X nostra, in un thread,
    riceve le richieste delle app; ogni icona entra in un Gtk.Socket della barra"""

    def __init__(self):
        super().__init__(spacing=px(2))
        self.prese = {}
        threading.Thread(target=self._ascolta, daemon=True).start()

    def _ascolta(self):
        x = ctypes.CDLL(ctypes.util.find_library("X11") or os.path.join(PREFIX, "lib/libX11.so"))
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XInternAtom.restype = ctypes.c_ulong
        x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x.XDefaultRootWindow.restype = ctypes.c_ulong
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XCreateSimpleWindow.restype = ctypes.c_ulong
        x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                                          ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
        x.XSetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
        x.XGetSelectionOwner.restype = ctypes.c_ulong
        x.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(XEv)]
        x.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.POINTER(XEv)]
        x.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int,
                                      ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        x.XFlush.argtypes = [ctypes.c_void_p]
        dpy = x.XOpenDisplay(None)
        _gestisci_errori(x, dpy)
        if not dpy:
            return
        root = x.XDefaultRootWindow(dpy)
        sel = x.XInternAtom(dpy, b"_NET_SYSTEM_TRAY_S0", 0)
        opcode = x.XInternAtom(dpy, b"_NET_SYSTEM_TRAY_OPCODE", 0)
        win = x.XCreateSimpleWindow(dpy, root, -1, -1, 1, 1, 0, 0, 0)
        orient = (ctypes.c_long * 1)(0)   # orizzontale
        x.XChangeProperty(dpy, win, x.XInternAtom(dpy, b"_NET_SYSTEM_TRAY_ORIENTATION", 0),
                          x.XInternAtom(dpy, b"CARDINAL", 0), 32, 0, orient, 1)
        # la "visual" delle icone: quella predefinita dello schermo (GTK confronta la sua con questa)
        x.XDefaultVisual.restype = ctypes.c_void_p
        x.XDefaultVisual.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XVisualIDFromVisual.restype = ctypes.c_ulong
        x.XVisualIDFromVisual.argtypes = [ctypes.c_void_p]
        vis = (ctypes.c_long * 1)(x.XVisualIDFromVisual(x.XDefaultVisual(dpy, 0)))
        x.XChangeProperty(dpy, win, x.XInternAtom(dpy, b"_NET_SYSTEM_TRAY_VISUAL", 0),
                          x.XInternAtom(dpy, b"VISUALID", 0), 32, 0, vis, 1)
        x.XSetSelectionOwner(dpy, sel, win, 0)
        if x.XGetSelectionOwner(dpy, sel) != win:
            log("area di notifica: c'è già un altro gestore")
            return
        ev = XEv()   # annuncio: MANAGER alla radice, così le app già aperte rimettono le loro icone
        ev.xclient.type = 33
        ev.xclient.window = root
        ev.xclient.message_type = x.XInternAtom(dpy, b"MANAGER", 0)
        ev.xclient.format = 32
        ev.xclient.data[0], ev.xclient.data[1], ev.xclient.data[2] = 0, sel, win
        x.XSendEvent(dpy, root, 0, 1 << 17, ctypes.byref(ev))   # StructureNotifyMask
        x.XFlush(dpy)
        log("area di notifica pronta")
        while True:
            x.XNextEvent(dpy, ctypes.byref(ev))
            if ev.type == 33 and ev.xclient.message_type == opcode and ev.xclient.data[1] == 0:   # REQUEST_DOCK
                xid = ev.xclient.data[2]
                GLib.idle_add(self._aggiungi, xid)

    def _aggiungi(self, xid):
        if xid in self.prese:
            return False
        presa = Gtk.Socket()
        presa.set_size_request(px(20), px(20))
        presa.set_valign(Gtk.Align.CENTER)
        self.pack_start(presa, False, False, px(2))
        presa.show()
        presa.add_id(xid)
        self.prese[xid] = presa
        presa.connect("plug-removed", lambda p: (self.prese.pop(xid, None), p.destroy(), False)[-1])
        return False


# --- icone di sistema (a destra) ---------------------------------------------------------------
PANNELLO = os.path.join(QUI, "tod-pannello")
GIORNI = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"]
MESI = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre",
        "novembre", "dicembre"]


def riga_volume(v, muto):
    """riga genmon dell'icona del volume; v = percentuale (None: audio non disponibile)"""
    if v is None:
        i, t = "audio-volume-muted-symbolic", T("Audio non disponibile", "Audio unavailable")
    else:
        i = ("audio-volume-muted-symbolic" if muto or v == 0 else "audio-volume-low-symbolic" if v < 34
             else "audio-volume-medium-symbolic" if v < 67 else "audio-volume-high-symbolic")
        t = f"Volume: {v}%"
    return f"<icon>{i}</icon><tool>{t}</tool><iconclick>{PANNELLO} volume</iconclick>"


def riga_notifiche(dnd, nuove):
    if dnd:
        i, t = "notification-disabled-symbolic", T("Non disturbare", "Do not disturb")
    elif nuove:
        i, t = "notification-new-symbolic", T("Notifiche nuove", "New notifications")
    else:
        i, t = "notification-symbolic", T("Notifiche", "Notifications")
    return f"<icon>{i}</icon><tool>{t}</tool><iconclick>{PANNELLO} notifiche</iconclick>"


def riga_orologio(t):
    """ora sopra, data sotto (come l'orologio di XFCE); il clic apre il nostro calendario"""
    if ITALIAN:   # Termux non ha le lingue di sistema: nomi di giorni e mesi scritti qui
        lungo = f"{GIORNI[(t.tm_wday + 1) % 7]} {t.tm_mday} {MESI[t.tm_mon - 1]} {t.tm_year}"
    else:
        lungo = time.strftime("%A %-d %B %Y", t)
    return (f"<txt><span>{time.strftime('%H:%M', t)}</span>\n<span>{time.strftime('%d/%m/%Y', t)}</span></txt>"
            f"<tool>{lungo}</tool><txtclick>{PANNELLO} calendario</txtclick>")


def leggi_volume(testo):
    """(percentuale, muto) dall'uscita di pactl get-sink-volume + get-sink-mute"""
    v = re.search(r" (\d+)% ", testo)
    m = testo.splitlines()[-1] if testo.strip() else ""   # l'ultima riga è quella di get-sink-mute (anche tradotta)
    return (int(v.group(1)) if v else None), ("yes" in m or "sì" in m)


def stato_telefono():
    """le funzioni delle icone di tod-phone-status.py, caricate una volta (prima: un Python nuovo ogni 10 s)"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("tod_phone_status", os.path.join(QUI, "tod-phone-status.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Vassoio(Gtk.Box):
    """le nostre icone di stato, calcolate qui senza avviare programmi (prima ~60 processi ogni 30 s, 8% di
    un core): orologio allo scoccare del minuto, batteria e rete dal file del demone del telefono, notifiche
    via D-Bus, volume solo quando cambia (un pactl subscribe sempre aperto)"""
    VOCI = ["rete", "volume", "batteria", "notifiche", "orologio"]

    def __init__(self, barra):
        super().__init__(spacing=0)
        self.barra, self.parti, self.clic, self.ultima = barra, {}, {}, {}
        self.telefono, self.bus, self.ascolto = None, None, None
        for nome in self.VOCI:
            ev = Gtk.EventBox()
            ev.set_visible_window(False)
            box = Gtk.Box(spacing=px(4))
            box.get_style_context().add_class("vassoio")
            img = Gtk.Image()
            img.set_no_show_all(True)
            lab = Gtk.Label()
            lab.set_no_show_all(True)
            lab.set_justify(Gtk.Justification.RIGHT)
            lab.get_style_context().add_class("orologio")
            box.pack_start(img, False, False, 0)
            box.pack_start(lab, False, False, 0)
            ev.add(box)
            ev.connect("button-release-event", lambda _w, e, n=nome: self._clic(n, e))
            self.pack_start(ev, False, False, 0)
            self.parti[nome] = (ev, img, lab)
        self.aggiorna_tutto()
        GLib.timeout_add_seconds(10, lambda: (self.aggiorna("rete"), self.aggiorna("batteria")) and True)
        GLib.timeout_add_seconds(3, lambda: self.aggiorna("notifiche") or True)
        GLib.timeout_add_seconds(60, lambda: self.aggiorna("volume") or True)   # riserva, se l'ascolto non c'è
        self._minuto()
        self._ascolta_volume()

    def aggiorna_tutto(self):
        for nome in self.VOCI:
            self.aggiorna(nome)

    def aggiorna(self, nome):
        if nome == "orologio":
            self._mostra(nome, riga_orologio(time.localtime()))
        elif nome in ("rete", "batteria"):
            try:
                if self.telefono is None:
                    self.telefono = stato_telefono()
                st = self.telefono.load()
                self._mostra(nome, self.telefono.network(st) if nome == "rete" else self.telefono.battery(st))
            except Exception as e:   # noqa: BLE001 - un'icona che manca non ferma la barra
                print(f"tod-barra: {nome}: {e}", file=sys.stderr)
        elif nome == "notifiche":
            self._notifiche()
        elif nome == "volume":
            try:
                p = Gio.Subprocess.new(["sh", "-c", "pactl get-sink-volume @DEFAULT_SINK@; pactl get-sink-mute @DEFAULT_SINK@"],
                                       Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE)
            except GLib.Error:
                return
            p.communicate_utf8_async(None, None, self._letto_volume)

    def _letto_volume(self, pr, res):
        try:
            _ok, out, _err = pr.communicate_utf8_finish(res)
        except GLib.Error:
            out = ""
        self._mostra("volume", riga_volume(*leggi_volume(out or "")))

    def _ascolta_volume(self):
        """un solo pactl subscribe: ogni cambio di uscita o di volume ridisegna l'icona"""
        try:
            p = Gio.Subprocess.new(["pactl", "subscribe"], Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error:
            GLib.timeout_add_seconds(10, lambda: self._ascolta_volume() and False)
            return
        self.ascolto = Gio.DataInputStream.new(p.get_stdout_pipe())
        self.ascolto.read_line_async(GLib.PRIORITY_DEFAULT, None, self._evento_volume)

    def _evento_volume(self, flusso, res):
        try:
            riga, _n = flusso.read_line_finish_utf8(res)
        except GLib.Error:
            riga = None
        if riga is None:   # PulseAudio riavviato o assente: si riprova tra poco
            GLib.timeout_add_seconds(5, lambda: self._ascolta_volume() and False)
            return
        if "sink" in riga or "server" in riga:   # anche con i messaggi tradotti
            if not getattr(self, "_vol_atteso", False):   # una raffica di eventi = una lettura
                self._vol_atteso = True
                GLib.timeout_add(150, lambda: setattr(self, "_vol_atteso", False) or self.aggiorna("volume") and False)
        flusso.read_line_async(GLib.PRIORITY_DEFAULT, None, self._evento_volume)

    def _notifiche(self):
        """non disturbare (xfconf) e notifiche non lette (registro di xfce4-notifyd), via D-Bus"""
        try:
            if self.bus is None:
                self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        except GLib.Error:
            return self._mostra("notifiche", riga_notifiche(False, False))
        stato = {}

        def fine():
            if len(stato) == 2:
                self._mostra("notifiche", riga_notifiche(stato["dnd"], stato["nuove"]))

        def letto(chiave, valore):
            def cb(bus, res):
                try:
                    stato[chiave] = valore(bus.call_finish(res))
                except GLib.Error:
                    stato[chiave] = False
                fine()
            return cb
        self.bus.call("org.xfce.Xfconf", "/org/xfce/Xfconf", "org.xfce.Xfconf", "GetProperty",
                      GLib.Variant("(ss)", ("xfce4-notifyd", "/do-not-disturb")), None, Gio.DBusCallFlags.NONE, 2000,
                      None, letto("dnd", lambda r: r.unpack()[0] is True))
        self.bus.call("org.xfce.Notifyd", "/org/xfce/Notifyd", "org.xfce.Notifyd.Log", "HasUnread", None, None,
                      Gio.DBusCallFlags.NONE, 2000, None, letto("nuove", lambda r: bool(r.unpack()[0])))

    def _minuto(self):
        self.aggiorna("orologio")
        GLib.timeout_add_seconds(61 - time.localtime().tm_sec, lambda: self._minuto() and False)

    def _mostra(self, nome, out):
        if out == self.ultima.get(nome):   # niente di cambiato: niente da ridisegnare
            return
        self.ultima[nome] = out
        ev, img, lab = self.parti[nome]
        if not out or not out.strip():
            ev.hide()
            return
        tag = {k: (re.search(rf"<{k}>(.*?)</{k}>", out, re.S) or [None, None])[1] for k in ("icon", "txt", "tool", "iconclick", "txtclick")}
        if tag["icon"]:
            img.set_from_icon_name(tag["icon"], Gtk.IconSize.MENU)
            img.set_pixel_size(px(16))
            img.show()
        else:
            img.hide()
        if tag["txt"]:
            lab.set_markup(re.sub(r"font_desc='[^']*'", "", tag["txt"]))
            lab.show()
        else:
            lab.hide()
        ev.set_tooltip_text(tag["tool"] or None)
        self.clic[nome] = tag["iconclick"] or tag["txtclick"]
        ev.show_all()
        ev.get_child().get_children()[0].set_visible(bool(tag["icon"]))
        ev.get_child().get_children()[1].set_visible(bool(tag["txt"]))

    def _clic(self, nome, e):
        if e.button == 1 and self.clic.get(nome):
            subprocess.Popen(["sh", "-c", self.clic[nome]], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            GLib.timeout_add(600, lambda: self.aggiorna_tutto() and False)
        return True


# --- la barra ----------------------------------------------------------------------------------
BERSAGLIO = [Gtk.TargetEntry.new("tod-barra/app", Gtk.TargetFlags.SAME_APP, 0),
             Gtk.TargetEntry.new("text/uri-list", 0, 1)]


class Barra(Gtk.Window):
    def __init__(self):
        global SCALA
        res = Gdk.Screen.get_default().get_resolution()
        SCALA = res / 96.0 if res and res > 0 else 1.0
        super().__init__(title="tod-barra")
        self.conf = carica()
        self.get_style_context().add_class("tod-barra")
        self.set_type_hint(Gdk.WindowTypeHint.DOCK)
        # la barra non prende mai il fuoco: chiudendo un pannello xfwm4 lo passava a lei e GTK cadeva
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_can_focus(False)
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.stick()
        self.set_keep_above(True)
        self.prov = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), self.prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 3)
        self.prov.load_from_data(css())
        Gtk.Settings.get_default().connect("notify::gtk-theme-name", lambda *a: self.prov.load_from_data(css()))

        self.catalogo = Catalogo()
        self.anteprima = Anteprima(self)
        self.pulsanti = {}      # chiave → pulsante
        self.voci = []
        self.trascinata = None
        self._rifai_id = 0

        fuori = Gtk.Box()
        self.add(fuori)
        self.sinistra = Gtk.Box()
        self.centro = Gtk.Box(spacing=px(2))
        self.destra = Gtk.Box()
        fuori.pack_start(self.sinistra, True, True, 0)
        fuori.set_center_widget(self.centro)
        # come Windows: la striscia in fondo a destra mostra il desktop; un altro clic riporta le finestre
        punto = Gtk.EventBox()
        punto.get_style_context().add_class("desktop")
        punto.set_size_request(px(8), -1)
        punto.set_tooltip_text(T("Mostra desktop", "Show desktop"))
        punto.connect("button-release-event", lambda _w, e: e.button == 1 and self.mostra_desktop())
        fuori.pack_end(punto, False, False, 0)
        fuori.pack_end(self.destra, False, False, px(6))
        self.vassoio = Vassoio(self)
        self.destra.pack_end(self.vassoio, False, False, 0)
        self.notifica = AreaNotifica()
        self.destra.pack_end(self.notifica, False, False, px(4))
        # tasto destro sulla barra vuota
        self.add_events(Gdk.EventMask.BUTTON_RELEASE_MASK)
        self.connect("button-release-event", self._menu_barra)

        self.schermo = Schermo(lambda: self.rifai() or False)
        Gdk.Screen.get_default().connect("monitors-changed", lambda *a: self.colloca())
        Gdk.Screen.get_default().connect("size-changed", lambda *a: self.colloca())
        self.connect("realize", lambda *a: self.colloca())
        self.rifai_ora()
        self.show_all()
        self.colloca()

    def mostra_desktop(self):
        p = self.schermo.p
        acceso = p.interi(p.root, "_NET_SHOWING_DESKTOP")
        messaggio_wm(p.root, "_NET_SHOWING_DESKTOP", 0 if acceso and acceso[0] else 1)
        return True

    # posizione e spazio riservato
    def area(self):
        d = Gdk.Display.get_default()
        return (d.get_primary_monitor() or d.get_monitor(0)).get_workarea()

    def geometria(self):
        d = Gdk.Display.get_default()
        return (d.get_primary_monitor() or d.get_monitor(0)).get_geometry()

    def colloca(self):
        g = self.geometria()
        h = px(GRANDEZZE.get(self.conf["grandezza"], GRANDEZZE["media"])[0])
        self.set_size_request(g.width, h)
        self.resize(g.width, h)
        self.move(g.x, g.y + g.height - h)
        riserva_spazio(self, h, g.width, g.height)
        # allineamento: al centro (Windows 11) o a sinistra
        fuori = self.centro.get_parent()
        if self.conf["allineamento"] == "sinistra" and fuori.get_center_widget() is self.centro:
            fuori.set_center_widget(None)
            self.sinistra.pack_start(self.centro, False, False, px(6))
        elif self.conf["allineamento"] != "sinistra" and fuori.get_center_widget() is not self.centro:
            self.sinistra.remove(self.centro)
            fuori.set_center_widget(self.centro)

    # modello: fissate + aperte
    def rifai(self):
        if not self._rifai_id:
            self._rifai_id = GLib.timeout_add(60, self.rifai_ora)

    def rifai_ora(self):
        self._rifai_id = 0
        voci, per_chiave = [], {}
        for ident in self.conf["fissate"]:
            info = self.catalogo.info(ident)
            if info is not None and ident not in per_chiave:
                per_chiave[ident] = Voce(ident, info)
                voci.append(per_chiave[ident])
        for w in self.schermo.get_windows():
            if not w.da_mostrare():
                continue
            if w.get_name() == "tod-barra":
                continue
            info = self.catalogo.per_finestra(w)
            chiave = info.get_id() if info is not None else "wm:" + (w.get_class_group_name() or str(w.get_xid()))
            if chiave not in per_chiave:
                per_chiave[chiave] = Voce(chiave, info)
                voci.append(per_chiave[chiave])
            per_chiave[chiave].finestre.append(w)
        self.voci = voci
        self.disegna()
        return False

    def disegna(self):
        """i pulsanti restano gli stessi (distruggerli a ogni cambio di finestra mandava GTK in crash):
        si aggiungono i nuovi, si tolgono quelli spariti, si rimettono in ordine e si aggiorna lo stato"""
        if getattr(self, "start", None) is None:
            self.start = self.pulsante_start()
            self.centro.pack_start(self.start, False, False, 0)
        attiva = self.schermo.get_active_window()
        chiavi = [v.chiave for v in self.voci]
        for k in [k for k in self.pulsanti if k not in chiavi]:
            ev = self.pulsanti.pop(k)
            self.centro.remove(ev)
            GLib.idle_add(lambda e=ev: e.destroy() and False)   # dopo, fuori dai suoi stessi eventi
        for i, v in enumerate(self.voci):
            ev = self.pulsanti.get(v.chiave)
            if ev is None:
                ev = self.pulsante(v)
                self.centro.pack_start(ev, False, False, 0)
            self.centro.reorder_child(ev, i + 1)
            self.aggiorna_pulsante(ev, v, attiva)
        self.centro.show_all()

    def dim(self):
        return GRANDEZZE.get(self.conf["grandezza"], GRANDEZZE["media"])

    def pulsante_start(self):
        ev = Gtk.EventBox()
        ev.set_visible_window(False)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.get_style_context().add_class("app")
        img = Gtk.Image.new_from_icon_name("tod-start", Gtk.IconSize.DND)
        img.set_pixel_size(px(self.dim()[1]))
        img.set_vexpand(True)
        box.set_size_request(px(self.dim()[0] - 4), -1)
        box.pack_start(img, True, True, 0)
        ev.add(box)
        ev.set_tooltip_text("Start")
        ev.connect("button-release-event", lambda *_: subprocess.Popen(
            [os.path.join(PREFIX, "bin/tod-start")], start_new_session=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) and True)
        return ev

    def pulsante(self, v):
        ev = Gtk.EventBox()
        ev.set_visible_window(False)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.get_style_context().add_class("app")
        box.set_size_request(px(self.dim()[0] - 4), -1)
        ev.img = Gtk.Image()
        ev.img.set_pixel_size(px(self.dim()[1]))
        ev.img.set_vexpand(True)
        ev.img.set_valign(Gtk.Align.CENTER)
        box.pack_start(ev.img, True, True, 0)
        ev.segno = Gtk.Box()
        ev.segno.get_style_context().add_class("segno")
        ev.segno.set_halign(Gtk.Align.CENTER)
        ev.segno.set_margin_bottom(px(2))
        box.pack_end(ev.segno, False, False, 0)
        ev.box = box
        ev.add(box)
        ev.voce = v
        ev.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        ev.connect("button-release-event", self._clic_app)
        ev.connect("enter-notify-event", lambda w, e: self._sopra(w))
        ev.connect("leave-notify-event", lambda w, e: self.anteprima.chiudi_tra(300))
        # trascinare (tenendo premuto) per riordinare; si possono lasciare qui anche app dallo Start o dal desktop
        ev.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [BERSAGLIO[0]], Gdk.DragAction.MOVE)
        ev.connect("drag-begin", self._inizio_trascina)
        ev.connect("drag-data-get", lambda w, ctx, sel, info, t: sel.set(sel.get_target(), 8, w.voce.chiave.encode()))
        ev.connect("drag-end", self._fine_trascina)
        ev.drag_dest_set(Gtk.DestDefaults.ALL, BERSAGLIO, Gdk.DragAction.MOVE | Gdk.DragAction.COPY)
        ev.connect("drag-data-received", self._lasciata)
        self.pulsanti[v.chiave] = ev
        return ev

    def aggiorna_pulsante(self, ev, v, attiva):
        ev.voce = v
        if v.info is not None and v.info.get_icon() is not None:
            ev.img.set_from_gicon(v.info.get_icon(), Gtk.IconSize.DND)
        elif v.finestre and v.finestre[0].get_icon() is not None:
            # l'icona della finestra già alla misura giusta: set_pixel_size vale solo per le icone del tema, e a
            # 48 px fissi le app senza voce di menu avevano l'icona enorme (1° novembre, visto sul S20+)
            ev.img.set_from_pixbuf(v.finestre[0].get_icon(px(self.dim()[1])))
        else:
            ev.img.set_from_icon_name("application-x-executable", Gtk.IconSize.DND)
        ev.img.set_pixel_size(px(self.dim()[1]))
        # il segno: lungo nell'accento = in primo piano; corto = aperta (anche se ridotta); niente = chiusa
        primo = attiva is not None and attiva in v.finestre and not attiva.is_minimized()
        for w, c in ((ev.box, "attiva"), (ev.segno, "attiva")):
            (w.get_style_context().add_class if primo else w.get_style_context().remove_class)(c)
        ev.segno.set_size_request(px(16 if primo else 6), px(3))
        ev.segno.set_opacity(1.0 if v.finestre else 0.0)
        ev.set_tooltip_text(None if v.finestre else v.nome)

    def sopra_voce(self, voce):
        p = self.pulsanti.get(voce.chiave) if voce is not None else None
        if p is None or p.get_window() is None:
            return False
        _s, x, y, _m = p.get_window().get_device_position(Gdk.Display.get_default().get_default_seat().get_pointer())
        a = p.get_allocation()
        return a.x <= x < a.x + a.width and a.y <= y < a.y + a.height

    def _sopra(self, w):
        if w.voce.finestre and self.conf.get("anteprime", True) and self.trascinata is None:
            self.anteprima.annulla_chiusura()
            chiave = w.voce.chiave
            GLib.timeout_add(350, lambda: self._mostra_anteprima(chiave) and False)

    def _mostra_anteprima(self, chiave):
        ev = self.pulsanti.get(chiave)   # il pulsante di adesso (le finestre possono essere cambiate)
        if ev is not None and ev.get_window() is not None and ev.voce.finestre and self.sopra_voce(ev.voce):
            self.anteprima.mostra(ev.voce, ev)

    # clic
    def attiva(self, w):
        # _NET_ACTIVE_WINDOW da "pager" (2) con l'ora "adesso", come xdotool (vale anche per le ridotte)
        messaggio_wm(w.get_xid(), "_NET_ACTIVE_WINDOW", 2, 0, 0)

    def avvia(self, v):
        if v.info is None:
            return
        ctx = Gdk.Display.get_default().get_app_launch_context()
        ctx.set_timestamp(Gtk.get_current_event_time())
        try:
            v.info.launch([], ctx)
        except GLib.Error as e:
            log("avvio non riuscito:", v.chiave, e.message)

    def _clic_app(self, ev, e):
        v = ev.voce
        if e.button == 2:
            self.avvia(v)
        elif e.button == 3:
            self._menu_app(v, e)
        elif e.button == 1:
            if not v.finestre:
                self.avvia(v)
            elif len(v.finestre) == 1:
                w = v.finestre[0]
                if w == self.schermo.get_active_window() and not w.is_minimized():
                    messaggio_wm(w.get_xid(), "WM_CHANGE_STATE", 3)   # IconicState: ridotta a icona
                else:
                    self.attiva(w)
                self.anteprima.hide()
            else:
                self.anteprima.mostra(v, ev)   # più finestre: si sceglie dall'anteprima
        return True

    def _menu_app(self, v, e):
        m = Gtk.Menu()

        def voce(testo, cb):
            it = Gtk.MenuItem(label=testo)
            it.connect("activate", lambda *_: cb())
            m.append(it)

        if v.info is not None:
            voce(v.nome, lambda: self.avvia(v))
            m.append(Gtk.SeparatorMenuItem())
            if v.chiave in self.conf["fissate"]:
                voce(T("Rimuovi dalla barra", "Unpin from taskbar"), lambda: self.fissa(v.chiave, False))
            else:
                voce(T("Aggiungi alla barra", "Pin to taskbar"), lambda: self.fissa(v.chiave, True))
        if v.finestre:
            voce(T("Chiudi finestra", "Close window") if len(v.finestre) == 1 else T("Chiudi tutte le finestre", "Close all windows"),
                 lambda: [messaggio_wm(w.get_xid(), "_NET_CLOSE_WINDOW", 0, 2) for w in v.finestre])
        m.show_all()
        m.attach_to_widget(self, None)
        m.popup_at_pointer(e)

    def _menu_barra(self, _w, e):
        if e.button != 3:
            return False
        m = Gtk.Menu()
        for testo, cmd in ((T("Impostazioni della barra", "Taskbar settings"), ["python3", os.path.join(QUI, "tod-settings.py"), "barra"]),
                           (T("Gestione attività", "Task Manager"), ["xfce4-taskmanager"])):
            it = Gtk.MenuItem(label=testo)
            it.connect("activate", lambda _i, c=cmd: subprocess.Popen(c, start_new_session=True, stdin=subprocess.DEVNULL,
                                                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            m.append(it)
        m.show_all()
        m.attach_to_widget(self, None)
        m.popup_at_pointer(e)
        return True

    def fissa(self, chiave, si):
        f = [x for x in self.conf["fissate"] if x != chiave]
        if si:
            # al posto in cui sta adesso tra le app della barra
            ordine = [v.chiave for v in self.voci if v.chiave in f or v.chiave == chiave]
            f = [x for x in ordine if x in f or x == chiave] + [x for x in f if x not in ordine]
        self.conf["fissate"] = f
        salva(self.conf)
        self.rifai_ora()

    # trascinare
    def _inizio_trascina(self, w, ctx):
        self.trascinata = w.voce.chiave
        self.anteprima.hide()
        g = w.voce.info.get_icon() if w.voce.info is not None else None
        if g is not None:
            Gtk.drag_set_icon_gicon(ctx, g, px(self.dim()[1]) // 2, px(self.dim()[1]) // 2)
        w.box.get_style_context().add_class("trascina")

    def _fine_trascina(self, w, _ctx):
        self.trascinata = None
        w.box.get_style_context().remove_class("trascina")
        self.rifai_ora()

    def _lasciata(self, dest, ctx, x, _y, sel, info, t):
        chiavi = [v.chiave for v in self.voci]
        if dest.voce.chiave not in chiavi:
            return
        if info == 0:
            mossa = sel.get_data().decode()
        else:   # un .desktop dallo Start o dal desktop: diventa un'app fissata
            uri = (sel.get_uris() or [""])[0]
            p = Gio.File.new_for_uri(uri).get_path() or ""
            if not p.endswith(".desktop"):
                return
            mossa = os.path.basename(p)
            if self.catalogo.info(mossa) is None:
                return
        if mossa in chiavi:
            chiavi.remove(mossa)
        i = chiavi.index(dest.voce.chiave) if dest.voce.chiave in chiavi else len(chiavi)
        if x > dest.get_allocation().width // 2:
            i += 1
        chiavi.insert(i, mossa)
        # chi viene trascinato diventa fissato: l'ordine si ricorda solo per le fissate
        fissate = set(self.conf["fissate"]) | {mossa}
        self.conf["fissate"] = [c for c in chiavi if c in fissate and not c.startswith("wm:")]
        salva(self.conf)
        self.rifai_ora()


def main():
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGUSR1, signal.SIGUSR2})
    if Gdk.Screen.get_default() is None:   # schermo già chiuso (fine sessione): niente da fare
        log("nessuno schermo, esco")
        return 0
    try:
        vecchio = int(open(PIDFILE).read().strip())
        if b"tod-barra.py" in open(f"/proc/{vecchio}/cmdline", "rb").read() and vecchio != os.getpid():
            if "--replace" not in sys.argv:
                log("già attiva:", vecchio)
                return 0
            os.kill(vecchio, signal.SIGTERM)
            time.sleep(0.5)
    except (OSError, ValueError):
        pass
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, Gtk.main_quit)
    barra = Barra()
    # SIGUSR2: volume o notifiche cambiati (da tod-pannelli): le icone a destra si ridisegnano subito
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGUSR2,
                         lambda: barra.vassoio.aggiorna_tutto() or True)
    # SIGUSR1: impostazioni cambiate (da tod-settings): si rileggono
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGUSR1,
                         lambda: (setattr(barra, "conf", carica()), barra.colloca(), barra.rifai_ora()) and True)
    Gtk.main()
    try:
        if open(PIDFILE).read().strip() == str(os.getpid()):
            os.unlink(PIDFILE)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
