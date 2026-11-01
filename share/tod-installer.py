#!/usr/bin/env python3
"""Installer dei pacchetti .deb, come quello dei .pkg di macOS (doppio clic su un .deb).

  tod-installer.py file.deb

Passi a sinistra (Introduzione → Installazione → Riepilogo), a destra il pacchetto con icona,
nome e descrizione presi dal .deb. Dove va (Termux o Debian), le dipendenze, il menu Start e la
regola "un'app in un solo sistema" li decide tod (`tod _deb_check`, `tod _deb_install`): qui solo
le domande che servono (versione più vecchia, già installata) e niente gergo.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")   # senza, Termux carica Gdk 4 e GTK 3 non parte
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango  # noqa: E402

GLib.set_prgname("tod-deb")   # la barra riconosce la finestra (tod-deb.desktop) e ne mostra l'icona

PREFIX = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
TOD = os.path.join(PREFIX, "bin/tod")
ITALIAN = os.environ.get("LANGUAGE", os.environ.get("LANG", "")).startswith("it")


def T(it, en):
    return it if ITALIAN else en


def field(deb, name):
    try:
        return subprocess.run(["dpkg-deb", "-f", deb, name], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def check(deb):
    out = {}
    try:
        r = subprocess.run(["bash", TOD, "_deb_check", deb], capture_output=True, text=True, timeout=120)
        for line in r.stdout.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k] = v
    except (OSError, subprocess.TimeoutExpired):
        pass
    return out


def contents(deb):
    try:
        r = subprocess.run(["dpkg-deb", "-c", deb], capture_output=True, text=True, timeout=60)
        return [line.split()[-1] if " -> " not in line else line.split(" -> ")[0].split()[-1]
                for line in r.stdout.splitlines() if line.strip()]
    except (OSError, subprocess.TimeoutExpired):
        return []


def extract(deb, member, dest):
    """Estrae un solo file dal .deb (dpkg-deb --fsys-tarfile | tar)."""
    try:
        tar = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", deb], stdout=subprocess.PIPE)
        with open(dest, "wb") as f:
            r = subprocess.run(["tar", "-xOf", "-", member], stdin=tar.stdout, stdout=f,
                               stderr=subprocess.DEVNULL, timeout=120)
        tar.wait(30)
        return r.returncode == 0 and os.path.getsize(dest) > 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def app_info(deb, files, tmp):
    """Nome, icona e id della voce di menu, se il pacchetto contiene un'app."""
    desk = [f for f in files if "/share/applications/" in f and f.endswith(".desktop")]
    info = {"desktop": None, "name": None, "icon": None}
    for d in desk:
        p = os.path.join(tmp, "app.desktop")
        if not extract(deb, d, p):
            continue
        name = icon = None
        hidden = False
        main = True
        for line in open(p, errors="replace"):
            if line.startswith("["):
                main = line.strip() == "[Desktop Entry]"
            elif not main:
                continue
            elif line.startswith("NoDisplay=true"):
                hidden = True
            elif line.startswith(f"Name[{'it' if ITALIAN else 'en'}]=") or (line.startswith("Name=") and not name):
                name = line.split("=", 1)[1].strip()
            elif line.startswith("Icon="):
                icon = line[5:].strip()
        if hidden:
            continue
        info.update(desktop=os.path.basename(d), name=name)
        if icon:
            info["icon"] = find_icon(deb, files, icon, tmp)
        break
    return info


def find_icon(deb, files, icon, tmp):
    if icon.startswith("/"):
        cands = [f for f in files if f.lstrip(".") == icon]
    else:
        cands = [f for f in files if re.search(rf"/(icons|pixmaps)/.*/?{re.escape(icon)}\.(png|svg|xpm)$", f)]

    def size(f):
        m = re.search(r"/(\d+)x\d+/", f)
        return (1000 if f.endswith(".svg") else int(m.group(1)) if m else 48)
    for f in sorted(cands, key=size, reverse=True):
        dest = os.path.join(tmp, "icon" + os.path.splitext(f)[1])
        if extract(deb, f, dest):
            return dest
    return None


