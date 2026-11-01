#!/usr/bin/env python3
"""Menu Start di Termux On DeX, in stile Windows 11.

Ricerca in alto, app aggiunte a griglia, "Consigliati" (file aperti di recente),
utente e Spegni in basso, "Tutte le app" in ordine alfabetico.
Resta in memoria nascosto (si apre all'istante): `tod-start` manda SIGUSR1 al
processo vivo, oppure lo avvia con --show.
"""
import os
import re
import signal
import subprocess
import sys
import time

T0 = time.monotonic()


def tlog(msg):   # tempi nel registro (start.log): per capire dove si perde tempo
    print(f"tod-start {time.strftime('%H:%M:%S')} pid={os.getpid()} +{time.monotonic() - T0:.2f}s {msg}",
          file=sys.stderr, flush=True)

import gi

os.environ.setdefault("XDG_CURRENT_DESKTOP", "XFCE")   # altrimenti le app "solo XFCE" (Impostazioni) spariscono
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
TMP = os.environ.get("TMPDIR", "/tmp")
PIDFILE = os.path.join(TMP, "tod-start.pid")
REQFILE = os.path.join(TMP, "tod-start.req")   # tod-start scrive qui un numero, noi lo rimandiamo in ACKFILE
ACKFILE = os.path.join(TMP, "tod-start.ack")
CONF = os.path.join(os.environ.get("TOD_TERMUX_HOME", os.path.expanduser("~")), ".config", "tod")
PINNED_FILE = os.path.join(CONF, "start-aggiunte")
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "")).startswith("it")

DEFAULT_PINNED = [
    "thunar.desktop", "chromium.desktop", "firefox.desktop", "xfce4-terminal.desktop",
    "libreoffice-writer.desktop", "libreoffice-calc.desktop",
    "code-oss.desktop", "org.xfce.mousepad.desktop", "org.xfce.ristretto.desktop",
    "gimp.desktop", "org.inkscape.Inkscape.desktop", "xfce-settings-manager.desktop",
]

# nomi brevi come in Windows ("Esplora file", non "Gestore di file Thunar")
SHORT_NAMES = {
    "thunar.desktop": ("Esplora file", "File Explorer"),
    "xfce4-terminal.desktop": ("Terminale", "Terminal"),
    "org.xfce.mousepad.desktop": ("Blocco note", "Notepad"),
    "org.xfce.ristretto.desktop": ("Foto", "Photos"),
    "xfce-settings-manager.desktop": None,   # al suo posto le Impostazioni di Termux On DeX
    "tod-settings.desktop": ("Impostazioni", "Settings"),
    "libreoffice-writer.desktop": ("Writer", "Writer"),
    "libreoffice-calc.desktop": ("Calc", "Calc"),
    "libreoffice-impress.desktop": ("Impress", "Impress"),
    "libreoffice-base.desktop": ("Base", "Base"),
    "libreoffice-draw.desktop": ("Draw", "Draw"),
    "libreoffice-math.desktop": ("Math", "Math"),
    "xfce4-taskmanager.desktop": ("Gestione attività", "Task Manager"),
    "gimp.desktop": ("GIMP", "GIMP"),
    "org.inkscape.Inkscape.desktop": ("Inkscape", "Inkscape"),
    "code-oss.desktop": ("Code", "Code"),
    "org.gnome.FileRoller.desktop": ("Archivi compressi", "Archives"),
    "org.pulseaudio.pavucontrol.desktop": ("Volume", "Volume"),
    "xfce4-screenshooter.desktop": ("Strumento di cattura", "Snipping Tool"),
    "xfce4-clipman.desktop": None,   # gira già nella barra
    "xfce4-appfinder.desktop": None,
    "org.xfce.mousepad-settings.desktop": None,
}

TEXT = {
    "search": ("Digita qui per cercare", "Type here to search"),
    "pinned": ("Aggiunte", "Pinned"),
    "all": ("Tutte le app", "All apps"),
    "back": ("Indietro", "Back"),
    "recent": ("Consigliati", "Recommended"),
    "no_recent": ("I file che apri compariranno qui.", "Files you open will show up here."),
    "best": ("Corrispondenza migliore", "Best match"),
    "apps": ("App", "Apps"),
    "phone_app": ("App del telefono", "Phone app"),
    "pc_app": ("App", "App"),
    "none": ("Nessun risultato", "No results"),
    "power": ("Spegni", "Shut down"),
    "pin": ("Aggiungi a Start", "Pin to Start"),
    "unpin": ("Rimuovi da Start", "Unpin from Start"),
    "desk_add": ("Aggiungi alla scrivania", "Add to desktop"),
    "desk_del": ("Rimuovi dalla scrivania", "Remove from desktop"),
    "now": ("Adesso", "Just now"),
    "min": ("%d min fa", "%d min ago"),
    "hours": ("%d ore fa", "%d hours ago"),
    "yesterday": ("Ieri", "Yesterday"),
}


