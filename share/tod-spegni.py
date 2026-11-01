#!/usr/bin/env python3
"""Spegnimento vero, come su un PC: prima si chiudono le app, poi i servizi, poi lo schermo.

Ogni finestra riceve la richiesta di chiusura dal gestore delle finestre (_NET_CLOSE_WINDOW, come la X
della sua barra): le app con lavoro non salvato possono chiedere che cosa fare. Una finestrella mostra
"Chiusura delle app" e quelle ancora aperte; chiuse tutte, `tod spegni --subito` ferma in ordine dischi,
Debian, audio e desktop. Se dopo un po' qualcuna resta aperta: "Spegni comunque" o "Annulla".

  tod-spegni.py        (da `tod spegni` dentro il desktop: Start → Spegni, barra, "Esci")
"""
import ctypes
import ctypes.util
import os
import subprocess
import sys

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

ITALIAN = (os.environ.get("LANGUAGE") or os.environ.get("LANG") or "it").startswith("it")
TESTI = {
    "titolo": ("Spegnimento", "Shutting down"),
    "chiusura": ("Chiusura delle app in corso…", "Closing apps…"),
    "spegnimento": ("Spegnimento in corso…", "Shutting down…"),
    "restano": ("Queste app non si sono ancora chiuse. Se hanno lavoro da salvare, salvalo; poi chiudile, "
                "oppure spegni comunque (il lavoro non salvato andrà perso).",
                "These apps have not closed yet. Save any unsaved work and close them, or shut down "
                "anyway (unsaved work will be lost)."),
    "comunque": ("Spegni comunque", "Shut down anyway"),
    "annulla": ("Annulla", "Cancel"),
}
PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
ATTESA = 15   # secondi prima di proporre "Spegni comunque"


def t(k):
    return TESTI[k][0 if ITALIAN else 1]


class X:
    """Il minimo di Xlib (ctypes): elenco delle finestre delle app e richiesta di chiusura."""
    def __init__(self):
        self.x = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so")
        self.x.XOpenDisplay.restype = ctypes.c_void_p
        self.x.XInternAtom.restype = ctypes.c_ulong
        self.x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        self.x.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.x.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long,
                                              ctypes.c_long, ctypes.c_int, ctypes.c_ulong,
                                              ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
                                              ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
                                              ctypes.POINTER(ctypes.c_void_p)]
        self.x.XFree.argtypes = [ctypes.c_void_p]
        self.x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
        self.x.XFlush.argtypes = [ctypes.c_void_p]
        self.d = self.x.XOpenDisplay(None)
        if not self.d:
            raise RuntimeError("niente display")
        self.root = self.x.XDefaultRootWindow(self.d)
        self.a = {n: self.x.XInternAtom(self.d, n.encode(), 0) for n in (
            "_NET_CLIENT_LIST", "_NET_WM_WINDOW_TYPE", "_NET_WM_WINDOW_TYPE_DOCK", "_NET_WM_WINDOW_TYPE_DESKTOP",
            "_NET_WM_WINDOW_TYPE_NOTIFICATION", "_NET_WM_NAME", "UTF8_STRING", "_NET_WM_PID", "_NET_CLOSE_WINDOW",
            "WM_CLASS")}

    def prop(self, w, atom, tipo=0, n=4096):
        t_, f, ni, ba = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong()
        p = ctypes.c_void_p()
        if self.x.XGetWindowProperty(self.d, w, atom, 0, n, 0, tipo, ctypes.byref(t_), ctypes.byref(f),
                                     ctypes.byref(ni), ctypes.byref(ba), ctypes.byref(p)) != 0 or not p.value:
            return f.value, b"", 0
        if f.value == 32:   # gli elementi da 32 bit sono long in memoria
            dati = bytes((ctypes.c_ulong * ni.value).from_address(p.value))
        else:
            dati = ctypes.string_at(p.value, ni.value * f.value // 8)
        self.x.XFree(p)
        return f.value, dati, ni.value

    def ulongs(self, w, atom):
        f, dati, n = self.prop(w, atom)
        return list((ctypes.c_ulong * n).from_buffer_copy(dati)) if f == 32 and n else []

    def app(self):
        """[(finestra, nome)] delle finestre delle app (niente barra, scrivania, notifiche, noi)."""
        fuori = {self.a["_NET_WM_WINDOW_TYPE_DOCK"], self.a["_NET_WM_WINDOW_TYPE_DESKTOP"],
                 self.a["_NET_WM_WINDOW_TYPE_NOTIFICATION"]}
        out = []
        for w in self.ulongs(self.root, self.a["_NET_CLIENT_LIST"]):
            if fuori & set(self.ulongs(w, self.a["_NET_WM_WINDOW_TYPE"])):
                continue
            if os.getpid() in self.ulongs(w, self.a["_NET_WM_PID"]):
                continue
            nome = self.prop(w, self.a["_NET_WM_NAME"], self.a["UTF8_STRING"])[1].decode(errors="replace")
            if not nome:
                classe = self.prop(w, self.a["WM_CLASS"])[1].split(b"\0")
                nome = (classe[1] if len(classe) > 1 else classe[0]).decode(errors="replace")
            out.append((w, nome or "?"))
        return out

    def chiudi(self, w):
        """Come la X della barra: _NET_CLOSE_WINDOW al gestore delle finestre (che manda WM_DELETE)."""
        class Ev(ctypes.Structure):
            _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                        ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                        ("format", ctypes.c_int), ("l", ctypes.c_long * 5), ("pad", ctypes.c_long * 12)]
        ev = Ev(type=33, send_event=1, display=self.d, window=w, message_type=self.a["_NET_CLOSE_WINDOW"], format=32)
        ev.l[0], ev.l[1] = 0, 2   # ora corrente, richiesta da un "pager" (l'utente)
        self.x.XSendEvent(self.d, self.root, 0, (1 << 20) | (1 << 19), ctypes.byref(ev))
        self.x.XFlush(self.d)