def human(kib):
    try:
        b = int(kib) * 1024
    except ValueError:
        return ""
    for unit in ("byte", "KB", "MB", "GB"):
        if b < 1024 or unit == "GB":
            return f"{b:.0f} {unit}" if unit in ("byte", "KB") else f"{b:.1f} {unit}".replace(".", "," if ITALIAN else ".")
        b /= 1024


class Installer(Gtk.Window):
    STEPS = [("intro", T("Introduzione", "Introduction")), ("install", T("Installazione", "Installation")),
             ("done", T("Riepilogo", "Summary"))]

    def __init__(self, deb):
        super().__init__(title=T("Installa pacchetto", "Install package"))
        self.deb = deb
        self.tmp = tempfile.mkdtemp(prefix="tod-installer-")
        self.set_default_size(720, 500)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_icon_name("system-software-install")
        self.connect("destroy", self.quit)
        css = Gtk.CssProvider()
        css.load_from_data(b"""
            .side { background-color: alpha(@theme_fg_color, 0.04); }
            .step { padding: 6px 4px; opacity: 0.55; }
            .step.current { opacity: 1; font-weight: bold; }
            .big { font-size: 20pt; font-weight: bold; }
            .warn { color: #b25e00; }
        """)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        outer = Gtk.Box()
        self.add(outer)
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, margin=20)
        side.set_size_request(190, -1)
        side.get_style_context().add_class("side")
        outer.pack_start(side, False, False, 0)
        self.side_icon = Gtk.Image.new_from_icon_name("system-software-install", Gtk.IconSize.DIALOG)
        self.side_icon.set_pixel_size(64)
        self.side_icon.set_margin_bottom(16)
        side.pack_start(self.side_icon, False, False, 0)
        self.step_labels = {}
        for key, title in self.STEPS:
            lab = Gtk.Label(label="•  " + title, xalign=0)
            lab.get_style_context().add_class("step")
            side.pack_start(lab, False, False, 0)
            self.step_labels[key] = lab

        right = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin=24, spacing=16)
        outer.pack_start(right, True, True, 0)
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT)
        right.pack_start(self.stack, True, True, 0)
        buttons = Gtk.Box(spacing=8)
        right.pack_end(buttons, False, False, 0)
        self.back = Gtk.Button(label=T("Annulla", "Cancel"))
        self.back.connect("clicked", lambda *a: self.destroy())
        buttons.pack_start(self.back, False, False, 0)
        self.next = Gtk.Button(label=T("Installa", "Install"))
        self.next.get_style_context().add_class("suggested-action")
        self.next.connect("clicked", self.on_next)
        buttons.pack_end(self.next, False, False, 0)
        self.extra = Gtk.Button()   # "Apri" sull'app già installata, o dopo l'installazione
        self.extra.set_no_show_all(True)
        self.extra.connect("clicked", lambda *a: self.open_app())
        buttons.pack_end(self.extra, False, False, 0)

        self.stack.add_named(self.loading_page(), "loading")
        self.go("loading")
        self.next.set_sensitive(False)
        threading.Thread(target=self.inspect, daemon=True).start()

    # --- pagine ----------------------------------------------------------------------------
    def loading_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, valign=Gtk.Align.CENTER)
        sp = Gtk.Spinner()
        sp.start()
        box.pack_start(sp, False, False, 0)
        box.pack_start(Gtk.Label(label=T("Lettura del pacchetto…", "Reading the package…")), False, False, 0)
        return box

    def go(self, page):
        self.stack.set_visible_child_name(page)
        for key, lab in self.step_labels.items():
            ctx = lab.get_style_context()
            (ctx.add_class if key == page or (page == "loading" and key == "intro") else ctx.remove_class)("current")

    def inspect(self):
        info = {k: field(self.deb, k) for k in ("Package", "Version", "Description", "Installed-Size",
                                                 "Maintainer", "Architecture", "Homepage")}
        files = contents(self.deb)
        app = app_info(self.deb, files, self.tmp)
        chk = check(self.deb)
        GLib.idle_add(self.show_intro, info, app, chk)

    def show_intro(self, info, app, chk):
        self.info, self.app, self.chk = info, app, chk
        name = app.get("name") or info["Package"] or os.path.basename(self.deb)
        self.app_name = name
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        head = Gtk.Box(spacing=16)
        box.pack_start(head, False, False, 0)
        img = Gtk.Image()
        if app.get("icon"):
            try:
                img.set_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_size(app["icon"], 72, 72))
                self.side_icon.set_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_size(app["icon"], 64, 64))
            except GLib.Error:
                img.set_from_icon_name("package-x-generic", Gtk.IconSize.DIALOG)
        else:
            img.set_from_icon_name("package-x-generic", Gtk.IconSize.DIALOG)
        img.set_pixel_size(72)
        head.pack_start(img, False, False, 0)
        t = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, valign=Gtk.Align.CENTER)
        head.pack_start(t, True, True, 0)
        title = Gtk.Label(label=name, xalign=0)
        title.get_style_context().add_class("big")
        title.set_line_wrap(True)
        t.pack_start(title, False, False, 0)
        sub = T("Versione", "Version") + " " + (info["Version"] or "?")
        if info["Installed-Size"]:
            sub += " · " + T("occupa circa ", "takes about ") + human(info["Installed-Size"])
        s = Gtk.Label(label=sub, xalign=0)
        s.get_style_context().add_class("dim-label")
        t.pack_start(s, False, False, 0)

        desc = info["Description"].splitlines()
        text = (desc[0] if desc else "") + ("\n\n" + "\n".join(l.strip() if l.strip() != "." else ""
                                                                for l in desc[1:]) if len(desc) > 1 else "")
        lab = Gtk.Label(label=text.strip(), xalign=0, yalign=0)
        lab.set_line_wrap(True)
        lab.set_selectable(True)
        sw = Gtk.ScrolledWindow(vexpand=True)
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.add(lab)
        box.pack_start(sw, True, True, 0)

        # avvisi: solo quando c'è da decidere qualcosa
        target, cmp_, owner = chk.get("target", ""), chk.get("cmp", "none"), chk.get("owner", "")
        note = None
        self.next.set_label(T("Installa", "Install"))
        self.next.set_sensitive(True)
        if target.startswith("non-arm"):
            arch = target.split(":", 1)[-1]
            note = T(f"Questo pacchetto è fatto per computer con processore {arch} (per esempio i PC Intel e AMD) "
                     "e non può funzionare su questo telefono. Cerca la versione «arm64» o «aarch64».",
                     f"This package is built for {arch} computers (e.g. Intel and AMD PCs) and cannot run on this "
                     "phone. Look for the «arm64» or «aarch64» version.")
            self.next.set_sensitive(False)
        elif owner:
            note = T(f"Quest'app è già installata ({owner}): non serve una seconda copia.",
                     f"This app is already installed ({owner}): no second copy needed.")
            self.next.set_sensitive(False)
            self.offer_open(owner)
        elif cmp_ == "same":
            note = T("Questa versione è già installata.", "This version is already installed.")
            self.next.set_label(T("Reinstalla", "Reinstall"))
            self.offer_open()
        elif cmp_ == "older":
            note = T(f"È già installata una versione più recente ({chk.get('installed')}). "
                     "Se continui la sostituisci con questa, più vecchia.",
                     f"A newer version ({chk.get('installed')}) is already installed. "
                     "Continuing replaces it with this older one.")
            self.next.set_label(T("Sostituisci", "Replace"))
        elif cmp_ == "newer":
            note = T(f"Aggiorna la versione installata ({chk.get('installed')}).",
                     f"Updates the installed version ({chk.get('installed')}).")
            self.next.set_label(T("Aggiorna", "Update"))
        if note:
            n = Gtk.Label(label=note, xalign=0)
            n.set_line_wrap(True)
            n.get_style_context().add_class("warn")
            box.pack_start(n, False, False, 0)

        # dettagli tecnici, chiusi: per chi li vuole
        exp = Gtk.Expander(label=T("Dettagli", "Details"))
        grid = Gtk.Grid(column_spacing=12, row_spacing=4, margin_top=6)
        rows = [(T("Pacchetto", "Package"), info["Package"]), (T("Architettura", "Architecture"), info["Architecture"]),
                (T("Autore", "Maintainer"), info["Maintainer"]), (T("Sito", "Homepage"), info["Homepage"]),
                (T("Dove va", "Goes to"), {"termux": "Termux", "container": "Debian"}.get(target, target)),
                ("File", self.deb)]
        for i, (k, v) in enumerate(r for r in rows if r[1]):
            a = Gtk.Label(label=k, xalign=0)
            a.get_style_context().add_class("dim-label")
            b = Gtk.Label(label=v, xalign=0, selectable=True)
            b.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            grid.attach(a, 0, i, 1, 1)
            grid.attach(b, 1, i, 1, 1)
        exp.add(grid)
        box.pack_start(exp, False, False, 0)
        self.stack.add_named(box, "intro")
        box.show_all()
        self.go("intro")

    def offer_open(self, owner=None):
        self.extra.set_label(T("Apri", "Open"))
        self.extra.show()

    def on_next(self, *a):
        page = self.stack.get_visible_child_name()
        if page == "intro":
            self.start_install()
        elif page == "done":
            if self.trash.get_active():
                try:
                    Gio.File.new_for_path(self.deb).trash(None)
                except GLib.Error:
                    pass
            self.destroy()

    # --- installazione ------------------------------------------------------------------------
    def start_install(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, valign=Gtk.Align.CENTER)
        lab = Gtk.Label(label=T(f"Installazione di {self.app_name}…", f"Installing {self.app_name}…"), xalign=0)
        lab.get_style_context().add_class("big")
        lab.set_line_wrap(True)
        box.pack_start(lab, False, False, 0)
        self.bar = Gtk.ProgressBar(show_text=True)
        self.bar.set_text(T("Preparazione…", "Preparing…"))
        box.pack_start(self.bar, False, False, 0)
        exp = Gtk.Expander(label=T("Mostra i dettagli", "Show details"))
        self.log = Gtk.TextView(editable=False, monospace=True, cursor_visible=False)
        self.log.set_wrap_mode(Gtk.WrapMode.CHAR)
        sw = Gtk.ScrolledWindow(min_content_height=160)
        sw.add(self.log)
        exp.add(sw)
        box.pack_start(exp, False, False, 0)
        self.stack.add_named(box, "install")
        box.show_all()
        self.go("install")
        self.next.set_sensitive(False)
        self.back.set_sensitive(False)
        self.extra.hide()
        self.pulse = GLib.timeout_add(120, lambda: self.bar.pulse() or True)
        threading.Thread(target=self.run_install, daemon=True).start()

    def run_install(self):
        stages = [(re.compile(r"^(Get|Scaricamento|Prelevamento):"), 0.2, T("Scaricamento dei componenti…", "Downloading components…")),
                  (re.compile(r"^(Unpacking|Estrazione di|Preparing to unpack)"), 0.5, T("Copia dei file…", "Copying files…")),
                  (re.compile(r"^(Setting up|Configurazione di)"), 0.8, T("Configurazione…", "Configuring…")),
                  (re.compile(r"^(Processing triggers|Elaborazione)"), 0.9, T("Ultimi ritocchi…", "Finishing…"))]
        tail = []
        try:
            p = subprocess.Popen(["bash", TOD, "_deb_install", self.deb], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, stdin=subprocess.DEVNULL,
                                 env=dict(os.environ, DEBIAN_FRONTEND="noninteractive"))
            for line in p.stdout:
                line = re.sub(r"\x1b\[[0-9;]*m", "", line)
                tail = (tail + [line.rstrip()])[-12:]
                for rx, frac, text in stages:
                    if rx.search(line.strip()):
                        GLib.idle_add(self.progress, frac, text)
                        break
                GLib.idle_add(self.append, line)
            rc = p.wait()
        except OSError as e:
            rc, tail = 1, [str(e)]
        GLib.idle_add(self.finish, rc == 0, tail)

    def progress(self, frac, text):
        if self.pulse:
            GLib.source_remove(self.pulse)
            self.pulse = None
        self.bar.set_fraction(max(self.bar.get_fraction(), frac))
        self.bar.set_text(text)

    def append(self, line):
        buf = self.log.get_buffer()
        buf.insert(buf.get_end_iter(), line)
        self.log.scroll_to_iter(buf.get_end_iter(), 0, False, 0, 0)

    def finish(self, ok, tail):
        if self.pulse:
            GLib.source_remove(self.pulse)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, valign=Gtk.Align.CENTER)
        icon = Gtk.Image.new_from_icon_name("emblem-ok-symbolic" if ok else "dialog-error-symbolic", Gtk.IconSize.DIALOG)
        icon.set_pixel_size(64)
        box.pack_start(icon, False, False, 0)
        lab = Gtk.Label(label=T("Installazione completata", "Installation complete") if ok
                        else T("Installazione non riuscita", "Installation failed"))
        lab.get_style_context().add_class("big")
        box.pack_start(lab, False, False, 0)
        if ok:
            sub = T(f"{self.app_name} è pronta. La trovi nel menu Start.", f"{self.app_name} is ready. Find it in Start.") \
                if self.app.get("desktop") else T("Il pacchetto è stato installato.", "The package was installed.")
        else:
            useful = [l for l in tail if l.strip() and not l.startswith(("Reading", "Lettura", "Building", "Generazione"))]
            sub = T("Non è stato possibile completare l'installazione:", "The installation could not be completed:") + \
                "\n" + "\n".join(useful[-3:])
        s = Gtk.Label(label=sub, wrap=True, justify=Gtk.Justification.CENTER, selectable=not ok)
        box.pack_start(s, False, False, 0)
        self.trash = Gtk.CheckButton(label=T("Sposta il file del pacchetto nel Cestino", "Move the package file to the Trash"))
        self.trash.set_halign(Gtk.Align.CENTER)
        self.trash.set_active(ok and os.path.dirname(os.path.realpath(self.deb)).endswith(("Download", "Downloads")))
        if ok:
            box.pack_start(self.trash, False, False, 0)
        self.stack.add_named(box, "done")
        box.show_all()
        self.go("done")
        self.next.set_label(T("Chiudi", "Close"))
        self.next.set_sensitive(True)
        self.back.hide()
        if ok and self.app.get("desktop"):
            self.offer_open()

    def open_app(self):
        base = self.app.get("desktop")
        ids = [base, "tod-cx-" + base] if base else []
        for i in ids:
            try:
                info = Gio.DesktopAppInfo.new(i)
            except TypeError:
                info = None
            if info:
                info.launch([], Gdk.Display.get_default().get_app_launch_context())
                self.destroy()
                return
        self.extra.set_sensitive(False)

    def quit(self, *a):
        shutil.rmtree(self.tmp, ignore_errors=True)
        Gtk.main_quit()


def main():
    if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
        d = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.CLOSE,
                              text=T("Pacchetto non trovato", "Package not found"))
        d.format_secondary_text(sys.argv[1] if len(sys.argv) > 1 else "")
        d.run()
        return 1
    win = Installer(os.path.abspath(sys.argv[1]))
    win.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