def T(key):
    return TEXT[key][0 if ITALIAN else 1]


CSS = b"""
.tod-start { background-color: transparent; }
.tod-start .root {
  background-color: #f3f3f3;
  border: 1px solid rgba(0,0,0,0.14);
  border-radius: 8px;
  font-family: Inter, sans-serif;
  color: #1a1a1a;
}
.tod-start.flat .root { border-radius: 0; }
.tod-start entry.search {
  min-height: 34px;
  padding: 0 14px;
  border-radius: 18px;
  border: 1px solid #dcdcdc;
  border-bottom: 1px solid #c4c4c4;
  background: #ffffff;
  box-shadow: none;
  font-size: 10.5pt;
}
.tod-start entry.search:focus { border-bottom: 2px solid #005fb8; }
.tod-start .section { font-weight: 600; font-size: 10.5pt; }
.tod-start button.pill {
  min-height: 24px;
  padding: 0 10px;
  border-radius: 4px;
  border: 1px solid #e3e3e3;
  background: #fbfbfb;
  box-shadow: none;
  font-size: 9pt;
}
.tod-start button.pill:hover { background: #f6f6f6; }
.tod-start button.tile, .tod-start button.row {
  border: none;
  border-radius: 4px;
  background: transparent;
  box-shadow: none;
  padding: 8px 2px 6px 2px;
}
.tod-start button.row { padding: 6px 10px; }
.tod-start button.tile:hover, .tod-start button.row:hover,
.tod-start button.tile:focus, .tod-start button.row:focus { background: rgba(0,0,0,0.045); }
.tod-start button.tile:active, .tod-start button.row:active { background: rgba(0,0,0,0.08); }
.tod-start .tile-label { font-size: 9pt; }
.tod-start .sub { font-size: 8.5pt; color: #5f5f5f; }
.tod-start .letter { font-weight: 600; color: #005fb8; padding: 10px 10px 2px 10px; }
.tod-start .best {
  background: rgba(0,0,0,0.035);
  border-radius: 6px;
  padding: 18px;
}
.tod-start .footer {
  background: #ebebeb;
  border-top: 1px solid rgba(0,0,0,0.07);
  border-radius: 0 0 8px 8px;
  padding: 10px 46px;
}
.tod-start.flat .footer { border-radius: 0; }
.tod-start .avatar {
  background: #005fb8;
  color: #ffffff;
  border-radius: 16px;
  min-width: 32px;
  min-height: 32px;
  font-weight: 600;
}
.tod-start .name { font-size: 9.5pt; }
.tod-start scrollbar { background: transparent; border: none; }
.tod-start scrollbar slider { min-width: 3px; background: rgba(0,0,0,0.3); border-radius: 3px; }
"""

# tema scuro (Impostazioni → Aspetto): stessi spazi, colori di Windows 11 in modalità scura
CSS_DARK = b"""
.tod-start .root { background-color: #202020; border: 1px solid rgba(255,255,255,0.10); color: #f3f3f3; }
.tod-start entry.search { background: #2b2b2b; color: #f3f3f3; border: 1px solid #3a3a3a; border-bottom: 1px solid #4a4a4a; }
.tod-start entry.search:focus { border-bottom: 2px solid #60cdff; }
.tod-start button.pill { background: #2d2d2d; border: 1px solid #3a3a3a; color: #f3f3f3; }
.tod-start button.pill:hover { background: #353535; }
.tod-start button.tile, .tod-start button.row { color: #f3f3f3; }
.tod-start button.tile:hover, .tod-start button.row:hover,
.tod-start button.tile:focus, .tod-start button.row:focus { background: rgba(255,255,255,0.06); }
.tod-start button.tile:active, .tod-start button.row:active { background: rgba(255,255,255,0.10); }
.tod-start .sub { color: #a8a8a8; }
.tod-start .letter { color: #60cdff; }
.tod-start .best { background: rgba(255,255,255,0.05); }
.tod-start .footer { background: #1c1c1c; border-top: 1px solid rgba(255,255,255,0.07); }
.tod-start scrollbar slider { background: rgba(255,255,255,0.3); }
"""