def spegni_davvero():
    """Servizi in ordine e schermo chiuso (tod spegni --subito, staccato: chiude anche noi)."""
    # TOD_SPEGNIMENTO: tod non riapre mai questa finestrella da qui (niente cicli)
    subprocess.Popen([os.path.join(PREFIX, "bin", "tod"), "spegni", "--subito"], start_new_session=True,
                     env=dict(os.environ, TOD_SPEGNIMENTO="1"),
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Finestra(Gtk.Window):
    def __init__(self, x):
        super().__init__(title=t("titolo"))
        self.x, self.passati = x, 0
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_keep_above(True)
        self.set_resizable(False)
        self.set_default_size(420, -1)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=24)
        riga = Gtk.Box(spacing=12)
        self.ruota = Gtk.Spinner()
        self.ruota.start()
        self.testo = Gtk.Label(label=t("chiusura"), xalign=0)
        self.testo.get_style_context().add_class("title-4")
        riga.pack_start(self.ruota, False, False, 0)
        riga.pack_start(self.testo, True, True, 0)
        box.pack_start(riga, False, False, 0)
        self.spiega = Gtk.Label(label=t("restano"), xalign=0, wrap=True, max_width_chars=48)
        self.elenco = Gtk.Label(xalign=0)
        box.pack_start(self.spiega, False, False, 0)
        box.pack_start(self.elenco, False, False, 0)
        tasti = Gtk.Box(spacing=8, halign=Gtk.Align.END)
        self.annulla = Gtk.Button(label=t("annulla"))
        self.comunque = Gtk.Button(label=t("comunque"))
        self.comunque.get_style_context().add_class("destructive-action")
        self.annulla.connect("clicked", lambda *_: Gtk.main_quit())
        self.comunque.connect("clicked", lambda *_: self.fine())
        tasti.pack_start(self.annulla, False, False, 0)
        tasti.pack_start(self.comunque, False, False, 0)
        box.pack_start(tasti, False, False, 0)
        self.add(box)
        self.connect("destroy", lambda *_: Gtk.main_quit())
        self.show_all()
        for w in (self.spiega, self.elenco, self.comunque):
            w.hide()
        for w, _ in self.x.app():   # la richiesta di chiusura a tutte, una volta
            self.x.chiudi(w)
        GLib.timeout_add(500, self.guarda)

    def guarda(self):
        restano = self.x.app()
        if not restano:
            self.fine()
            return False
        self.passati += 0.5
        self.elenco.set_text("\n".join("• " + n for _, n in restano[:8]))
        if self.passati >= ATTESA and not self.comunque.get_visible():
            self.spiega.show()
            self.elenco.show()
            self.comunque.show()
            self.ruota.stop()
        return True

    def fine(self):
        self.testo.set_text(t("spegnimento"))
        for w in (self.spiega, self.elenco, self.comunque, self.annulla):
            w.hide()
        self.ruota.start()
        spegni_davvero()
        return False


def main():
    try:
        x = X()
    except (OSError, RuntimeError):   # niente schermo: si spegne e basta
        spegni_davvero()
        return 0
    if not x.app():   # nessuna app aperta: niente finestrella
        spegni_davvero()
        return 0
    GLib.set_prgname("tod-spegni")
    Finestra(x)
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
