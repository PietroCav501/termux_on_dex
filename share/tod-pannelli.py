#!/usr/bin/env python3
"""Pannelli della barra di DeX OS, tra Windows 11 e macOS: Notifiche, Volume, Calendario, Batteria, Rete.

  notifiche  le notifiche (dal registro di xfce4-notifyd, via D-Bus) raggruppate per app, con l'ora;
             clic = apre l'app, × = toglie, "Cancella tutto", "Non disturbare"; sotto, il calendario
  volume     volume generale (con muto), uscita audio, volume di ogni app che suona, microfono
  batteria   batteria del telefono (durata stimata, consumo, temperatura) e memoria: Desktop/Android/cache,
             memoria virtuale, le app del desktop per memoria usata (PSS), con "Chiudi"
  rete       Wi-Fi (segnale, banda, IP, reti vicine con la Posizione accesa) e rete mobile

Resta in memoria nascosto (si apre all'istante): `tod-pannello notifiche|volume` scrive il pannello
voluto in $TMPDIR/tod-pannelli.req e manda SIGUSR1; se non c'è, lo avvia con --show <pannello>.
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

try:   # GLib 2.86: le funzioni Unix di Gio stanno in GioUnix
    gi.require_version("GioUnix", "2.0")
    from gi.repository import GioUnix
    DesktopAppInfo = GioUnix.DesktopAppInfo
except (ValueError, ImportError):
    DesktopAppInfo = Gio.DesktopAppInfo

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
TMP = os.environ.get("TMPDIR", "/tmp")
PIDFILE = os.path.join(TMP, "tod-pannelli.pid")
REQFILE = os.path.join(TMP, "tod-pannelli.req")
ACKFILE = os.path.join(TMP, "tod-pannelli.ack")
CASA = os.environ.get("TOD_TERMUX_HOME", os.path.expanduser("~"))
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "")).startswith("it")

TEXT = {
    "notifiche": ("Notifiche", "Notifications"),
    "cancella": ("Cancella tutto", "Clear all"),
    "nessuna": ("Nessuna notifica nuova", "No new notifications"),
    "dnd": ("Non disturbare", "Do not disturb"),
    "altre": ("+%d", "+%d"),
    "meno": ("Mostra meno", "Show less"),
    "suono": ("Suono", "Sound"),
    "calendario": ("Calendario", "Calendar"),
    "oggi": ("Oggi", "Today"),
    "adesso": ("Adesso", "Now"),
    "min": ("%d min fa", "%d min ago"),
    "ore": ("%d h fa", "%d h ago"),
    "ieri": ("Ieri", "Yesterday"),
    "volume": ("Volume", "Volume"),
    "uscita": ("Uscita", "Output"),
    "app": ("App", "Apps"),
    "nessuna_app": ("Nessuna app sta riproducendo audio", "No app is playing audio"),
    "microfono": ("Microfono", "Microphone"),
    "impost": ("Impostazioni Suono…", "Sound Settings…"),
    "muto": ("Muto", "Muted"),
    "telefono": ("Telefono", "Phone"),
}


def T(k):
    return TEXT[k][0 if ITALIAN else 1]


# nomi di giorni e mesi qui: Termux (Bionic) non ha le lingue di sistema, strftime e Gtk.Calendar
# parlerebbero inglese
MESI = (("gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre",
         "ottobre", "novembre", "dicembre"),
        ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
         "November", "December"))
GIORNI = (("lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"),
          ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"))


def mese(n):
    return MESI[0 if ITALIAN else 1][n - 1]


def giorno(n):
    return GIORNI[0 if ITALIAN else 1][n]


# tra macOS (Centro di controllo, Centro notifiche) e DeX OS: fondi pieni (niente vetro: Pietro), angoli
# ampi, schede che galleggiano, cursori a capsula nell'accento con l'icona dentro
CSS = """
.tod-pannello { background-color: transparent; font-family: Inter, sans-serif; color: #1d1d1f; }
.tod-pannello .root.vetro {
  background-color: #f2f2f5;
  border: 1px solid rgba(255, 255, 255, 0.65);
  border-radius: 18px;
  box-shadow: inset 0 0 0 1px rgba(0, 0, 0, 0.06);
}
.tod-pannello.flat .root.vetro, .tod-pannello.flat .root { background-color: #ececf0; border-radius: 0; }
.tod-pannello .modulo {
  background-color: #ffffff;
  border: 1px solid rgba(0, 0, 0, 0.05);
  border-radius: 14px;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.06);
  padding: 12px 14px;
}
.tod-pannello .titolo { font-weight: 600; font-size: 10pt; }
.tod-pannello .grande { font-weight: 600; font-size: 15pt; }
.tod-pannello .gruppo { font-weight: 600; font-size: 8.5pt; color: #6e6e73; }
.tod-pannello .gruppo.pillola {
  background-color: #ffffff; border-radius: 12px; padding: 3px 10px; color: #3a3a3c;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.12), 0 0 0 1px rgba(0, 0, 0, 0.05);
}
.tod-pannello .riassunto { font-weight: 600; font-size: 9.5pt; }
.tod-pannello .testo { font-size: 9pt; color: #3a3a3c; }
.tod-pannello .tenue { font-size: 8.5pt; color: #6e6e73; }
.tod-pannello .scheda {
  background-color: #ffffff;
  border: 1px solid rgba(0, 0, 0, 0.06);
  border-radius: 16px;
  padding: 12px 14px;
  box-shadow: 0 6px 18px rgba(0, 0, 0, 0.16), 0 0 0 1px rgba(0, 0, 0, 0.05);
  margin: 0 8px;
}
.tod-pannello.flat .scheda { background-color: #ffffff; box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.08); }
.tod-pannello .sotto {
  background-color: #e9e9ee;
  border-radius: 0 0 14px 14px;
  min-height: 8px;
  margin: 0 20px;
  box-shadow: 0 4px 10px rgba(0, 0, 0, 0.12);
}
.tod-pannello button.pillola {
  background-color: #ffffff;
  border: 1px solid rgba(0, 0, 0, 0.06);
  box-shadow: 0 3px 10px rgba(0, 0, 0, 0.14), 0 0 0 1px rgba(0, 0, 0, 0.05);
  border-radius: 14px; padding: 4px 12px; min-height: 0; color: #1d1d1f; font-size: 8.5pt; font-weight: 600;
}
.tod-pannello button.pillola:hover { background-color: #f4f4f6; }
.tod-pannello button.pillola.acceso { background-color: ACCENTO; color: #ffffff; border-color: ACCENTO; }
.tod-pannello button.piatto {
  border: none; background: transparent; box-shadow: none; border-radius: 8px; padding: 4px 8px; min-height: 0; min-width: 0;
}
.tod-pannello button.piatto:hover { background: rgba(0, 0, 0, 0.06); }
.tod-pannello button.chiudi {
  padding: 3px; border-radius: 10px; background: rgba(0, 0, 0, 0.06); opacity: 0.8; min-width: 0; min-height: 0;
}
.tod-pannello button.chiudi:hover { opacity: 1; background: rgba(0, 0, 0, 0.12); }
.tod-pannello .riga { border-radius: 8px; padding: 4px 6px; }
.tod-pannello .riga:hover { background: rgba(0, 0, 0, 0.05); }
.tod-pannello .cerchio {
  background-color: rgba(0, 0, 0, 0.08); border-radius: 14px; min-width: 28px; min-height: 28px;
}
.tod-pannello .cerchio.scelto { background-color: ACCENTO; color: #ffffff; }
.tod-pannello .spunta { color: ACCENTO; }
.tod-pannello scale { padding: 0; margin: 0; }
.tod-pannello scale trough {
  min-height: 24px; padding: 0; margin: 0; border: none; border-radius: 12px;
  background-color: rgba(0, 0, 0, 0.09);
}
.tod-pannello scale trough highlight, .tod-pannello scale highlight {
  min-height: 24px; margin: 0; border: none; border-radius: 12px; background-color: ACCENTO; background-image: none;
}
.tod-pannello scale trough slider, .tod-pannello scale slider {
  background-image: none; outline: none;
  min-width: 24px; min-height: 24px; margin: 0; padding: 0; border: none; border-radius: 12px;
  background-color: #ffffff; box-shadow: 0 0 0 0.5px rgba(0, 0, 0, 0.2), 0 1px 4px rgba(0, 0, 0, 0.28);
}
.tod-pannello scale.piccola trough, .tod-pannello scale.piccola trough highlight { min-height: 18px; border-radius: 9px; }
.tod-pannello scale.piccola trough slider { min-width: 18px; min-height: 18px; border-radius: 9px; }
.tod-pannello scale:disabled highlight { background-color: alpha(ACCENTO, 0.4); }
.tod-pannello .in-capsula { color: #ffffff; }
.tod-pannello .in-capsula.vuota { color: #6e6e73; }
.tod-pannello button.voce {
  border: none; box-shadow: none; background: transparent; border-radius: 8px; padding: 6px 10px; min-height: 0;
  font-size: 9.5pt;
}
.tod-pannello button.voce:hover { background: rgba(0, 0, 0, 0.06); }
.tod-pannello .widget .mese { color: ACCENTO; font-weight: 700; font-size: 8.5pt; letter-spacing: 1px; }
.tod-pannello .giorno { font-size: 8.5pt; border-radius: 12px; }
.tod-pannello .giorno.oggi { background-color: ACCENTO; color: #ffffff; font-weight: 600; }
.tod-pannello .giorno.fuori { color: #a1a1a6; }
.tod-pannello separator { background-color: rgba(0, 0, 0, 0.08); min-height: 1px; }
.tod-pannello .numero { font-weight: 600; font-size: 20pt; }
.tod-pannello .tessera { background-color: rgba(0, 0, 0, 0.04); border-radius: 10px; padding: 7px 10px; }
.tod-pannello .stato {
  font-weight: 600; font-size: 8pt; border-radius: 10px; padding: 2px 9px;
  background-color: alpha(ACCENTO, 0.14); color: ACCENTO;
}
.tod-pannello .stato.alta { background-color: ACCENTO; color: #ffffff; }
.tod-pannello .stato.piccolo { font-size: 7pt; padding: 0 6px; border-radius: 8px; }
.tod-pannello scrollbar { background: transparent; border: none; }
.tod-pannello scrollbar slider { min-width: 3px; background: rgba(0, 0, 0, 0.3); border-radius: 3px; }
"""

CSS_SCURO = """
.tod-pannello { color: #f5f5f7; }
.tod-pannello .root.vetro {
  background-color: #242428; border-color: rgba(255, 255, 255, 0.12);
  box-shadow: inset 0 0 0 1px rgba(0, 0, 0, 0.4);
}
.tod-pannello.flat .root.vetro, .tod-pannello.flat .root { background-color: #26262a; }
.tod-pannello .modulo { background-color: #2e2e33; border-color: rgba(255, 255, 255, 0.08); }
.tod-pannello .gruppo, .tod-pannello .tenue { color: #a1a1a6; }
.tod-pannello .testo { color: #d1d1d6; }
.tod-pannello .scheda {
  background-color: #2c2c30; border-color: rgba(255, 255, 255, 0.1);
  box-shadow: 0 6px 18px rgba(0, 0, 0, 0.4), 0 0 0 1px rgba(0, 0, 0, 0.4);
}
.tod-pannello.flat .scheda { background-color: #2c2c30; }
.tod-pannello .sotto { background-color: #38383d; }
.tod-pannello button.pillola { background-color: #2c2c30; border-color: rgba(255, 255, 255, 0.1); color: #f5f5f7; }
.tod-pannello .gruppo.pillola { background-color: #2c2c30; color: #d1d1d6; }
.tod-pannello button.pillola:hover { background-color: #3a3a3f; }
.tod-pannello button.piatto:hover, .tod-pannello .riga:hover, .tod-pannello button.voce:hover { background: rgba(255, 255, 255, 0.08); }
.tod-pannello button.chiudi { background: rgba(255, 255, 255, 0.1); }
.tod-pannello .cerchio { background-color: rgba(255, 255, 255, 0.12); }
.tod-pannello .spunta { color: CHIARO; }
.tod-pannello scale trough { background-color: rgba(255, 255, 255, 0.12); }
.tod-pannello .in-capsula.vuota { color: #a1a1a6; }
.tod-pannello .widget .mese { color: CHIARO; }
.tod-pannello .giorno.fuori { color: #636366; }
.tod-pannello separator { background-color: rgba(255, 255, 255, 0.1); }
.tod-pannello .tessera { background-color: rgba(255, 255, 255, 0.06); }
.tod-pannello .stato { background-color: alpha(CHIARO, 0.16); color: CHIARO; }
.tod-pannello .stato.alta { background-color: CHIARO; color: #1d1d1f; }
.tod-pannello scrollbar slider { background: rgba(255, 255, 255, 0.3); }
"""


def accento():
    a = "#0067c0"
    try:
        for r in open(os.path.join(CASA, ".config/tod/tod.conf")):
            if r.startswith("ACCENTO="):
                v = r.split("=", 1)[1].strip().strip('"')
                if re.fullmatch(r"#[0-9a-fA-F]{6}", v):
                    a = v
    except OSError:
        pass
    r, g, b = (int(a[i:i + 2], 16) for i in (1, 3, 5))
    chiaro = "#%02x%02x%02x" % tuple(int(c + (255 - c) * 0.45) for c in (r, g, b))
    return a, chiaro


def scuro():
    return "dark" in (Gtk.Settings.get_default().get_property("gtk-theme-name") or "").lower()


SCALA = 1.0
MARGINE = 12   # distanza dei pannelli dalla barra e dal bordo dello schermo (come lo Start)


def px(n):
    return int(round(n * SCALA))


def css_scalato(css):
    return re.sub(r"(\d+(?:\.\d+)?)px", lambda m: "%dpx" % max(1, px(float(m.group(1)))), css)


def etichetta(testo, classe=None, ellissi=False, righe=0, xalign=0.0):
    l = Gtk.Label(label=testo, xalign=xalign)
    if classe:
        for c in classe.split():
            l.get_style_context().add_class(c)
    if ellissi:
        l.set_ellipsize(Pango.EllipsizeMode.END)
    if righe:
        l.set_line_wrap(True)
        l.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        l.set_lines(righe)
        l.set_ellipsize(Pango.EllipsizeMode.END)
    return l


def bottone(icona, classe, cb, tip=None, dim=16):
    b = Gtk.Button()
    for c in classe.split():
        b.get_style_context().add_class(c)
    img = Gtk.Image.new_from_icon_name(icona, Gtk.IconSize.BUTTON)
    img.set_pixel_size(px(dim))
    b.add(img)
    b.set_relief(Gtk.ReliefStyle.NONE)
    if tip:
        b.set_tooltip_text(tip)
    b.connect("clicked", lambda *_: cb())
    return b


def quando(ts):
    d = time.time() - ts
    if d < 60:
        return T("adesso")
    if d < 3600:
        return T("min") % (d // 60)
    if time.localtime(ts).tm_yday == time.localtime().tm_yday and d < 86400:
        return time.strftime("%H:%M", time.localtime(ts))
    if d < 172800:
        return T("ieri")
    return time.strftime("%d/%m", time.localtime(ts))


def aggiorna_barra():
    """le icone della barra si ridisegnano subito, senza aspettare il loro giro (SIGUSR2 a tod-barra)"""
    try:
        pid = int(open(os.path.join(os.environ.get("TMPDIR", "/tmp"), "tod-barra.pid")).read().strip())
        if b"tod-barra.py" in open(f"/proc/{pid}/cmdline", "rb").read():
            os.kill(pid, signal.SIGUSR2)
    except (OSError, ValueError):
        pass


# --- finestra base -----------------------------------------------------------------------------
class Pannello(Gtk.Window):
    LARGHEZZA, ALTEZZA = 380, 560

    def __init__(self, titolo, vetro=True):
        super().__init__(title=titolo)
        self.get_style_context().add_class("tod-pannello")
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_type_hint(Gdk.WindowTypeHint.DIALOG)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)
            self.set_app_paintable(True)
        else:
            self.get_style_context().add_class("flat")
        self.nascosto_alle = 0.0
        self.connect("focus-out-event", lambda *a: GLib.timeout_add(120, self._forse_nascondi) and False)
        self.connect("key-press-event", self._tasto)
        self.connect("delete-event", lambda *a: self.nascondi() or True)
        self.connect("size-allocate", self._ancora)
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.root.get_style_context().add_class("root")
        if vetro:
            self.root.get_style_context().add_class("vetro")
        self.root.set_size_request(px(self.LARGHEZZA), -1)   # la finestra non ridimensionabile segue il contenuto
        self.add(self.root)

    def colloca(self, altezza=None):
        display = Gdk.Display.get_default()
        mon = display.get_primary_monitor() or display.get_monitor(0)
        wa = mon.get_workarea()
        w = px(self.LARGHEZZA)
        h = min(altezza or px(self.ALTEZZA), wa.height - px(24))
        # agganciati in basso a destra, alla stessa distanza dalla barra dello Start (MARGINE); se il
        # contenuto cambia altezza, _ancora rimette il bordo basso al suo posto (la "gravity" di GTK
        # xfwm4 non la rispetta)
        self.resize(w, h)
        self.move(wa.x + wa.width - w - px(MARGINE), wa.y + wa.height - h - px(MARGINE))

    def _ancora(self, _w, alloc):
        if not self.get_visible():
            return
        display = Gdk.Display.get_default()
        wa = (display.get_primary_monitor() or display.get_monitor(0)).get_workarea()
        x, y = wa.x + wa.width - alloc.width - px(MARGINE), wa.y + wa.height - alloc.height - px(MARGINE)
        if self.get_position() != (x, y):
            GLib.idle_add(lambda: self.move(x, y) and False)

    def mostra(self):
        self.riempi()
        self.root.show_all()
        self.colloca(self.altezza_voluta())
        self.show()
        self.present()
        gw = self.get_window()
        if gw is not None:
            try:
                gi.require_version("GdkX11", "3.0")
                from gi.repository import GdkX11
                self.present_with_time(GdkX11.x11_get_server_time(gw))
            except (ValueError, ImportError, TypeError):
                pass
            gw.focus(Gdk.CURRENT_TIME)

    def altezza_voluta(self):
        _m, nat = self.root.get_preferred_height_for_width(px(self.LARGHEZZA))
        return max(nat, px(120))

    def nascondi(self):
        if self.get_visible():
            self.nascosto_alle = time.monotonic()
            self.hide()
            self.chiuso()

    def chiuso(self):
        pass

    def alterna(self):
        if self.get_visible():
            self.nascondi()
        elif time.monotonic() - self.nascosto_alle > 0.35:   # il clic sull'icona che l'ha appena chiuso
            self.mostra()

    def _forse_nascondi(self):
        menu = any(isinstance(w, Gtk.Window) and w.get_visible() and w.get_type_hint() in (
            Gdk.WindowTypeHint.POPUP_MENU, Gdk.WindowTypeHint.DROPDOWN_MENU) for w in Gtk.Window.list_toplevels())
        if self.get_visible() and not self.is_active() and not menu:
            self.nascondi()
        return False

    def _tasto(self, _w, ev):
        if ev.keyval == Gdk.KEY_Escape:
            self.nascondi()
            return True
        return False


# --- notifiche (come il Centro notifiche di macOS) ----------------------------------------------
class Notifiche(Pannello):
    LARGHEZZA, ALTEZZA = 380, 760

    def __init__(self):
        super().__init__(T("notifiche"), vetro=False)
        self.aperti = set()   # app con la pila aperta
        self.log = None
        try:
            self.log = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
                                                      "org.xfce.Notifyd", "/org/xfce/Notifyd", "org.xfce.Notifyd.Log", None)
            self.log.connect("g-signal", self._segnale)
        except GLib.Error:
            self.log = None
        testa = Gtk.Box(spacing=px(6))
        testa.set_margin_top(px(6))
        testa.set_margin_end(px(8))
        testa.set_halign(Gtk.Align.END)
        self.cancella = Gtk.Button(label=T("cancella"))
        self.cancella.get_style_context().add_class("pillola")
        self.cancella.connect("clicked", lambda *_: self._chiama("Clear"))
        testa.pack_start(self.cancella, False, False, 0)
        self.dnd = Gtk.Button()
        self.dnd.get_style_context().add_class("pillola")
        riga = Gtk.Box(spacing=px(6))
        self.dnd_icona = Gtk.Image.new_from_icon_name("notification-disabled-symbolic", Gtk.IconSize.BUTTON)
        self.dnd_icona.set_pixel_size(px(14))
        riga.pack_start(self.dnd_icona, False, False, 0)
        riga.pack_start(Gtk.Label(label=T("dnd")), False, False, 0)
        self.dnd.add(riga)
        self.dnd.connect("clicked", lambda *_: self._dnd())
        testa.pack_start(self.dnd, False, False, 0)
        self.root.pack_start(testa, False, False, 0)
        self.scorri = Gtk.ScrolledWindow()
        self.scorri.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scorri.set_propagate_natural_height(True)
        self.scorri.set_max_content_height(px(self.ALTEZZA - 60))
        self.elenco = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(10))
        self.elenco.set_margin_top(px(10))
        self.elenco.set_margin_bottom(px(14))   # spazio per le ombre delle schede
        self.scorri.add(self.elenco)
        self.root.pack_start(self.scorri, True, True, 0)

    def _chiama(self, metodo, args=None):
        if self.log is None:
            return None
        try:
            return self.log.call_sync(metodo, args, Gio.DBusCallFlags.NONE, 3000, None)
        except GLib.Error:
            return None

    def _segnale(self, _p, _mitt, segnale, _par):
        if self.get_visible() and segnale in ("RowAdded", "RowDeleted", "Cleared", "Truncated"):
            GLib.idle_add(self._rifai)

    def _rifai(self):
        self.riempi()
        self.root.show_all()
        self._dnd_mostra()
        self.colloca(self.altezza_voluta())
        return False

    def voci(self):
        r = self._chiama("List", GLib.Variant("(sub)", ("", 200, False)))
        if r is None:
            return []
        out = []
        for e in r.unpack()[0]:
            ident, ts, _tz, app_id, app_nome, icona, riassunto, corpo, _azioni, _scad, letto = e
            ts = ts / 1e6 if ts > 1e11 else ts   # microsecondi (GDateTime) o secondi
            out.append(dict(id=ident, ts=ts, app_id=app_id or "", app=app_nome or app_id or "?", icona=icona or "",
                            riassunto=riassunto or "", corpo=corpo or "", letto=letto))
        return out

    def riempi(self):
        for c in self.elenco.get_children():
            self.elenco.remove(c)
        voci = self.voci()
        self.cancella.set_no_show_all(not voci)
        self.cancella.set_visible(bool(voci))
        if not voci:
            vuoto = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(4))
            vuoto.get_style_context().add_class("scheda")
            vuoto.pack_start(etichetta(T("nessuna"), "riassunto", xalign=0.5), False, False, 0)
            self.elenco.pack_start(vuoto, False, False, 0)
            return
        gruppi = {}
        for v in voci:
            gruppi.setdefault(v["app"], []).append(v)
        for app, lista in sorted(gruppi.items(), key=lambda kv: -max(v["ts"] for v in kv[1])):
            self.elenco.pack_start(self.gruppo(app, sorted(lista, key=lambda v: -v["ts"])), False, False, 0)

    def gruppo(self, app, lista):
        """come macOS: le notifiche della stessa app in pila (si apre con un clic), × per toglierle tutte"""
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        if len(lista) > 1:
            testa = Gtk.Box(spacing=px(6))
            testa.set_margin_start(px(14))
            testa.set_margin_end(px(12))
            testa.set_margin_bottom(px(4))
            nome = etichetta(app, "gruppo pillola", ellissi=True)
            nome.set_halign(Gtk.Align.START)
            testa.pack_start(nome, True, True, 0)
            aperta = app in self.aperti
            meno = Gtk.Button(label=T("meno") if aperta else T("altre") % (len(lista) - 1))
            meno.get_style_context().add_class("pillola")
            meno.connect("clicked", lambda *_: self._pila(app))
            testa.pack_end(self._x(lambda: self._chiama("Delete", GLib.Variant("(as)", ([v["id"] for v in lista],)))),
                           False, False, 0)
            testa.pack_end(meno, False, False, 0)
            box.pack_start(testa, False, False, 0)
            if not aperta:
                box.pack_start(self.scheda(lista[0], len(lista)), False, False, 0)
                box.pack_start(self._sotto(), False, False, 0)
                return box
        for k, v in enumerate(lista[:8]):
            s = self.scheda(v)
            if k:
                s.set_margin_top(px(8))
            box.pack_start(s, False, False, 0)
        return box

    def _sotto(self):
        s = Gtk.Box()
        s.get_style_context().add_class("sotto")
        return s

    def _pila(self, app):
        (self.aperti.discard if app in self.aperti else self.aperti.add)(app)
        self._rifai()

    def _x(self, cb):
        b = bottone("window-close-symbolic", "chiudi", cb, None, 10)
        b.set_valign(Gtk.Align.CENTER)
        return b

    def icona_app(self, v, dim):
        img = Gtk.Image()
        ic = v["icona"]
        if ic.startswith("file://"):
            ic = ic[7:]
        if ic.startswith("/") and os.path.isfile(ic):
            try:
                from gi.repository import GdkPixbuf
                img.set_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_size(ic, px(dim), px(dim)))
                return img
            except GLib.Error:
                pass
        info = self.app_info(v)
        if ic and not ic.startswith("/"):
            img.set_from_icon_name(ic, Gtk.IconSize.DIALOG)
        elif info is not None and info.get_icon() is not None:
            img.set_from_gicon(info.get_icon(), Gtk.IconSize.DIALOG)
        else:
            img.set_from_icon_name("dialog-information", Gtk.IconSize.DIALOG)
        img.set_pixel_size(px(dim))
        return img

    @staticmethod
    def app_info(v):
        for n in (v["app_id"], v["app_id"].lower(), v["app"].lower()):
            if not n:
                continue
            try:
                info = DesktopAppInfo.new(n if n.endswith(".desktop") else n + ".desktop")
            except TypeError:
                info = None
            if info is not None:
                return info
        return None

    def scheda(self, v, quante=1):
        ev = Gtk.EventBox()
        box = Gtk.Box(spacing=px(12))
        box.get_style_context().add_class("scheda")
        box.pack_start(self.icona_app(v, 36), False, False, 0)
        testi = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        riga = Gtk.Box(spacing=6)
        riga.pack_start(etichetta(v["riassunto"] or v["app"], "riassunto", ellissi=True), True, True, 0)
        riga.pack_end(etichetta(quando(v["ts"]), "tenue"), False, False, 0)
        testi.pack_start(riga, False, False, 0)
        if v["corpo"]:
            corpo = re.sub(r"<[^>]+>", "", v["corpo"]).replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
            testi.pack_start(etichetta(corpo, "testo", righe=4), False, False, 0)
        box.pack_start(testi, True, True, 0)
        if quante == 1:
            x = self._x(lambda: self._chiama("Delete", GLib.Variant("(as)", ([v["id"]],))))
            x.set_valign(Gtk.Align.START)
            box.pack_end(x, False, False, 0)
        ev.add(box)
        info = self.app_info(v)
        if quante > 1:
            ev.connect("button-release-event", lambda *_: self._pila(v["app"]) or True)
        elif info is not None:
            ev.connect("button-release-event", lambda *_: self.apri(info, v))
        return ev

    def apri(self, info, v):
        self.nascondi()
        try:
            info.launch([], None)
        except GLib.Error:
            pass
        self._chiama("Delete", GLib.Variant("(as)", ([v["id"]],)))
        return True

    def _dnd_stato(self):
        try:
            return subprocess.run(["xfconf-query", "-c", "xfce4-notifyd", "-p", "/do-not-disturb"], capture_output=True,
                                  text=True, timeout=3).stdout.strip() == "true"
        except (OSError, subprocess.SubprocessError):
            return False

    def _dnd_mostra(self):
        ctx = self.dnd.get_style_context()
        (ctx.add_class if self._dnd_stato() else ctx.remove_class)("acceso")

    def _dnd(self):
        subprocess.run(["xfconf-query", "-c", "xfce4-notifyd", "-p", "/do-not-disturb", "-n", "-t", "bool",
                        "-s", "false" if self._dnd_stato() else "true"], timeout=3, check=False)
        self._dnd_mostra()
        aggiorna_barra()

    def mostra(self):
        super().mostra()
        self._dnd_mostra()
        self._chiama("MarkAllRead")
        aggiorna_barra()


# --- calendario (dall'orologio della barra) ----------------------------------------------------
class Calendario(Pannello):
    LARGHEZZA = 320

    def __init__(self):
        super().__init__(T("calendario"))
        corpo = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(10))
        for m in ("top", "bottom", "start", "end"):
            getattr(corpo, f"set_margin_{m}")(px(12))
        self.root.pack_start(corpo, True, True, 0)
        # in alto la data di oggi, grande; sotto il mese
        oggi = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        oggi.set_margin_start(px(4))
        self.giorno_sett = etichetta("", "gruppo")
        self.data = etichetta("", "grande")
        oggi.pack_start(self.giorno_sett, False, False, 0)
        oggi.pack_start(self.data, False, False, 0)
        corpo.pack_start(oggi, False, False, 0)
        widget = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(6))
        for c in ("modulo", "widget"):
            widget.get_style_context().add_class(c)
        testa = Gtk.Box(spacing=2)
        self.mese = etichetta("", "mese")
        testa.pack_start(self.mese, True, True, 0)
        testa.pack_start(bottone("go-previous-symbolic", "piatto", lambda: self._mese(-1), None, 12), False, False, 0)
        oggi_b = bottone("media-record-symbolic", "piatto", lambda: self._mese(0), T("oggi"), 8)
        testa.pack_start(oggi_b, False, False, 0)
        testa.pack_start(bottone("go-next-symbolic", "piatto", lambda: self._mese(1), None, 12), False, False, 0)
        widget.pack_start(testa, False, False, 0)
        self.griglia = Gtk.Grid(column_homogeneous=True, row_spacing=px(2))
        widget.pack_start(self.griglia, False, False, 0)
        corpo.pack_start(widget, False, False, 0)
        self.visto = None

    def _mese(self, passo):
        if passo == 0 or self.visto is None:
            t = time.localtime()
            self.visto = (t.tm_year, t.tm_mon)
        else:
            a, m = self.visto
            m += passo
            self.visto = (a - 1, 12) if m < 1 else (a + 1, 1) if m > 12 else (a, m)
        self.disegna()

    def riempi(self):
        t = time.localtime()
        self.giorno_sett.set_text(giorno(t.tm_wday).upper())
        self.data.set_text(f"{t.tm_mday} {mese(t.tm_mon)} {t.tm_year}")
        self._mese(0)

    def disegna(self):
        import calendar
        oggi = time.localtime()
        a, m = self.visto
        self.mese.set_text(f"{mese(m).upper()} {a}")
        for c in self.griglia.get_children():
            self.griglia.remove(c)
        for k in range(7):
            self.griglia.attach(etichetta(giorno(k)[:3 if not ITALIAN else 2].capitalize(), "tenue", xalign=0.5), k, 0, 1, 1)
        settimane = calendar.Calendar(0).monthdatescalendar(a, m)
        import datetime
        while len(settimane) < 6:   # sempre sei righe: cambiando mese il pannello non cambia altezza
            settimane.append([settimane[-1][-1] + datetime.timedelta(days=k + 1) for k in range(7)])
        for r, settimana in enumerate(settimane):
            for k, d in enumerate(settimana):
                l = etichetta(str(d.day), "giorno", xalign=0.5)
                ctx = l.get_style_context()
                if (d.year, d.month, d.day) == (oggi.tm_year, oggi.tm_mon, oggi.tm_mday):
                    ctx.add_class("oggi")
                elif d.month != m:
                    ctx.add_class("fuori")
                l.set_size_request(px(26), px(26))
                box = Gtk.Box()
                box.set_halign(Gtk.Align.CENTER)
                box.pack_start(l, False, False, 0)
                self.griglia.attach(box, k, r + 1, 1, 1)
        self.griglia.show_all()


# --- volume (come il modulo Suono del Centro di controllo di macOS) -----------------------------
def pactl_json(*args):
    try:
        out = subprocess.run(["pactl", "-f", "json", *args], capture_output=True, text=True, timeout=4).stdout
        return json.loads(out or "[]")
    except (OSError, subprocess.SubprocessError, ValueError):
        return []


def pactl(*args):
    subprocess.Popen(["pactl", *args], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def percento(vol):
    try:
        return int(next(iter(vol.values()))["value_percent"].rstrip("%"))
    except (StopIteration, KeyError, ValueError, AttributeError):
        return 0


def icona_volume(p, muto):
    if muto or p == 0:
        return "audio-volume-muted-symbolic"
    return "audio-volume-low-symbolic" if p < 34 else "audio-volume-medium-symbolic" if p < 67 else "audio-volume-high-symbolic"


def nome_uscita(s):
    d = s.get("description") or s.get("name", "")
    if re.search(r"sles|opensl|aaudio|android", d + s.get("name", ""), re.I):
        return T("telefono")   # l'altoparlante (o le cuffie) del telefono, come lo sceglie Android
    return d


class Capsula(Gtk.Overlay):
    """il cursore a capsula di macOS: l'icona dentro, a sinistra; trascinato a 0 è muto"""

    def __init__(self, icona_di, valore, muto, cambia, piccola=False):
        super().__init__()
        self.icona_di, self.cambia = icona_di, cambia
        self.scala = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
        self.scala.set_draw_value(False)
        if piccola:
            self.scala.get_style_context().add_class("piccola")
        self.scala.set_value(0 if muto else valore)
        self.scala.connect("value-changed", self._cambiato)
        self.add(self.scala)
        self.img = Gtk.Image.new_from_icon_name(icona_di(valore, muto), Gtk.IconSize.BUTTON)
        self.img.set_pixel_size(px(12 if piccola else 14))
        self.img.get_style_context().add_class("in-capsula")
        self.img.set_halign(Gtk.Align.START)
        self.img.set_valign(Gtk.Align.CENTER)
        self.img.set_margin_start(px(7 if piccola else 9))
        self.add_overlay(self.img)
        self.set_overlay_pass_through(self.img, True)
        self._vuota(0 if muto else valore)

    def _vuota(self, v):   # l'icona sta sul riempimento (bianca) solo se il riempimento arriva fin lì
        ctx = self.img.get_style_context()
        (ctx.add_class if v < 12 else ctx.remove_class)("vuota")

    def _cambiato(self, s):
        v = int(s.get_value())
        self.img.set_from_icon_name(self.icona_di(v, v == 0), Gtk.IconSize.BUTTON)
        self._vuota(v)
        self.cambia(v)


class Volume(Pannello):
    LARGHEZZA = 340

    def __init__(self):
        super().__init__(T("volume"))
        self.corpo = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(10))
        for m in ("top", "start", "end"):
            getattr(self.corpo, f"set_margin_{m}")(px(10))
        self.root.pack_start(self.corpo, True, True, 0)
        altre = Gtk.Button(label=T("impost"))
        altre.get_style_context().add_class("voce")
        altre.get_child().set_xalign(0)
        altre.connect("clicked", lambda *_: self._altre())
        altre.set_margin_start(px(6))
        altre.set_margin_end(px(6))
        altre.set_margin_top(px(4))
        altre.set_margin_bottom(px(8))
        self.root.pack_end(altre, False, False, 0)
        self._timer = 0

    def _altre(self):
        self.nascondi()
        subprocess.Popen(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "tod-settings.py"), "suono"],
                         start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def modulo(self, titolo):
        m = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(8))
        m.get_style_context().add_class("modulo")
        m.pack_start(etichetta(titolo, "titolo"), False, False, 0)
        self.corpo.pack_start(m, False, False, 0)
        return m

    def riempi(self):
        for c in self.corpo.get_children():
            self.corpo.remove(c)
        info = {}
        try:
            for r in subprocess.run(["pactl", "info"], capture_output=True, text=True, timeout=4).stdout.splitlines():
                k, _, v = r.partition(":")
                info[k.strip()] = v.strip()
        except (OSError, subprocess.SubprocessError):
            pass
        uscite = pactl_json("list", "sinks")
        predef = info.get("Default Sink", "")
        sink = next((s for s in uscite if s.get("name") == predef), uscite[0] if uscite else None)
        suono = self.modulo(T("suono"))
        if sink is not None:
            nome = sink["name"]
            suono.pack_start(Capsula(icona_volume, percento(sink.get("volume", {})), bool(sink.get("mute")),
                                     lambda v: (pactl("set-sink-mute", nome, "1" if v == 0 else "0"),
                                                pactl("set-sink-volume", nome, f"{v}%"), self._dopo())), False, False, 0)
            suono.pack_start(Gtk.Separator(), False, False, px(2))
            suono.pack_start(etichetta(T("uscita"), "gruppo"), False, False, 0)
            for s in uscite:
                b = Gtk.EventBox()   # una riga, non un pulsante: GTK centrerebbe il contenuto
                r = Gtk.Box(spacing=px(10))
                r.get_style_context().add_class("riga")
                cerchio = Gtk.Box()
                cerchio.get_style_context().add_class("cerchio")
                if s is sink:
                    cerchio.get_style_context().add_class("scelto")
                img = Gtk.Image.new_from_icon_name("audio-speakers-symbolic", Gtk.IconSize.BUTTON)
                img.set_pixel_size(px(14))
                cerchio.pack_start(img, True, True, 0)
                r.pack_start(cerchio, False, False, 0)
                r.pack_start(etichetta(nome_uscita(s), ellissi=True), True, True, 0)
                if s is sink:
                    spunta = Gtk.Image.new_from_icon_name("object-select-symbolic", Gtk.IconSize.BUTTON)
                    spunta.get_style_context().add_class("spunta")
                    r.pack_end(spunta, False, False, 0)
                b.add(r)
                b.connect("button-release-event", lambda *_a, n=s["name"]: (pactl("set-default-sink", n), self._dopo(300)) and False)
                suono.pack_start(b, False, False, 0)
        # le app che suonano adesso, ognuna col suo volume
        flussi = pactl_json("list", "sink-inputs")
        if flussi:
            app = self.modulo(T("app"))
            for f in flussi:
                pr = f.get("properties", {})
                nome = pr.get("application.name") or pr.get("media.name") or "?"
                riga = Gtk.Box(spacing=px(10))
                img = Gtk.Image.new_from_icon_name(pr.get("application.icon_name") or
                                                   (pr.get("application.process.binary") or "").lower() or "audio-x-generic",
                                                   Gtk.IconSize.DND)
                img.set_pixel_size(px(24))
                img.set_tooltip_text(nome)
                riga.pack_start(img, False, False, 0)
                i = str(f.get("index"))
                c = Capsula(icona_volume, percento(f.get("volume", {})), bool(f.get("mute")),
                            lambda v, i=i: (pactl("set-sink-input-mute", i, "1" if v == 0 else "0"),
                                            pactl("set-sink-input-volume", i, f"{v}%")), piccola=True)
                riga.pack_start(c, True, True, 0)
                app.pack_start(riga, False, False, 0)
        # microfono: la sorgente predefinita, se non è il "monitor" di un'uscita
        sorgenti = [s for s in pactl_json("list", "sources") if not s.get("monitor_source") and ".monitor" not in s.get("name", "")]
        if sorgenti:
            predef = info.get("Default Source", "")
            s = next((x for x in sorgenti if x.get("name") == predef), sorgenti[0])
            n = s["name"]
            mic = self.modulo(T("microfono"))
            mic.pack_start(Capsula(lambda p, m: "microphone-sensitivity-muted-symbolic" if m else "audio-input-microphone-symbolic",
                                   percento(s.get("volume", {})), bool(s.get("mute")),
                                   lambda v: (pactl("set-source-mute", n, "1" if v == 0 else "0"),
                                              pactl("set-source-volume", n, f"{v}%"))), False, False, 0)

    def _dopo(self, ms=250):
        """dopo un cambio: icona della barra aggiornata (una volta, a cose fatte)"""
        if self._timer:
            GLib.source_remove(self._timer)
        self._timer = GLib.timeout_add(ms, self._rinfresca)

    def _rinfresca(self):
        self._timer = 0
        aggiorna_barra()
        return False


# --- batteria (con la memoria) e rete: aiuti comuni ---------------------------------------------
QUI = os.path.dirname(os.path.abspath(__file__))
STATO_TELEFONO = os.path.join(TMP, "tod-phone.json")
COLORE = [(0.0, 0.4, 0.75)]   # l'accento in RGB (lo aggiorna Pannelli.tema)


def TT(it, en):
    return it if ITALIAN else en


def stato_telefono():
    try:
        with open(STATO_TELEFONO) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def in_thread(lavoro, fatto):
    """lavoro() fuori dal thread di GTK; fatto(risultato) di nuovo dentro"""
    import threading

    def corri():
        try:
            r = lavoro()
        except Exception:   # noqa: BLE001 — un dato non letto non deve far cadere il pannello
            r = None
        GLib.idle_add(lambda: fatto(r) and False)
    threading.Thread(target=corri, daemon=True).start()


def termux_api(cmd):
    """un comando di Termux:API (un processo Java: ~1 s) → JSON, o None"""
    try:
        return json.loads(subprocess.run([cmd], capture_output=True, text=True, timeout=15).stdout or "null")
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def avvia(*cmd):
    subprocess.Popen(list(cmd), start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL)


def impostazioni(voce):
    avvia("python3", os.path.join(QUI, "tod-settings.py"), voce)


def android(azione):   # una schermata delle impostazioni del telefono (in DeX si apre in una finestra)
    avvia(os.path.join(PREFIX, "bin/am"), "start", "--user", "0", "-a", azione)


def numero(x, cifre=1):
    s = f"{x:.{cifre}f}"
    return s.replace(".", ",") if ITALIAN else s


def gb(kb):
    return numero(kb / 1048576, 1 if kb < 100 * 1048576 else 0) + " GB"


def misura(kb):   # 640 MB, 1,2 GB
    return f"{kb / 1024:.0f} MB" if kb < 0.95 * 1048576 else gb(kb)


def voce_menu(testo, cb):
    """le voci in fondo ai pannelli (come "Impostazioni Suono…")"""
    b = Gtk.Button(label=testo)
    b.get_style_context().add_class("voce")
    b.get_child().set_xalign(0)
    b.connect("clicked", lambda *_: cb())
    return b


class Parti(Gtk.DrawingArea):
    """una capsula divisa in parti, nelle tinte dell'accento: [(frazione, opacità), ...]"""

    def __init__(self, alto=10):
        super().__init__()
        self.parti = []
        self.set_size_request(-1, px(alto))
        self.connect("draw", self._disegna)

    def imposta(self, parti):
        if parti != self.parti:
            self.parti = parti
            self.queue_draw()

    def _disegna(self, w, cr):
        import math
        a = w.get_allocation()
        larg, alto = a.width, a.height
        r = alto / 2
        cr.new_sub_path()
        cr.arc(r, r, r, math.pi / 2, 3 * math.pi / 2)
        cr.arc(larg - r, r, r, -math.pi / 2, math.pi / 2)
        cr.close_path()
        cr.clip()
        cr.set_source_rgba(*((1, 1, 1, 0.12) if scuro() else (0, 0, 0, 0.08)))
        cr.paint()
        x = 0.0
        for frazione, opacita in self.parti:
            w_parte = max(0.0, min(1.0, frazione)) * larg
            cr.set_source_rgba(*COLORE[0], opacita)
            cr.rectangle(x, 0, w_parte, alto)
            cr.fill()
            x += w_parte
        return False


def pallino(opacita):
    d = Parti(8)
    d.set_size_request(px(8), px(8))
    d.set_valign(Gtk.Align.CENTER)
    d.imposta([(1.0, opacita)])
    return d


def tessera(titolo, valore):
    """un riquadro piccolo: nome tenue sopra, valore sotto"""
    t = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(2))
    t.get_style_context().add_class("tessera")
    t.pack_start(etichetta(titolo, "tenue"), False, False, 0)
    v = etichetta(valore, "riassunto", ellissi=True)
    t.pack_start(v, False, False, 0)
    t.valore = v
    return t


def griglia_tessere(tessere):
    g = Gtk.Grid(column_homogeneous=True, column_spacing=px(8), row_spacing=px(8))
    for k, t in enumerate(tessere):
        g.attach(t, k % 2, k // 2, 1, 1)
    return g


class PannelloModuli(Pannello):
    """moduli uno sotto l'altro, voci in fondo, dati che si aggiornano mentre è aperto"""
    LARGHEZZA = 360
    OGNI = 3000   # ms

    def __init__(self, titolo):
        super().__init__(titolo)
        self.corpo = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(10))
        for m in ("top", "start", "end"):
            getattr(self.corpo, f"set_margin_{m}")(px(10))
        self.root.pack_start(self.corpo, True, True, 0)
        self.fondo = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        for m, v in (("start", 6), ("end", 6), ("top", 4), ("bottom", 8)):
            getattr(self.fondo, f"set_margin_{m}")(px(v))
        self.root.pack_end(self.fondo, False, False, 0)
        self._giro = 0

    def modulo(self, titolo, destra=None):
        m = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(8))
        m.get_style_context().add_class("modulo")
        testa = Gtk.Box(spacing=px(8))
        testa.pack_start(etichetta(titolo, "titolo"), True, True, 0)
        if destra is not None:
            testa.pack_end(destra, False, False, 0)
        m.pack_start(testa, False, False, 0)
        self.corpo.pack_start(m, False, False, 0)
        return m

    def mostra(self):
        super().mostra()
        if not self._giro:
            self._giro = GLib.timeout_add(self.OGNI, self._tic)

    def chiuso(self):
        if self._giro:
            GLib.source_remove(self._giro)
            self._giro = 0

    def _tic(self):
        if not self.get_visible():
            self._giro = 0
            return False
        self.aggiorna()
        return True

    def aggiorna(self):
        pass


# --- memoria: quanta ne usa il desktop, quanta Android, e quali app -----------------------------
def meminfo():
    m = {}
    with open("/proc/meminfo") as f:
        for r in f:
            k, _, v = r.partition(":")
            try:
                m[k] = int(v.split()[0])
            except (ValueError, IndexError):
                pass
    return m


def processi():
    """{pid: (genitore, memoria in kB)} dei processi nostri (Android non mostra gli altri). La memoria è la
    PSS: le parti condivise si dividono tra chi le usa, così la somma non conta due volte"""
    out = {}
    for n in os.listdir("/proc"):
        if not n.isdigit():
            continue
        try:
            with open(f"/proc/{n}/stat") as f:
                genitore = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            continue
        kb = 0
        try:
            with open(f"/proc/{n}/smaps_rollup") as f:
                for r in f:
                    if r.startswith("Pss:"):
                        kb = int(r.split()[1])
                        break
        except (OSError, ValueError):
            try:
                with open(f"/proc/{n}/status") as f:
                    kb = next((int(r.split()[1]) for r in f if r.startswith("VmRSS:")), 0)
            except (OSError, ValueError):
                pass
        out[int(n)] = (genitore, kb)
    return out


def finestre_aperte():
    """[(finestra, pid, istanza, classe)] delle finestre "da barra" (EWMH, con xprop)"""
    def xprop(*a):
        try:
            return subprocess.run(["xprop", "-notype", *a], capture_output=True, text=True, timeout=3).stdout
        except (OSError, subprocess.SubprocessError):
            return ""
    out = []
    for xid in re.findall(r"0x[0-9a-f]+", xprop("-root", "_NET_CLIENT_LIST")):
        p = xprop("-id", xid, "_NET_WM_PID", "WM_CLASS", "_NET_WM_STATE", "_NET_WM_WINDOW_TYPE")
        if "SKIP_TASKBAR" in p or re.search(r"_NET_WM_WINDOW_TYPE = .*_(DOCK|DESKTOP|SPLASH|TOOLBAR|MENU)", p):
            continue
        pid = re.search(r"_NET_WM_PID = (\d+)", p)
        cl = re.findall(r'"([^"]*)"', (re.search(r"WM_CLASS = (.*)", p) or [None, ""])[1])
        if pid:
            out.append((int(xid, 16), int(pid.group(1)), cl[0] if cl else "", cl[1] if len(cl) > 1 else ""))
    return out


def chiudi_finestra(xid):
    """_NET_CLOSE_WINDOW: come la × della finestra (l'app può chiedere di salvare)"""
    import ctypes
    import ctypes.util

    class Ev(ctypes.Structure):
        _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                    ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                    ("format", ctypes.c_int), ("data", ctypes.c_long * 5), ("pad", ctypes.c_long * 12)]
    x = ctypes.CDLL(ctypes.util.find_library("X11") or os.path.join(PREFIX, "lib/libX11.so"))
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XInternAtom.restype = ctypes.c_ulong
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XDefaultRootWindow.restype = ctypes.c_ulong
    x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
    x.XFlush.argtypes = [ctypes.c_void_p]
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    dpy = x.XOpenDisplay(None)
    if not dpy:
        return
    ev = Ev(type=33, send_event=1, window=xid, message_type=x.XInternAtom(dpy, b"_NET_CLOSE_WINDOW", 0), format=32)
    ev.data[0], ev.data[1] = 0, 2   # ora, sorgente: un pannello come una barra
    x.XSendEvent(dpy, x.XDefaultRootWindow(dpy), 0, (1 << 19) | (1 << 20), ctypes.byref(ev))
    x.XFlush(dpy)
    x.XCloseDisplay(dpy)


class Catalogo:
    """dalla classe della finestra alla voce del menu (nome e icona dell'app)"""

    def __init__(self):
        self.voci = None

    def _carica(self):
        self.voci = {}
        for a in Gio.AppInfo.get_all():
            chiavi = [(a.get_id() or "").removesuffix(".desktop")]
            if isinstance(a, DesktopAppInfo):
                chiavi.append(a.get_startup_wm_class() or "")
            chiavi.append(os.path.basename(a.get_executable() or ""))
            for k in chiavi:
                k = k.lower()
                if k and k not in self.voci:
                    self.voci[k] = a
            for k in chiavi[:1]:   # tod-cx-org.esempio.App → anche "org.esempio.app"
                k = k.lower().removeprefix("tod-cx-").removeprefix("tod-android-")
                self.voci.setdefault(k, a)

    def cerca(self, istanza, classe):
        if self.voci is None:
            self._carica()
        for k in (classe, istanza):
            k = (k or "").lower()
            if k in self.voci:
                return self.voci[k]
            if k.rsplit(".", 1)[-1] in self.voci:
                return self.voci[k.rsplit(".", 1)[-1]]
        return None


def in_proot(pid, proc="/proc"):
    """vero se il processo gira con proot: proot lo segue con ptrace (TracerPid). Le app di Debian
    partite senza proot hanno il nostro caricatore e nessun tracciatore, quelle di Termux nemmeno"""
    try:
        with open(f"{proc}/{pid}/status") as f:
            t = next((int(r.split()[1]) for r in f if r.startswith("TracerPid:")), 0)
        if not t:
            return False
        with open(f"{proc}/{t}/cmdline", "rb") as f:
            return b"proot" in os.path.basename(f.read().split(b"\0")[0])
    except (OSError, ValueError, IndexError):
        return False


def raggruppa(procs, finestre, catalogo, proot=in_proot):
    """ogni processo va all'app della finestra più vicina tra i suoi antenati (i processi di un'app Electron
    sotto la sua finestra); il resto è il sistema del desktop"""
    app, radici = {}, {}
    for xid, pid, ist, cl in finestre:
        if pid not in procs:
            continue
        info = catalogo.cerca(ist, cl)
        chiave = info.get_id() if info is not None else (cl or ist or str(pid)).lower()
        a = app.setdefault(chiave, {"chiave": chiave, "info": info, "nome": info.get_display_name() if info else (cl or ist),
                                    "classe": (cl or ist).lower(), "finestre": [], "kb": 0, "proot": False})
        a["finestre"].append(xid)
        a["proot"] = a["proot"] or proot(pid)
        radici.setdefault(pid, chiave)
    sistema = 0
    for pid, (_gen, kb) in procs.items():
        p, passi = pid, 0
        while p in procs and p not in radici and passi < 64:
            p, passi = procs[p][0], passi + 1
        if p in radici:
            app[radici[p]]["kb"] += kb
        else:
            sistema += kb
    return sorted(app.values(), key=lambda a: -a["kb"]), sistema


# --- batteria e memoria ------------------------------------------------------------------------
SALUTE = {"GOOD": ("Buona", "Good"), "OVERHEAT": ("Surriscaldata", "Overheating"), "DEAD": ("Esaurita", "Dead"),
          "OVER_VOLTAGE": ("Sovratensione", "Over voltage"), "COLD": ("Troppo fredda", "Too cold"),
          "UNSPECIFIED_FAILURE": ("Guasto", "Failure")}


def in_carica(b):
    return b.get("status") in ("CHARGING", "FULL") or b.get("plugged") not in (None, "UNPLUGGED")


def corrente_ua(b):
    """corrente media in µA (negativa: si scarica); alcuni telefoni la danno in mA"""
    i = b.get("current_average") or b.get("current") or 0
    return i * 1000 if 0 < abs(i) < 20000 else i


def stima_ore(b):
    p, i, q = b.get("percentage") or 0, corrente_ua(b), b.get("charge_counter") or 0
    if q and q < 100000:   # mAh → µAh
        q *= 1000
    if not (p and i and q):
        return None
    ore = (q * 100 / p - q) / i if in_carica(b) and i > 0 else q / -i if not in_carica(b) and i < 0 else None
    return ore if ore is not None and 0 < ore < 100 else None


def durata(ore):
    h, m = int(ore), int(round((ore - int(ore)) * 60))
    if m == 60:
        h, m = h + 1, 0
    return (f"{h} h " if h else "") + f"{m} min"


def icona_batteria(b):
    p = int(b.get("percentage") or 0)
    livello = min(100, (p + 5) // 10 * 10)
    if in_carica(b):
        return "battery-level-100-charged-symbolic" if p >= 99 else f"battery-level-{livello}-charging-symbolic"
    return "battery-caution-symbolic" if p <= 10 else f"battery-level-{livello}-symbolic"


class Batteria(PannelloModuli):
    """batteria del telefono e, sotto, la memoria: totale, chi la usa, le app del desktop più pesanti"""

    def __init__(self):
        super().__init__(TT("Batteria", "Battery"))
        self.catalogo = Catalogo()
        Gio.AppInfoMonitor.get().connect("changed", lambda *a: setattr(self.catalogo, "voci", None))
        self.fondo.pack_start(voce_menu(TT("Gestione attività…", "Task Manager…"),
                                        lambda: (self.nascondi(), avvia("xfce4-taskmanager"))), False, False, 0)
        self.fondo.pack_start(voce_menu(TT("Impostazioni Batteria…", "Battery Settings…"),
                                        lambda: (self.nascondi(), impostazioni("batteria"))), False, False, 0)
        self.batt = None
        self.n = 0
        self.lettura = False
        self.conferma = None   # l'app di cui si chiede "Chiudere?"
        self.ultime = ([], 0, {})

    # costruzione: una volta per apertura; poi si aggiornano solo testi e barre
    def riempi(self):
        for c in self.corpo.get_children():
            self.corpo.remove(c)
        self.conferma = None
        self.firma = None
        self.batt = stato_telefono().get("battery") or {}
        self._modulo_batteria()
        self._modulo_memoria()
        self.mod_app = self.modulo(TT("App del desktop", "Desktop apps"), etichetta(TT("memoria", "memory"), "tenue"))
        self.scorri = Gtk.ScrolledWindow()
        self.scorri.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scorri.set_propagate_natural_height(True)
        self.scorri.set_max_content_height(px(300))
        self.elenco = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(2))
        self.scorri.add(self.elenco)
        self.mod_app.pack_start(self.scorri, False, False, 0)
        self.n = 0
        self.aggiorna()
        in_thread(lambda: termux_api("termux-battery-status"), self._batteria_letta)

    def _modulo_batteria(self):
        m = self.modulo(TT("Batteria", "Battery"))
        b = self.batt
        if "percentage" not in b:
            m.pack_start(etichetta(TT("In attesa di Termux:API…", "Waiting for Termux:API…"), "tenue"), False, False, 0)
            self.b_num = None
            return
        sopra = Gtk.Box(spacing=px(12))
        self.b_icona = Gtk.Image()
        self.b_icona.set_pixel_size(px(30))
        sopra.pack_start(self.b_icona, False, False, 0)
        self.b_num = etichetta("", "numero")
        sopra.pack_start(self.b_num, False, False, 0)
        destra = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        destra.set_valign(Gtk.Align.CENTER)
        self.b_stato = etichetta("", "riassunto", xalign=1)
        self.b_tempo = etichetta("", "tenue", xalign=1)
        destra.pack_start(self.b_stato, False, False, 0)
        destra.pack_start(self.b_tempo, False, False, 0)
        sopra.pack_end(destra, True, True, 0)
        m.pack_start(sopra, False, False, 0)
        self.b_barra = Parti(8)
        m.pack_start(self.b_barra, False, False, px(2))
        self.b_tess = [tessera(TT("Consumo", "Power"), ""), tessera(TT("Temperatura", "Temperature"), ""),
                       tessera(TT("Salute", "Health"), ""), tessera(TT("Tensione", "Voltage"), "")]
        m.pack_start(griglia_tessere(self.b_tess), False, False, 0)
        self._mostra_batteria()

    def _batteria_letta(self, d):
        if isinstance(d, dict) and "percentage" in d:
            nuova = "percentage" not in self.batt
            self.batt = d
            if nuova and self.get_visible():
                self.riempi()
                self.root.show_all()
            else:
                self._mostra_batteria()
        return False

    def _mostra_batteria(self):
        b = self.batt
        if self.b_num is None or "percentage" not in b:
            return
        p = int(b["percentage"])
        self.b_icona.set_from_icon_name(icona_batteria(b), Gtk.IconSize.DIALOG)
        self.b_num.set_text(f"{p}%")
        ore = stima_ore(b)
        if in_carica(b):
            presa = {"PLUGGED_AC": TT("caricatore", "charger"), "PLUGGED_USB": "USB",
                     "PLUGGED_WIRELESS": "wireless"}.get(b.get("plugged"), "")
            self.b_stato.set_text(TT("In carica", "Charging") + (f" · {presa}" if presa else ""))
            self.b_tempo.set_text(TT("Carica completa", "Fully charged") if p >= 100 or b.get("status") == "FULL" else
                                  (TT("piena tra ", "full in ") + durata(ore)) if ore else "")
        else:
            self.b_stato.set_text(TT("Con la batteria", "On battery"))
            self.b_tempo.set_text((TT("circa ", "about ") + durata(ore) + TT(" rimanenti", " left")) if ore else "")
        self.b_barra.imposta([(p / 100, 1.0)])
        i, v = abs(corrente_ua(b)), b.get("voltage") or 0
        self.b_tess[0].valore.set_text(f"{numero(v / 1000 * i / 1e6)} W" if i and v else "—")
        self.b_tess[1].valore.set_text(f"{numero(float(b['temperature']), 0)} °C" if b.get("temperature") else "—")
        sal = SALUTE.get(b.get("health") or "")
        self.b_tess[2].valore.set_text((sal[0] if ITALIAN else sal[1]) if sal else "—")
        self.b_tess[3].valore.set_text(f"{numero(v / 1000, 2)} V" if v else "—")

    def _modulo_memoria(self):
        self.m_pressione = etichetta("", "stato")
        m = self.modulo(TT("Memoria", "Memory"), self.m_pressione)
        riga = Gtk.Box(spacing=px(6))
        self.m_uso = etichetta("", "numero")
        riga.pack_start(self.m_uso, False, False, 0)
        self.m_tot = etichetta("", "tenue")
        self.m_tot.set_valign(Gtk.Align.END)
        self.m_tot.set_margin_bottom(px(5))
        riga.pack_start(self.m_tot, False, False, 0)
        m.pack_start(riga, False, False, 0)
        self.m_barra = Parti(10)
        m.pack_start(self.m_barra, False, False, 0)
        self.m_voci = []
        g = Gtk.Grid(column_spacing=px(8), row_spacing=px(4))
        nomi = (TT("Desktop", "Desktop"), TT("Android e app", "Android & apps"), TT("Cache", "Cache"), TT("Libera", "Free"))
        for k, (nome, op) in enumerate(zip(nomi, (1.0, 0.5, 0.22, 0.0))):
            r = Gtk.Box(spacing=px(6))
            if op:
                r.pack_start(pallino(op), False, False, 0)
            else:   # la parte libera è il fondo della capsula
                d = Parti(8)
                d.set_size_request(px(8), px(8))
                d.set_valign(Gtk.Align.CENTER)
                r.pack_start(d, False, False, 0)
            r.pack_start(etichetta(nome, "testo"), False, False, 0)
            v = etichetta("", "tenue", xalign=1)
            r.pack_end(v, True, True, 0)
            g.attach(r, k % 2, k // 2, 1, 1)
            self.m_voci.append(v)
        g.set_column_homogeneous(True)
        m.pack_start(g, False, False, 0)
        m.pack_start(Gtk.Separator(), False, False, px(2))
        sw = Gtk.Box(spacing=px(8))
        sw.pack_start(etichetta(TT("Memoria virtuale", "Swap"), "testo"), False, False, 0)
        self.m_swap = etichetta("", "tenue", xalign=1)
        sw.pack_end(self.m_swap, True, True, 0)
        m.pack_start(sw, False, False, 0)
        self.m_swap_barra = Parti(4)
        m.pack_start(self.m_swap_barra, False, False, 0)

    def aggiorna(self):
        self.n += 1
        if self.n % 5 == 0:   # la batteria ogni 15 s (Termux:API costa un processo Java)
            in_thread(lambda: termux_api("termux-battery-status"), self._batteria_letta)
        if self.lettura:
            return
        self.lettura = True
        in_thread(lambda: (meminfo(), processi(), finestre_aperte()), self._letto)

    def _letto(self, r):
        self.lettura = False
        if r is None or not self.get_visible():
            return False
        mem, procs, fin = r
        tot, disp, libera = mem.get("MemTotal", 1), mem.get("MemAvailable", 0), mem.get("MemFree", 0)
        usata = tot - disp
        desktop = min(usata, sum(kb for _g, kb in procs.values()))
        cache = max(0, disp - libera)
        self.m_uso.set_text(gb(usata))
        self.m_tot.set_text(TT(f"in uso su {gb(tot)}", f"used of {gb(tot)}"))
        self.m_barra.imposta([(desktop / tot, 1.0), ((usata - desktop) / tot, 0.5), (cache / tot, 0.22)])
        for v, kb in zip(self.m_voci, (desktop, usata - desktop, cache, libera)):
            v.set_text(misura(kb))
        quota = disp / tot
        ctx = self.m_pressione.get_style_context()
        if quota >= 0.2:
            self.m_pressione.set_text(TT("Normale", "Normal"))
            ctx.remove_class("alta")
        else:
            self.m_pressione.set_text(TT("Memoria quasi piena", "Memory almost full") if quota < 0.1 else TT("Sotto sforzo", "Under pressure"))
            ctx.add_class("alta")
        self.m_pressione.set_tooltip_text(TT(f"{gb(disp)} disponibili subito", f"{gb(disp)} available now"))
        st, sf = mem.get("SwapTotal", 0), mem.get("SwapFree", 0)
        self.m_swap.set_text(TT(f"{gb(st - sf)} su {gb(st)}", f"{gb(st - sf)} of {gb(st)}") if st else TT("spenta", "off"))
        self.m_swap_barra.imposta([((st - sf) / st, 0.5)] if st else [])
        app, sistema = raggruppa(procs, fin, self.catalogo)
        self._elenco_app(app, sistema)
        return False

    def _elenco_app(self, app, sistema):
        app = app[:12] + [{"chiave": None, "nome": TT("Sistema del desktop", "Desktop system"), "info": None,
                           "classe": "", "kb": sistema, "finestre": []}]
        massimo = max([a["kb"] for a in app] + [1])
        firma = ([(a["chiave"], a.get("proot")) for a in app], self.conferma)
        if firma == getattr(self, "firma", None):   # stesse app: solo numeri e barre (niente sfarfallio)
            for a in app:
                lab, barra = self.righe[a["chiave"]]
                lab.set_text(misura(a["kb"]))
                barra.imposta([(a["kb"] / massimo, 0.5 if a["chiave"] is None else 1.0)])
            return
        self.firma, self.righe = firma, {}
        for c in self.elenco.get_children():
            self.elenco.remove(c)
        if len(app) == 1:
            self.elenco.pack_start(etichetta(TT("Nessuna app aperta", "No open apps"), "tenue"), False, False, px(4))
        for a in app:
            self.elenco.pack_start(self._riga_app(a, massimo), False, False, 0)
        self.elenco.show_all()

    def _riga_app(self, a, massimo):
        r = Gtk.Box(spacing=px(10))
        r.get_style_context().add_class("riga")
        img = Gtk.Image()
        if a["chiave"] is None:
            img.set_from_icon_name("computer-symbolic", Gtk.IconSize.DND)
        elif a["info"] is not None and a["info"].get_icon() is not None:
            img.set_from_gicon(a["info"].get_icon(), Gtk.IconSize.DND)
        else:
            img.set_from_icon_name(a["classe"] or "application-x-executable", Gtk.IconSize.DND)
        img.set_pixel_size(px(24))
        r.pack_start(img, False, False, 0)
        if self.conferma is not None and self.conferma == a["chiave"]:
            domanda = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            domanda.set_valign(Gtk.Align.CENTER)
            domanda.pack_start(etichetta(a["nome"], "riassunto", ellissi=True), False, False, 0)
            domanda.pack_start(etichetta(TT("Chiuderla?", "Quit it?"), "tenue"), False, False, 0)
            r.pack_start(domanda, True, True, 0)
            no = Gtk.Button(label=TT("Annulla", "Cancel"))
            no.get_style_context().add_class("pillola")
            no.connect("clicked", lambda *_: self._chiedi(None))
            si = Gtk.Button(label=TT("Chiudi", "Close"))
            for c in ("pillola", "acceso"):
                si.get_style_context().add_class(c)
            si.connect("clicked", lambda *_, f=list(a["finestre"]): self._chiudi(f))
            r.pack_end(si, False, False, 0)
            r.pack_end(no, False, False, 0)
            self.righe[a["chiave"]] = (Gtk.Label(), Parti(4))   # niente da aggiornare finché si decide
            return r
        testi = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(4))
        su = Gtk.Box(spacing=px(6))
        nome = etichetta(a["nome"], "testo", ellissi=True)
        su.pack_start(nome, not a.get("proot"), True, 0)   # con il segno lo spazio va dopo il segno
        if a.get("proot"):   # le app di Debian partono senza proot; questa no (più lenta)
            segno = etichetta("proot", "stato piccolo")
            segno.set_tooltip_text(TT("Aperta con proot: più lenta di un'app senza proot",
                                      "Running under proot: slower than without proot"))
            segno.set_valign(Gtk.Align.CENTER)
            su.pack_start(segno, False, False, 0)
            su.pack_start(Gtk.Box(), True, True, 0)
        quanto = etichetta(misura(a["kb"]), "tenue")
        su.pack_end(quanto, False, False, 0)
        testi.pack_start(su, False, False, 0)
        barra = Parti(4)
        barra.imposta([(a["kb"] / massimo, 0.5 if a["chiave"] is None else 1.0)])
        self.righe[a["chiave"]] = (quanto, barra)
        testi.pack_start(barra, False, False, 0)
        testi.set_valign(Gtk.Align.CENTER)
        r.pack_start(testi, True, True, 0)
        if a["chiave"] is not None:
            x = bottone("window-close-symbolic", "chiudi", lambda k=a["chiave"]: self._chiedi(k),
                        TT("Chiudi l'app", "Quit app"), 10)
            x.set_valign(Gtk.Align.CENTER)
            r.pack_end(x, False, False, 0)
        return r

    def _chiedi(self, chiave):
        self.conferma = chiave
        self.aggiorna()

    def _chiudi(self, finestre):
        for xid in finestre:
            chiudi_finestra(xid)
        self.conferma = None
        GLib.timeout_add(800, lambda: self.aggiorna() and False)


# --- Wi-Fi e rete ------------------------------------------------------------------------------
TIPI_RETE = {"lte": "4G", "lte_ca": "4G+", "nr": "5G", "hspa": "3G", "hspap": "3G+", "umts": "3G", "hsdpa": "3G",
             "hsupa": "3G", "edge": "2G", "gprs": "2G", "gsm": "2G"}


def qualita(rssi):
    """(nome, livello dell'icona) dal segnale in dBm"""
    if rssi >= -55:
        return TT("Ottimo", "Excellent"), "excellent"
    if rssi >= -67:
        return TT("Buono", "Good"), "good"
    if rssi >= -75:
        return TT("Discreto", "Fair"), "ok"
    return TT("Debole", "Weak"), "weak"


def banda(mhz):
    if not mhz:
        return ""
    return "2,4 GHz" if mhz < 3000 else "5 GHz" if mhz < 5925 else "6 GHz"


def wifi_connesso(w):
    return w.get("supplicant_state") == "COMPLETED" or (w.get("ip") not in (None, "0.0.0.0") and (w.get("rssi") or -127) > -127)


class Rete(PannelloModuli):
    """la rete del telefono: Wi-Fi (con le reti vicine, se la Posizione è accesa) e rete mobile. La
    connessione la decide Android: per cambiarla si aprono le sue impostazioni"""
    OGNI = 10000

    def __init__(self):
        super().__init__(TT("Rete", "Network"))
        self.fondo.pack_start(voce_menu(TT("Impostazioni Wi-Fi del telefono…", "Phone Wi-Fi Settings…"),
                                        lambda: (self.nascondi(), android("android.settings.WIFI_SETTINGS"))), False, False, 0)
        self.fondo.pack_start(voce_menu(TT("Impostazioni di rete…", "Network Settings…"),
                                        lambda: (self.nascondi(), impostazioni("rete"))), False, False, 0)
        self.stato = {}
        self.vicine = None

    def riempi(self):
        st = stato_telefono()
        self.stato = {"wifi": st.get("wifi") or {}, "phone": st.get("phone") or {}}
        self.disegna()
        self.aggiorna()

    def aggiorna(self):
        in_thread(lambda: (termux_api("termux-wifi-connectioninfo"), termux_api("termux-telephony-deviceinfo"),
                           termux_api("termux-wifi-scaninfo")), self._letto)

    def _letto(self, r):
        if r is None or not self.get_visible():
            return False
        w, ph, vicine = r
        if isinstance(w, dict) and "API_ERROR" not in w:
            self.stato["wifi"] = w
        if isinstance(ph, dict) and "API_ERROR" not in ph:
            self.stato["phone"] = ph
        self.vicine = vicine
        self.disegna()
        self.root.show_all()
        return False

    def _riga(self, icona, nome, sotto=None, scelto=False, destra=None, clic=None):
        ev = Gtk.EventBox()
        r = Gtk.Box(spacing=px(10))
        r.get_style_context().add_class("riga")
        cerchio = Gtk.Box()
        cerchio.get_style_context().add_class("cerchio")
        if scelto:
            cerchio.get_style_context().add_class("scelto")
        img = Gtk.Image.new_from_icon_name(icona, Gtk.IconSize.BUTTON)
        img.set_pixel_size(px(14))
        cerchio.pack_start(img, True, True, 0)
        cerchio.set_valign(Gtk.Align.CENTER)
        r.pack_start(cerchio, False, False, 0)
        testi = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        testi.set_valign(Gtk.Align.CENTER)
        testi.pack_start(etichetta(nome, "riassunto" if scelto else "testo", ellissi=True), False, False, 0)
        if sotto:
            testi.pack_start(etichetta(sotto, "tenue", ellissi=True), False, False, 0)
        r.pack_start(testi, True, True, 0)
        if destra is not None:
            r.pack_end(destra, False, False, 0)
        ev.add(r)
        if clic:
            ev.connect("button-release-event", lambda *_: clic() or False)
        return ev

    def disegna(self):
        for c in self.corpo.get_children():
            self.corpo.remove(c)
        w, ph = self.stato["wifi"], self.stato["phone"]
        m = self.modulo("Wi-Fi")
        senza_posizione = "Location" in json.dumps(self.vicine or "") or not (w.get("ssid") or "").strip('"').strip("<>") \
            or "unknown ssid" in (w.get("ssid") or "")
        if wifi_connesso(w):
            rssi = int(w.get("rssi") or -127)
            nome_q, liv = qualita(rssi)
            ssid = (w.get("ssid") or "").strip('"')
            if ssid in ("", "<unknown ssid>"):
                ssid = TT("Rete Wi-Fi", "Wi-Fi network")
            dettagli = " · ".join(x for x in (TT("Connesso", "Connected"), banda(w.get("frequency_mhz")),
                                              f"{w['link_speed_mbps']} Mbit/s" if w.get("link_speed_mbps") else "") if x)
            spunta = Gtk.Image.new_from_icon_name("object-select-symbolic", Gtk.IconSize.BUTTON)
            spunta.get_style_context().add_class("spunta")
            m.pack_start(self._riga(f"network-wireless-signal-{liv}-symbolic", ssid, dettagli, True, spunta), False, False, 0)
            m.pack_start(griglia_tessere([tessera(TT("Segnale", "Signal"), f"{nome_q} · {rssi} dBm"),
                                          tessera(TT("Indirizzo IP", "IP address"), w.get("ip") or "—")]), False, False, 0)
        else:
            m.pack_start(self._riga("network-wireless-offline-symbolic", TT("Non connesso", "Not connected"),
                                    TT("Il telefono non è collegato a una rete Wi-Fi", "The phone is not on a Wi-Fi network")),
                         False, False, 0)
        if isinstance(self.vicine, list) and self.vicine:
            m.pack_start(Gtk.Separator(), False, False, px(2))
            m.pack_start(etichetta(TT("Reti vicine", "Nearby networks"), "gruppo"), False, False, 0)
            visti = set()
            for n in sorted(self.vicine, key=lambda n: -(n.get("rssi") or -127)):
                ssid = (n.get("ssid") or "").strip()
                if not ssid or ssid in visti or ssid == (w.get("ssid") or "").strip('"'):
                    continue
                visti.add(ssid)
                _q, liv = qualita(n.get("rssi") or -127)
                lucchetto = None
                if re.search(r"WPA|WEP|SAE|PSK|EAP", n.get("capabilities") or ""):
                    lucchetto = Gtk.Image.new_from_icon_name("changes-prevent-symbolic", Gtk.IconSize.BUTTON)
                    lucchetto.set_pixel_size(px(12))
                    lucchetto.get_style_context().add_class("dim-label")
                m.pack_start(self._riga(f"network-wireless-signal-{liv}-symbolic", ssid, banda(n.get("frequency_mhz")),
                                        destra=lucchetto,
                                        clic=lambda: (self.nascondi(), android("android.settings.WIFI_SETTINGS"))),
                             False, False, 0)
                if len(visti) >= 6:
                    break
        elif senza_posizione:
            nota = etichetta(TT("Accendi la Posizione del telefono per vedere il nome della rete e quelle vicine.",
                                "Turn on the phone's Location to see the network name and nearby networks."), "tenue", righe=3)
            m.pack_start(nota, False, False, 0)
        # rete mobile
        if ph.get("network_operator_name") or ph.get("sim_state") == "ready":
            mm = self.modulo(TT("Rete mobile", "Mobile network"))
            tipo = TIPI_RETE.get((ph.get("network_type") or "").lower(), (ph.get("network_type") or "").upper())
            usati = ph.get("data_state") == "connected"
            dati = TT("Dati in uso", "Data in use") if usati else \
                TT("Dati pronti", "Data ready") if str(ph.get("data_enabled")) == "true" else TT("Dati spenti", "Data off")
            sotto = " · ".join(x for x in (tipo, dati, TT("in roaming", "roaming") if ph.get("network_roaming") else "") if x)
            mm.pack_start(self._riga("network-cellular-signal-good-symbolic",
                                     ph.get("network_operator_name") or ph.get("sim_operator_name") or TT("Rete mobile", "Mobile"),
                                     sotto, usati), False, False, 0)


# --- processo in memoria -----------------------------------------------------------------------
class Pannelli:
    def __init__(self):
        global SCALA
        res = Gdk.Screen.get_default().get_resolution()
        SCALA = res / 96.0 if res and res > 0 else 1.0
        self.prov = Gtk.CssProvider()
        self.prov_scuro = Gtk.CssProvider()
        screen = Gdk.Screen.get_default()
        Gtk.StyleContext.add_provider_for_screen(screen, self.prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        Gtk.StyleContext.add_provider_for_screen(screen, self.prov_scuro, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2)
        self.tema()
        Gtk.Settings.get_default().connect("notify::gtk-theme-name", lambda *a: self.tema())
        self.finestre = {"notifiche": Notifiche(), "volume": Volume(), "calendario": Calendario(),
                         "batteria": Batteria(), "rete": Rete()}

    def tema(self):
        a, chiaro = accento()
        COLORE[0] = tuple(int(a[i:i + 2], 16) / 255 for i in (1, 3, 5))
        self.prov.load_from_data(css_scalato(CSS).replace("ACCENTO", a).encode())
        self.prov_scuro.load_from_data(css_scalato(CSS_SCURO).replace("CHIARO", chiaro).encode() if scuro() else b"")

    def alterna(self, nome):
        for n, w in self.finestre.items():
            if n != nome and w.get_visible():
                w.nascondi()
        if nome in self.finestre:
            self.finestre[nome].alterna()


def main():
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGUSR1})   # Android lo tiene bloccato (vedi tod-start.py)
    pannelli = {"p": None, "attesa": None}
    if "--show" in sys.argv:
        i = sys.argv.index("--show")
        pannelli["attesa"] = sys.argv[i + 1] if i + 1 < len(sys.argv) else "notifiche"

    def richiesta():
        try:
            with open(REQFILE) as f:
                tok, _, nome = f.read().strip().partition(" ")
            with open(ACKFILE, "w") as f:
                f.write(tok)
        except OSError:
            return GLib.SOURCE_CONTINUE
        if pannelli["p"] is None:
            pannelli["attesa"] = nome
        else:
            pannelli["p"].alterna(nome)
        return GLib.SOURCE_CONTINUE

    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGUSR1, richiesta)
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, Gtk.main_quit)
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    pannelli["p"] = Pannelli()
    if pannelli["attesa"]:
        GLib.idle_add(lambda: pannelli["p"].alterna(pannelli["attesa"]) and False)
    Gtk.main()
    try:
        with open(PIDFILE) as f:
            if f.read().strip() == str(os.getpid()):
                os.unlink(PIDFILE)
    except OSError:
        pass


if __name__ == "__main__":
    main()