def accent():
    """Il colore d'accento scelto (Impostazioni → Aspetto), con una versione chiara per lo scuro."""
    a = "#005fb8"
    try:
        for line in open(os.path.expanduser("~/.config/tod/tod.conf")):
            if line.startswith("ACCENTO="):
                v = line.split("=", 1)[1].strip().strip('"')
                if re.fullmatch(r"#[0-9a-fA-F]{6}", v):
                    a = v
    except OSError:
        pass
    r, g, b = (int(a[i:i + 2], 16) for i in (1, 3, 5))
    light = "#%02x%02x%02x" % tuple(int(c + (255 - c) * 0.45) for c in (r, g, b))
    return a.encode(), light.encode()


def dark_theme():
    name = Gtk.Settings.get_default().get_property("gtk-theme-name") or ""
    return "dark" in name.lower()


W, H = 640, 700
SCALE = 1.0   # DPI dello schermo / 96: tutto ciò che è in pixel cresce come il testo


def px(n):
    return int(round(n * SCALE))


def scaled_css():
    return re.sub(rb"(\d+(?:\.\d+)?)px", lambda m: b"%dpx" % px(float(m.group(1))), CSS)


def short_name(info):
    n = SHORT_NAMES.get(info.get_id() or "")
    if n:
        return n[0 if ITALIAN else 1]
    return info.get_display_name() or info.get_name() or "?"


def is_phone_app(info):
    try:
        return info.get_string("X-TOD-Android") == "true"
    except (AttributeError, TypeError):
        return False


def kind_label(info):
    return T("phone_app") if is_phone_app(info) else T("pc_app")


def app_icon(info, size):
    img = Gtk.Image()
    gi_icon = info.get_icon()
    if gi_icon is not None:
        img.set_from_gicon(gi_icon, Gtk.IconSize.DIALOG)
    else:
        img.set_from_icon_name("application-x-executable", Gtk.IconSize.DIALOG)
    img.set_pixel_size(size)
    return img


def when(ts):
    d = time.time() - ts
    if d < 60:
        return T("now")
    if d < 3600:
        return T("min") % (d // 60)
    if d < 86400:
        return T("hours") % (d // 3600)
    if d < 172800:
        return T("yesterday")
    return time.strftime("%d/%m/%Y", time.localtime(ts))


class Start(Gtk.Window):
    def __init__(self):
        global SCALE
        res = Gdk.Screen.get_default().get_resolution()
        SCALE = res / 96.0 if res and res > 0 else 1.0
        super().__init__(title="Start")
        self.get_style_context().add_class("tod-start")
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_type_hint(Gdk.WindowTypeHint.DIALOG)
        self.set_default_size(px(W), px(H))
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)
            self.set_app_paintable(True)
        else:
            self.get_style_context().add_class("flat")

        self.prov = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(screen, self.prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        self.dark_prov = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(screen, self.dark_prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 2)
        self.apply_theme()
        # chiaro/scuro cambiato dalle Impostazioni: il menu (sempre in memoria) si adegua subito
        Gtk.Settings.get_default().connect("notify::gtk-theme-name", lambda *a: self.apply_theme())

        self.hidden_at = 0.0
        self.apps = []
        self.connect("focus-out-event", self.on_focus_out)
        self.connect("map-event", lambda *a: self.on_mapped() or False)
        self.connect("key-press-event", self.on_key)
        self.connect("delete-event", lambda *a: self.hide_menu() or True)
        self.connect("size-allocate", self._ancora)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.get_style_context().add_class("root")
        self.add(root)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        body.set_margin_top(px(28))
        body.set_margin_start(px(32))
        body.set_margin_end(px(32))
        body.set_margin_bottom(px(16))
        root.pack_start(body, True, True, 0)

        self.search = Gtk.Entry()
        self.search.get_style_context().add_class("search")
        self.search.set_placeholder_text(T("search"))
        self.search.set_icon_from_icon_name(Gtk.EntryIconPosition.PRIMARY, "system-search-symbolic")
        self.search.connect("changed", self.on_search)
        self.search.connect("activate", self.on_search_enter)
        body.pack_start(self.search, False, False, 4)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(90)
        body.pack_start(self.stack, True, True, 0)

        self.stack.add_named(self.build_home(), "home")
        self.stack.add_named(self.build_all(), "all")
        self.stack.add_named(self.build_results(), "results")

        root.pack_end(self.build_footer(), False, False, 0)

        self.monitor = Gio.AppInfoMonitor.get()
        # una raffica di cambi (230 app del telefono tolte, un .deb che scrive le sue voci): si ricostruisce
        # una volta sola, quando si fermano; prima ogni cambio rifaceva tutto e lo Start restava bloccato
        self._ricarica = 0
        self.monitor.connect("changed", lambda *a: self._ricarica_dopo())
        self.recent = Gtk.RecentManager.get_default()
        self.recent.connect("changed", lambda *a: self.fill_recent())
        self.reload()
        root.show_all()

    # ---------- costruzione ----------
    def header(self, title, button_text=None, cb=None, back=False):
        box = Gtk.Box(spacing=8)
        lab = Gtk.Label(label=title, xalign=0)
        lab.get_style_context().add_class("section")
        box.pack_start(lab, True, True, 0)
        if button_text:
            b = Gtk.Button()
            b.get_style_context().add_class("pill")
            inner = Gtk.Box(spacing=4)
            if back:
                inner.pack_start(Gtk.Label(label="‹"), False, False, 0)
            inner.pack_start(Gtk.Label(label=button_text), False, False, 0)
            if not back:
                inner.pack_start(Gtk.Label(label="›"), False, False, 0)
            b.add(inner)
            b.connect("clicked", cb)
            box.pack_end(b, False, False, 0)
        box.set_margin_start(px(14))
        box.set_margin_end(px(14))
        return box

    def build_home(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.pack_start(self.header(T("pinned"), T("all"), lambda *a: self.show_page("all")), False, False, 0)
        self.grid = Gtk.FlowBox()
        self.grid.set_selection_mode(Gtk.SelectionMode.NONE)
        self.grid.set_homogeneous(True)
        self.grid.set_min_children_per_line(6)
        self.grid.set_max_children_per_line(6)
        self.grid.set_row_spacing(2)
        self.grid.set_column_spacing(2)
        self.grid.set_valign(Gtk.Align.START)
        self.grid.set_size_request(-1, 3 * px(92))
        box.pack_start(self.grid, False, False, 0)

        box.pack_start(self.header(T("recent")), False, False, 8)
        self.recent_grid = Gtk.Grid(column_spacing=8, row_spacing=2, column_homogeneous=True)
        box.pack_start(self.recent_grid, True, True, 0)
        return box

    def build_all(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.pack_start(self.header(T("all"), T("back"), lambda *a: self.show_page("home"), back=True), False, False, 0)
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.all_list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.all_list.set_margin_start(px(60))
        self.all_list.set_margin_end(px(60))
        sw.add(self.all_list)
        self.all_scroll = sw
        box.pack_start(sw, True, True, 0)
        return box

    def build_results(self):
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        sw.add(self.results)
        return sw

    def build_footer(self):
        foot = Gtk.Box(spacing=10)
        foot.get_style_context().add_class("footer")
        name = os.environ.get("TOD_USER_FULLNAME") or os.environ.get("TOD_USER") or os.environ.get("USER") or ""
        name = name[:1].upper() + name[1:]
        av = Gtk.Label(label=(name[:1] or "?"))
        av.get_style_context().add_class("avatar")
        foot.pack_start(av, False, False, 0)
        lab = Gtk.Label(label=name, xalign=0)
        lab.get_style_context().add_class("name")
        foot.pack_start(lab, False, False, 0)

        power = Gtk.Button()
        power.get_style_context().add_class("row")
        power.set_tooltip_text(T("power"))
        img = Gtk.Image.new_from_icon_name("system-shutdown-symbolic", Gtk.IconSize.LARGE_TOOLBAR)
        power.add(img)
        menu = Gtk.Menu()
        item = Gtk.MenuItem(label=T("power"))
        item.connect("activate", lambda *a: self.power_off())
        menu.append(item)
        menu.show_all()
        power.connect("clicked", lambda b: menu.popup_at_widget(b, Gdk.Gravity.NORTH, Gdk.Gravity.SOUTH, None))
        foot.pack_end(power, False, False, 0)
        return foot

    # ---------- dati ----------
    def pinned_ids(self):
        try:
            with open(PINNED_FILE) as f:
                return [line.strip() for line in f if line.strip()]
        except OSError:
            return list(DEFAULT_PINNED)

    def save_pinned(self, ids):
        os.makedirs(CONF, exist_ok=True)
        with open(PINNED_FILE, "w") as f:
            f.write("\n".join(ids) + "\n")

    def _ricarica_dopo(self, ms=1500):
        if self._ricarica:
            GLib.source_remove(self._ricarica)
        self._ricarica = GLib.timeout_add(ms, self._ricarica_ora)

    def _ricarica_ora(self):
        self._ricarica = 0
        self.reload()
        return False

    def reload(self):
        seen = set()
        apps = []
        for a in Gio.AppInfo.get_all():
            if not a.should_show() or not isinstance(a, Gio.DesktopAppInfo):
                continue
            if a.get_id() in seen or SHORT_NAMES.get(a.get_id(), 1) is None:
                continue
            # come Windows: i singoli pannelli stanno dentro "Impostazioni", non nello Start
            if "X-XFCE-SettingsDialog" in (a.get_categories() or "").split(";"):
                continue
            seen.add(a.get_id())
            apps.append(a)
        apps.sort(key=lambda a: short_name(a).casefold())
        self.apps = apps
        self.by_id = {a.get_id(): a for a in apps}
        self.fill_pinned()
        self.fill_all()
        self.fill_recent()

    def tile(self, info):
        b = Gtk.Button()
        b.get_style_context().add_class("tile")
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        v.pack_start(app_icon(info, px(40)), False, False, 0)
        lab = Gtk.Label(label=short_name(info))
        lab.get_style_context().add_class("tile-label")
        lab.set_ellipsize(Pango.EllipsizeMode.END)
        lab.set_max_width_chars(11)
        lab.set_width_chars(11)
        v.pack_start(lab, False, False, 0)
        b.add(v)
        b.set_tooltip_text(info.get_display_name())
        b.connect("clicked", lambda *a: self.launch(info))
        b.connect("button-press-event", self.on_app_button, info)
        return b

    def row(self, info, size=28, sub=None):
        b = Gtk.Button()
        b.get_style_context().add_class("row")
        h = Gtk.Box(spacing=12)
        h.pack_start(app_icon(info, px(size)), False, False, 0)
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        v.set_valign(Gtk.Align.CENTER)
        lab = Gtk.Label(label=short_name(info), xalign=0)
        lab.set_ellipsize(Pango.EllipsizeMode.END)
        v.pack_start(lab, False, False, 0)
        if sub:
            s = Gtk.Label(label=sub, xalign=0)
            s.get_style_context().add_class("sub")
            v.pack_start(s, False, False, 0)
        h.pack_start(v, True, True, 0)
        b.add(h)
        b.connect("clicked", lambda *a: self.launch(info))
        b.connect("button-press-event", self.on_app_button, info)
        return b

    def fill_pinned(self):
        for c in self.grid.get_children():
            self.grid.remove(c)
        for i in self.pinned_ids():
            if i in self.by_id:
                self.grid.add(self.tile(self.by_id[i]))
            if len(self.grid.get_children()) >= 18:
                break
        self.grid.show_all()

    def fill_all(self):
        for c in self.all_list.get_children():
            self.all_list.remove(c)
        last = None
        for a in self.apps:
            first = short_name(a)[:1].upper()
            if not first.isalpha():
                first = "#"
            if first != last:
                lab = Gtk.Label(label=first, xalign=0)
                lab.get_style_context().add_class("letter")
                self.all_list.pack_start(lab, False, False, 0)
                last = first
            self.all_list.pack_start(self.row(a, sub=T("phone_app") if is_phone_app(a) else None), False, False, 0)
        self.all_list.show_all()

    def fill_recent(self):
        for c in self.recent_grid.get_children():
            self.recent_grid.remove(c)
        items = []
        for it in self.recent.get_items():
            if it.is_local() and it.exists():
                items.append(it)
        items.sort(key=lambda it: it.get_modified(), reverse=True)
        if not items:
            lab = Gtk.Label(label=T("no_recent"), xalign=0.5)
            lab.get_style_context().add_class("sub")
            lab.set_margin_top(px(30))
            self.recent_grid.attach(lab, 0, 0, 2, 1)
        for n, it in enumerate(items[:6]):
            b = Gtk.Button()
            b.get_style_context().add_class("row")
            h = Gtk.Box(spacing=12)
            img = Gtk.Image.new_from_gicon(it.get_gicon(), Gtk.IconSize.DND)
            img.set_pixel_size(px(32))
            h.pack_start(img, False, False, 0)
            v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            v.set_valign(Gtk.Align.CENTER)
            lab = Gtk.Label(label=it.get_display_name(), xalign=0)
            lab.set_ellipsize(Pango.EllipsizeMode.END)
            lab.set_max_width_chars(22)
            v.pack_start(lab, False, False, 0)
            s = Gtk.Label(label=when(it.get_modified()), xalign=0)
            s.get_style_context().add_class("sub")
            v.pack_start(s, False, False, 0)
            h.pack_start(v, True, True, 0)
            b.add(h)
            uri = it.get_uri()
            b.connect("clicked", lambda _b, u=uri: self.open_uri(u))
            self.recent_grid.attach(b, n % 2, n // 2, 1, 1)
        self.recent_grid.show_all()

    # ---------- ricerca ----------
    def matches(self, q):
        q = q.casefold().strip()
        scored = []
        for a in self.apps:
            name = short_name(a).casefold()
            full = (a.get_display_name() or "").casefold()
            extra = " ".join(filter(None, [
                a.get_generic_name(), a.get_description(), a.get_executable(),
                " ".join(a.get_keywords() or []),
            ])).casefold()
            if name.startswith(q) or full.startswith(q):
                s = 0
            elif any(w.startswith(q) for w in (name + " " + full).split()):
                s = 1
            elif q in name or q in full:
                s = 2
            elif q in extra:
                s = 3
            else:
                continue
            scored.append((s, name, a))
        scored.sort(key=lambda x: (x[0], x[1]))
        return [a for _s, _n, a in scored]

    def on_search(self, entry):
        q = entry.get_text()
        if not q.strip():
            self.show_page("home")
            return
        for c in self.results.get_children():
            self.results.remove(c)
        found = self.matches(q)
        self.found = found
        if not found:
            lab = Gtk.Label(label=T("none"))
            lab.get_style_context().add_class("sub")
            lab.set_margin_top(px(40))
            self.results.pack_start(lab, False, False, 0)
        else:
            self.results.pack_start(self.header(T("best")), False, False, 4)
            best = Gtk.Button()
            best.get_style_context().add_class("row")
            bb = Gtk.Box(spacing=18)
            bb.get_style_context().add_class("best")
            bb.pack_start(app_icon(found[0], px(56)), False, False, 0)
            v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            v.set_valign(Gtk.Align.CENTER)
            t = Gtk.Label(label=short_name(found[0]), xalign=0)
            t.get_style_context().add_class("section")
            v.pack_start(t, False, False, 0)
            s = Gtk.Label(label=kind_label(found[0]), xalign=0)
            s.get_style_context().add_class("sub")
            v.pack_start(s, False, False, 0)
            bb.pack_start(v, True, True, 0)
            best.add(bb)
            best.connect("clicked", lambda *a: self.launch(found[0]))
            self.results.pack_start(best, False, False, 0)
            if len(found) > 1:
                self.results.pack_start(self.header(T("apps")), False, False, 8)
                for a in found[1:12]:
                    self.results.pack_start(self.row(a, 24, T("phone_app") if is_phone_app(a) else None), False, False, 0)
        self.results.show_all()
        self.stack.set_visible_child_name("results")

    def on_search_enter(self, entry):
        if entry.get_text().strip() and getattr(self, "found", None):
            self.launch(self.found[0])

    # ---------- azioni ----------
    def on_app_button(self, widget, event, info):
        if event.button != 3:
            return False
        menu = Gtk.Menu()
        ids = self.pinned_ids()
        if info.get_id() in ids:
            item = Gtk.MenuItem(label=T("unpin"))
            item.connect("activate", lambda *a: self.set_pinned(info.get_id(), False))
        else:
            item = Gtk.MenuItem(label=T("pin"))
            item.connect("activate", lambda *a: self.set_pinned(info.get_id(), True))
        menu.append(item)
        if info.get_filename():
            on_desk = os.path.exists(self.desktop_path(info))
            item = Gtk.MenuItem(label=T("desk_del" if on_desk else "desk_add"))
            item.connect("activate", lambda *a: self.set_on_desktop(info, not on_desk))
            menu.append(item)
        menu.show_all()
        menu.attach_to_widget(widget, None)
        menu.popup_at_pointer(event)
        return True

    @staticmethod
    def desktop_path(info):
        desk = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP) or os.path.expanduser("~/Desktop")
        return os.path.join(desk, os.path.basename(info.get_filename()))

    def set_on_desktop(self, info, on):
        """Collegamento sulla scrivania, come "Invia a → Desktop" di Windows. È una copia della voce del
        menu, segnata come fidata (checksum di xfdesktop): così mostra nome e icona veri, senza avvisi."""
        import hashlib
        import shutil
        dst = self.desktop_path(info)
        try:
            if not on:
                os.remove(dst)
                return
            shutil.copyfile(info.get_filename(), dst)
            os.chmod(dst, 0o755)
            with open(dst, "rb") as f:
                somma = hashlib.sha256(f.read()).hexdigest()
            Gio.File.new_for_path(dst).set_attribute_string("metadata::xfce-exe-checksum", somma,
                                                             Gio.FileQueryInfoFlags.NONE, None)
        except (OSError, GLib.Error) as e:
            print("scrivania:", e, file=sys.stderr)

    def set_pinned(self, app_id, on):
        ids = [i for i in self.pinned_ids() if i != app_id]
        if on:
            ids.append(app_id)
        self.save_pinned(ids)
        self.fill_pinned()

    def launch(self, info):
        self.hide_menu()
        ctx = Gdk.Display.get_default().get_app_launch_context()
        if info.get_boolean("Terminal"):   # Gio qui non trova un terminale: lo apriamo noi
            cmd = " ".join(w for w in (info.get_commandline() or "").split() if not w.startswith("%"))
            subprocess.Popen(["xfce4-terminal", "-x", "sh", "-c", cmd], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        try:
            info.launch([], ctx)
        except GLib.Error as e:
            print("tod-start:", e, file=sys.stderr)

    def open_uri(self, uri):
        self.hide_menu()
        try:
            Gio.AppInfo.launch_default_for_uri(uri, Gdk.Display.get_default().get_app_launch_context())
        except GLib.Error:
            subprocess.Popen(["xdg-open", uri], start_new_session=True)

    def power_off(self):
        self.hide_menu()
        subprocess.Popen([os.path.join(PREFIX, "bin", "tod"), "spegni"], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def show_page(self, name):
        self.stack.set_visible_child_name(name)
        if name == "all":
            self.all_scroll.get_vadjustment().set_value(0)

    # ---------- apri/chiudi ----------
    def place(self):
        display = Gdk.Display.get_default()
        mon = display.get_primary_monitor() or display.get_monitor(0)
        wa = mon.get_workarea()
        w, h = px(W), min(px(H), wa.height - px(24))
        self.resize(w, h)
        self.move(wa.x + (wa.width - w) // 2, wa.y + wa.height - h - px(12))

    def _ancora(self, _w, alloc):
        """il bordo basso alla stessa distanza dalla barra dei pannelli (tod-pannelli.py), qualunque
        sia l'altezza vera della finestra"""
        if not self.get_visible():
            return
        display = Gdk.Display.get_default()
        wa = (display.get_primary_monitor() or display.get_monitor(0)).get_workarea()
        x, y = wa.x + (wa.width - alloc.width) // 2, wa.y + wa.height - alloc.height - px(12)
        if self.get_position() != (x, y):
            GLib.idle_add(lambda: self.move(x, y) and False)

    def home_apps_check(self):
        """App installate da un programma nella cartella personale del container (AppImage dei launcher):
        se la loro cartella è cambiata, "tod cx sync-home" le mette nello Start (il menu si aggiorna da solo,
        con il controllo delle app di GIO)."""
        prefix = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
        conf = {}
        try:
            for line in open(os.path.join(CONF, "tod.conf")):
                k, _, v = line.strip().partition("=")
                conf[k] = v.strip('"')
        except OSError:
            pass
        distro, user = conf.get("CX_DISTRO", "debian"), conf.get("CX_USER", "dex")
        for d in (f"{prefix}/var/lib/proot-distro/containers/{distro}/rootfs/home/{user}/.local/share/applications",
                  f"{prefix}/var/lib/proot-distro/installed-rootfs/{distro}/home/{user}/.local/share/applications"):
            try:
                m = os.stat(d).st_mtime
            except OSError:
                continue
            prima = getattr(self, "home_apps_mtime", None)
            if m != prima:
                if prima is not None:   # la prima volta l'ha già fatto l'avvio del desktop (cx_sync_apps)
                    subprocess.Popen([os.path.join(prefix, "bin/tod"), "cx", "sync-home"], start_new_session=True,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self.home_apps_mtime = m
            return

    def show_menu(self):
        self.home_apps_check()
        self.search.set_text("")
        self.show_page("home")
        self.fill_recent()
        self.place()
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
        self.search.grab_focus()

    def hide_menu(self):
        if self.get_visible():
            self.hidden_at = time.monotonic()
            self.hide()

    def ack(self):
        # risposta a tod-start: "sono vivo e ho fatto quello che chiedevi"; senza, lui ci riavvia
        try:
            with open(REQFILE) as f:
                token = f.read()
            with open(ACKFILE, "w") as f:
                f.write(token)
        except OSError:
            pass

    def apply_theme(self):   # anche il colore d'accento: cambiandolo, il tema si ricarica e passa di qui
        a, light = accent()
        self.prov.load_from_data(scaled_css().replace(b"#005fb8", a))
        self.dark_prov.load_from_data(CSS_DARK.replace(b"#60cdff", light) if dark_theme() else b"")

    def on_mapped(self):
        if getattr(self, "asked_at", None):
            tlog(f"mostrato dopo {time.monotonic() - self.asked_at:.2f}s dal clic")
            self.asked_at = None
        self.ack()

    def toggle(self):
        self.asked_at = time.monotonic()
        if self.get_visible():
            self.hide_menu()
            self.ack()
        elif time.monotonic() - self.hidden_at > 0.35:   # clic sul tasto Start mentre era aperto
            self.show_menu()   # risponde quando la finestra è davvero sullo schermo (map-event)
            if self.get_mapped():
                self.ack()
        else:
            self.ack()
        return GLib.SOURCE_CONTINUE

    def on_focus_out(self, *a):
        # i menu a comparsa (tasto destro, Spegni) prendono il fuoco: non è un "clic fuori"
        GLib.timeout_add(120, self._maybe_hide)
        return False

    def _maybe_hide(self):
        if self.get_visible() and not self.is_active() and not self._menu_open():
            self.hide_menu()
        return False

    def _menu_open(self):
        return any(isinstance(w, Gtk.Window) and w.get_visible() and w.get_type_hint() in (
            Gdk.WindowTypeHint.POPUP_MENU, Gdk.WindowTypeHint.DROPDOWN_MENU) for w in Gtk.Window.list_toplevels())

    def on_key(self, _w, event):
        if event.keyval == Gdk.KEY_Escape:
            if self.search.get_text():
                self.search.set_text("")
            elif self.stack.get_visible_child_name() != "home":
                self.show_page("home")
            else:
                self.hide_menu()
            return True
        if event.keyval in (Gdk.KEY_Super_L, Gdk.KEY_Super_R):
            self.hide_menu()
            return True
        return False


def main():
    show = "--show" in sys.argv
    # Android (ART) tiene SIGUSR1 bloccato e i processi avviati da Termux lo ereditano: il segnale
    # del tasto Start restava in sospeso per sempre, e dopo l'attesa si avviava un menu nuovo
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGUSR1})
    # pid e segnali subito, prima di costruire il menu (che sotto carico richiede secondi):
    # un clic sul tasto Start in quel momento non avvia un secondo menu, viene messo in coda
    holder = {"win": None, "pending": show}

    def on_usr1():
        if holder["win"] is None:
            tlog("clic mentre il menu si prepara: in coda")
            holder["pending"] = not holder["pending"]
            try:   # risposta subito: il menu c'è, si sta solo caricando
                with open(REQFILE) as f, open(ACKFILE, "w") as g:
                    g.write(f.read().strip())
            except OSError:
                pass
        else:
            holder["win"].toggle()
        return GLib.SOURCE_CONTINUE

    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGUSR1, on_usr1)
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, Gtk.main_quit)
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))
    tlog("avvio" + (" (aperto da un clic)" if show else " (precaricato)"))
    win = holder["win"] = Start()
    tlog("menu pronto")
    if holder["pending"]:
        win.asked_at = T0
        GLib.idle_add(lambda: win.show_menu() and False)
    Gtk.main()
    tlog("uscita")
    try:   # solo se è ancora il nostro: un menu più nuovo può averlo già riscritto
        with open(PIDFILE) as f:
            if f.read().strip() == str(os.getpid()):
                os.unlink(PIDFILE)
    except OSError:
        pass


if __name__ == "__main__":
    main()
